use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

use coding_bot_agent::{AgentError, CodingAgent, LanguageModel};
use coding_bot_config::Config;
use coding_bot_domain::{CodingJob, DraftPullRequest, OpenedPullRequest, PullRequestReport};
use coding_bot_github::{GitHubAppApi, GitHubError};
use coding_bot_store::{PostgresStore, StoreError};
use metrics::{counter, histogram};
use thiserror::Error;
use tokio::sync::{oneshot, watch};
use tracing::{error, info, warn};
use uuid::Uuid;

use crate::{
    load_repository_config, proposal_branch, pull_request_title, run_controller_validation,
    CommandPolicy, DockerSandbox, DockerSandboxConfig, GitWorkflow, GitWorkflowError, PathPolicy,
    RepositoryConfigError, SandboxError, SandboxToolExecutor,
};

const START_COMMENT: &str =
    "I’m investigating this issue and will open a draft pull request if I can produce a validated fix.";

pub struct Worker {
    store: Arc<PostgresStore>,
    github: Arc<dyn GitHubAppApi>,
    model: Arc<dyn LanguageModel>,
    config: Arc<Config>,
    worker_id: String,
}

impl Worker {
    #[must_use]
    pub fn new(
        store: Arc<PostgresStore>,
        github: Arc<dyn GitHubAppApi>,
        model: Arc<dyn LanguageModel>,
        config: Arc<Config>,
    ) -> Self {
        Self {
            store,
            github,
            model,
            config,
            worker_id: format!("worker-{}", Uuid::new_v4().simple()),
        }
    }

    pub async fn run(self: Arc<Self>, mut shutdown: watch::Receiver<bool>) {
        info!(worker_id = %self.worker_id, "coding worker started");
        loop {
            if *shutdown.borrow() {
                break;
            }
            match self
                .store
                .claim(
                    &self.worker_id,
                    Duration::from_secs(self.config.worker_lease_seconds),
                )
                .await
            {
                Ok(Some(job)) => self.process_job(job).await,
                Ok(None) => {
                    tokio::select! {
                        changed = shutdown.changed() => {
                            if changed.is_err() || *shutdown.borrow() {
                                break;
                            }
                        }
                        () = tokio::time::sleep(Duration::from_secs(self.config.worker_poll_seconds)) => {}
                    }
                }
                Err(error) => {
                    error!(worker_id = %self.worker_id, error = %error, "job claim failed");
                    tokio::select! {
                        changed = shutdown.changed() => {
                            if changed.is_err() || *shutdown.borrow() {
                                break;
                            }
                        }
                        () = tokio::time::sleep(Duration::from_secs(self.config.worker_poll_seconds.max(1))) => {}
                    }
                }
            }
        }
        if let Err(error) = self.store.remove_worker(&self.worker_id).await {
            warn!(worker_id = %self.worker_id, error = %error, "failed to remove worker heartbeat");
        }
        info!(worker_id = %self.worker_id, "coding worker stopped");
    }

