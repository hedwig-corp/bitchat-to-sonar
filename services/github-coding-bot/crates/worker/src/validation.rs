use std::time::Duration;

use coding_bot_domain::ValidationResult;

use crate::{AllowedCommand, SandboxError, SandboxToolExecutor};

pub async fn validation_plan(
    executor: &SandboxToolExecutor,
) -> Result<Vec<AllowedCommand>, SandboxError> {
    let timeout = executor.command_timeout_seconds();
    if executor.repository_file_exists("Cargo.toml").await? {
        return Ok(vec![
            command("cargo", &["fmt", "--all", "--check"], timeout),
            command("cargo", &["check", "--workspace", "--all-targets"], timeout),
            command(
                "cargo",
                &[
                    "clippy",
                    "--workspace",
                    "--all-targets",
                    "--",
                    "-D",
                    "warnings",
                ],
                timeout,
            ),
            command("cargo", &["test", "--workspace"], timeout),
        ]);
    }
    if executor.repository_file_exists("go.mod").await? {
        return Ok(vec![command("go", &["test", "./..."], timeout)]);
    }
    if executor.repository_file_exists("package.json").await? {
        let program = if executor.repository_file_exists("pnpm-lock.yaml").await? {
            "pnpm"
        } else {
            "npm"
        };
        return Ok(vec![
            command(program, &["run", "lint"], timeout),
            command(program, &["test"], timeout),
            command(program, &["run", "build"], timeout),
        ]);
    }
    if executor.repository_file_exists("pyproject.toml").await?
        || executor.repository_file_exists("setup.py").await?
        || executor.repository_file_exists("setup.cfg").await?
    {
        return Ok(vec![command("python", &["-m", "pytest"], timeout)]);
    }
    if executor.repository_file_exists("Makefile").await? {
        return Ok(vec![command("make", &["test"], timeout)]);
    }
    Ok(Vec::new())
}

pub async fn run_controller_validation(
    executor: &SandboxToolExecutor,
) -> Result<Vec<ValidationResult>, SandboxError> {
    let plan = validation_plan(executor).await?;
    let mut results = Vec::with_capacity(plan.len());
    for command in plan {
        results.push(
            executor
                .run_validation(&command.program, &command.args)
                .await?,
        );
    }
    Ok(results)
}

fn command(program: &str, args: &[&str], timeout_seconds: u64) -> AllowedCommand {
    AllowedCommand {
        program: program.to_owned(),
        args: args.iter().map(|argument| (*argument).to_owned()).collect(),
        timeout_seconds,
    }
}

impl SandboxToolExecutor {
    #[must_use]
    pub(crate) fn command_timeout_seconds(&self) -> u64 {
        self.limits().max_command_seconds
    }

    pub(crate) async fn repository_file_exists(&self, path: &str) -> Result<bool, SandboxError> {
        let path = self.path_policy().validate_relative(path)?;
        let output = self
            .sandbox()
            .exec_in_repository("test", &["-f".to_owned(), path], Duration::from_secs(5))
            .await?;
        if output.success() {
            Ok(true)
        } else if output.code == Some(1) {
            Ok(false)
        } else {
            Err(SandboxError::Failed {
                operation: "inspect repository project type",
                code: output.code,
                stderr: output.stderr,
            })
        }
    }
}
