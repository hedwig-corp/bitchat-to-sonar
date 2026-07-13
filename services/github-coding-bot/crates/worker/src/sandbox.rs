use std::{
    collections::HashSet,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, MutexGuard,
    },
    time::{Duration, Instant},
};

use async_trait::async_trait;
use coding_bot_agent::{ToolExecutionError, ToolExecutor, WorkspaceAudit};
use coding_bot_domain::{AgentLimits, ModelToolCall, ToolOutput, ValidationResult};
use serde::Deserialize;
use thiserror::Error;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    process::Command,
};
use uuid::Uuid;

use crate::{AllowedCommand, CommandPolicy, PathPolicy, PolicyError};

const REPOSITORY_ROOT: &str = "/workspace/repo";
const GIT_METADATA_ROOT: &str = "/git";
const PUBLISHER_USER: &str = "10002:10001";
const DOCKER_COMMAND_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone)]
pub struct DockerSandboxConfig {
    pub docker_binary: String,
    pub image: String,
    pub network: String,
    pub memory: String,
    pub cpus: String,
    pub pids_limit: u32,
    pub workspace_size: String,
    pub max_output_bytes: usize,
}

pub struct DockerSandbox {
    config: DockerSandboxConfig,
    container_name: String,
    active: AtomicBool,
}

impl DockerSandbox {
    pub async fn create(config: DockerSandboxConfig, job_id: Uuid) -> Result<Self, SandboxError> {
        let short_id = job_id.simple().to_string();
        let container_name = format!("coding-bot-{}", &short_id[..12]);
        let sandbox = Self {
            config,
            container_name,
            active: AtomicBool::new(false),
        };
        let args = vec![
            "run".to_owned(),
            "--detach".to_owned(),
            "--rm".to_owned(),
            "--name".to_owned(),
            sandbox.container_name.clone(),
            "--network".to_owned(),
            "none".to_owned(),
            "--read-only".to_owned(),
            "--cap-drop".to_owned(),
            "ALL".to_owned(),
            "--security-opt".to_owned(),
            "no-new-privileges".to_owned(),
            "--pids-limit".to_owned(),
            sandbox.config.pids_limit.to_string(),
            "--memory".to_owned(),
            sandbox.config.memory.clone(),
            "--cpus".to_owned(),
            sandbox.config.cpus.clone(),
            "--tmpfs".to_owned(),
            format!(
                "/workspace:rw,exec,nosuid,nodev,uid=10001,gid=10001,mode=0775,size={}",
                sandbox.config.workspace_size
            ),
            "--tmpfs".to_owned(),
            format!(
                "/git:rw,noexec,nosuid,nodev,uid=10002,gid=10001,mode=0750,size={}",
                sandbox.config.workspace_size
            ),
            "--tmpfs".to_owned(),
            "/tmp:rw,exec,nosuid,nodev,size=512m".to_owned(),
            "--workdir".to_owned(),
            "/workspace".to_owned(),
            "--entrypoint".to_owned(),
            "/usr/bin/tail".to_owned(),
            sandbox.config.image.clone(),
            "-f".to_owned(),
            "/dev/null".to_owned(),
        ];
        let output = sandbox
            .run_docker("create sandbox", args, None, None, DOCKER_COMMAND_TIMEOUT)
            .await?;
        output.require_success("create sandbox")?;
        sandbox.active.store(true, Ordering::Release);
        Ok(sandbox)
    }

    pub async fn clone_repository(
        &self,
        web_base_url: &str,
        owner: &str,
        repository: &str,
        base_branch: &str,
        token: &str,
    ) -> Result<(), SandboxError> {
        validate_repository_component(owner)?;
        validate_repository_component(repository)?;
        validate_git_ref(base_branch)?;
        let url = format!(
            "{}/{}/{}.git",
            web_base_url.trim_end_matches('/'),
            owner,
            repository
        );

        let initialize = self
            .exec_at(
                "/workspace",
                "/usr/bin/git",
                &[
                    "init".to_owned(),
                    "--separate-git-dir".to_owned(),
                    GIT_METADATA_ROOT.to_owned(),
                    "--initial-branch".to_owned(),
                    base_branch.to_owned(),
                    REPOSITORY_ROOT.to_owned(),
                ],
                Duration::from_secs(30),
                None,
                None,
                true,
            )
            .await;
        initialize?.require_success("initialize isolated repository")?;

        for (key, value) in [
            ("core.hooksPath", "/dev/null"),
            ("submodule.recurse", "false"),
            ("fetch.recurseSubmodules", "false"),
            ("protocol.file.allow", "never"),
            ("credential.helper", ""),
            ("commit.gpgsign", "false"),
        ] {
            self.exec_checked_as_publisher(
                "configure repository",
                "git",
                &["config".to_owned(), key.to_owned(), value.to_owned()],
                Duration::from_secs(30),
            )
            .await?;
        }

        self.ensure_idle_for_network().await?;
        self.connect_network().await?;
        let fetch_result = self
            .exec_at(
                REPOSITORY_ROOT,
                "git",
                &[
                    "fetch".to_owned(),
                    "--no-tags".to_owned(),
                    "--depth".to_owned(),
                    "100".to_owned(),
                    url,
                    format!("refs/heads/{base_branch}"),
                ],
                Duration::from_secs(300),
                None,
                Some(token),
                true,
            )
            .await;
        let disconnect_result = self.disconnect_network().await;
        if disconnect_result.is_err() {
            let _ = self.force_kill().await;
            return Err(SandboxError::NetworkIsolation);
        }
        fetch_result?.require_success("fetch repository")?;
        self.exec_checked_as_publisher(
            "checkout repository",
            "git",
            &[
                "checkout".to_owned(),
                "--force".to_owned(),
                "-B".to_owned(),
                base_branch.to_owned(),
                "FETCH_HEAD".to_owned(),
            ],
            Duration::from_secs(60),
        )
        .await?;
        self.exec_checked_as_publisher(
            "make worktree writable",
            "chmod",
            &[
                "-R".to_owned(),
                "g+rwX".to_owned(),
                "--".to_owned(),
                REPOSITORY_ROOT.to_owned(),
            ],
            Duration::from_secs(60),
        )
        .await?;
        self.exec_checked_as_publisher(
            "protect repository pointer",
            "chmod",
            &[
                "g-w".to_owned(),
                "--".to_owned(),
                format!("{REPOSITORY_ROOT}/.git"),
            ],
            Duration::from_secs(30),
        )
        .await?;
        self.reject_escaping_symlinks().await
    }

