//! Blossom media storage probe for Sonar status.
//!
//! HTTP HEADs the Blossom server to verify it's reachable and serving.
//! v1 is a reachability + latency check; a full upload/GET round-trip can
//! follow once Blossom auth (BUD-02) is wired into the probe identity.

use std::time::{Duration, Instant};

use serde::Serialize;

use crate::schema::{ServiceState, StatusService};

/// Soft latency budget for Blossom HEAD (ms). Above this → degraded.
const MEDIA_DEGRADED_MS: u64 = 3_000;
/// Hard timeout for the Blossom probe.
const MEDIA_TIMEOUT: Duration = Duration::from_secs(8);

#[derive(Debug, Clone, Serialize)]
pub struct MediaProbeReport {
    pub ok: bool,
    pub state: ServiceState,
    pub server: String,
    pub status: Option<u16>,
    pub ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl MediaProbeReport {
    pub fn to_service(&self) -> StatusService {
        let desc = if self.ok {
            format!(
                "Blossom {} reachable · HTTP {} · {} ms",
                self.server,
                self.status.unwrap_or(0),
                self.ms
            )
        } else {
            format!(
                "Blossom {} unreachable: {}",
                self.server,
                self.error.as_deref().unwrap_or("unknown")
            )
        };
        let uptime = match self.state {
            ServiceState::Ok => 99.9,
            ServiceState::Degraded => 97.0,
            ServiceState::Down => 80.0,
        };
        StatusService {
            id: "media".into(),
            name: "Media messages".into(),
            desc,
            uptime,
            state: match self.state {
                ServiceState::Ok => None,
                other => Some(other),
            },
        }
    }
}

/// HEAD the Blossom server to verify reachability and measure latency.
///
/// No nsec needed for a HEAD/GET of the base URL — Blossom servers serve
/// public endpoints. Auth (BUD-02) is only needed for blob operations.
pub async fn probe_blossom(server: &str) -> MediaProbeReport {
    let t0 = Instant::now();
    let server = server.trim_end_matches('/').to_owned();

    let client = match reqwest::Client::builder()
        .timeout(MEDIA_TIMEOUT)
        .redirect(reqwest::redirect::Policy::limited(3))
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            return MediaProbeReport {
                ok: false,
                state: ServiceState::Down,
                server,
                status: None,
                ms: t0.elapsed().as_millis() as u64,
                error: Some(format!("build client: {e}")),
            };
        }
    };

    let fut = client.head(&server).send();
    match tokio::time::timeout(MEDIA_TIMEOUT, fut).await {
        Ok(Ok(resp)) => {
            let status = resp.status().as_u16();
            let ms = t0.elapsed().as_millis() as u64;
            let ok = resp.status().is_success() || resp.status().is_redirection();

            // Some Blossom servers return 405 for HEAD on base URL; retry GET.
            let (status, ok) = if status == 405 || status == 404 {
                match client.get(&server).send().await {
                    Ok(r) => {
                        let s = r.status().as_u16();
                        (s, r.status().is_success() || r.status().is_redirection())
                    }
                    Err(_) => (status, false),
                }
            } else {
                (status, ok)
            };

            let state = if !ok {
                if status >= 500 {
                    ServiceState::Down
                } else {
                    ServiceState::Degraded
                }
            } else if ms > MEDIA_DEGRADED_MS {
                ServiceState::Degraded
            } else {
                ServiceState::Ok
            };

            MediaProbeReport {
                ok,
                state,
                server,
                status: Some(status),
                ms,
                error: if ok {
                    None
                } else {
                    Some(format!("HTTP {status}"))
                },
            }
        }
        Ok(Err(e)) => MediaProbeReport {
            ok: false,
            state: ServiceState::Down,
            server,
            status: None,
            ms: t0.elapsed().as_millis() as u64,
            error: Some(e.to_string()),
        },
        Err(_) => MediaProbeReport {
            ok: false,
            state: ServiceState::Down,
            server,
            status: None,
            ms: t0.elapsed().as_millis() as u64,
            error: Some(format!("timed out after {}s", MEDIA_TIMEOUT.as_secs())),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_mapping_ok_omits_state() {
        let r = MediaProbeReport {
            ok: true,
            state: ServiceState::Ok,
            server: "https://nostr.download".into(),
            status: Some(200),
            ms: 350,
            error: None,
        };
        let s = r.to_service();
        assert_eq!(s.id, "media");
        assert!(s.state.is_none());
        assert!(s.desc.contains("reachable"));
    }

    #[test]
    fn service_mapping_down_includes_error() {
        let r = MediaProbeReport {
            ok: false,
            state: ServiceState::Down,
            server: "https://nostr.download".into(),
            status: Some(503),
            ms: 100,
            error: Some("HTTP 503".into()),
        };
        let s = r.to_service();
        assert_eq!(s.state, Some(ServiceState::Down));
        assert!(s.desc.contains("unreachable"));
    }
}
