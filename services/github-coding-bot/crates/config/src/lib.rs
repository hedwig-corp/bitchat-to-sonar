//! Typed, validated process configuration for the Hermes MCP tool server.

use std::{collections::HashSet, env, fmt, path::PathBuf};

use coding_bot_domain::WorkspaceLimits;
use secrecy::{ExposeSecret, SecretString};
use thiserror::Error;
use url::Url;

#[derive(Clone)]
pub struct Config {
    database_url: SecretString,
    pub github_app_id: u64,
    pub github_private_key_path: PathBuf,
    pub github_api_base_url: Url,
    pub github_web_base_url: Url,
    pub authorized_senders: HashSet<String>,
    pub repository_allowlist: HashSet<String>,
    pub confirmation_ttl_seconds: u64,
    pub limits: WorkspaceLimits,
    pub worker_image: String,
    pub docker_binary: String,
    pub worker_memory: String,
    pub worker_cpus: String,
    pub worker_pids_limit: u32,
    pub worker_network: String,
    pub worker_workspace_size: String,
    pub blocked_paths: Vec<String>,
    pub git_author_name: String,
    pub git_author_email: String,
}

impl fmt::Debug for Config {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Config")
            .field("database_url", &"[REDACTED]")
            .field("github_app_id", &self.github_app_id)
            .field("github_private_key_path", &self.github_private_key_path)
            .field("github_api_base_url", &self.github_api_base_url)
            .field("github_web_base_url", &self.github_web_base_url)
            .field("authorized_senders", &self.authorized_senders)
            .field("repository_allowlist", &self.repository_allowlist)
            .field("confirmation_ttl_seconds", &self.confirmation_ttl_seconds)
            .field("limits", &self.limits)
            .field("worker_image", &self.worker_image)
            .field("docker_binary", &self.docker_binary)
            .field("worker_memory", &self.worker_memory)
            .field("worker_cpus", &self.worker_cpus)
            .field("worker_pids_limit", &self.worker_pids_limit)
            .field("worker_network", &self.worker_network)
            .field("worker_workspace_size", &self.worker_workspace_size)
            .field("blocked_paths", &self.blocked_paths)
            .field("git_author_name", &self.git_author_name)
            .field("git_author_email", &self.git_author_email)
            .finish()
    }
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let lookup = |name: &'static str| env::var(name).ok();
        let config = Self::from_lookup(lookup)?;
        if !config.github_private_key_path.is_file() {
            return Err(ConfigError::Invalid {
                name: "GITHUB_PRIVATE_KEY_PATH",
                reason: format!(
                    "{} is not a readable file",
                    config.github_private_key_path.display()
                ),
            });
        }
        Ok(config)
    }

    fn from_lookup(lookup: impl Fn(&'static str) -> Option<String>) -> Result<Self, ConfigError> {
        let required = |name| {
            lookup(name)
                .filter(|value| !value.trim().is_empty())
                .ok_or(ConfigError::Missing(name))
        };
        let value_or = |name, default: &str| lookup(name).unwrap_or_else(|| default.to_owned());

        let authorized_senders = parse_set(&required("SONAR_AUTHORIZED_SENDERS")?);
        if authorized_senders.is_empty()
            || authorized_senders
                .iter()
                .any(|sender| sender.len() > 256 || sender.contains(char::is_whitespace))
        {
            return Err(ConfigError::Invalid {
                name: "SONAR_AUTHORIZED_SENDERS",
                reason: "expected comma-separated Sonar sender identifiers".to_owned(),
            });
        }

        let repository_allowlist = parse_set(&required("REPOSITORY_ALLOWLIST")?);
        if repository_allowlist.is_empty()
            || repository_allowlist
                .iter()
                .any(|entry| !valid_repository(entry))
        {
            return Err(ConfigError::Invalid {
                name: "REPOSITORY_ALLOWLIST",
                reason: "expected comma-separated owner/repository entries".to_owned(),
            });
        }

        let limits = WorkspaceLimits {
            max_files_read: parse(&lookup, "MAX_FILES_READ", "200")?,
            max_files_modified: parse(&lookup, "MAX_FILES_MODIFIED", "25")?,
            max_diff_lines: parse(&lookup, "MAX_DIFF_LINES", "1500")?,
            max_command_seconds: parse(&lookup, "COMMAND_TIMEOUT_SECONDS", "900")?,
            max_workspace_seconds: parse(&lookup, "WORKSPACE_TTL_SECONDS", "3600")?,
            max_tool_output_bytes: parse(&lookup, "MAX_TOOL_OUTPUT_BYTES", "65536")?,
        };
        validate_limits(&limits)?;

        let blocked_paths = value_or(
            "BLOCKED_PATHS",
            ".github/workflows/**,.github/actions/**,CODEOWNERS,.github/CODEOWNERS,**/CODEOWNERS,deploy/**,infrastructure/**,infra/**,k8s/**,helm/**,.git/**,.githooks/**,.env*,**/.env*,*secret*,**/*secret*,*credentials*,**/*credentials*,*token*,**/*token*,Dockerfile*,**/Dockerfile*,docker-compose*.yml,**/docker-compose*.yml,*.tf,**/*.tf,.gitlab-ci.yml",
        )
        .split(',')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .map(str::to_owned)
        .collect::<Vec<_>>();
        if blocked_paths.is_empty() {
            return Err(ConfigError::Invalid {
                name: "BLOCKED_PATHS",
                reason: "must contain at least one protected-path pattern".to_owned(),
            });
        }

        let worker_image = required("WORKER_IMAGE")?;
        let worker_pids_limit = parse(&lookup, "WORKER_PIDS_LIMIT", "256")?;
        let worker_network = value_or("WORKER_NETWORK", "bridge");
        if worker_pids_limit == 0 || worker_network == "host" || worker_network == "none" {
            return Err(ConfigError::Invalid {
                name: "WORKER_NETWORK",
                reason: "worker network must be a non-host Docker network used only for clone/push"
                    .to_owned(),
            });
        }

        let confirmation_ttl_seconds = parse(&lookup, "CONFIRMATION_TTL_SECONDS", "300")?;
        if !(30..=900).contains(&confirmation_ttl_seconds) {
            return Err(ConfigError::Invalid {
                name: "CONFIRMATION_TTL_SECONDS",
                reason: "must be between 30 and 900 seconds".to_owned(),
            });
        }

        Ok(Self {
            database_url: SecretString::from(required("DATABASE_URL")?),
            github_app_id: parse_required(&required, "GITHUB_APP_ID")?,
            github_private_key_path: PathBuf::from(required("GITHUB_PRIVATE_KEY_PATH")?),
            github_api_base_url: parse_url(
                "GITHUB_API_BASE_URL",
                &value_or("GITHUB_API_BASE_URL", "https://api.github.com"),
            )?,
            github_web_base_url: parse_url(
                "GITHUB_WEB_BASE_URL",
                &value_or("GITHUB_WEB_BASE_URL", "https://github.com"),
            )?,
            authorized_senders,
            repository_allowlist,
            confirmation_ttl_seconds,
            limits,
            worker_image,
            docker_binary: value_or("DOCKER_BINARY", "docker"),
            worker_memory: value_or("WORKER_MEMORY", "4g"),
            worker_cpus: value_or("WORKER_CPUS", "2"),
            worker_pids_limit,
            worker_network,
            worker_workspace_size: value_or("WORKER_WORKSPACE_SIZE", "8g"),
            blocked_paths,
            git_author_name: value_or("GIT_AUTHOR_NAME", "Hermes GitHub Bot"),
            git_author_email: value_or(
                "GIT_AUTHOR_EMAIL",
                "hermes-github-bot@users.noreply.github.com",
            ),
        })
    }

    #[must_use]
    pub fn database_url(&self) -> &str {
        self.database_url.expose_secret()
    }

    #[must_use]
    pub fn actor_allowed(&self, actor: &str) -> bool {
        self.authorized_senders
            .contains(&actor.to_ascii_lowercase())
    }

    #[must_use]
    pub fn repository_allowed(&self, owner: &str, repository: &str) -> bool {
        self.repository_allowlist
            .contains(&format!("{owner}/{repository}").to_ascii_lowercase())
    }
}

