use std::time::Duration;

use serde::Deserialize;
use thiserror::Error;

use crate::{AllowedCommand, CommandError, CommandPolicy, DockerSandbox, SandboxError};

pub const REPOSITORY_CONFIG_FILE: &str = ".ai-fix.toml";

#[derive(Debug, Default)]
pub struct ResolvedRepositoryConfig {
    pub additional_blocked_paths: Vec<String>,
    pub validation_commands: Vec<AllowedCommand>,
}

pub async fn load_repository_config(
    sandbox: &DockerSandbox,
    command_policy: &CommandPolicy,
) -> Result<ResolvedRepositoryConfig, RepositoryConfigError> {
    let exists = sandbox
        .exec_in_repository(
            "test",
            &["-f".to_owned(), REPOSITORY_CONFIG_FILE.to_owned()],
            Duration::from_secs(5),
        )
        .await?;
    if exists.code == Some(1) {
        return Ok(ResolvedRepositoryConfig::default());
    }
    if !exists.success() {
        return Err(RepositoryConfigError::Read(exists.stderr));
    }
    let output = sandbox
        .exec_in_repository(
            "cat",
            &["--".to_owned(), REPOSITORY_CONFIG_FILE.to_owned()],
            Duration::from_secs(5),
        )
        .await?;
    if !output.success() {
        return Err(RepositoryConfigError::Read(output.stderr));
    }
    resolve_repository_config(&output.stdout, command_policy)
}

fn resolve_repository_config(
    source: &str,
    command_policy: &CommandPolicy,
) -> Result<ResolvedRepositoryConfig, RepositoryConfigError> {
    if source.len() > 65_536 {
        return Err(RepositoryConfigError::TooLarge);
    }
    let parsed: RepositoryConfigFile = toml::from_str(source)?;
    if parsed.version != 1 {
        return Err(RepositoryConfigError::UnsupportedVersion(parsed.version));
    }
    if parsed.additional_blocked_paths.len() > 20 || parsed.validation_commands.len() > 20 {
        return Err(RepositoryConfigError::TooManyEntries);
    }
    if parsed
        .additional_blocked_paths
        .iter()
        .any(|pattern| pattern.trim().is_empty() || pattern.len() > 256 || pattern.contains('\0'))
    {
        return Err(RepositoryConfigError::InvalidBlockedPath);
    }
    let validation_commands = parsed
        .validation_commands
        .into_iter()
        .map(|command| command_policy.resolve(&command.program, &command.args))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(ResolvedRepositoryConfig {
        additional_blocked_paths: parsed.additional_blocked_paths,
        validation_commands,
    })
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RepositoryConfigFile {
    version: u32,
    #[serde(default)]
    additional_blocked_paths: Vec<String>,
    #[serde(default)]
    validation_commands: Vec<ConfiguredCommand>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfiguredCommand {
    program: String,
    args: Vec<String>,
}

#[derive(Debug, Error)]
pub enum RepositoryConfigError {
    #[error(transparent)]
    Sandbox(#[from] SandboxError),
    #[error("could not read {REPOSITORY_CONFIG_FILE}: {0}")]
    Read(String),
    #[error("{REPOSITORY_CONFIG_FILE} exceeds 64 KiB")]
    TooLarge,
    #[error("unsupported {REPOSITORY_CONFIG_FILE} version {0}")]
    UnsupportedVersion(u32),
    #[error("{REPOSITORY_CONFIG_FILE} has too many policy entries")]
    TooManyEntries,
    #[error("{REPOSITORY_CONFIG_FILE} contains an invalid blocked-path pattern")]
    InvalidBlockedPath,
    #[error(transparent)]
    Parse(#[from] toml::de::Error),
    #[error(transparent)]
    Command(#[from] CommandError),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repository_config_cannot_add_arbitrary_commands() {
        let source = r#"
version = 1

[[validation_commands]]
program = "curl"
args = ["https://example.com"]
"#;
        let result = resolve_repository_config(source, &CommandPolicy::standard(30));
        assert!(matches!(result, Err(RepositoryConfigError::Command(_))));
    }

    #[test]
    fn repository_config_can_only_tighten_policy() {
        let source = r#"
version = 1
additional_blocked_paths = ["generated/**"]

[[validation_commands]]
program = "cargo"
args = ["test", "--workspace"]
"#;
        let result = resolve_repository_config(source, &CommandPolicy::standard(30));
        let Ok(result) = result else {
            panic!("valid repository policy was rejected");
        };
        assert_eq!(result.additional_blocked_paths, ["generated/**"]);
        assert_eq!(result.validation_commands.len(), 1);
    }
}
