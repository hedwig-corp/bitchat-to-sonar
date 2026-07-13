//! Marmot / chat-path probes for Sonar status.
//!
//! v1 measures the DM bootstrap path used before a conversation exists:
//! connect → publish KeyPackage → fetch own KeyPackage from relays.
//!
//! This is the minimum honest check that "Encrypted DMs (Marmot)" depends on
//! Nostr + MLS KeyPackage distribution. A full A→B message canary is a
//! follow-up (see docs/SONAR-STATUS.md).

use std::path::PathBuf;
use std::time::{Duration, Instant};

use nostr::types::url::RelayUrl;
use serde::Serialize;
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;

use crate::schema::{ServiceState, StatusService};

/// Soft latency budget for KeyPackage publish+fetch (ms). Above this → degraded.
pub const DM_DEGRADED_MS: u64 = 8_000;
/// Hard timeout for the whole chat probe.
pub const DM_TIMEOUT: Duration = Duration::from_secs(45);

#[derive(Debug, Clone, Serialize)]
pub struct ChatProbeReport {
    pub ok: bool,
    pub state: ServiceState,
    pub publish_ms: Option<u64>,
    pub fetch_ms: Option<u64>,
    pub total_ms: u64,
    pub npub: String,
    pub pubkey_hex: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl ChatProbeReport {
    pub fn to_service(&self) -> StatusService {
        let desc = if self.ok {
            format!(
                "KeyPackage publish {} ms · fetch {} ms · probe {}",
                self.publish_ms.unwrap_or(0),
                self.fetch_ms.unwrap_or(0),
                truncate_npub(&self.npub)
            )
        } else {
            format!(
                "KeyPackage round-trip failed: {}",
                self.error.as_deref().unwrap_or("unknown")
            )
        };
        let uptime = match self.state {
            ServiceState::Ok => 99.9,
            ServiceState::Degraded => 97.5,
            ServiceState::Down => 85.0,
        };
        StatusService {
            id: "dm".into(),
            name: "Encrypted DMs (Marmot)".into(),
            desc,
            uptime,
            // Omit state when fully ok so the website shows Operational badge.
            state: match self.state {
                ServiceState::Ok => None,
                ServiceState::Degraded => Some(ServiceState::Degraded),
                ServiceState::Down => Some(ServiceState::Down),
            },
        }
    }
}

fn truncate_npub(npub: &str) -> String {
    if npub.len() <= 16 {
        return npub.to_owned();
    }
    format!("{}…{}", &npub[..12], &npub[npub.len().saturating_sub(6)..])
}

/// Load a probe identity from nsec string, file, or env (never from status publisher by default).
pub fn load_probe_secret(
    nsec: Option<&str>,
    nsec_file: Option<&PathBuf>,
    env_var: &str,
) -> Result<String, String> {
    if let Some(path) = nsec_file {
        let raw = std::fs::read_to_string(path)
            .map_err(|e| format!("read probe nsec file {}: {e}", path.display()))?;
        let s = raw.trim().to_owned();
        if s.is_empty() {
            return Err("empty probe nsec file".into());
        }
        return Ok(s);
    }
    if let Some(s) = nsec {
        let s = s.trim().to_owned();
        if s.is_empty() {
            return Err("empty probe nsec".into());
        }
        return Ok(s);
    }
    match std::env::var(env_var) {
        Ok(s) if !s.trim().is_empty() => Ok(s.trim().to_owned()),
        Ok(_) => Err(format!("{env_var} is set but empty")),
        Err(_) => Err(format!(
            "chat probe requested but no probe secret: pass --probe-nsec, --probe-nsec-file, or {env_var}"
        )),
    }
}

/// Run KeyPackage publish + fetch against `relay_urls` using a dedicated probe identity.
pub async fn probe_marmot_keypackage(
    secret: &str,
    relay_urls: &[String],
) -> ChatProbeReport {
    let t0 = Instant::now();
    match tokio::time::timeout(DM_TIMEOUT, probe_marmot_keypackage_inner(secret, relay_urls)).await
    {
        Ok(report) => report,
        Err(_) => ChatProbeReport {
            ok: false,
            state: ServiceState::Down,
            publish_ms: None,
            fetch_ms: None,
            total_ms: t0.elapsed().as_millis() as u64,
            npub: String::new(),
            pubkey_hex: String::new(),
            error: Some(format!("chat probe timed out after {}s", DM_TIMEOUT.as_secs())),
        },
    }
}

async fn probe_marmot_keypackage_inner(
    secret: &str,
    relay_urls: &[String],
) -> ChatProbeReport {
    let t0 = Instant::now();
    let identity = match Identity::import(secret) {
        Ok(id) => id,
        Err(e) => {
            return ChatProbeReport {
                ok: false,
                state: ServiceState::Down,
                publish_ms: None,
                fetch_ms: None,
                total_ms: t0.elapsed().as_millis() as u64,
                npub: String::new(),
                pubkey_hex: String::new(),
                error: Some(format!("import probe identity: {e}")),
            };
        }
    };
    let npub = identity.npub();
    let pubkey_hex = identity.public_key().to_hex();

    let mut relays = Vec::new();
    for url in relay_urls {
        match RelayUrl::parse(url) {
            Ok(r) => relays.push(r),
            Err(e) => {
                return ChatProbeReport {
                    ok: false,
                    state: ServiceState::Down,
                    publish_ms: None,
                    fetch_ms: None,
                    total_ms: t0.elapsed().as_millis() as u64,
                    npub,
                    pubkey_hex,
                    error: Some(format!("invalid relay {url}: {e}")),
                };
            }
        }
    }
    if relays.is_empty() {
        return ChatProbeReport {
            ok: false,
            state: ServiceState::Down,
            publish_ms: None,
            fetch_ms: None,
            total_ms: t0.elapsed().as_millis() as u64,
            npub,
            pubkey_hex,
            error: Some("no relays configured for chat probe".into()),
        };
    }

    let client = match SonarClient::connect_in_memory(identity.clone(), relays).await {
        Ok(c) => c,
        Err(e) => {
            return ChatProbeReport {
                ok: false,
                state: ServiceState::Down,
                publish_ms: None,
                fetch_ms: None,
                total_ms: t0.elapsed().as_millis() as u64,
                npub,
                pubkey_hex,
                error: Some(format!("connect: {e}")),
            };
        }
    };

    let t_pub = Instant::now();
    if let Err(e) = client.publish_key_package().await {
        return ChatProbeReport {
            ok: false,
            state: ServiceState::Down,
            publish_ms: Some(t_pub.elapsed().as_millis() as u64),
            fetch_ms: None,
            total_ms: t0.elapsed().as_millis() as u64,
            npub,
            pubkey_hex,
            error: Some(format!("publish KeyPackage: {e}")),
        };
    }
    let publish_ms = t_pub.elapsed().as_millis() as u64;

    let author = identity.public_key();
    let t_fetch = Instant::now();
    if let Err(e) = client.fetch_key_package(author).await {
        return ChatProbeReport {
            ok: false,
            state: ServiceState::Down,
            publish_ms: Some(publish_ms),
            fetch_ms: Some(t_fetch.elapsed().as_millis() as u64),
            total_ms: t0.elapsed().as_millis() as u64,
            npub,
            pubkey_hex,
            error: Some(format!("fetch own KeyPackage: {e}")),
        };
    }
    let fetch_ms = t_fetch.elapsed().as_millis() as u64;
    let total_ms = t0.elapsed().as_millis() as u64;

    let state = if total_ms > DM_DEGRADED_MS {
        ServiceState::Degraded
    } else {
        ServiceState::Ok
    };

    ChatProbeReport {
        ok: true,
        state,
        publish_ms: Some(publish_ms),
        fetch_ms: Some(fetch_ms),
        total_ms,
        npub,
        pubkey_hex,
        error: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_mapping_ok_omits_state() {
        let r = ChatProbeReport {
            ok: true,
            state: ServiceState::Ok,
            publish_ms: Some(100),
            fetch_ms: Some(200),
            total_ms: 300,
            npub: "npub1abcdefghijklmnopqrstuvwxyz".into(),
            pubkey_hex: "ab".into(),
            error: None,
        };
        let s = r.to_service();
        assert_eq!(s.id, "dm");
        assert!(s.state.is_none());
        assert!(s.desc.contains("KeyPackage publish"));
    }

    #[test]
    fn service_mapping_down_includes_error() {
        let r = ChatProbeReport {
            ok: false,
            state: ServiceState::Down,
            publish_ms: None,
            fetch_ms: None,
            total_ms: 10,
            npub: String::new(),
            pubkey_hex: String::new(),
            error: Some("connect: boom".into()),
        };
        let s = r.to_service();
        assert_eq!(s.state, Some(ServiceState::Down));
        assert!(s.desc.contains("boom"));
    }

    #[test]
    fn load_probe_secret_from_string() {
        let s = load_probe_secret(Some("  abc  "), None, "NOPE").unwrap();
        assert_eq!(s, "abc");
    }
}