fn parse_set(value: &str) -> HashSet<String> {
    value
        .split(',')
        .map(|entry| entry.trim().to_ascii_lowercase())
        .filter(|entry| !entry.is_empty())
        .collect()
}

fn parse<T: std::str::FromStr>(
    lookup: &impl Fn(&'static str) -> Option<String>,
    name: &'static str,
    default: &str,
) -> Result<T, ConfigError>
where
    T::Err: fmt::Display,
{
    lookup(name)
        .unwrap_or_else(|| default.to_owned())
        .parse()
        .map_err(|error: T::Err| ConfigError::Invalid {
            name,
            reason: error.to_string(),
        })
}

fn parse_required<T: std::str::FromStr>(
    required: &impl Fn(&'static str) -> Result<String, ConfigError>,
    name: &'static str,
) -> Result<T, ConfigError>
where
    T::Err: fmt::Display,
{
    required(name)?
        .parse()
        .map_err(|error: T::Err| ConfigError::Invalid {
            name,
            reason: error.to_string(),
        })
}

fn parse_url(name: &'static str, value: &str) -> Result<Url, ConfigError> {
    let url = Url::parse(value).map_err(|error| ConfigError::Invalid {
        name,
        reason: error.to_string(),
    })?;
    let host = url.host_str();
    let loopback_http =
        url.scheme() == "http" && matches!(host, Some("localhost" | "127.0.0.1" | "::1"));
    if (url.scheme() != "https" && !loopback_http) || host.is_none() {
        return Err(ConfigError::Invalid {
            name,
            reason: "expected an absolute HTTPS URL (HTTP is limited to loopback)".to_owned(),
        });
    }
    Ok(url)
}

fn valid_repository(value: &str) -> bool {
    let mut parts = value.split('/');
    matches!(
        (parts.next(), parts.next(), parts.next()),
        (Some(owner), Some(repository), None)
            if valid_component(owner) && valid_component(repository)
    )
}

fn valid_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 100
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "-_.".contains(character))
}

