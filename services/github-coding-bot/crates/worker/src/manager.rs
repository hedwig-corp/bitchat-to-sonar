use std::{collections::HashMap, sync::Arc};

use chrono::{Duration as ChronoDuration, Utc};
use coding_bot_domain::{ValidationResult, WorkspaceAudit, WorkspaceDescriptor, WorkspaceLimits};
use tokio::sync::{Mutex, RwLock};
use uuid::Uuid;

use crate::{
    proposal_branch, run_controller_validation, CommandPolicy, DockerSandbox, DockerSandboxConfig,
    GitWorkflow, GitWorkflowError, PathPolicy, PolicyError, SandboxError, SandboxToolExecutor,
};

#[derive(Debug, Clone)]
pub struct WorkspaceManagerConfig {
    pub sandbox: DockerSandboxConfig,
    pub limits: WorkspaceLimits,
    pub blocked_paths: Vec<String>,
    pub git_author_name: String,
    pub git_author_email: String,
    pub web_base_url: String,
}

pub struct Workspace {
    descriptor: WorkspaceDescriptor,
    sandbox: Arc<DockerSandbox>,
    executor: SandboxToolExecutor,
    gate: Mutex<()>,
    git_author_name: String,
    git_author_email: String,
    repository_url: String,
}

impl Workspace {
    #[must_use]
    pub fn descriptor(&self) -> &WorkspaceDescriptor {
        &self.descriptor
    }

    pub async fn list_files(
        &self,
        path: Option<&str>,
        max_depth: Option<u8>,
    ) -> Result<String, WorkspaceError> {
        let _guard = self.gate.lock().await;
        Ok(self.executor.list_files(path, max_depth).await?)
    }

    pub async fn search_files(
        &self,
        query: &str,
        path: Option<&str>,
    ) -> Result<String, WorkspaceError> {
        let _guard = self.gate.lock().await;
        Ok(self.executor.search_files(query, path).await?)
    }

    pub async fn read_file(
        &self,
        path: &str,
        start_line: Option<u32>,
        end_line: Option<u32>,
    ) -> Result<String, WorkspaceError> {
        let _guard = self.gate.lock().await;
        Ok(self.executor.read_file(path, start_line, end_line).await?)
    }

    pub async fn apply_patch(&self, patch: &str) -> Result<String, WorkspaceError> {
        let _guard = self.gate.lock().await;
        Ok(self.executor.apply_patch(patch).await?)
    }

    pub async fn status(&self) -> Result<String, WorkspaceError> {
        let _guard = self.gate.lock().await;
        Ok(self.executor.git_status().await?)
    }

    pub async fn diff(&self) -> Result<String, WorkspaceError> {
        let _guard = self.gate.lock().await;
        Ok(self.executor.git_diff().await?)
    }

    pub async fn validation_plan(&self) -> Result<Vec<String>, WorkspaceError> {
        let _guard = self.gate.lock().await;
        Ok(crate::validation_plan(&self.executor)
            .await?
            .into_iter()
            .map(|command| command.to_string())
            .collect())
    }

    pub async fn validate(&self) -> Result<Vec<ValidationResult>, WorkspaceError> {
        let _guard = self.gate.lock().await;
        Ok(run_controller_validation(&self.executor).await?)
    }

    pub async fn instructions(&self) -> Result<String, WorkspaceError> {
        let _guard = self.gate.lock().await;
        Ok(self.executor.load_repository_instructions().await?)
    }

    pub async fn audit(&self) -> Result<WorkspaceAudit, WorkspaceError> {
        let _guard = self.gate.lock().await;
        Ok(self.executor.final_security_audit().await?)
    }

    pub async fn commit_and_push(
        &self,
        message: &str,
        token: &str,
    ) -> Result<(String, WorkspaceAudit), WorkspaceError> {
        let _guard = self.gate.lock().await;
        let audit = self.executor.final_security_audit().await?;
        let changed_files = self.executor.changed_files().await?;
        let workflow = GitWorkflow::new(&self.sandbox);
        let revision = workflow
            .commit(
                &self.descriptor.branch_name,
                message,
                &changed_files,
                &self.git_author_name,
                &self.git_author_email,
            )
            .await?;
        workflow
            .push(&self.descriptor.branch_name, &self.repository_url, token)
            .await?;
        Ok((revision, audit))
    }

    pub async fn shutdown(&self) -> Result<(), WorkspaceError> {
        let _guard = self.gate.lock().await;
        Ok(self.sandbox.shutdown().await?)
    }
}

pub struct WorkspaceManager {
    config: WorkspaceManagerConfig,
    workspaces: RwLock<HashMap<Uuid, Arc<Workspace>>>,
}

