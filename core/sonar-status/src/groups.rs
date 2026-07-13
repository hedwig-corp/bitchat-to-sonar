//! Group chats probe for Sonar status.
//!
//! Unlike other probes, the groups probe is orchestrated by Hermes: it creates
//! a test MLS group with 5 probe identities, sends a message from each, and
//! validates that all agents received every message. The result is written to
//! a JSON file that `sonar-status` reads here.
//!
//! See `scripts/status/groups-probe.sh` and `docs/HERMES-STATUS.md`.

use serde::{Deserialize, Serialize};

use crate::schema::{ServiceState, StatusService};

/// Result file written by the Hermes groups-probe task.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroupsProbeResult {
    pub ok: bool,
    pub state: String,
    pub agents: usize,
    pub messages_expected: usize,
    pub messages_verified: usize,
    pub ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl GroupsProbeResult {
    pub fn to_service(&self) -> StatusService {
        let state = match self.state.as_str() {
            "down" => ServiceState::Down,
            "degraded" => ServiceState::Degraded,
            _ => ServiceState::Ok,
        };
        let desc = if self.ok {
            format!(
                "{} agents · {}/{} messages verified · {} ms",
                self.agents, self.messages_verified, self.messages_expected, self.ms
            )
        } else {
            format!(
                "Group probe failed: {}",
                self.error.as_deref().unwrap_or("unknown")
            )
        };
        let uptime = match state {
            ServiceState::Ok => 99.9,
            ServiceState::Degraded => 97.0,
            ServiceState::Down => 80.0,
        };
        StatusService {
            id: "groups".into(),
            name: "Group chats (White Noise)".into(),
            desc,
            uptime,
            state: match state {
                ServiceState::Ok => None,
                other => Some(other),
            },
        }
    }
}

/// Read a groups probe result from a JSON file written by the Hermes task.
pub fn load_groups_result(path: &std::path::Path) -> Result<GroupsProbeResult, String> {
    let raw = std::fs::read_to_string(path)
        .map_err(|e| format!("read groups result {}: {e}", path.display()))?;
    let result: GroupsProbeResult = serde_json::from_str(&raw)
        .map_err(|e| format!("parse groups result: {e}"))?;
    Ok(result)
}

/// Placeholder "coming soon" service for payments (Bolt12).
pub fn payments_coming_soon() -> StatusService {
    StatusService {
        id: "payments".into(),
        name: "Payments (Bolt12)".into(),
        desc: "Lightning Bolt12 integration — coming soon".into(),
        uptime: 100.0,
        state: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_result_ok() {
        let r = GroupsProbeResult {
            ok: true,
            state: "ok".into(),
            agents: 5,
            messages_expected: 5,
            messages_verified: 5,
            ms: 3500,
            error: None,
        };
        let s = r.to_service();
        assert_eq!(s.id, "groups");
        assert!(s.state.is_none());
        assert!(s.desc.contains("5 agents"));
    }

    #[test]
    fn groups_result_failed() {
        let r = GroupsProbeResult {
            ok: false,
            state: "down".into(),
            agents: 5,
            messages_expected: 5,
            messages_verified: 2,
            ms: 10000,
            error: Some("3 agents did not receive all messages".into()),
        };
        let s = r.to_service();
        assert_eq!(s.state, Some(ServiceState::Down));
        assert!(s.desc.contains("failed"));
    }

    #[test]
    fn payments_placeholder() {
        let s = payments_coming_soon();
        assert_eq!(s.id, "payments");
        assert!(s.desc.contains("coming soon"));
        assert!(s.state.is_none());
    }
}
