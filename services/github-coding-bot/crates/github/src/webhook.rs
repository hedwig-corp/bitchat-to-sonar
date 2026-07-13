use std::collections::HashSet;

use coding_bot_domain::NewCodingJob;
use hmac::{Hmac, Mac};
use serde::Deserialize;
use sha2::Sha256;
use thiserror::Error;

type HmacSha256 = Hmac<Sha256>;

pub fn verify_signature(secret: &[u8], body: &[u8], header: &str) -> Result<(), WebhookError> {
    let encoded = header
        .strip_prefix("sha256=")
        .ok_or(WebhookError::InvalidSignatureFormat)?;
    let signature = hex::decode(encoded).map_err(|_| WebhookError::InvalidSignatureFormat)?;
    if signature.len() != 32 {
        return Err(WebhookError::InvalidSignatureFormat);
    }

    let mut mac =
        HmacSha256::new_from_slice(secret).map_err(|_| WebhookError::InvalidSignatureFormat)?;
    mac.update(body);
    mac.verify_slice(&signature)
        .map_err(|_| WebhookError::SignatureMismatch)
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct IssuesWebhook {
    pub action: String,
    pub issue: WebhookIssue,
    pub label: Option<WebhookLabel>,
    pub repository: WebhookRepository,
    pub sender: WebhookUser,
    pub installation: Option<WebhookInstallation>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct WebhookIssue {
    pub number: u64,
    pub state: String,
    pub title: String,
    #[serde(default)]
    pub body: Option<String>,
    pub user: WebhookUser,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct WebhookLabel {
    pub name: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct WebhookRepository {
    pub id: u64,
    pub name: String,
    pub owner: WebhookUser,
    pub default_branch: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct WebhookUser {
    pub login: String,
    #[serde(rename = "type", default)]
    pub kind: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct WebhookInstallation {
    pub id: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TriggerCandidate {
    pub job: NewCodingJob,
    pub sender_login: String,
    pub issue_author: String,
}

pub fn filter_issue_event(
    delivery_id: &str,
    payload: IssuesWebhook,
    bot_login: &str,
    repository_allowlist: &HashSet<String>,
) -> FilterDecision {
    if payload.action != "labeled" {
        return FilterDecision::Ignored(IgnoreReason::WrongAction);
    }
    if payload.issue.state != "open" {
        return FilterDecision::Ignored(IgnoreReason::IssueClosed);
    }
    if payload.label.as_ref().map(|label| label.name.as_str()) != Some("ai-fix") {
        return FilterDecision::Ignored(IgnoreReason::WrongLabel);
    }
    if payload.sender.login.eq_ignore_ascii_case(bot_login) {
        return FilterDecision::Ignored(IgnoreReason::BotSender);
    }

    let full_name = format!(
        "{}/{}",
        payload.repository.owner.login, payload.repository.name
    );
    if !repository_allowlist.contains(&full_name.to_ascii_lowercase()) {
        return FilterDecision::Ignored(IgnoreReason::RepositoryNotAllowed);
    }
    let Some(installation) = payload.installation else {
        return FilterDecision::Ignored(IgnoreReason::MissingInstallation);
    };

    FilterDecision::Candidate(TriggerCandidate {
        job: NewCodingJob {
            delivery_id: delivery_id.to_owned(),
            repository_id: payload.repository.id,
            repository_owner: payload.repository.owner.login,
            repository_name: payload.repository.name,
            issue_number: payload.issue.number,
            installation_id: installation.id,
            base_branch: payload.repository.default_branch,
        },
        sender_login: payload.sender.login,
        issue_author: payload.issue.user.login,
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FilterDecision {
    Candidate(TriggerCandidate),
    Ignored(IgnoreReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IgnoreReason {
    WrongAction,
    IssueClosed,
    WrongLabel,
    BotSender,
    RepositoryNotAllowed,
    MissingInstallation,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum WebhookError {
    #[error("invalid X-Hub-Signature-256 format")]
    InvalidSignatureFormat,
    #[error("webhook signature did not match")]
    SignatureMismatch,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verifies_known_signature_and_rejects_tampering() {
        let body = br#"{"action":"labeled"}"#;
        let mut mac = HmacSha256::new_from_slice(b"secret");
        let Ok(ref mut mac) = mac else {
            panic!("HMAC accepts arbitrary key lengths");
        };
        mac.update(body);
        let header = format!(
            "sha256={}",
            hex::encode(mac.clone().finalize().into_bytes())
        );

        assert_eq!(verify_signature(b"secret", body, &header), Ok(()));
        assert_eq!(
            verify_signature(b"secret", b"tampered", &header),
            Err(WebhookError::SignatureMismatch)
        );
    }

    #[test]
    fn filters_closed_unlabeled_and_bot_events() {
        let allowlist = HashSet::from(["owner/repo".to_owned()]);
        let mut payload = fixture();
        payload.issue.state = "closed".to_owned();
        assert_eq!(
            filter_issue_event("delivery", payload, "ai-bot", &allowlist),
            FilterDecision::Ignored(IgnoreReason::IssueClosed)
        );

        let mut payload = fixture();
        payload.label = Some(WebhookLabel {
            name: "other".to_owned(),
        });
        assert_eq!(
            filter_issue_event("delivery", payload, "ai-bot", &allowlist),
            FilterDecision::Ignored(IgnoreReason::WrongLabel)
        );

        let mut payload = fixture();
        payload.sender.login = "AI-BOT".to_owned();
        assert_eq!(
            filter_issue_event("delivery", payload, "ai-bot", &allowlist),
            FilterDecision::Ignored(IgnoreReason::BotSender)
        );
    }

    fn fixture() -> IssuesWebhook {
        IssuesWebhook {
            action: "labeled".to_owned(),
            issue: WebhookIssue {
                number: 7,
                state: "open".to_owned(),
                title: "Fix it".to_owned(),
                body: None,
                user: WebhookUser {
                    login: "reporter".to_owned(),
                    kind: "User".to_owned(),
                },
            },
            label: Some(WebhookLabel {
                name: "ai-fix".to_owned(),
            }),
            repository: WebhookRepository {
                id: 10,
                name: "repo".to_owned(),
                owner: WebhookUser {
                    login: "owner".to_owned(),
                    kind: "Organization".to_owned(),
                },
                default_branch: "main".to_owned(),
            },
            sender: WebhookUser {
                login: "maintainer".to_owned(),
                kind: "User".to_owned(),
            },
            installation: Some(WebhookInstallation { id: 11 }),
        }
    }
}
