use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IssueComment {
    pub author: String,
    pub body: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IssueContext {
    pub title: String,
    pub body: String,
    pub author: String,
    pub state: String,
    pub labels: Vec<String>,
    pub comments: Vec<IssueComment>,
    pub html_url: String,
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
pub struct PullRequestReport {
    pub summary: String,
    pub changes: Vec<String>,
    pub changed_files: Vec<String>,
    pub validation: Vec<ValidationResult>,
    pub limitations: Vec<String>,
    pub issue_number: u64,
}

impl PullRequestReport {
    #[must_use]
    pub fn to_markdown(&self) -> String {
        let changes = markdown_list(&self.changes, "No change details were reported.");
        let files = markdown_code_list(&self.changed_files, "No files reported.");
        let validation = if self.validation.is_empty() {
            "- No validation commands were run.".to_owned()
        } else {
            self.validation
                .iter()
                .map(|result| {
                    let state = if result.passed { "passed" } else { "failed" };
                    format!("- `{}` — {state}", result.command)
                })
                .collect::<Vec<_>>()
                .join("\n")
        };
        let limitations = markdown_list(&self.limitations, "None identified.");

        format!(
            "## Summary\n\n{}\n\n## Changes\n\n{}\n\n## Changed files\n\n{}\n\n## Validation\n\n{}\n\n## Limitations\n\n{}\n\nFixes #{}",
            self.summary, changes, files, validation, limitations, self.issue_number
        )
    }
}

fn markdown_list(values: &[String], empty: &str) -> String {
    if values.is_empty() {
        return format!("- {empty}");
    }
    values
        .iter()
        .map(|value| format!("- {value}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn markdown_code_list(values: &[String], empty: &str) -> String {
    if values.is_empty() {
        return format!("- {empty}");
    }
    values
        .iter()
        .map(|value| format!("- `{value}`"))
        .collect::<Vec<_>>()
        .join("\n")
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DraftPullRequest {
    pub title: String,
    pub head: String,
    pub base: String,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenedPullRequest {
    pub number: u64,
    pub html_url: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_validation_is_never_reported_as_passed() {
        let report = PullRequestReport {
            summary: "Fix parser".to_owned(),
            changes: vec!["Reject invalid input".to_owned()],
            changed_files: vec!["src/parser.rs".to_owned()],
            validation: vec![ValidationResult {
                command: "cargo test".to_owned(),
                passed: false,
                exit_code: Some(1),
                output: "test failed".to_owned(),
                duration_ms: 10,
            }],
            limitations: vec![],
            issue_number: 42,
        };

        let body = report.to_markdown();
        assert!(body.contains("`cargo test` — failed"));
        assert!(!body.contains("`cargo test` — passed"));
        assert!(body.ends_with("Fixes #42"));
    }
}