    pub async fn ensure_idle_for_network(&self) -> Result<(), SandboxError> {
        let output = self
            .run_docker(
                "inspect sandbox processes",
                vec!["top".to_owned(), self.container_name.clone()],
                None,
                None,
                DOCKER_COMMAND_TIMEOUT,
            )
            .await?;
        output.require_success("inspect sandbox processes")?;
        if process_rows(&output.stdout) != 1 {
            let _ = self.force_kill().await;
            return Err(SandboxError::UnexpectedProcesses);
        }
        Ok(())
    }

    pub async fn exec_as_publisher(
        &self,
        program: &str,
        args: &[String],
        timeout: Duration,
    ) -> Result<ProcessOutput, SandboxError> {
        self.exec_at(REPOSITORY_ROOT, program, args, timeout, None, None, true)
            .await
    }

    pub async fn exec_with_token_as_publisher(
        &self,
        program: &str,
        args: &[String],
        timeout: Duration,
        token: &str,
    ) -> Result<ProcessOutput, SandboxError> {
        self.exec_at(
            REPOSITORY_ROOT,
            program,
            args,
            timeout,
            None,
            Some(token),
            true,
        )
        .await
    }

    async fn exec_checked_as_publisher(
        &self,
        operation: &'static str,
        program: &str,
        args: &[String],
        timeout: Duration,
    ) -> Result<ProcessOutput, SandboxError> {
        let output = self.exec_as_publisher(program, args, timeout).await?;
        output.require_success(operation)?;
        Ok(output)
    }

    pub async fn shutdown(&self) -> Result<(), SandboxError> {
        if !self.active.swap(false, Ordering::AcqRel) {
            return Ok(());
        }
        let output = self
            .run_docker(
                "remove sandbox",
                vec![
                    "rm".to_owned(),
                    "--force".to_owned(),
                    self.container_name.clone(),
                ],
                None,
                None,
                DOCKER_COMMAND_TIMEOUT,
            )
            .await?;
        if output.success() || output.stderr.contains("No such container") {
            Ok(())
        } else {
            Err(output.failure("remove sandbox"))
        }
    }

    pub async fn exec_in_repository(
        &self,
        program: &str,
        args: &[String],
        timeout: Duration,
    ) -> Result<ProcessOutput, SandboxError> {
        self.exec_at(REPOSITORY_ROOT, program, args, timeout, None, None, false)
            .await
    }

    pub async fn exec_with_token(
        &self,
        program: &str,
        args: &[String],
        timeout: Duration,
        token: &str,
    ) -> Result<ProcessOutput, SandboxError> {
        self.exec_at(
            REPOSITORY_ROOT,
            program,
            args,
            timeout,
            None,
            Some(token),
            false,
        )
        .await
    }

    pub async fn exec_with_stdin(
        &self,
        program: &str,
        args: &[String],
        timeout: Duration,
        stdin: &[u8],
    ) -> Result<ProcessOutput, SandboxError> {
        self.exec_at(
            REPOSITORY_ROOT,
            program,
            args,
            timeout,
            Some(stdin),
            None,
            false,
        )
        .await
    }

    pub async fn connect_network(&self) -> Result<(), SandboxError> {
        let output = self
            .run_docker(
                "connect sandbox network",
                vec![
                    "network".to_owned(),
                    "connect".to_owned(),
                    self.config.network.clone(),
                    self.container_name.clone(),
                ],
                None,
                None,
                DOCKER_COMMAND_TIMEOUT,
            )
            .await?;
        output.require_success("connect sandbox network")
    }

    pub async fn disconnect_network(&self) -> Result<(), SandboxError> {
        let output = self
            .run_docker(
                "disconnect sandbox network",
                vec![
                    "network".to_owned(),
                    "disconnect".to_owned(),
                    self.config.network.clone(),
                    self.container_name.clone(),
                ],
                None,
                None,
                DOCKER_COMMAND_TIMEOUT,
            )
            .await?;
        output.require_success("disconnect sandbox network")
    }

