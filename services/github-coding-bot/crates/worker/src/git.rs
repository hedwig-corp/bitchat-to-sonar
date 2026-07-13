use std::time::Duration;

use uuid::Uuid;

use crate::{validate_git_ref, DockerSandbox, SandboxError};

pub struct GitWorkflow<'a> {
    sandbox: &'a DockerSandbox,
}

impl<'a> GitWorkflow<'a> {
    #[must_use]
    pub fn new(sandbox: &'a DockerSandbox) -> Self {
        Self { sandbox }
    }

    pub async fn commit(
        &self,
        branch: &str,
        issue_number: u64,
        changed_files: &[String],
    ) -> Result<String, GitWorkflowError> {
        validate_git_ref(branch)?;
        if changed_files.is_empty() {
            return Err(GitWorkflowError::NoChanges);
        }
        self.run(
            "configure Git author",
            &[
                "config".to_owned(),
                "user.name".to_owned(),
                "Sonar AI Fix Bot".to_owned(),
            ],
        )
        .await?;
        self.run(
            "configure Git email",
            &[
                "config".to_owned(),
                "user.email".to_owned(),
                "ai-fix-bot@users.noreply.github.com".to_owned(),
            ],
        )
        .await?;
        self.run(
            "create proposal branch",
            &[
                "switch".to_owned(),
                "--create".to_owned(),
                branch.to_owned(),
            ],
        )
        .await?;

        let mut add = vec!["add".to_owned(), "--".to_owned()];
        add.extend(changed_files.iter().cloned());
        self.run("stage intended changes", &add).await?;

        let staged = self
            .sandbox
            .exec_in_repository(
                "git",
                &[
                    "diff".to_owned(),
                    "--cached".to_owned(),
                    "--quiet".to_owned(),
                    "--exit-code".to_owned(),
                ],
                Duration::from_secs(30),
            )
            .await?;
        if staged.code == Some(0) {
            return Err(GitWorkflowError::NoChanges);
        }
        if staged.code != Some(1) {
            return Err(GitWorkflowError::GitCommand {
                operation: "inspect staged changes",
                code: staged.code,
                stderr: staged.stderr,
            });
        }

        self.run(
            "commit proposal",
            &[
                "commit".to_owned(),
                "--message".to_owned(),
                format!("fix: resolve issue #{issue_number}"),
            ],
        )
        .await?;
        let revision = self
            .run(
                "read proposal revision",
                &["rev-parse".to_owned(), "HEAD".to_owned()],
            )
            .await?;
        let revision = revision.stdout.trim();
        if revision.len() != 40 || !revision.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(GitWorkflowError::InvalidRevision);
        }
        Ok(revision.to_owned())
    }

    pub async fn push(
        &self,
        branch: &str,
        repository_url: &str,
        token: &str,
    ) -> Result<(), GitWorkflowError> {
        validate_git_ref(branch)?;
        if !repository_url.starts_with("https://") && !repository_url.starts_with("http://") {
            return Err(GitWorkflowError::InvalidRepositoryUrl);
        }
        self.sandbox.ensure_idle_for_network().await?;
        self.sandbox.connect_network().await?;
        let push = self
            .sandbox
            .exec_with_token_as_publisher(
                "git",
                &[
                    "push".to_owned(),
                    repository_url.to_owned(),
                    format!("HEAD:refs/heads/{branch}"),
                ],
                Duration::from_secs(300),
                token,
            )
            .await;
        let disconnected = self.sandbox.disconnect_network().await;
        if disconnected.is_err() {
            let _ = self.sandbox.shutdown().await;
            return Err(GitWorkflowError::NetworkIsolation);
        }
        let output = push?;
        if output.success() {
            Ok(())
        } else {
            Err(GitWorkflowError::GitCommand {
                operation: "push proposal branch",
                code: output.code,
                stderr: output.stderr,
            })
        }
    }

    async fn run(
        &self,
        operation: &'static str,
        args: &[String],
    ) -> Result<crate::ProcessOutput, GitWorkflowError> {
        let output = self
            .sandbox
            .exec_as_publisher("git", args, Duration::from_secs(60))
            .await?;
        if output.success() {
            Ok(output)
        } else {
            Err(GitWorkflowError::GitCommand {
                operation,
                code: output.code,
                stderr: output.stderr,
            })
        }
    }
}

#[must_use]
pub fn proposal_branch(issue_number: u64, title: &str, job_id: Uuid) -> String {
    let mut slug = String::new();
    let mut previous_dash = false;
    for character in title.chars().flat_map(char::to_lowercase) {
        if character.is_ascii_alphanumeric() {
            slug.push(character);
            previous_dash = false;
        } else if !previous_dash && !slug.is_empty() {
            slug.push('-');
            previous_dash = true;
        }
        if slug.len() >= 48 {
            break;
        }
    }
    let slug = slug.trim_matches('-');
    let slug = if slug.is_empty() {
        "proposed-fix"
    } else {
        slug
    };
    let id = job_id.simple().to_string();
    format!("ai-fix/issue-{issue_number}-{slug}-{}", &id[..8])
}

#[must_use]
pub fn pull_request_title(summary: &str) -> String {
    let single_line = summary.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut title = single_line.chars().take(120).collect::<String>();
    if title.is_empty() {
        title = "Propose a safe issue fix".to_owned();
    }
    if let Some(first) = title.get_mut(0..1) {
        first.make_ascii_uppercase();
    }
    title
}

#[derive(Debug, thiserror::Error)]
pub enum GitWorkflowError {
    #[error(transparent)]
    Sandbox(#[from] SandboxError),
    #[error("{operation} failed with exit code {code:?}: {stderr}")]
    GitCommand {
        operation: &'static str,
        code: Option<i32>,
        stderr: String,
    },
    #[error("proposal contains no meaningful changes")]
    NoChanges,
    #[error("Git returned an invalid commit revision")]
    InvalidRevision,
    #[error("repository publication URL must be absolute HTTP(S)")]
    InvalidRepositoryUrl,
    #[error("sandbox network could not be disabled after push")]
    NetworkIsolation,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn branch_names_are_sanitized_and_bounded() {
        let id = Uuid::from_u128(0x1234);
        let branch = proposal_branch(
            42,
            "Fix parser: don't accept ../../outside or `--flags`!",
            id,
        );
        assert!(branch.starts_with("ai-fix/issue-42-fix-parser-don-t-accept-outside-or-flags-"));
        assert!(validate_git_ref(&branch).is_ok());
        assert!(branch.len() < 120);
    }
}
