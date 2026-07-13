//! Typed, validated process configuration.

use std::{
    collections::HashSet,
    env, fmt,
    net::SocketAddr,
    path::{Path, PathBuf},
    str::FromStr,
};

use coding_bot_domain::AgentLimits;
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use url::Url;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RunMode {
    Api,
    Worker,
    All,
}

impl FromStr for RunMode {
    type Err = ConfigError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value.to_ascii_lowercase().as_str() {
            "api" => Ok(Self::Api),
            "worker" => Ok(Self::Worker),
            "all" => Ok(Self::All),
            _ => Err(ConfigError::Invalid {
                name: "RUN_MODE",
                reason: "expected api, worker, or all".to_owned(),
            }),
        }
    }
}

#[derive(Clone)]
pub struct Config {
    pub run_mode: RunMode,
    pub listen_addr: SocketAddr,
    database_url: SecretString,
    pub github_app_id: u64,
    pub github_private_key_path: PathBuf,
    github_webhook_secret: SecretString,
    pub github_bot_login: String,
    pub github_api_base_url: Url,
    pub github_web_base_url: Url,
    llm_api_key: SecretString,
    pub llm_base_url: Url,
    pub llm_model: String,
    admin_api_token: SecretString,
    pub repository_allowlist: HashSet<String>,
    pub limits: AgentLimits,
    pub worker_image: String,
    pub docker_binary: String,
    pub worker_poll_seconds: u64,
    pub worker_lease_seconds: u64,
    pub worker_memory: String,
    pub worker_cpus: String,
    pub worker_pids_limit: u32,
    pub worker_network: String,
    pub worker_workspace_size: String,
    pub blocked_paths: Vec<String>,
}