    #[allow(clippy::too_many_arguments)]
    async fn exec_at(
        &self,
        working_directory: &str,
        program: &str,
        command_args: &[String],
        timeout: Duration,
        stdin: Option<&[u8]>,
        token: Option<&str>,
        publisher: bool,
    ) -> Result<ProcessOutput, SandboxError> {
        if !self.active.load(Ordering::Acquire) {
            return Err(SandboxError::Inactive);
        }
        let mut args = vec![
            "exec".to_owned(),
            "--workdir".to_owned(),
            working_directory.to_owned(),
        ];
        if publisher {
            args.extend(["--user".to_owned(), PUBLISHER_USER.to_owned()]);
        }
        if program == "git" {
            args.extend([
                "--env".to_owned(),
                format!("GIT_DIR={GIT_METADATA_ROOT}"),
                "--env".to_owned(),
                format!("GIT_WORK_TREE={REPOSITORY_ROOT}"),
                "--env".to_owned(),
                "GIT_CONFIG_NOSYSTEM=1".to_owned(),
                "--env".to_owned(),
                "GIT_CONFIG_GLOBAL=/dev/null".to_owned(),
            ]);
            if !publisher {
                args.extend(["--env".to_owned(), "GIT_OPTIONAL_LOCKS=0".to_owned()]);
            }
        }
        let mut secret_environment = None;
        if let Some(token) = token {
            args.extend([
                "--env".to_owned(),
                "GIT_CONFIG_COUNT=1".to_owned(),
                "--env".to_owned(),
                "GIT_CONFIG_KEY_0=http.extraHeader".to_owned(),
                "--env".to_owned(),
                "GIT_CONFIG_VALUE_0".to_owned(),
                "--env".to_owned(),
                "GIT_TERMINAL_PROMPT=0".to_owned(),
            ]);
            secret_environment = Some((
                "GIT_CONFIG_VALUE_0".to_owned(),
                format!("Authorization: Bearer {token}"),
            ));
        }
        if stdin.is_some() {
            args.push("--interactive".to_owned());
        }
        args.push(self.container_name.clone());
        args.push(program.to_owned());
        args.extend(command_args.iter().cloned());

        let result = self
            .run_docker("sandbox command", args, stdin, secret_environment, timeout)
            .await;
        if matches!(result, Err(SandboxError::Timeout(_))) {
            let _ = self.force_kill().await;
        }
        let mut output = result?;
        if let Some(token) = token {
            output.redact(token);
        }
        Ok(output)
    }

    async fn run_docker(
        &self,
        operation: &'static str,
        args: Vec<String>,
        stdin: Option<&[u8]>,
        environment: Option<(String, String)>,
        timeout: Duration,
    ) -> Result<ProcessOutput, SandboxError> {
        let mut command = Command::new(&self.config.docker_binary);
        command.args(args);
        if let Some((name, value)) = environment {
            command.env(name, value);
        }
        run_process(
            operation,
            command,
            stdin,
            timeout,
            self.config.max_output_bytes,
        )
        .await
    }

    async fn force_kill(&self) -> Result<(), SandboxError> {
        let output = self
            .run_docker(
                "kill sandbox",
                vec!["kill".to_owned(), self.container_name.clone()],
                None,
                None,
                Duration::from_secs(10),
            )
            .await?;
        self.active.store(false, Ordering::Release);
        if output.success() || output.stderr.contains("No such container") {
            Ok(())
        } else {
            Err(output.failure("kill sandbox"))
        }
    }

    async fn reject_escaping_symlinks(&self) -> Result<(), SandboxError> {
        let output = self
            .exec_in_repository(
                "find",
                &[
                    ".".to_owned(),
                    "-type".to_owned(),
                    "l".to_owned(),
                    "-print0".to_owned(),
                ],
                Duration::from_secs(30),
            )
            .await?;
        output.require_success("list repository symlinks")?;
        for path in output.stdout.split('\0').filter(|path| !path.is_empty()) {
            let resolved = self
                .exec_in_repository(
                    "readlink",
                    &["-f".to_owned(), "--".to_owned(), path.to_owned()],
                    Duration::from_secs(5),
                )
                .await?;
            if !resolved.success() {
                return Err(SandboxError::EscapingSymlink(path.to_owned()));
            }
            let target = resolved.stdout.trim();
            if target != REPOSITORY_ROOT && !target.starts_with(&format!("{REPOSITORY_ROOT}/")) {
                return Err(SandboxError::EscapingSymlink(path.to_owned()));
            }
        }
        Ok(())
    }

    async fn canonical_repository_path(&self, path: &str) -> Result<(), SandboxError> {
        let output = self
            .exec_in_repository(
                "readlink",
                &["-f".to_owned(), "--".to_owned(), path.to_owned()],
                Duration::from_secs(5),
            )
            .await?;
        output.require_success("resolve repository path")?;
        let resolved = output.stdout.trim();
        if resolved == REPOSITORY_ROOT || resolved.starts_with(&format!("{REPOSITORY_ROOT}/")) {
            Ok(())
        } else {
            Err(SandboxError::PathEscaped(path.to_owned()))
        }
    }
}

