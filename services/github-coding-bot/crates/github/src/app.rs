use std::{fmt, path::Path, sync::Arc};

use async_trait::async_trait;
use coding_bot_domain::{DraftPullRequest, IssueComment, IssueContext, OpenedPullRequest};
use jsonwebtoken::EncodingKey;
use octocrab::{models::AppId, Octocrab};
use secrecy::{ExposeSecret, SecretString};
use serde::Deserialize;
use thiserror::Error;
use url::Url;

const MAX_ISSUE_BODY_BYTES: usize = 32 * 1024;
const MAX_COMMENT_BODY_BYTES: usize = 4 * 1024;
const MAX_ISSUE_COMMENTS: usize = 50;

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

    pub fn generate_app_jwt(app_id: u64, key: &EncodingKey) -> Result<String, GitHubError> {
        Ok(octocrab::auth::create_jwt(AppId(app_id), key)?)
    }
}

#[async_trait]
pub trait GitHubAppApi: Send + Sync {
    async fn installation(&self, installation_id: u64) -> Result<InstallationAccess, GitHubError>;
}

#[async_trait]
impl GitHubAppApi for GitHubApp {
    async fn installation(&self, installation_id: u64) -> Result<InstallationAccess, GitHubError> {
        let (client, token) = self
            .app
            .installation_and_token(octocrab::models::InstallationId(installation_id))
            .await?;
        Ok(InstallationAccess {
            api: Arc::new(OctocrabInstallation { client }),
            token: InstallationToken(token),
        })
    }
}

pub struct InstallationAccess {
    pub api: Arc<dyn GitHubInstallationApi>,
    token: InstallationToken,
}

impl InstallationAccess {
    #[must_use]
    pub fn new(api: Arc<dyn GitHubInstallationApi>, token: String) -> Self {
        Self {
            api,
            token: InstallationToken::new(token),
        }
    }

    #[must_use]
    pub fn token(&self) -> &str {
        self.token.expose()
    }
}

impl fmt::Debug for InstallationAccess {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("InstallationAccess")
            .field("api", &"GitHubInstallationApi")
            .field("token", &self.token)
            .finish()
    }
}

pub struct InstallationToken(SecretString);

impl InstallationToken {
    #[must_use]
    pub fn new(value: String) -> Self {
        Self(SecretString::from(value))
    }

    #[must_use]
    pub fn expose(&self) -> &str {
        self.0.expose_secret()
    }
}

impl fmt::Debug for InstallationToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("InstallationToken([REDACTED])")
    }
}

#[async_trait]
pub trait GitHubInstallationApi: Send + Sync {
    async fn trusted_actor(
        &self,
        owner: &str,
        repository: &str,
        login: &str,
    ) -> Result<bool, GitHubError>;

    async fn issue_context(
        &self,
        owner: &str,
        repository: &str,
        issue_number: u64,
    ) -> Result<IssueContext, GitHubError>;

    async fn issue_is_open_with_label(
        &self,
        owner: &str,
        repository: &str,
        issue_number: u64,
        label: &str,
    ) -> Result<bool, GitHubError>;

    async fn comment(
        &self,
        owner: &str,
        repository: &str,
        issue_number: u64,
        body: &str,
    ) -> Result<(), GitHubError>;

    async fn create_draft_pull_request(
        &self,
        owner: &str,
        repository: &str,
        request: DraftPullRequest,
    ) -> Result<OpenedPullRequest, GitHubError>;
}

struct OctocrabInstallation {
    client: Octocrab,
}

#[async_trait]
impl GitHubInstallationApi for OctocrabInstallation {
    async fn trusted_actor(
        &self,
        owner: &str,
        repository: &str,
        login: &str,
    ) -> Result<bool, GitHubError> {
        let route = format!("/repos/{owner}/{repository}/collaborators/{login}/permission");
        let response: PermissionResponse = self.client.get(route, None::<&()>).await?;
        Ok(matches!(
            response.permission.as_str(),
            "admin" | "maintain" | "write"
        ))
    }

