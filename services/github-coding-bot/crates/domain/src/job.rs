use std::{fmt, str::FromStr};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

/// Durable lifecycle state for a coding job.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobStatus {
    Pending,
    Running,
    Succeeded,
    Failed,
    Cancelled,
}

impl JobStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Running => "running",
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }

    #[must_use]
    pub const fn is_active(self) -> bool {
        matches!(self, Self::Pending | Self::Running)
    }
}

impl fmt::Display for JobStatus {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for JobStatus {
    type Err = ParseJobStatusError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "pending" => Ok(Self::Pending),
            "running" => Ok(Self::Running),
            "succeeded" => Ok(Self::Succeeded),
            "failed" => Ok(Self::Failed),
            "cancelled" => Ok(Self::Cancelled),
            _ => Err(ParseJobStatusError(value.to_owned())),
        }
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
#[error("unknown job status `{0}`")]
pub struct ParseJobStatusError(String);

/// Persistent queue record. Numeric GitHub identifiers are retained exactly.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CodingJob {
    pub id: Uuid,
    pub repository_id: u64,
    pub repository_owner: String,
    pub repository_name: String,
    pub issue_number: u64,
    pub installation_id: u64,
    pub base_branch: String,
    pub status: JobStatus,
    pub attempt: u32,
    pub created_at: DateTime<Utc>,
    pub started_at: Option<DateTime<Utc>>,
    pub finished_at: Option<DateTime<Utc>>,
    pub lease_expires_at: Option<DateTime<Utc>>,
    pub cancel_requested: bool,
    pub error_message: Option<String>,
    pub branch_name: Option<String>,
    pub pull_request_number: Option<u64>,
}

impl CodingJob {
    #[must_use]
    pub fn repository_full_name(&self) -> String {
        format!("{}/{}", self.repository_owner, self.repository_name)
    }
}

/// Validated data used to enqueue a job.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewCodingJob {
    pub delivery_id: String,
    pub repository_id: u64,
    pub repository_owner: String,
    pub repository_name: String,
    pub issue_number: u64,
    pub installation_id: u64,
    pub base_branch: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct JobFailure {
    pub public_reason: String,
    pub internal_context: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn job_status_round_trips() {
        for status in [
            JobStatus::Pending,
            JobStatus::Running,
            JobStatus::Succeeded,
            JobStatus::Failed,
            JobStatus::Cancelled,
        ] {
            let parsed = status.as_str().parse::<JobStatus>();
            assert_eq!(parsed, Ok(status));
        }
    }
}