impl Drop for DockerSandbox {
    fn drop(&mut self) {
        if !self.active.swap(false, Ordering::AcqRel) {
            return;
        }
        let docker = self.config.docker_binary.clone();
        let container = self.container_name.clone();
        let _ = std::thread::Builder::new()
            .name("coding-bot-sandbox-cleanup".to_owned())
            .spawn(move || {
                let _ = std::process::Command::new(docker)
                    .args(["rm", "--force", &container])
                    .status();
            });
    }
}

pub struct SandboxToolExecutor {
    sandbox: Arc<DockerSandbox>,
    paths: PathPolicy,
    commands: CommandPolicy,
    limits: AgentLimits,
    files_read: Mutex<HashSet<String>>,
    validations: Mutex<Vec<ValidationResult>>,
    cancelled: Arc<AtomicBool>,
    repository_validation: Vec<AllowedCommand>,
}

impl SandboxToolExecutor {
    #[must_use]
    pub fn new(
        sandbox: Arc<DockerSandbox>,
        paths: PathPolicy,
        commands: CommandPolicy,
        limits: AgentLimits,
        cancelled: Arc<AtomicBool>,
        repository_validation: Vec<AllowedCommand>,
    ) -> Self {
        Self {
            sandbox,
            paths,
            commands,
            limits,
            files_read: Mutex::new(HashSet::new()),
            validations: Mutex::new(Vec::new()),
            cancelled,
            repository_validation,
        }
    }

    pub(crate) fn sandbox(&self) -> &DockerSandbox {
        &self.sandbox
    }

    pub(crate) fn path_policy(&self) -> &PathPolicy {
        &self.paths
    }

    pub(crate) fn limits(&self) -> &AgentLimits {
        &self.limits
    }

    pub(crate) fn repository_validation_commands(&self) -> &[AllowedCommand] {
        &self.repository_validation
    }

    pub async fn run_validation(
        &self,
        program: &str,
        args: &[String],
    ) -> Result<ValidationResult, SandboxError> {
        let command = self.commands.resolve(program, args)?;
        let started = Instant::now();
        let output = self
            .sandbox
            .exec_in_repository(
                &command.program,
                &command.args,
                Duration::from_secs(command.timeout_seconds),
            )
            .await?;
        let passed = output.success();
        let exit_code = output.code;
        let mut combined = output.stdout;
        if !output.stderr.is_empty() {
            if !combined.is_empty() {
                combined.push('\n');
            }
            combined.push_str(&output.stderr);
        }
        let result = ValidationResult {
            command: command.to_string(),
            passed,
            exit_code,
            output: combined,
            duration_ms: u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
        };
        metrics::histogram!("coding_bot_command_duration_seconds", "command" => command.to_string())
            .record(started.elapsed().as_secs_f64());
        if !result.passed {
            metrics::counter!("coding_bot_command_failures_total", "command" => command.to_string())
                .increment(1);
        }
        tracing::info!(
            tool_name = "run_validation_command",
            command = %command,
            command_duration_ms = result.duration_ms,
            passed = result.passed,
            "validation command completed"
        );
        lock_or_recover(&self.validations).push(result.clone());
        Ok(result)
    }

    pub async fn load_repository_instructions(&self) -> Result<String, SandboxError> {
        const ROOT_ORDER: &[&str] = &["AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", "README.md"];
        const MAX_INSTRUCTION_BYTES: usize = 65_536;
        const MAX_INSTRUCTION_FILES: usize = 40;

        let mut paths = Vec::new();
        for path in ROOT_ORDER {
            if self.repository_file_exists(path).await? {
                paths.push((*path).to_owned());
            }
        }
        let nested = self
            .sandbox
            .exec_in_repository(
                "find",
                &[
                    ".".to_owned(),
                    "-mindepth".to_owned(),
                    "2".to_owned(),
                    "-type".to_owned(),
                    "f".to_owned(),
                    "(".to_owned(),
                    "-name".to_owned(),
                    "AGENTS.md".to_owned(),
                    "-o".to_owned(),
                    "-name".to_owned(),
                    "CLAUDE.md".to_owned(),
                    ")".to_owned(),
                    "-print".to_owned(),
                ],
                Duration::from_secs(30),
            )
            .await?;
        nested.require_success("discover scoped repository instructions")?;
        let mut nested_paths = nested
            .stdout
            .lines()
            .map(|path| path.trim_start_matches("./").to_owned())
            .filter(|path| !path.is_empty())
            .collect::<Vec<_>>();
        nested_paths.sort_by_key(|path| (path.matches('/').count(), path.clone()));
        paths.extend(nested_paths);
        paths.dedup();
        paths.truncate(MAX_INSTRUCTION_FILES);

        let mut context = String::new();
        for path in paths {
            let path = self.paths.validate_relative(&path)?;
            self.sandbox.canonical_repository_path(&path).await?;
            let output = self
                .sandbox
                .exec_in_repository(
                    "sed",
                    &[
                        "-n".to_owned(),
                        "1,400p".to_owned(),
                        "--".to_owned(),
                        path.clone(),
                    ],
                    Duration::from_secs(30),
                )
                .await?;
            output.require_success("read repository instructions")?;
            lock_or_recover(&self.files_read).insert(path.clone());
            let section = format!("\n## {path}\n\n{}\n", output.stdout);
            if context.len().saturating_add(section.len()) > MAX_INSTRUCTION_BYTES {
                context.push_str("\n[additional repository instructions omitted by size limit]\n");
                break;
            }
            context.push_str(&section);
        }
        Ok(context)
    }