impl fmt::Debug for Config {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Config")
            .field("run_mode", &self.run_mode)
            .field("listen_addr", &self.listen_addr)
            .field("database_url", &"[REDACTED]")
            .field("github_app_id", &self.github_app_id)
            .field("github_private_key_path", &self.github_private_key_path)
            .field("github_webhook_secret", &"[REDACTED]")
            .field("github_bot_login", &self.github_bot_login)
            .field("github_api_base_url", &self.github_api_base_url)
            .field("github_web_base_url", &self.github_web_base_url)
            .field("llm_api_key", &"[REDACTED]")
            .field("llm_base_url", &self.llm_base_url)
            .field("llm_model", &self.llm_model)
            .field("admin_api_token", &"[REDACTED]")
            .field("repository_allowlist", &self.repository_allowlist)
            .field("limits", &self.limits)
            .field("worker_image", &self.worker_image)
            .field("docker_binary", &self.docker_binary)
            .field("worker_poll_seconds", &self.worker_poll_seconds)
            .field("worker_lease_seconds", &self.worker_lease_seconds)
            .field("worker_memory", &self.worker_memory)
            .field("worker_cpus", &self.worker_cpus)
            .field("worker_pids_limit", &self.worker_pids_limit)
            .field("worker_network", &self.worker_network)
            .field("worker_workspace_size", &self.worker_workspace_size)
            .field("blocked_paths", &self.blocked_paths)
            .finish()
    }
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let lookup = |name: &'static str| env::var(name).ok();
        let config = Self::from_lookup(lookup)?;
        config.validate_private_key()?;
        Ok(config)
    }

    fn from_lookup(lookup: impl Fn(&'static str) -> Option<String>) -> Result<Self, ConfigError> {
        let required = |name| {
            lookup(name)
                .filter(|value| !value.trim().is_empty())
                .ok_or(ConfigError::Missing(name))
        };
        let value_or = |name, default: &str| lookup(name).unwrap_or_else(|| default.to_owned());

        let allowlist = required("REPOSITORY_ALLOWLIST")?
            .split(',')
            .map(|entry| entry.trim().to_ascii_lowercase())
            .filter(|entry| !entry.is_empty())
            .collect::<HashSet<_>>();
        if allowlist.is_empty() || allowlist.iter().any(|entry| !valid_repository(entry)) {
            return Err(ConfigError::Invalid {
                name: "REPOSITORY_ALLOWLIST",
                reason: "expected comma-separated owner/repository entries".to_owned(),
            });
        }

        let limits = AgentLimits {
            max_steps: parse(&lookup, "MAX_AGENT_STEPS", "40")?,
            max_files_read: parse(&lookup, "MAX_FILES_READ", "200")?,
            max_files_modified: parse(&lookup, "MAX_FILES_MODIFIED", "25")?,
            max_diff_lines: parse(&lookup, "MAX_DIFF_LINES", "1500")?,
            max_command_seconds: parse(&lookup, "COMMAND_TIMEOUT_SECONDS", "900")?,
            max_job_seconds: parse(&lookup, "JOB_TIMEOUT_SECONDS", "3600")?,
            max_llm_tokens: parse(&lookup, "MAX_LLM_TOKENS", "120000")?,
            max_retries: parse(&lookup, "MAX_RETRY_COUNT", "3")?,
            max_tool_output_bytes: parse(&lookup, "MAX_TOOL_OUTPUT_BYTES", "65536")?,
        };
        validate_limits(&limits)?;

        let blocked_paths = value_or(
            "BLOCKED_PATHS",
            ".github/workflows/**,.github/actions/**,CODEOWNERS,.github/CODEOWNERS,**/CODEOWNERS,deploy/**,infrastructure/**,infra/**,k8s/**,helm/**,.git/**,.githooks/**,.ai-fix.toml,.env*,**/.env*,*secret*,**/*secret*,*credentials*,**/*credentials*,*token*,**/*token*,Dockerfile*,**/Dockerfile*,docker-compose*.yml,**/docker-compose*.yml,*.tf,**/*.tf,.gitlab-ci.yml",
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
        let worker_poll_seconds = parse(&lookup, "WORKER_POLL_SECONDS", "2")?;
        let worker_lease_seconds = parse(&lookup, "WORKER_LEASE_SECONDS", "60")?;
        let worker_memory = value_or("WORKER_MEMORY", "4g");
        let worker_cpus = value_or("WORKER_CPUS", "2");
        let worker_pids_limit = parse(&lookup, "WORKER_PIDS_LIMIT", "256")?;
        let worker_network = value_or("WORKER_NETWORK", "bridge");
        let worker_workspace_size = value_or("WORKER_WORKSPACE_SIZE", "8g");
        validate_worker_configuration(
            &worker_image,
            worker_poll_seconds,
            worker_lease_seconds,
            &worker_memory,
            &worker_cpus,
            worker_pids_limit,
            &worker_network,
            &worker_workspace_size,
        )?;

        Ok(Self {
            run_mode: value_or("RUN_MODE", "all").parse()?,
            listen_addr: parse(&lookup, "LISTEN_ADDR", "0.0.0.0:8080")?,
            database_url: SecretString::from(required("DATABASE_URL")?),
            github_app_id: parse_required(&required, "GITHUB_APP_ID")?,
            github_private_key_path: PathBuf::from(required("GITHUB_PRIVATE_KEY_PATH")?),
            github_webhook_secret: SecretString::from(required("GITHUB_WEBHOOK_SECRET")?),
            github_bot_login: required("GITHUB_BOT_LOGIN")?,
            github_api_base_url: parse_url(
                "GITHUB_API_BASE_URL",
                &value_or("GITHUB_API_BASE_URL", "https://api.github.com"),
            )?,
            github_web_base_url: parse_url(
                "GITHUB_WEB_BASE_URL",
                &value_or("GITHUB_WEB_BASE_URL", "https://github.com"),
            )?,
            llm_api_key: SecretString::from(required("LLM_API_KEY")?),
            llm_base_url: parse_url("LLM_BASE_URL", &required("LLM_BASE_URL")?)?,
            llm_model: required("LLM_MODEL")?,
            admin_api_token: SecretString::from(required("ADMIN_API_TOKEN")?),
            repository_allowlist: allowlist,
            limits,
            worker_image,
            docker_binary: value_or("DOCKER_BINARY", "docker"),
            worker_poll_seconds,
            worker_lease_seconds,
            worker_memory,
            worker_cpus,
            worker_pids_limit,
            worker_network,
            worker_workspace_size,
            blocked_paths,
        })
    }

    fn validate_private_key(&self) -> Result<(), ConfigError> {
        if !private_key_path_is_safe(&self.github_private_key_path)
            || !self.github_private_key_path.is_file()
        {
            return Err(ConfigError::Invalid {
                name: "GITHUB_PRIVATE_KEY_PATH",
                reason: format!(
                    "{} is not a readable file",
                    self.github_private_key_path.display()
                ),
            });
        }
        Ok(())
    }

    #[must_use]
    pub fn database_url(&self) -> &str {
        self.database_url.expose_secret()
    }

    #[must_use]
    pub fn github_webhook_secret(&self) -> &str {
        self.github_webhook_secret.expose_secret()
    }

    #[must_use]
    pub fn llm_api_key(&self) -> &str {
        self.llm_api_key.expose_secret()
    }

    #[must_use]
    pub fn admin_api_token(&self) -> &str {
        self.admin_api_token.expose_secret()
    }

    #[must_use]
    pub fn repository_allowed(&self, owner: &str, repository: &str) -> bool {
        self.repository_allowlist
            .contains(&format!("{owner}/{repository}").to_ascii_lowercase())
    }
}

fn parse<T: FromStr>(
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

fn parse_required<T: FromStr>(
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
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        return Err(ConfigError::Invalid {
            name,
            reason: "expected an absolute http(s) URL".to_owned(),
        });
    }
    Ok(url)
}

fn valid_repository(value: &str) -> bool {
    let mut components = value.split('/');
    matches!(
        (components.next(), components.next(), components.next()),
        (Some(owner), Some(repository), None) if !owner.is_empty() && !repository.is_empty()
    )
}

fn validate_limits(limits: &AgentLimits) -> Result<(), ConfigError> {
    if limits.max_steps == 0
        || limits.max_files_read == 0
        || limits.max_files_modified == 0
        || limits.max_diff_lines == 0
        || limits.max_command_seconds == 0
        || limits.max_job_seconds == 0
        || limits.max_llm_tokens == 0
        || limits.max_tool_output_bytes == 0
    {
        return Err(ConfigError::Invalid {
            name: "agent limits",
            reason: "all hard limits must be greater than zero".to_owned(),
        });
    }
    if limits.max_retries > 10 {
        return Err(ConfigError::Invalid {
            name: "MAX_RETRY_COUNT",
            reason: "must not exceed 10".to_owned(),
        });
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn validate_worker_configuration(
    image: &str,
    poll_seconds: u64,
    lease_seconds: u64,
    memory: &str,
    cpus: &str,
    pids_limit: u32,
    network: &str,
    workspace_size: &str,
) -> Result<(), ConfigError> {
    if poll_seconds == 0 || lease_seconds < 3 || pids_limit == 0 {
        return Err(ConfigError::Invalid {
            name: "worker scheduling limits",
            reason: "poll and PID limits must be positive and the lease must be at least 3 seconds"
                .to_owned(),
        });
    }
    if !valid_docker_identifier(image, true) || !valid_docker_identifier(network, false) {
        return Err(ConfigError::Invalid {
            name: "WORKER_IMAGE/WORKER_NETWORK",
            reason: "contains characters unsafe for Docker CLI arguments".to_owned(),
        });
    }
    if !valid_resource_size(memory) || !valid_resource_size(workspace_size) {
        return Err(ConfigError::Invalid {
            name: "WORKER_MEMORY/WORKER_WORKSPACE_SIZE",
            reason: "expected a positive integer with an optional b, k, m, g, or t suffix"
                .to_owned(),
        });
    }
    if cpus.parse::<f64>().map_or(true, |value| {
        !value.is_finite() || value <= 0.0 || value > 256.0
    }) {
        return Err(ConfigError::Invalid {
            name: "WORKER_CPUS",
            reason: "expected a number greater than zero and no more than 256".to_owned(),
        });
    }
    Ok(())
}

fn valid_docker_identifier(value: &str, allow_reference_separators: bool) -> bool {
    !value.is_empty()
        && value.len() <= 255
        && !value.starts_with('-')
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric()
                || "._-".contains(character)
                || (allow_reference_separators && "/:@".contains(character))
        })
}

fn valid_resource_size(value: &str) -> bool {
    let value = value.to_ascii_lowercase();
    let digits = value.trim_end_matches(['b', 'k', 'm', 'g', 't']);
    !digits.is_empty()
        && digits.len() + usize::from(digits.len() != value.len()) == value.len()
        && digits.bytes().all(|byte| byte.is_ascii_digit())
        && digits.parse::<u64>().is_ok_and(|number| number > 0)
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("missing required environment variable {0}")]
    Missing(&'static str),
    #[error("invalid {name}: {reason}")]
    Invalid { name: &'static str, reason: String },
}

#[must_use]
pub fn private_key_path_is_safe(path: &Path) -> bool {
    path.is_absolute() && path.file_name().is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_values_are_redacted() {
        let secret = SecretString::from("top-secret-value".to_owned());
        let rendered = format!("{secret:?}");
        assert!(!rendered.contains("top-secret-value"));
    }

    #[test]
    fn repository_names_require_owner_and_name() {
        assert!(valid_repository("hedwig-corp/sonar"));
        assert!(!valid_repository("sonar"));
        assert!(!valid_repository("a/b/c"));
    }
}