    async fn process_job(&self, job: CodingJob) {
        let started = Instant::now();
        counter!("coding_bot_jobs_started_total").increment(1);
        info!(
            job_id = %job.id,
            repository = %job.repository_full_name(),
            issue_number = job.issue_number,
            installation_id = job.installation_id,
            attempt = job.attempt,
            "coding job started"
        );

        let cancelled = Arc::new(AtomicBool::new(false));
        let (lease_stop, lease_stopped) = oneshot::channel();
        let lease_task = self.spawn_lease_monitor(&job, cancelled.clone(), lease_stopped);
        let result = tokio::time::timeout(
            Duration::from_secs(self.config.limits.max_job_seconds),
            self.execute_job(&job, cancelled.clone()),
        )
        .await
        .unwrap_or(Err(WorkerError::JobTimeout));
        let _ = lease_stop.send(());
        let _ = lease_task.await;

        match result {
            Ok(opened) => {
                if let Err(error) = self.store.succeed(job.id, job.attempt).await {
                    error!(job_id = %job.id, error = %error, "failed to persist job success");
                }
                counter!("coding_bot_jobs_completed_total").increment(1);
                counter!("coding_bot_pull_requests_opened_total").increment(1);
                info!(
                    job_id = %job.id,
                    pull_request = opened.number,
                    url = %opened.html_url,
                    "coding job succeeded"
                );
            }
            Err(WorkerError::Cancelled) => {
                if let Err(error) = self.store.finish_cancelled(job.id, job.attempt).await {
                    error!(job_id = %job.id, error = %error, "failed to persist cancellation");
                }
                info!(job_id = %job.id, "coding job cancelled");
            }
            Err(error) => {
                let public_reason = error.public_reason();
                if let Err(store_error) = self.store.fail(job.id, job.attempt, public_reason).await
                {
                    error!(job_id = %job.id, error = %store_error, "failed to persist job failure");
                }
                self.post_failure_comment(&job, public_reason).await;
                counter!("coding_bot_jobs_failed_total").increment(1);
                error!(job_id = %job.id, error = %error, "coding job failed");
            }
        }
        histogram!("coding_bot_job_duration_seconds").record(started.elapsed().as_secs_f64());
        let final_status = self
            .store
            .get(job.id)
            .await
            .ok()
            .flatten()
            .map_or_else(|| "unknown".to_owned(), |job| job.status.to_string());
        info!(
            job_id = %job.id,
            job_duration_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
            final_status = %final_status,
            "coding job finished"
        );
    }

    fn spawn_lease_monitor(
        &self,
        job: &CodingJob,
        cancelled: Arc<AtomicBool>,
        mut stop: oneshot::Receiver<()>,
    ) -> tokio::task::JoinHandle<()> {
        let store = self.store.clone();
        let worker_id = self.worker_id.clone();
        let job_id = job.id;
        let attempt = job.attempt;
        let lease = Duration::from_secs(self.config.worker_lease_seconds.max(3));
        tokio::spawn(async move {
            let interval = Duration::from_secs((lease.as_secs() / 3).max(1));
            loop {
                tokio::select! {
                    _ = &mut stop => break,
                    () = tokio::time::sleep(interval) => {
                        match store.cancellation_requested(job_id).await {
                            Ok(true) => {
                                cancelled.store(true, Ordering::Release);
                                break;
                            }
                            Err(error) => {
                                warn!(%job_id, error = %error, "could not check job cancellation");
                            }
                            Ok(false) => {}
                        }
                        match store.renew_lease(&worker_id, job_id, attempt, lease).await {
                            Ok(true) => {}
                            Ok(false) => {
                                cancelled.store(true, Ordering::Release);
                                break;
                            }
                            Err(error) => {
                                error!(%job_id, error = %error, "could not renew job lease");
                                cancelled.store(true, Ordering::Release);
                                break;
                            }
                        }
                    }
                }
            }
        })
    }

    async fn execute_job(
        &self,
        job: &CodingJob,
        cancelled: Arc<AtomicBool>,
    ) -> Result<OpenedPullRequest, WorkerError> {
        let access = self.github.installation(job.installation_id).await?;
        access
            .api
            .comment(
                &job.repository_owner,
                &job.repository_name,
                job.issue_number,
                START_COMMENT,
            )
            .await?;
        let issue = access
            .api
            .issue_context(
                &job.repository_owner,
                &job.repository_name,
                job.issue_number,
            )
            .await?;
        if issue.state != "open" || !issue.labels.iter().any(|label| label == "ai-fix") {
            return Err(WorkerError::IssueNoLongerEligible);
        }
        if cancelled.load(Ordering::Acquire) {
            return Err(WorkerError::Cancelled);
        }

        let sandbox = Arc::new(
            DockerSandbox::create(
                DockerSandboxConfig {
                    docker_binary: self.config.docker_binary.clone(),
                    image: self.config.worker_image.clone(),
                    network: self.config.worker_network.clone(),
                    memory: self.config.worker_memory.clone(),
                    cpus: self.config.worker_cpus.clone(),
                    pids_limit: self.config.worker_pids_limit,
                    workspace_size: self.config.worker_workspace_size.clone(),
                    max_output_bytes: self.config.limits.max_tool_output_bytes,
                },
                job.id,
            )
            .await?,
        );
        let result = self
            .execute_in_sandbox(job, &issue, access.token(), sandbox.clone(), cancelled)
            .await;
        if result.is_err() {
            let _ = sandbox.shutdown().await;
        }
        result
    }