    #[must_use]
    pub fn validation_results(&self) -> Vec<ValidationResult> {
        lock_or_recover(&self.validations).clone()
    }

    pub async fn changed_files(&self) -> Result<Vec<String>, SandboxError> {
        let tracked = self
            .sandbox
            .exec_in_repository(
                "git",
                &[
                    "diff".to_owned(),
                    "--name-only".to_owned(),
                    "-z".to_owned(),
                    "HEAD".to_owned(),
                ],
                Duration::from_secs(30),
            )
            .await?;
        tracked.require_success("list changed tracked files")?;
        let untracked = self
            .sandbox
            .exec_in_repository(
                "git",
                &[
                    "ls-files".to_owned(),
                    "--others".to_owned(),
                    "--exclude-standard".to_owned(),
                    "-z".to_owned(),
                ],
                Duration::from_secs(30),
            )
            .await?;
        untracked.require_success("list untracked files")?;
        let mut paths = tracked
            .stdout
            .split('\0')
            .chain(untracked.stdout.split('\0'))
            .filter(|path| !path.is_empty())
            .map(str::to_owned)
            .collect::<Vec<_>>();
        paths.sort();
        paths.dedup();
        Ok(paths)
    }

    pub async fn full_diff(&self) -> Result<String, SandboxError> {
        let tracked = self
            .sandbox
            .exec_in_repository(
                "git",
                &[
                    "diff".to_owned(),
                    "--no-ext-diff".to_owned(),
                    "--no-color".to_owned(),
                    "HEAD".to_owned(),
                ],
                Duration::from_secs(30),
            )
            .await?;
        tracked.require_success("read Git diff")?;
        let mut diff = tracked.stdout;
        for path in self.untracked_files().await? {
            let output = self
                .sandbox
                .exec_in_repository(
                    "git",
                    &[
                        "diff".to_owned(),
                        "--no-index".to_owned(),
                        "--no-color".to_owned(),
                        "--".to_owned(),
                        "/dev/null".to_owned(),
                        path,
                    ],
                    Duration::from_secs(30),
                )
                .await?;
            if !output.success() && output.code != Some(1) {
                return Err(output.failure("read untracked file diff"));
            }
            diff.push_str(&output.stdout);
        }
        Ok(diff)
    }

    pub async fn final_security_audit(&self) -> Result<WorkspaceAudit, SandboxError> {
        let changed = self.changed_files().await?;
        self.paths
            .validate_changed_files(changed.iter().map(String::as_str))?;
        let diff_lines = self.diff_lines(&changed).await?;
        if diff_lines > self.limits.max_diff_lines {
            return Err(SandboxError::Limit(format!(
                "diff has {diff_lines} lines; limit is {}",
                self.limits.max_diff_lines
            )));
        }
        let file_count = u32::try_from(changed.len()).unwrap_or(u32::MAX);
        if file_count > self.limits.max_files_modified {
            return Err(SandboxError::Limit(format!(
                "diff modifies {file_count} files; limit is {}",
                self.limits.max_files_modified
            )));
        }
        self.reject_changed_symlinks(&changed).await?;
        self.sandbox.reject_escaping_symlinks().await?;
        Ok(WorkspaceAudit {
            files_read: u32::try_from(lock_or_recover(&self.files_read).len()).unwrap_or(u32::MAX),
            files_modified: file_count,
            diff_lines,
        })
    }

    async fn untracked_files(&self) -> Result<Vec<String>, SandboxError> {
        let output = self
            .sandbox
            .exec_in_repository(
                "git",
                &[
                    "ls-files".to_owned(),
                    "--others".to_owned(),
                    "--exclude-standard".to_owned(),
                    "-z".to_owned(),
                ],
                Duration::from_secs(30),
            )
            .await?;
        output.require_success("list untracked files")?;
        Ok(output
            .stdout
            .split('\0')
            .filter(|path| !path.is_empty())
            .map(str::to_owned)
            .collect())
    }

    async fn diff_lines(&self, changed: &[String]) -> Result<u32, SandboxError> {
        let tracked = self
            .sandbox
            .exec_in_repository(
                "git",
                &["diff".to_owned(), "--numstat".to_owned(), "HEAD".to_owned()],
                Duration::from_secs(30),
            )
            .await?;
        tracked.require_success("measure tracked diff")?;
        let mut count = parse_numstat(&tracked.stdout)?;
        let untracked = self.untracked_files().await?;
        for path in untracked {
            if !changed.contains(&path) {
                continue;
            }
            let output = self
                .sandbox
                .exec_in_repository(
                    "git",
                    &[
                        "diff".to_owned(),
                        "--no-index".to_owned(),
                        "--numstat".to_owned(),
                        "--".to_owned(),
                        "/dev/null".to_owned(),
                        path,
                    ],
                    Duration::from_secs(30),
                )
                .await?;
            if !output.success() && output.code != Some(1) {
                return Err(output.failure("measure untracked diff"));
            }
            count = count.saturating_add(parse_numstat(&output.stdout)?);
        }
        Ok(count)
    }

