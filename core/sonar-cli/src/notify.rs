//! Operator-facing notification fan-out for inbound CLI messages.
//!
//! `--notify-command` lets a headless Sonar CLI agent alert its human operator
//! in near-real-time when a new message arrives, without the operator polling
//! a UI. For each newly-drained inbound message the configured command is run
//! through the platform shell with `SONAR_*` environment variables describing
//! the message.
//!
//! This is a *local* alert relay. It is intentionally NOT part of the
//! Nostr/MIP-05 transponder push system: a headless process has no APNs/FCM
//! device token to receive those pushes directly. HTTP/webhook alerting is
//! instead achieved by pointing `--notify-command` at e.g.
//! `curl -s -X POST https://example/hook -d "$SONAR_CONTENT"`.

use std::process::{Command, Stdio};

use nostr::ToBech32;
use sonar_core::marmot::ChatMessage;

/// One new inbound message, unpacked into the values exposed to a notifier.
#[derive(Clone, Debug)]
pub(crate) struct NotifyContext {
    pub msg_id: String,
    pub sender: String,
    pub group_id: String,
    pub group_name: String,
    pub content: String,
    pub created_at_secs: u64,
}

impl NotifyContext {
    pub(crate) fn from_message(msg: &ChatMessage, group_name: &str) -> Self {
        Self {
            msg_id: msg.id.to_hex(),
            sender: msg.sender.to_bech32().unwrap_or_default(),
            group_id: hex::encode(msg.group_id.as_slice()),
            group_name: group_name.to_string(),
            content: msg.content.clone(),
            created_at_secs: msg.created_at.as_secs(),
        }
    }

    /// Environment variables injected into every notify command.
    fn env_vars(&self) -> Vec<(&'static str, String)> {
        vec![
            ("SONAR_MSG_ID", self.msg_id.clone()),
            ("SONAR_SENDER", self.sender.clone()),
            ("SONAR_GROUP_ID", self.group_id.clone()),
            ("SONAR_GROUP_NAME", self.group_name.clone()),
            ("SONAR_CONTENT", self.content.clone()),
            ("SONAR_CREATED_AT", self.created_at_secs.to_string()),
        ]
    }
}

/// Run `template` through the platform shell for one message.
///
/// Best-effort: the command's exit status is reported to stderr but never
/// aborts the caller. `status()` blocks until the command exits, so a cron
/// `listen --once` cycle finishes its alert before the process exits — keep the
/// command short, or background it inside the shell (`... &`) for a long-lived
/// listener.
pub(crate) fn run_command(template: &str, ctx: &NotifyContext) {
    let (program, flag) = shell_for_platform();
    let mut cmd = Command::new(program);
    cmd.arg(flag).arg(template);
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::null());
    cmd.stderr(Stdio::null());
    for (k, v) in ctx.env_vars() {
        cmd.env(k, v);
    }
    match cmd.status() {
        Ok(status) if status.success() => {}
        Ok(status) => eprintln!(
            "sonar-cli: notify-command exited non-zero (msg {}): {status}",
            ctx.msg_id
        ),
        Err(e) => eprintln!(
            "sonar-cli: notify-command failed to spawn (msg {}): {e}",
            ctx.msg_id
        ),
    }
}

#[cfg(unix)]
fn shell_for_platform() -> (&'static str, &'static str) {
    ("sh", "-c")
}

#[cfg(not(unix))]
fn shell_for_platform() -> (&'static str, &'static str) {
    ("cmd", "/C")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_ctx() -> NotifyContext {
        NotifyContext {
            msg_id: "deadbeef".to_string(),
            sender: "npub1sender".to_string(),
            group_id: "aabbcc".to_string(),
            group_name: "agent DM".to_string(),
            content: "hello".to_string(),
            created_at_secs: 123,
        }
    }

    #[test]
    fn env_vars_expose_all_message_fields() {
        let vars: Vec<(String, String)> = sample_ctx()
            .env_vars()
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect();
        let get = |key: &str| -> String {
            vars.iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.clone())
                .unwrap_or_default()
        };
        assert_eq!(get("SONAR_MSG_ID"), "deadbeef");
        assert_eq!(get("SONAR_SENDER"), "npub1sender");
        assert_eq!(get("SONAR_GROUP_ID"), "aabbcc");
        assert_eq!(get("SONAR_GROUP_NAME"), "agent DM");
        assert_eq!(get("SONAR_CONTENT"), "hello");
        assert_eq!(get("SONAR_CREATED_AT"), "123");
    }

    #[cfg(unix)]
    #[test]
    fn run_command_injects_env_vars_into_shell() {
        let temp = tempfile::tempdir().expect("tempdir");
        let out = temp.path().join("notified.txt");
        let template = format!(
            "printf '%s\\n%s\\n' \"$SONAR_MSG_ID\" \"$SONAR_CONTENT\" > {}",
            out.display()
        );
        let mut ctx = sample_ctx();
        ctx.msg_id = "cafef00d".to_string();
        ctx.content = "ping".to_string();
        run_command(&template, &ctx);
        let written = std::fs::read_to_string(&out).expect("notify wrote file");
        assert!(written.contains("cafef00d"), "msg id forwarded: {written}");
        assert!(written.contains("ping"), "content forwarded: {written}");
    }

    #[cfg(unix)]
    #[test]
    fn run_command_swallows_nonzero_exit() {
        // Exits 3; must not panic and must not surface an error to the caller.
        run_command("exit 3", &sample_ctx());
    }
}
