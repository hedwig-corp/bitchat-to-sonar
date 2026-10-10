use std::fmt;

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AllowedCommand {
    pub program: String,
    pub args: Vec<String>,
    pub timeout_seconds: u64,
}

impl fmt::Display for AllowedCommand {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.program)?;
        for argument in &self.args {
            formatter.write_str(" ")?;
            formatter.write_str(argument)?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct CommandPolicy {
    commands: Vec<AllowedCommand>,
}

impl CommandPolicy {
    #[must_use]
    pub fn standard(timeout_seconds: u64) -> Self {
        let specs: &[(&str, &[&str])] = &[
            ("cargo", &["fmt", "--check"]),
            ("cargo", &["fmt", "--all", "--check"]),
            ("cargo", &["check"]),
            ("cargo", &["check", "--workspace", "--all-targets"]),
            ("cargo", &["test"]),
            ("cargo", &["test", "--workspace"]),
            ("cargo", &["clippy", "--workspace", "--all-targets"]),
            (
                "cargo",
                &[
                    "clippy",
                    "--workspace",
                    "--all-targets",
                    "--",
                    "-D",
                    "warnings",
                ],
            ),
            ("go", &["test", "./..."]),
            ("npm", &["test"]),
            ("npm", &["run", "lint"]),
            ("npm", &["run", "build"]),
            ("pnpm", &["test"]),
            ("pnpm", &["run", "lint"]),
            ("pnpm", &["run", "build"]),
            ("pytest", &[]),
            ("python", &["-m", "pytest"]),
            ("make", &["test"]),
        ];
        Self {
            commands: specs
                .iter()
                .map(|(program, args)| AllowedCommand {
                    program: (*program).to_owned(),
                    args: args.iter().map(|argument| (*argument).to_owned()).collect(),
                    timeout_seconds,
                })
                .collect(),
        }
    }

    pub fn resolve(&self, program: &str, args: &[String]) -> Result<AllowedCommand, CommandError> {
        self.commands
            .iter()
            .find(|command| command.program == program && command.args == args)
            .cloned()
            .ok_or_else(|| CommandError::NotAllowed {
                program: program.to_owned(),
                args: args.to_vec(),
            })
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum CommandError {
    #[error("command is not allowlisted: {program} {args:?}")]
    NotAllowed { program: String, args: Vec<String> },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_exact_validation_commands_are_allowed() {
        let policy = CommandPolicy::standard(30);
        assert!(policy
            .resolve("cargo", &["test".to_owned(), "--workspace".to_owned()])
            .is_ok());
        assert!(policy
            .resolve("curl", &["https://example.com".to_owned()])
            .is_err());
        assert!(policy
            .resolve(
                "cargo",
                &["test".to_owned(), "|".to_owned(), "sh".to_owned()]
            )
            .is_err());
        assert!(policy
            .resolve("sh", &["-c".to_owned(), "cargo test".to_owned()])
            .is_err());
    }
}