    async fn reject_changed_symlinks(&self, changed: &[String]) -> Result<(), SandboxError> {
        for path in changed {
            let output = self
                .sandbox
                .exec_in_repository(
                    "stat",
                    &[
                        "-c".to_owned(),
                        "%F".to_owned(),
                        "--".to_owned(),
                        path.clone(),
                    ],
                    Duration::from_secs(5),
                )
                .await?;
            if output.success() && output.stdout.contains("symbolic link") {
                return Err(SandboxError::ChangedSymlink(path.clone()));
            }
            if !output.success() && output.code != Some(1) {
                return Err(output.failure("inspect changed file type"));
            }
        }
        Ok(())
    }
}

#[async_trait]
impl ToolExecutor for SandboxToolExecutor {
    async fn execute(&self, call: &ModelToolCall) -> Result<ToolOutput, ToolExecutionError> {
        self.execute_tool(call)
            .await
            .map_err(|error| ToolExecutionError {
                public_message: error.to_string(),
            })
    }

    async fn audit(&self) -> Result<WorkspaceAudit, ToolExecutionError> {
        self.final_security_audit()
            .await
            .map_err(|error| ToolExecutionError {
                public_message: error.to_string(),
            })
    }

    async fn cancelled(&self) -> Result<bool, ToolExecutionError> {
        Ok(self.cancelled.load(Ordering::Acquire))
    }
}

impl SandboxToolExecutor {
    async fn execute_tool(&self, call: &ModelToolCall) -> Result<ToolOutput, SandboxError> {
        match call.name.as_str() {
            "list_files" => {
                let arguments: ListFiles = parse_arguments(call)?;
                let path = self
                    .paths
                    .validate_relative(arguments.path.as_deref().unwrap_or("."))?;
                self.sandbox.canonical_repository_path(&path).await?;
                let depth = arguments.max_depth.unwrap_or(4).clamp(1, 8);
                let output = self
                    .sandbox
                    .exec_in_repository(
                        "find",
                        &[
                            path,
                            "-maxdepth".to_owned(),
                            depth.to_string(),
                            "-type".to_owned(),
                            "f".to_owned(),
                            "-not".to_owned(),
                            "-path".to_owned(),
                            "./.git".to_owned(),
                            "-not".to_owned(),
                            "-path".to_owned(),
                            "./.git/*".to_owned(),
                            "-print".to_owned(),
                        ],
                        Duration::from_secs(30),
                    )
                    .await?;
                output.into_tool_output()
            }
            "search_files" => {
                let arguments: SearchFiles = parse_arguments(call)?;
                if arguments.query.len() > 256 || arguments.query.contains('\0') {
                    return Err(SandboxError::InvalidToolArguments(
                        "search query exceeds 256 bytes or contains NUL".to_owned(),
                    ));
                }
                let path = self
                    .paths
                    .validate_relative(arguments.path.as_deref().unwrap_or("."))?;
                self.sandbox.canonical_repository_path(&path).await?;
                let output = self
                    .sandbox
                    .exec_in_repository(
                        "rg",
                        &[
                            "--line-number".to_owned(),
                            "--fixed-strings".to_owned(),
                            "--no-heading".to_owned(),
                            "--glob".to_owned(),
                            "!.git/**".to_owned(),
                            "--".to_owned(),
                            arguments.query,
                            path,
                        ],
                        Duration::from_secs(30),
                    )
                    .await?;
                if output.success() || output.code == Some(1) {
                    for line in output.stdout.lines() {
                        if let Some(path) = line.split(':').next() {
                            if !path.is_empty() {
                                lock_or_recover(&self.files_read).insert(path.to_owned());
                            }
                        }
                    }
                    Ok(ToolOutput {
                        content: output.stdout,
                        is_error: false,
                    })
                } else {
                    output.into_tool_output()
                }
            }
            "read_file" => {
                let arguments: ReadFile = parse_arguments(call)?;
                let path = self.paths.validate_relative(&arguments.path)?;
                self.sandbox.canonical_repository_path(&path).await?;
                let start = arguments.start_line.unwrap_or(1);
                let end = arguments
                    .end_line
                    .unwrap_or_else(|| start.saturating_add(399));
                if start == 0 || end < start || end.saturating_sub(start) > 399 {
                    return Err(SandboxError::InvalidToolArguments(
                        "read_file permits at most 400 lines and uses 1-based ranges".to_owned(),
                    ));
                }
                lock_or_recover(&self.files_read).insert(path.clone());
                let output = self
                    .sandbox
                    .exec_in_repository(
                        "sed",
                        &[
                            "-n".to_owned(),
                            format!("{start},{end}p"),
                            "--".to_owned(),
                            path,
                        ],
                        Duration::from_secs(30),
                    )
                    .await?;
                output.into_tool_output()
            }
            "apply_patch" => {
                let arguments: ApplyPatch = parse_arguments(call)?;
                let maximum = usize::try_from(self.limits.max_diff_lines)
                    .unwrap_or(usize::MAX)
                    .saturating_mul(4096);
                if arguments.patch.len() > maximum {
                    return Err(SandboxError::Limit("patch payload is too large".to_owned()));
                }
                self.paths.validate_patch(&arguments.patch)?;
                let output = self
                    .sandbox
                    .exec_with_stdin(
                        "git",
                        &[
                            "apply".to_owned(),
                            "--whitespace=nowarn".to_owned(),
                            "--".to_owned(),
                            "-".to_owned(),
                        ],
                        Duration::from_secs(30),
                        arguments.patch.as_bytes(),
                    )
                    .await?;
                output.into_tool_output()
            }
            "git_diff" => {
                for path in self.changed_files().await? {
                    lock_or_recover(&self.files_read).insert(path);
                }
                Ok(ToolOutput {
                    content: self.full_diff().await?,
                    is_error: false,
                })
            }
            "git_status" => {
                let output = self
                    .sandbox
                    .exec_in_repository(
                        "git",
                        &[
                            "status".to_owned(),
                            "--short".to_owned(),
                            "--untracked-files=all".to_owned(),
                        ],
                        Duration::from_secs(30),
                    )
                    .await?;
                output.into_tool_output()
            }
            "run_validation_command" => {
                let arguments: ValidationCommand = parse_arguments(call)?;
                let result = self
                    .run_validation(&arguments.program, &arguments.args)
                    .await?;
                Ok(ToolOutput {
                    content: serde_json::to_string(&result)
                        .map_err(|error| SandboxError::InvalidToolArguments(error.to_string()))?,
                    is_error: !result.passed,
                })
            }
            _ => Err(SandboxError::InvalidToolArguments(
                "unsupported tool".to_owned(),
            )),
        }
    }
}

