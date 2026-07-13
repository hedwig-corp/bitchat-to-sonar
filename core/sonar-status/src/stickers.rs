//! Sticker pack directory probe for Sonar status.
//!
//! REQs kind 30031 (sticker pack) on each bootstrap relay and counts how many
//! sticker pack events are visible. A healthy directory should return at least
//! one event; EOSE with zero events on all relays means the index is stale.

use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use crate::schema::{ServiceState, StatusService};

const STICKER_PACK_KIND: u64 = 30031;
const STICKER_TIMEOUT: Duration = Duration::from_secs(8);

#[derive(Debug, Clone, Serialize)]
pub struct StickerProbeReport {
    pub ok: bool,
    pub state: ServiceState,
    pub packs_found: usize,
    pub relays_answered: usize,
    pub total_relays: usize,
    pub ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl StickerProbeReport {
    pub fn to_service(&self) -> StatusService {
        let desc = if self.ok {
            format!(
                "{} pack(s) visible across {}/{} relays · {} ms",
                self.packs_found, self.relays_answered, self.total_relays, self.ms
            )
        } else {
            format!(
                "Sticker index unreachable: {}",
                self.error.as_deref().unwrap_or("no packs found on any relay")
            )
        };
        let uptime = match self.state {
            ServiceState::Ok => 99.9,
            ServiceState::Degraded => 97.0,
            ServiceState::Down => 80.0,
        };
        StatusService {
            id: "stickers".into(),
            name: "Stickers directory".into(),
            desc,
            uptime,
            state: match self.state {
                ServiceState::Ok => None,
                other => Some(other),
            },
        }
    }
}

pub async fn probe_sticker_index(relay_urls: &[String]) -> StickerProbeReport {
    let t0 = Instant::now();
    let total_relays = relay_urls.len();

    let mut tasks = Vec::with_capacity(relay_urls.len());
    for url in relay_urls {
        let url = url.clone();
        tasks.push(tokio::spawn(async move { probe_single_relay(&url).await }));
    }

    let mut packs_found = 0usize;
    let mut relays_answered = 0usize;
    for task in tasks {
        match task.await {
            Ok(Ok((count, answered))) => {
                packs_found += count;
                if answered {
                    relays_answered += 1;
                }
            }
            Ok(Err(e)) => eprintln!("sticker probe relay error: {e}"),
            Err(e) => eprintln!("sticker probe task panicked: {e}"),
        }
    }

    let ms = t0.elapsed().as_millis() as u64;
    let (ok, state) = if packs_found > 0 {
        (true, ServiceState::Ok)
    } else if relays_answered > 0 {
        (false, ServiceState::Degraded)
    } else {
        (false, ServiceState::Down)
    };

    StickerProbeReport {
        ok,
        state,
        packs_found,
        relays_answered,
        total_relays,
        ms,
        error: if ok {
            None
        } else if relays_answered > 0 {
            Some("EOSE with 0 sticker packs".into())
        } else {
            Some("no relays answered".into())
        },
    }
}

async fn probe_single_relay(url: &str) -> Result<(usize, bool), String> {
    let (mut ws, _) =
        connect_async(url).await.map_err(|e| format!("connect {url}: {e}"))?;

    let sub_id = format!("sticker-status-{:x}", rand_u64());
    let req = serde_json::json!([
        "REQ",
        &sub_id,
        {"kinds": [STICKER_PACK_KIND], "limit": 50}
    ])
    .to_string();

    ws.send(Message::text(req))
        .await
        .map_err(|e| format!("send REQ {url}: {e}"))?;

    let mut pack_count = 0usize;
    let mut got_eose = false;

    let deadline = tokio::time::sleep(STICKER_TIMEOUT);
    tokio::pin!(deadline);

    loop {
        tokio::select! {
            _ = &mut deadline => break,
            msg = ws.next() => {
                match msg {
                    Some(Ok(Message::Text(raw))) => {
                        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw) {
                            match v.get(0).and_then(|t| t.as_str()) {
                                Some("EVENT") => {
                                    if v.get(1).and_then(|s| s.as_str()) == Some(&sub_id) {
                                        pack_count += 1;
                                    }
                                }
                                Some("EOSE") => {
                                    if v.get(1).and_then(|s| s.as_str()) == Some(&sub_id) {
                                        got_eose = true;
                                        break;
                                    }
                                }
                                _ => {}
                            }
                        }
                    }
                    Some(Ok(_)) => {}
                    Some(Err(e)) => return Err(format!("ws read {url}: {e}")),
                    None => break,
                }
            }
        }
    }

    let _ = ws
        .send(Message::Close(None))
        .await;
    Ok((pack_count, got_eose))
}

fn rand_u64() -> u64 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    Instant::now().hash(&mut h);
    h.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_mapping_ok_omits_state() {
        let r = StickerProbeReport {
            ok: true,
            state: ServiceState::Ok,
            packs_found: 5,
            relays_answered: 3,
            total_relays: 7,
            ms: 1200,
            error: None,
        };
        let s = r.to_service();
        assert_eq!(s.id, "stickers");
        assert!(s.state.is_none());
        assert!(s.desc.contains("5 pack(s)"));
    }

    #[test]
    fn service_mapping_down_includes_error() {
        let r = StickerProbeReport {
            ok: false,
            state: ServiceState::Down,
            packs_found: 0,
            relays_answered: 0,
            total_relays: 7,
            ms: 100,
            error: Some("no relays answered".into()),
        };
        let s = r.to_service();
        assert_eq!(s.state, Some(ServiceState::Down));
        assert!(s.desc.contains("unreachable"));
    }
}
