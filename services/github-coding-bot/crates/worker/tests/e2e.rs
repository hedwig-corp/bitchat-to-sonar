use std::{
    collections::VecDeque,
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Arc, Mutex, MutexGuard},
};

use async_trait::async_trait;
use coding_bot_agent::{
    CodingAgent, LanguageModel, ModelError, ToolExecutionError, ToolExecutor, WorkspaceAudit,
};
use coding_bot_domain::{
    AgentLimits, DraftPullRequest, IssueContext, MessageRole, ModelRequest, ModelResponse,
    ModelToolCall, OpenedPullRequest, PullRequestReport, ToolOutput, ValidationResult,
};
use coding_bot_github::{GitHubError, GitHubInstallationApi};
use serde_json::json;
use tempfile::TempDir;

const PATCH: &str = "diff --git a/src.txt b/src.txt\nindex df967b9..3bd1f0e 100644\n--- a/src.txt\n+++ b/src.txt\n@@ -1 +1 @@\n-base\n+fixed\n";

#[tokio::test]
async fn mocked_agent_edits_temp_repo_and_opens_draft_pr() {
    let repository = initialize_repository();
    let model = Arc::new(FakeModel::new(vec![
        response("apply_patch", json!({"patch": PATCH})),
        response("git_diff", json!({})),
        response(
            "finish",
            json!({
                "summary": "Reject the broken parser input",
                "changes": ["Update parser behavior"],
                "tests": ["cargo test"],
                "limitations": []
            }),
        ),
    ]));
    let tools = Arc::new(LocalTools {
        repository: repository.path().to_path_buf(),
    });
    let agent = CodingAgent::new(model, tools, limits());
    let issue = IssueContext {
        title: "Parser accepts broken input".to_owned(),
        body: "Please reject it.".to_owned(),
        author: "reporter".to_owned(),
        state: "open".to_owned(),
        labels: vec!["ai-fix".to_owned()],
        comments: vec![],
        html_url: "https://example.test/owner/repo/issues/7".to_owned(),
    };
    let run = match agent.run(&issue).await {
        Ok(run) => run,
        Err(error) => panic!("mocked agent failed: {error}"),
    };
    let diff = git(repository.path(), &["diff", "--no-color", "HEAD"]);
    assert!(diff.contains("+fixed"));

    let report = PullRequestReport {
        summary: run.report.summary.clone(),
        changes: run.report.changes,
        changed_files: vec!["src.txt".to_owned()],
        validation: vec![ValidationResult {
            command: "cargo test".to_owned(),
            passed: true,
            exit_code: Some(0),
            output: "ok".to_owned(),
            duration_ms: 1,
        }],
        limitations: run.report.limitations,
        issue_number: 7,
    };
    let github = FakeGitHub::default();
    let opened = github
        .create_draft_pull_request(
            "owner",
            "repo",
            DraftPullRequest {
                title: run.report.summary,
                head: "ai-fix/issue-7-parser".to_owned(),
                base: "main".to_owned(),
                body: report.to_markdown(),
            },
        )
        .await;
    let opened = match opened {
        Ok(opened) => opened,
        Err(error) => panic!("mocked PR creation failed: {error}"),
    };
    assert_eq!(opened.number, 99);
    let request = lock(&github.created);
    let Some(request) = request.as_ref() else {
        panic!("mock GitHub did not record a PR request");
    };
    assert!(request.body.contains("`cargo test` — passed"));
    assert!(request.body.ends_with("Fixes #7"));
}

fn initialize_repository() -> TempDir {
    let directory = match tempfile::tempdir() {
        Ok(directory) => directory,
        Err(error) => panic!("failed to create temp repository: {error}"),
    };
    run_git(directory.path(), &["init", "--initial-branch=main"]);
    if let Err(error) = std::fs::write(directory.path().join("src.txt"), "base\n") {
        panic!("failed to seed temp repository: {error}");
    }
    run_git(directory.path(), &["add", "src.txt"]);
    run_git(
        directory.path(),
        &[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.test",
            "commit",
            "-m",
            "initial",
        ],
    );
    directory
}

fn run_git(repository: &Path, args: &[&str]) {
    let output = Command::new("git")
        .current_dir(repository)
        .args(args)
        .output();
    let output = match output {
        Ok(output) => output,
        Err(error) => panic!("failed to spawn git: {error}"),
    };
    if !output.status.success() {
        panic!("git failed: {}", String::from_utf8_lossy(&output.stderr));
    }
}

