//! Website-compatible status document types.
//!
//! Must stay aligned with `web/src/lib/status-data.js` and
//! `web/src/lib/status-nostr.js` (kind 30078, d=sonar-status).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ServiceState {
    Ok,
    Degraded,
    Down,
}

impl ServiceState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Degraded => "degraded",
            Self::Down => "down",
        }
    }

    pub fn rank(&self) -> u8 {
        match self {
            Self::Ok => 0,
            Self::Degraded => 1,
            Self::Down => 2,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusService {
    pub id: String,
    pub name: String,
    pub desc: String,
    pub uptime: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<ServiceState>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusRelay {
    pub url: String,
    pub region: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum IncidentLevel {
    Degraded,
    Maintenance,
    Down,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IncidentUpdate {
    pub t: String,
    pub s: String,
    pub b: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusIncident {
    pub date: String,
    pub title: String,
    pub level: IncidentLevel,
    pub updates: Vec<IncidentUpdate>,
}

/// Website-compatible payload (`web/src/lib/status-nostr.js` schema).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusPayload {
    pub services: Vec<StatusService>,
    pub relays: Vec<StatusRelay>,
    pub incidents: Vec<StatusIncident>,
    /// Operator-only metadata (stripped before publish).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub probe: Option<serde_json::Value>,
}

/// Strip operator-only fields so the website schema validator stays happy.
pub fn website_view(payload: &StatusPayload) -> StatusPayload {
    StatusPayload {
        services: payload.services.clone(),
        relays: payload.relays.clone(),
        incidents: payload.incidents.clone(),
        updated_at: None,
        probe: None,
    }
}