impl WorkspaceManager {
    #[must_use]
    pub fn new(config: WorkspaceManagerConfig) -> Self {
        Self {
            config,
            workspaces: RwLock::new(HashMap::new()),
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn create(
        &self,
        actor: &str,
        owner: &str,
        repository: &str,
        base_ref: &str,
        expected_base_sha: &str,
        task: &str,
        token: &str,
    ) -> Result<Arc<Workspace>, WorkspaceError> {
        validate_sha(expected_base_sha)?;
        let id = Uuid::new_v4();
        let branch_name = proposal_branch(task, id);
        let sandbox = Arc::new(DockerSandbox::create(self.config.sandbox.clone(), id).await?);
        sandbox
            .clone_repository(
                &self.config.web_base_url,
                owner,
                repository,
                base_ref,
                token,
            )
            .await?;
        let revision = sandbox
            .exec_as_publisher(
                "git",
                &["rev-parse".to_owned(), "HEAD".to_owned()],
                std::time::Duration::from_secs(30),
            )
            .await?;
        if !revision.success() || revision.stdout.trim() != expected_base_sha {
            return Err(WorkspaceError::BaseMoved {
                expected: expected_base_sha.to_owned(),
                actual: revision.stdout.trim().to_owned(),
            });
        }
        let paths = PathPolicy::new(&self.config.blocked_paths)?;
        let commands = CommandPolicy::standard(self.config.limits.max_command_seconds);
        let executor =
            SandboxToolExecutor::new(sandbox.clone(), paths, commands, self.config.limits.clone());
        let created_at = Utc::now();
        let ttl = i64::try_from(self.config.limits.max_workspace_seconds)
            .map_err(|_| WorkspaceError::InvalidTtl)?;
        let descriptor = WorkspaceDescriptor {
            id,
            actor: actor.to_owned(),
            owner: owner.to_owned(),
            repository: repository.to_owned(),
            base_ref: base_ref.to_owned(),
            base_sha: expected_base_sha.to_owned(),
            branch_name,
            created_at,
            expires_at: created_at + ChronoDuration::seconds(ttl),
        };
        let repository_url = format!(
            "{}/{}/{}.git",
            self.config.web_base_url.trim_end_matches('/'),
            owner,
            repository
        );
        let workspace = Arc::new(Workspace {
            descriptor,
            sandbox,
            executor,
            gate: Mutex::new(()),
            git_author_name: self.config.git_author_name.clone(),
            git_author_email: self.config.git_author_email.clone(),
            repository_url,
        });
        self.workspaces.write().await.insert(id, workspace.clone());
        Ok(workspace)
    }

    pub async fn get(&self, id: Uuid, actor: &str) -> Result<Arc<Workspace>, WorkspaceError> {
        let workspace = self
            .workspaces
            .read()
            .await
            .get(&id)
            .cloned()
            .ok_or(WorkspaceError::Unavailable)?;
        if workspace.descriptor.actor != actor || workspace.descriptor.expires_at <= Utc::now() {
            return Err(WorkspaceError::Unavailable);
        }
        Ok(workspace)
    }

    pub async fn remove(&self, id: Uuid, actor: &str) -> Result<(), WorkspaceError> {
        let workspace = self.get(id, actor).await?;
        self.workspaces.write().await.remove(&id);
        workspace.shutdown().await
    }

    pub async fn expire(&self) -> Vec<Uuid> {
        let now = Utc::now();
        let stale = self
            .workspaces
            .read()
            .await
            .iter()
            .filter_map(|(id, workspace)| (workspace.descriptor.expires_at <= now).then_some(*id))
            .collect::<Vec<_>>();
        for id in &stale {
            if let Some(workspace) = self.workspaces.write().await.remove(id) {
                let _ = workspace.shutdown().await;
            }
        }
        stale
    }

    pub async fn shutdown_all(&self) {
        let workspaces = self
            .workspaces
            .write()
            .await
            .drain()
            .map(|(_, workspace)| workspace)
            .collect::<Vec<_>>();
        for workspace in workspaces {
            let _ = workspace.shutdown().await;
        }
    }
}

fn validate_sha(value: &str) -> Result<(), WorkspaceError> {
    if value.len() != 40 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(WorkspaceError::InvalidSha);
    }
    Ok(())
}

#[derive(Debug, thiserror::Error)]
pub enum WorkspaceError {
    #[error(transparent)]
    Sandbox(#[from] SandboxError),
    #[error(transparent)]
    Git(#[from] GitWorkflowError),
    #[error(transparent)]
    Policy(#[from] PolicyError),
    #[error("workspace is unavailable, expired, or belongs to another Sonar sender")]
    Unavailable,
    #[error(
        "repository base moved while the workspace was created (expected {expected}, got {actual})"
    )]
    BaseMoved { expected: String, actual: String },
    #[error("GitHub returned an invalid commit SHA")]
    InvalidSha,
    #[error("workspace TTL is out of range")]
    InvalidTtl,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requires_full_commit_sha() {
        assert!(validate_sha("0123456789012345678901234567890123456789").is_ok());
        assert!(validate_sha("main").is_err());
    }
}