fn validate_limits(limits: &WorkspaceLimits) -> Result<(), ConfigError> {
    if limits.max_files_read == 0
        || limits.max_files_modified == 0
        || limits.max_diff_lines == 0
        || limits.max_command_seconds == 0
        || limits.max_workspace_seconds < 60
        || limits.max_tool_output_bytes < 1024
    {
        return Err(ConfigError::Invalid {
            name: "workspace limits",
            reason: "all limits must be non-zero and workspace TTL must be at least 60 seconds"
                .to_owned(),
        });
    }
    Ok(())
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("missing required environment variable {0}")]
    Missing(&'static str),
    #[error("invalid {name}: {reason}")]
    Invalid { name: &'static str, reason: String },
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    fn valid() -> HashMap<&'static str, String> {
        HashMap::from([
            ("DATABASE_URL", "postgres://localhost/test".to_owned()),
            ("GITHUB_APP_ID", "42".to_owned()),
            ("GITHUB_PRIVATE_KEY_PATH", "/tmp/app.pem".to_owned()),
            ("SONAR_AUTHORIZED_SENDERS", "npub1alice,npub1bob".to_owned()),
            ("REPOSITORY_ALLOWLIST", "acme/widgets".to_owned()),
            ("WORKER_IMAGE", "hermes-worker:latest".to_owned()),
        ])
    }

    #[test]
    fn does_not_require_an_llm_or_webhook_secret() {
        let values = valid();
        let config = Config::from_lookup(|name| values.get(name).cloned());
        assert!(config.is_ok());
    }

    #[test]
    fn rejects_host_network_and_empty_actor_policy() {
        let mut values = valid();
        values.insert("WORKER_NETWORK", "host".to_owned());
        assert!(Config::from_lookup(|name| values.get(name).cloned()).is_err());

        let mut values = valid();
        values.insert("SONAR_AUTHORIZED_SENDERS", "  ".to_owned());
        assert!(Config::from_lookup(|name| values.get(name).cloned()).is_err());

        let mut values = valid();
        values.insert(
            "GITHUB_API_BASE_URL",
            "http://github.example.test".to_owned(),
        );
        assert!(Config::from_lookup(|name| values.get(name).cloned()).is_err());
    }
}