fn parse_arguments<T: for<'de> Deserialize<'de>>(call: &ModelToolCall) -> Result<T, SandboxError> {
    serde_json::from_value(call.arguments.clone())
        .map_err(|error| SandboxError::InvalidToolArguments(error.to_string()))
}

fn parse_numstat(value: &str) -> Result<u32, SandboxError> {
    let mut total = 0_u32;
    for line in value.lines().filter(|line| !line.is_empty()) {
        let mut columns = line.split('\t');
        let additions = columns.next().unwrap_or_default();
        let deletions = columns.next().unwrap_or_default();
        if additions == "-" || deletions == "-" {
            return Err(SandboxError::BinaryChange);
        }
        let additions = additions
            .parse::<u32>()
            .map_err(|_| SandboxError::InvalidGitOutput)?;
        let deletions = deletions
            .parse::<u32>()
            .map_err(|_| SandboxError::InvalidGitOutput)?;
        total = total.saturating_add(additions).saturating_add(deletions);
    }
    Ok(total)
}

fn process_rows(value: &str) -> usize {
    value
        .lines()
        .skip(1)
        .filter(|line| !line.trim().is_empty())
        .count()
}

fn lock_or_recover<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn validate_repository_component(value: &str) -> Result<(), SandboxError> {
    if value.is_empty()
        || value.len() > 100
        || !value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "-_.".contains(character))
    {
        return Err(SandboxError::InvalidRepository);
    }
    Ok(())
}

pub fn validate_git_ref(value: &str) -> Result<(), SandboxError> {
    if value.is_empty()
        || value.len() > 200
        || value.starts_with(['-', '.', '/'])
        || value.ends_with('/')
        || value.ends_with(".lock")
        || value.contains("..")
        || value.contains("@{")
        || value
            .chars()
            .any(|character| character.is_control() || " ~^:?*[\\".contains(character))
    {
        return Err(SandboxError::InvalidGitRef(value.to_owned()));
    }
    Ok(())
}

async fn run_process(
    operation: &'static str,
    mut command: Command,
    stdin: Option<&[u8]>,
    timeout: Duration,
    maximum_output: usize,
) -> Result<ProcessOutput, SandboxError> {
    command
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|source| SandboxError::Spawn { operation, source })?;

    if let Some(input) = stdin {
        let mut child_stdin = child.stdin.take().ok_or(SandboxError::MissingPipe)?;
        child_stdin
            .write_all(input)
            .await
            .map_err(|source| SandboxError::Io { operation, source })?;
        child_stdin
            .shutdown()
            .await
            .map_err(|source| SandboxError::Io { operation, source })?;
    }

    let stdout = child.stdout.take().ok_or(SandboxError::MissingPipe)?;
    let stderr = child.stderr.take().ok_or(SandboxError::MissingPipe)?;
    let stdout_task = tokio::spawn(read_bounded(stdout, maximum_output));
    let stderr_task = tokio::spawn(read_bounded(stderr, maximum_output));

    let status = match tokio::time::timeout(timeout, child.wait()).await {
        Ok(status) => status.map_err(|source| SandboxError::Io { operation, source })?,
        Err(_) => {
            let _ = child.kill().await;
            let _ = stdout_task.await;
            let _ = stderr_task.await;
            return Err(SandboxError::Timeout(operation));
        }
    };
    let stdout = stdout_task
        .await
        .map_err(|error| SandboxError::Reader(error.to_string()))??;
    let stderr = stderr_task
        .await
        .map_err(|error| SandboxError::Reader(error.to_string()))??;
    Ok(ProcessOutput {
        code: status.code(),
        stdout,
        stderr,
    })
}

