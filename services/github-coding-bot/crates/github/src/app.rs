use std::{fmt, path::Path};

use jsonwebtoken::EncodingKey;
use octocrab::{models::AppId, Octocrab};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;
use url::Url;

#[derive(Clone)]
pub struct GitHubApp {
    app: Octocrab,
}

impl GitHubApp {
    pub fn from_pem_file(
        app_id: u64,
        private_key_path: &Path,
        api_base_url: &Url,
    ) -> Result<Self, GitHubError> {
        let metadata =
            std::fs::metadata(private_key_path).map_err(|source| GitHubError::ReadKey {
                path: private_key_path.display().to_string(),
                source,
            })?;
        if metadata.len() > 1024 * 1024 {
            return Err(GitHubError::KeyTooLarge);
        }
        let pem = std::fs::read(private_key_path).map_err(|source| GitHubError::ReadKey {
            path: private_key_path.display().to_string(),
            source,
        })?;
        let key = EncodingKey::from_rsa_pem(&pem)?;
        let app = Octocrab::builder()
            .base_uri(api_base_url.as_str())?
            .app(AppId(app_id), key)
            .build()?;
        Ok(Self { app })
    }

    pub async fn repository(
        &self,
        owner: &str,
        repository: &str,
    ) -> Result<RepositoryClient, GitHubError> {
        validate_component(owner)?;
        validate_component(repository)?;
        let route = format!("/repos/{owner}/{repository}/installation");
        let installation: RepositoryInstallation = self.app.get(route, None::<&()>).await?;
        let (client, token) = self
            .app
            .installation_and_token(octocrab::models::InstallationId(installation.id))
            .await?;
        Ok(RepositoryClient {
            client,
            token: InstallationToken(SecretString::from(token)),
            owner: owner.to_owned(),
            repository: repository.to_owned(),
            installation_id: installation.id,
        })
    }
}

pub struct RepositoryClient {
    client: Octocrab,
    token: InstallationToken,
    owner: String,
    repository: String,
    installation_id: u64,
}

impl RepositoryClient {
    #[must_use]
    pub fn installation_id(&self) -> u64 {
        self.installation_id
    }

    #[must_use]
    pub fn token(&self) -> &str {
        self.token.0.expose_secret()
    }

    pub fn repository_route(&self, suffix: &str) -> Result<String, GitHubError> {
        if (!suffix.is_empty() && !suffix.starts_with('/')) || suffix.starts_with("//") {
            return Err(GitHubError::InvalidRoute);
        }
        if suffix.contains("..") || suffix.contains(['?', '#', '\0']) {
            return Err(GitHubError::InvalidRoute);
        }
        Ok(format!(
            "/repos/{}/{}{}",
            self.owner, self.repository, suffix
        ))
    }

    pub async fn get<P: Serialize + ?Sized>(
        &self,
        suffix: &str,
        query: Option<&P>,
    ) -> Result<Value, GitHubError> {
        Ok(self
            .client
            .get(self.repository_route(suffix)?, query)
            .await?)
    }

    pub async fn post<B: Serialize + ?Sized>(
        &self,
        suffix: &str,
        body: &B,
    ) -> Result<Value, GitHubError> {
        Ok(self
            .client
            .post(self.repository_route(suffix)?, Some(body))
            .await?)
    }

    pub async fn patch<B: Serialize + ?Sized>(
        &self,
        suffix: &str,
        body: &B,
    ) -> Result<Value, GitHubError> {
        Ok(self
            .client
            .patch(self.repository_route(suffix)?, Some(body))
            .await?)
    }

    pub async fn put<B: Serialize + ?Sized>(
        &self,
        suffix: &str,
        body: &B,
    ) -> Result<Value, GitHubError> {
        Ok(self
            .client
            .put(self.repository_route(suffix)?, Some(body))
            .await?)
    }
}

struct InstallationToken(SecretString);

impl fmt::Debug for InstallationToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("InstallationToken([REDACTED])")
    }
}

#[derive(Debug, Deserialize)]
struct RepositoryInstallation {
    id: u64,
}

pub fn validate_component(value: &str) -> Result<(), GitHubError> {
    if value.is_empty()
        || value.len() > 100
        || !value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "-_.".contains(character))
    {
        return Err(GitHubError::InvalidRepository);
    }
    Ok(())
}

pub fn bounded_json(value: &Value, maximum_bytes: usize) -> Result<String, GitHubError> {
    let serialized = serde_json::to_string_pretty(value)?;
    if serialized.len() <= maximum_bytes {
        return Ok(serialized);
    }
    let mut boundary = maximum_bytes.saturating_sub(64);
    while boundary > 0 && !serialized.is_char_boundary(boundary) {
        boundary -= 1;
    }
    Ok(format!(
        "{}\n[GitHub response truncated at {maximum_bytes} bytes]",
        &serialized[..boundary]
    ))
}

#[derive(Debug, Error)]
pub enum GitHubError {
    #[error("failed to read GitHub App key at {path}: {source}")]
    ReadKey {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error(transparent)]
    Jwt(#[from] jsonwebtoken::errors::Error),
    #[error(transparent)]
    Octocrab(#[from] octocrab::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error("repository owner or name is invalid")]
    InvalidRepository,
    #[error("GitHub API route is invalid")]
    InvalidRoute,
    #[error("GitHub App private key exceeds 1 MiB")]
    KeyTooLarge,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repository_components_cannot_inject_routes() {
        assert!(validate_component("acme-inc").is_ok());
        assert!(validate_component("../installation").is_err());
        assert!(validate_component("name/other").is_err());
    }

    #[test]
    fn bounded_json_limits_model_context() {
        let value = serde_json::json!({"body": "x".repeat(10_000)});
        let rendered = bounded_json(&value, 1024).expect("JSON should serialize");
        assert!(rendered.len() < 1100);
        assert!(rendered.contains("truncated"));
    }
}