    async fn execute_in_sandbox(
        &self,
        job: &CodingJob,
        issue: &coding_bot_domain::IssueContext,
        clone_token: &str,
        sandbox: Arc<DockerSandbox>,
        cancelled: Arc<AtomicBool>,
    ) -> Result<OpenedPullRequest, WorkerError> {
        sandbox
            .clone_repository(
                self.config.github_web_base_url.as_str(),
                &job.repository_owner,
                &job.repository_name,
                &job.base_branch,
                clone_token,
            )
            .await?;
        let command_policy = CommandPolicy::standard(self.config.limits.max_command_seconds);
        let repository_config = load_repository_config(&sandbox, &command_policy).await?;
        let mut blocked_paths = self.config.blocked_paths.clone();
        blocked_paths.extend(repository_config.additional_blocked_paths);
        let executor = Arc::new(SandboxToolExecutor::new(
            sandbox.clone(),
            PathPolicy::new(&blocked_paths).map_err(SandboxError::from)?,
            command_policy,
            self.config.limits.clone(),
            cancelled.clone(),
            repository_config.validation_commands,
        ));
        let repository_instructions = executor.load_repository_instructions().await?;
        let agent = CodingAgent::new(
            self.model.clone(),
            executor.clone(),
            self.config.limits.clone(),
        );
        let run = agent
            .run_with_repository_instructions(issue, &repository_instructions)
            .await?;
        counter!("coding_bot_agent_steps_total").increment(u64::from(run.steps));
        if cancelled.load(Ordering::Acquire) {
            return Err(WorkerError::Cancelled);
        }

        let audit = executor.final_security_audit().await?;
        if audit.files_modified == 0 || audit.diff_lines == 0 {
            return Err(WorkerError::NoMeaningfulChanges);
        }
        let controller_validation = run_controller_validation(&executor).await?;
        let audit = executor.final_security_audit().await?;
        if audit.files_modified == 0 || audit.diff_lines == 0 {
            return Err(WorkerError::NoMeaningfulChanges);
        }
        let changed_files = executor.changed_files().await?;
        let branch = proposal_branch(job.issue_number, &issue.title, job.id);
        self.store.record_branch(job.id, &branch).await?;
        let git = GitWorkflow::new(&sandbox);
        let _revision = git
            .commit(&branch, job.issue_number, &changed_files)
            .await?;

        if cancelled.load(Ordering::Acquire) || self.store.cancellation_requested(job.id).await? {
            return Err(WorkerError::Cancelled);
        }
        let publish_access = self.github.installation(job.installation_id).await?;
        let still_eligible = publish_access
            .api
            .issue_is_open_with_label(
                &job.repository_owner,
                &job.repository_name,
                job.issue_number,
                "ai-fix",
            )
            .await?;
        if !still_eligible {
            return Err(WorkerError::IssueNoLongerEligible);
        }
        let repository_url = format!(
            "{}/{}/{}.git",
            self.config
                .github_web_base_url
                .as_str()
                .trim_end_matches('/'),
            job.repository_owner,
            job.repository_name
        );
        git.push(&branch, &repository_url, publish_access.token())
            .await?;
        sandbox.shutdown().await?;
        if cancelled.load(Ordering::Acquire) || self.store.cancellation_requested(job.id).await? {
            return Err(WorkerError::Cancelled);
        }

        let mut limitations = run.report.limitations;
        if controller_validation.is_empty() {
            limitations.push("No controller validation plan matched this repository.".to_owned());
        }
        let failed = controller_validation
            .iter()
            .filter(|result| !result.passed)
            .map(|result| format!("`{}`", result.command))
            .collect::<Vec<_>>();
        if !failed.is_empty() {
            limitations.push(format!("Validation failed: {}.", failed.join(", ")));
        }
        let report = PullRequestReport {
            summary: run.report.summary.clone(),
            changes: run.report.changes,
            changed_files,
            validation: controller_validation,
            limitations,
            issue_number: job.issue_number,
        };
        let opened = publish_access
            .api
            .create_draft_pull_request(
                &job.repository_owner,
                &job.repository_name,
                DraftPullRequest {
                    title: pull_request_title(&run.report.summary),
                    head: branch,
                    base: job.base_branch.clone(),
                    body: report.to_markdown(),
                },
            )
            .await?;
        if let Err(error) = self.store.record_pull_request(job.id, opened.number).await {
            error!(
                job_id = %job.id,
                pull_request = opened.number,
                %error,
                "draft PR exists but its number could not be persisted"
            );
        }
        if let Err(error) = publish_access
            .api
            .comment(
                &job.repository_owner,
                &job.repository_name,
                job.issue_number,
                &format!("I created draft PR #{} with a proposed fix.", opened.number),
            )
            .await
        {
            warn!(
                job_id = %job.id,
                pull_request = opened.number,
                %error,
                "draft PR exists but lifecycle comment failed"
            );
        }
        Ok(opened)
    }