async fn read_bounded(
    mut reader: impl AsyncRead + Unpin,
    maximum: usize,
) -> Result<String, SandboxError> {
    let mut retained = Vec::with_capacity(maximum.min(8192));
    let mut buffer = [0_u8; 8192];
    let mut truncated = false;
    loop {
        let read = reader
            .read(&mut buffer)
            .await
            .map_err(|source| SandboxError::Io {
                operation: "read command output",
                source,
            })?;
        if read == 0 {
            break;
        }
        let remaining = maximum.saturating_sub(retained.len());
        if remaining > 0 {
            retained.extend_from_slice(&buffer[..read.min(remaining)]);
        }
        truncated |= read > remaining;
    }
    let mut output = String::from_utf8_lossy(&retained).into_owned();
    if truncated {
        output.push_str("\n[process output truncated]");
    }
    Ok(output)
}

#[derive(Debug)]
pub struct ProcessOutput {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

impl ProcessOutput {
    #[must_use]
    pub fn success(&self) -> bool {
        self.code == Some(0)
    }

    fn require_success(&self, operation: &'static str) -> Result<(), SandboxError> {
        if self.success() {
            Ok(())
        } else {
            Err(self.failure(operation))
        }
    }

    fn failure(&self, operation: &'static str) -> SandboxError {
        SandboxError::Failed {
            operation,
            code: self.code,
            stderr: self.stderr.clone(),
        }
    }

    fn into_tool_output(self) -> Result<ToolOutput, SandboxError> {
        let is_error = !self.success();
        let mut content = self.stdout;
        if !self.stderr.is_empty() {
            if !content.is_empty() {
                content.push('\n');
            }
            content.push_str(&self.stderr);
        }
        Ok(ToolOutput { content, is_error })
    }

    fn redact(&mut self, secret: &str) {
        if secret.is_empty() {
            return;
        }
        self.stdout = self.stdout.replace(secret, "[REDACTED]");
        self.stderr = self.stderr.replace(secret, "[REDACTED]");
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ListFiles {
    path: Option<String>,
    max_depth: Option<u8>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SearchFiles {
    query: String,
    path: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadFile {
    path: String,
    start_line: Option<u32>,
    end_line: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ApplyPatch {
    patch: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ValidationCommand {
    program: String,
    args: Vec<String>,
}

#[derive(Debug, Error)]
pub enum SandboxError {
    #[error("failed to spawn {operation}: {source}")]
    Spawn {
        operation: &'static str,
        #[source]
        source: std::io::Error,
    },
    #[error("I/O failure during {operation}: {source}")]
    Io {
        operation: &'static str,
        #[source]
        source: std::io::Error,
    },
    #[error("{0} timed out; sandbox was terminated")]
    Timeout(&'static str),
    #[error("{operation} failed with exit code {code:?}: {stderr}")]
    Failed {
        operation: &'static str,
        code: Option<i32>,
        stderr: String,
    },
    #[error("sandbox process pipe was unavailable")]
    MissingPipe,
    #[error("sandbox output reader failed: {0}")]
    Reader(String),
    #[error("sandbox is no longer active")]
    Inactive,
    #[error("sandbox network could not be disconnected; sandbox was terminated")]
    NetworkIsolation,
    #[error("sandbox retained an untrusted process before network access and was terminated")]
    UnexpectedProcesses,
    #[error("repository owner or name is invalid")]
    InvalidRepository,
    #[error("invalid Git ref `{0}`")]
    InvalidGitRef(String),
    #[error("repository symlink `{0}` escapes the workspace")]
    EscapingSymlink(String),
    #[error("path `{0}` resolves outside the repository")]
    PathEscaped(String),
    #[error("changed path `{0}` is a symlink")]
    ChangedSymlink(String),
    #[error("binary changes are disabled")]
    BinaryChange,
    #[error("Git returned malformed diff statistics")]
    InvalidGitOutput,
    #[error("hard limit exceeded: {0}")]
    Limit(String),
    #[error("invalid tool arguments: {0}")]
    InvalidToolArguments(String),
    #[error(transparent)]
    Policy(#[from] PolicyError),
    #[error(transparent)]
    Command(#[from] crate::CommandError),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_branch_names_without_option_injection() {
        assert!(validate_git_ref("ai-fix/issue-42-parser").is_ok());
        assert!(validate_git_ref("--upload-pack=evil").is_err());
        assert!(validate_git_ref("refs/../evil").is_err());
        assert!(validate_git_ref("bad name").is_err());
    }

    #[test]
    fn docker_top_output_detects_residual_processes() {
        let idle = "UID PID PPID C STIME TTY TIME CMD\nworker 100 1 0 00:00 ? 00:00:00 tail -f /dev/null\n";
        let busy = format!("{idle}worker 101 1 0 00:00 ? 00:00:00 malicious\n");
        assert_eq!(process_rows(idle), 1);
        assert_eq!(process_rows(&busy), 2);
    }

    #[test]
    fn binary_numstat_is_rejected() {
        assert!(matches!(
            parse_numstat("-\t-\timage.png\n"),
            Err(SandboxError::BinaryChange)
        ));
    }

    #[tokio::test]
    async fn process_timeout_stops_the_command() {
        let mut command = Command::new("sleep");
        command.arg("2");
        let started = Instant::now();
        let result = run_process(
            "timeout test",
            command,
            None,
            Duration::from_millis(20),
            1024,
        )
        .await;
        assert!(matches!(result, Err(SandboxError::Timeout("timeout test"))));
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