    async fn issue_context(
        &self,
        owner: &str,
        repository: &str,
        issue_number: u64,
    ) -> Result<IssueContext, GitHubError> {
        let issue = self
            .client
            .issues(owner, repository)
            .get(issue_number)
            .await?;
        let mut page = self
            .client
            .issues(owner, repository)
            .list_comments(issue_number)
            .per_page(100)
            .send()
            .await?;
        let mut comments = Vec::new();
        loop {
            for comment in page.take_items() {
                if comments.len() >= MAX_ISSUE_COMMENTS {
                    break;
                }
                comments.push(IssueComment {
                    author: comment.user.login,
                    body: bounded_text(comment.body.unwrap_or_default(), MAX_COMMENT_BODY_BYTES),
                });
            }
            if comments.len() >= MAX_ISSUE_COMMENTS {
                break;
            }
            let Some(next) = self.client.get_page(&page.next).await? else {
                break;
            };
            page = next;
        }

        Ok(IssueContext {
            title: issue.title,
            body: bounded_text(issue.body.unwrap_or_default(), MAX_ISSUE_BODY_BYTES),
            author: issue.user.login,
            state: format!("{:?}", issue.state).to_ascii_lowercase(),
            labels: issue.labels.into_iter().map(|label| label.name).collect(),
            comments,
            html_url: issue.html_url.to_string(),
        })
    }

    async fn issue_is_open_with_label(
        &self,
        owner: &str,
        repository: &str,
        issue_number: u64,
        label: &str,
    ) -> Result<bool, GitHubError> {
        let issue = self
            .client
            .issues(owner, repository)
            .get(issue_number)
            .await?;
        Ok(format!("{:?}", issue.state).eq_ignore_ascii_case("open")
            && issue.labels.iter().any(|candidate| candidate.name == label))
    }

    async fn comment(
        &self,
        owner: &str,
        repository: &str,
        issue_number: u64,
        body: &str,
    ) -> Result<(), GitHubError> {
        self.client
            .issues(owner, repository)
            .create_comment(issue_number, body)
            .await?;
        Ok(())
    }

    async fn create_draft_pull_request(
        &self,
        owner: &str,
        repository: &str,
        request: DraftPullRequest,
    ) -> Result<OpenedPullRequest, GitHubError> {
        let pull = self
            .client
            .pulls(owner, repository)
            .create(request.title, request.head, request.base)
            .body(request.body)
            .draft(true)
            .send()
            .await?;
        let html_url = pull
            .html_url
            .ok_or(GitHubError::MissingResponseField("pull_request.html_url"))?;
        Ok(OpenedPullRequest {
            number: pull.number,
            html_url: html_url.to_string(),
        })
    }
}

fn bounded_text(mut value: String, maximum_bytes: usize) -> String {
    if value.len() <= maximum_bytes {
        return value;
    }
    let mut boundary = maximum_bytes;
    while boundary > 0 && !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    value.truncate(boundary);
    value.push_str("\n[truncated by coding bot]");
    value
}

#[derive(Debug, Deserialize)]
struct PermissionResponse {
    permission: String,
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
    #[error("GitHub response omitted {0}")]
    MissingResponseField(&'static str),
}

#[cfg(test)]
mod tests {
    use jsonwebtoken::{decode_header, Algorithm};
    use rand::rngs::OsRng;
    use rsa::{pkcs8::EncodePrivateKey, RsaPrivateKey};

    use super::*;

    #[test]
    fn installation_token_debug_is_redacted() {
        let token = InstallationToken::new("ghs_test_secret".to_owned());
        let rendered = format!("{token:?}");
        assert!(!rendered.contains("ghs_test_secret"));
        assert!(rendered.contains("REDACTED"));
    }

    #[test]
    fn generates_rs256_github_app_jwt() {
        let key = RsaPrivateKey::new(&mut OsRng, 2048);
        let Ok(key) = key else {
            panic!("test RSA key generation failed");
        };
        let pem = key.to_pkcs8_pem(Default::default());
        let Ok(pem) = pem else {
            panic!("test RSA key encoding failed");
        };
        let encoding_key = EncodingKey::from_rsa_pem(pem.as_bytes());
        let Ok(encoding_key) = encoding_key else {
            panic!("jsonwebtoken rejected generated RSA key");
        };
        let token = GitHubApp::generate_app_jwt(1234, &encoding_key);
        let Ok(token) = token else {
            panic!("GitHub App JWT generation failed");
        };
        let header = decode_header(&token);
        let Ok(header) = header else {
            panic!("generated JWT header could not be decoded");
        };
        assert_eq!(header.alg, Algorithm::RS256);
        assert_eq!(token.split('.').count(), 3);
    }
}