fn git(repository: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .current_dir(repository)
        .args(args)
        .output();
    let output = match output {
        Ok(output) => output,
        Err(error) => panic!("failed to spawn git: {error}"),
    };
    if !output.status.success() {
        panic!("git failed: {}", String::from_utf8_lossy(&output.stderr));
    }
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn response(name: &str, arguments: serde_json::Value) -> ModelResponse {
    ModelResponse {
        content: None,
        tool_calls: vec![ModelToolCall {
            id: format!("call-{name}"),
            name: name.to_owned(),
            arguments,
        }],
        input_tokens: 10,
        output_tokens: 10,
    }
}

fn limits() -> AgentLimits {
    AgentLimits {
        max_steps: 10,
        max_files_read: 10,
        max_files_modified: 5,
        max_diff_lines: 100,
        max_command_seconds: 5,
        max_job_seconds: 30,
        max_llm_tokens: 100_000,
        max_retries: 0,
        max_tool_output_bytes: 8192,
    }
}

struct FakeModel {
    responses: Mutex<VecDeque<ModelResponse>>,
}

impl FakeModel {
    fn new(responses: Vec<ModelResponse>) -> Self {
        Self {
            responses: Mutex::new(responses.into()),
        }
    }
}

#[async_trait]
impl LanguageModel for FakeModel {
    async fn complete(&self, request: ModelRequest) -> Result<ModelResponse, ModelError> {
        assert!(request
            .messages
            .iter()
            .any(|message| message.role == MessageRole::User));
        lock(&self.responses)
            .pop_front()
            .ok_or_else(|| ModelError::InvalidResponse("mock response queue exhausted".to_owned()))
    }
}

struct LocalTools {
    repository: PathBuf,
}

#[async_trait]
impl ToolExecutor for LocalTools {
    async fn execute(&self, call: &ModelToolCall) -> Result<ToolOutput, ToolExecutionError> {
        match call.name.as_str() {
            "apply_patch" => {
                let Some(patch) = call.arguments.get("patch").and_then(|value| value.as_str())
                else {
                    return Err(tool_error("patch argument missing"));
                };
                let mut child = Command::new("git")
                    .current_dir(&self.repository)
                    .args(["apply", "-"])
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped())
                    .spawn()
                    .map_err(|error| tool_error(&error.to_string()))?;
                let Some(mut stdin) = child.stdin.take() else {
                    return Err(tool_error("git apply stdin unavailable"));
                };
                stdin
                    .write_all(patch.as_bytes())
                    .map_err(|error| tool_error(&error.to_string()))?;
                drop(stdin);
                let output = child
                    .wait_with_output()
                    .map_err(|error| tool_error(&error.to_string()))?;
                Ok(ToolOutput {
                    content: String::from_utf8_lossy(&output.stderr).into_owned(),
                    is_error: !output.status.success(),
                })
            }
            "git_diff" => Ok(ToolOutput {
                content: git(&self.repository, &["diff", "--no-color", "HEAD"]),
                is_error: false,
            }),
            _ => Err(tool_error("unexpected mock tool")),
        }
    }

    async fn audit(&self) -> Result<WorkspaceAudit, ToolExecutionError> {
        let numstat = git(&self.repository, &["diff", "--numstat", "HEAD"]);
        let mut files = 0_u32;
        let mut lines = 0_u32;
        for line in numstat.lines() {
            let columns = line.split('\t').collect::<Vec<_>>();
            if columns.len() >= 3 {
                files = files.saturating_add(1);
                lines = lines.saturating_add(columns[0].parse::<u32>().unwrap_or(0));
                lines = lines.saturating_add(columns[1].parse::<u32>().unwrap_or(0));
            }
        }
        Ok(WorkspaceAudit {
            files_read: 1,
            files_modified: files,
            diff_lines: lines,
        })
    }

    async fn cancelled(&self) -> Result<bool, ToolExecutionError> {
        Ok(false)
    }
}

fn tool_error(message: &str) -> ToolExecutionError {
    ToolExecutionError {
        public_message: message.to_owned(),
    }
}

#[derive(Default)]
struct FakeGitHub {
    created: Mutex<Option<DraftPullRequest>>,
}

#[async_trait]
impl GitHubInstallationApi for FakeGitHub {
    async fn trusted_actor(
        &self,
        _owner: &str,
        _repository: &str,
        _login: &str,
    ) -> Result<bool, GitHubError> {
        Ok(true)
    }

    async fn issue_context(
        &self,
        _owner: &str,
        _repository: &str,
        _issue_number: u64,
    ) -> Result<IssueContext, GitHubError> {
        Err(GitHubError::MissingResponseField("unused mock call"))
    }

    async fn issue_is_open_with_label(
        &self,
        _owner: &str,
        _repository: &str,
        _issue_number: u64,
        _label: &str,
    ) -> Result<bool, GitHubError> {
        Ok(true)
    }

    async fn comment(
        &self,
        _owner: &str,
        _repository: &str,
        _issue_number: u64,
        _body: &str,
    ) -> Result<(), GitHubError> {
        Ok(())
    }

    async fn create_draft_pull_request(
        &self,
        _owner: &str,
        _repository: &str,
        request: DraftPullRequest,
    ) -> Result<OpenedPullRequest, GitHubError> {
        *lock(&self.created) = Some(request);
        Ok(OpenedPullRequest {
            number: 99,
            html_url: "https://example.test/owner/repo/pull/99".to_owned(),
        })
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}
