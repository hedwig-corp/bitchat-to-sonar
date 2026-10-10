//! Shared, serializable types for the Hermes GitHub MCP server.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkspaceLimits {
    pub max_files_read: u32,
    pub max_files_modified: u32,
    pub max_diff_lines: u32,
    pub max_command_seconds: u64,
    pub max_workspace_seconds: u64,
    pub max_tool_output_bytes: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ValidationResult {
    pub command: String,
    pub passed: bool,
    pub exit_code: Option<i32>,
    pub output: String,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkspaceAudit {
    pub files_read: u32,
    pub files_modified: u32,
    pub diff_lines: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConfirmationAction {
    CloseIssue,
    MergePullRequest,
}

impl ConfirmationAction {
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::CloseIssue => "close_issue",
            Self::MergePullRequest => "merge_pull_request",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConfirmationScope {
    pub actor: String,
    pub action: ConfirmationAction,
    pub owner: String,
    pub repository: String,
    pub target_number: u64,
    pub expected_head_sha: Option<String>,
    pub qualifier: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PreparedConfirmation {
    pub confirmation_token: String,
    pub expires_at: DateTime<Utc>,
    pub summary: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AuditEvent {
    pub actor: String,
    pub tool: String,
    pub owner: Option<String>,
    pub repository: Option<String>,
    pub target: Option<String>,
    pub outcome: String,
    pub details: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkspaceDescriptor {
    pub id: Uuid,
    pub actor: String,
    pub owner: String,
    pub repository: String,
    pub base_ref: String,
    pub base_sha: String,
    pub branch_name: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}