    async fn post_failure_comment(&self, job: &CodingJob, reason: &str) {
        let comment = format!(
            "I could not produce a safe fix for this issue.\n\nReason:\n{reason}\n\nNo pull request was created."
        );
        let result = async {
            let access = self.github.installation(job.installation_id).await?;
            access
                .api
                .comment(
                    &job.repository_owner,
                    &job.repository_name,
                    job.issue_number,
                    &comment,
                )
                .await
        }
        .await;
        if let Err(error) = result {
            warn!(job_id = %job.id, error = %error, "failed to post job failure comment");
        }
    }
}

#[derive(Debug, Error)]
pub enum WorkerError {
    #[error(transparent)]
    Agent(#[from] AgentError),
    #[error(transparent)]
    GitHub(#[from] GitHubError),
    #[error(transparent)]
    Git(#[from] GitWorkflowError),
    #[error(transparent)]
    Sandbox(#[from] SandboxError),
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    RepositoryConfig(#[from] RepositoryConfigError),
    #[error("job was cancelled")]
    Cancelled,
    #[error("job exceeded its total time limit")]
    JobTimeout,
    #[error("issue is no longer open with the ai-fix label")]
    IssueNoLongerEligible,
    #[error("agent produced no meaningful changes")]
    NoMeaningfulChanges,
}

impl WorkerError {
    #[must_use]
    pub fn public_reason(&self) -> &'static str {
        match self {
            Self::Cancelled => "The job was cancelled.",
            Self::JobTimeout => "The job exceeded its configured time limit.",
            Self::IssueNoLongerEligible => {
                "The issue was closed or the ai-fix label was removed before publication."
            }
            Self::NoMeaningfulChanges | Self::Git(GitWorkflowError::NoChanges) => {
                "The agent did not produce a meaningful, reviewable change."
            }
            Self::Agent(_) => "The coding agent could not safely complete the task.",
            Self::GitHub(_) => "A required GitHub App operation failed.",
            Self::Git(_) => "The proposal could not be committed or pushed safely.",
            Self::Sandbox(_) => "The isolated workspace failed a safety or execution check.",
            Self::Store(_) => "The durable job state could not be updated safely.",
            Self::RepositoryConfig(_) => {
                "The repository's .ai-fix.toml policy was invalid or unsafe."
            }
        }
    }
}
