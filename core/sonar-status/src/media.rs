//! Blossom media storage probe for Sonar status.
//!
//! Compares the app default Blossom server against a public fallback
//! (`https://nostr.download`) so `/status` can show real upload latency —
//! the path that matters for media send — not only a HEAD reachability ping.
//!
//! When a probe nsec is available, each server gets a BUD-02 upload + GET +
//! best-effort delete of a tiny canary blob. Without a probe nsec, the probe
//! falls back to HEAD/GET reachability (same as v1).

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use nostr::Url;
use nostr_blossom::prelude::*;
use serde::Serialize;
use sonar_core::identity::Identity;

use crate::schema::{ServiceState, StatusService};

/// Soft latency budget for Blossom upload (ms). Above this → degraded.
const MEDIA_UPLOAD_DEGRADED_MS: u64 = 5_000;
/// Soft latency budget for HEAD-only mode (ms).
const MEDIA_HEAD_DEGRADED_MS: u64 = 5_000;
/// Hard timeout per server operation (HEAD or upload+get).
const MEDIA_TIMEOUT: Duration = Duration::from_secs(20);
/// Canary payload size (~4 KiB) — enough to exercise the PUT body path without
/// dominating cron runtime.
const CANARY_BYTES: usize = 4_096;

/// Previous public Blossom default — kept as the status compare target so
/// `/status` shows Hedwig vs the old public host.
pub const PUBLIC_BLOSSOM_COMPARE: &str = "https://nostr.download";

/// Hedwig Blossom public URL (also the app [`sonar_core::client::DEFAULT_BLOSSOM_SERVER`]).
pub const HEDWIG_BLOSSOM_SERVER: &str = "https://push.sonar.hedwig.sh";

#[derive(Debug, Clone, Serialize)]
pub struct MediaServerSample {
    pub server: String,
    /// True when this row is the app default / primary.
    pub primary: bool,
    pub ok: bool,
    /// `head` | `upload` — which path produced the timings.
    pub mode: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub head_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub upload_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub get_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MediaProbeReport {
    pub ok: bool,
    pub state: ServiceState,
    pub primary: String,
    pub mode: String,
    pub servers: Vec<MediaServerSample>,
}

impl MediaProbeReport {
    pub fn to_service(&self) -> StatusService {
        let desc = format_media_desc(self);
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

fn format_media_desc(report: &MediaProbeReport) -> String {
    let parts: Vec<String> = report
        .servers
        .iter()
        .map(|s| {
            let host = short_host(&s.server);
            let role = if s.primary { "primary" } else { "candidate" };
            if s.ok {
                if s.mode == "upload" {
                    format!(
                        "{role} {host} upload {} ms · get {} ms",
                        s.upload_ms.unwrap_or(0),
                        s.get_ms.unwrap_or(0)
                    )
                } else {
                    format!("{role} {host} reachable · {} ms", s.head_ms.unwrap_or(0))
                }
            } else {
                format!(
                    "{role} {host} fail: {}",
                    s.error.as_deref().unwrap_or("unknown")
                )
            }
        })
        .collect();
    if parts.is_empty() {
        "Blossom probe produced no samples".into()
    } else {
        parts.join(" · ")
    }
}

fn short_host(server: &str) -> String {
    Url::parse(server)
        .ok()
        .and_then(|u| u.host_str().map(|h| h.to_owned()))
        .unwrap_or_else(|| server.trim_end_matches('/').to_owned())
}

/// Build the ordered server list: primary first, then candidates (deduped).
pub fn blossom_servers_to_probe(
    primary: &str,
    compare: &[String],
) -> Vec<(String, bool /* primary */)> {
    let primary = primary.trim_end_matches('/').to_owned();
    let mut out = vec![(primary.clone(), true)];
    for raw in compare {
        let s = raw.trim().trim_end_matches('/').to_owned();
        if s.is_empty() {
            continue;
        }
        if out.iter().any(|(existing, _)| existing == &s) {
            continue;
        }
        out.push((s, false));
    }
    out
}

/// Default compare list when the operator does not pass `--blossom-compare`.
pub fn default_blossom_compare() -> Vec<String> {
    vec![PUBLIC_BLOSSOM_COMPARE.to_owned()]
}

/// Probe Blossom servers. With `probe_secret`, run BUD-02 upload+GET+delete;
/// otherwise HEAD/GET reachability only.
pub async fn probe_blossom_servers(
    primary: &str,
    compare: &[String],
    probe_secret: Option<&str>,
) -> MediaProbeReport {
    let servers = blossom_servers_to_probe(primary, compare);
    let mode = if probe_secret.is_some() {
        "upload"
    } else {
        "head"
    };

    let keys = match probe_secret {
        Some(secret) => match Identity::import(secret) {
            Ok(id) => Some(id.keys().clone()),
            Err(e) => {
                return MediaProbeReport {
                    ok: false,
                    state: ServiceState::Down,
                    primary: primary.trim_end_matches('/').to_owned(),
                    mode: mode.into(),
                    servers: vec![MediaServerSample {
                        server: primary.trim_end_matches('/').to_owned(),
                        primary: true,
                        ok: false,
                        mode: mode.into(),
                        status: None,
                        head_ms: None,
                        upload_ms: None,
                        get_ms: None,
                        error: Some(format!("import probe identity: {e}")),
                    }],
                };
            }
        },
        None => None,
    };

    let mut samples = Vec::with_capacity(servers.len());
    for (server, is_primary) in &servers {
        let sample = if let Some(ref keys) = keys {
            probe_upload(server, *is_primary, keys).await
        } else {
            probe_head(server, *is_primary).await
        };
        samples.push(sample);
    }

    summarize(primary, mode, samples)
}

fn summarize(primary: &str, mode: &str, samples: Vec<MediaServerSample>) -> MediaProbeReport {
    let primary_sample = samples.iter().find(|s| s.primary);
    let (ok, state) = match primary_sample {
        Some(s) if s.ok => {
            let slow = match mode {
                "upload" => s.upload_ms.unwrap_or(0) > MEDIA_UPLOAD_DEGRADED_MS,
                _ => s.head_ms.unwrap_or(0) > MEDIA_HEAD_DEGRADED_MS,
            };
            if slow {
                (true, ServiceState::Degraded)
            } else {
                (true, ServiceState::Ok)
            }
        }
        Some(_) => (false, ServiceState::Down),
        None => (false, ServiceState::Down),
    };

    MediaProbeReport {
        ok,
        state,
        primary: primary.trim_end_matches('/').to_owned(),
        mode: mode.into(),
        servers: samples,
    }
}

async fn probe_head(server: &str, primary: bool) -> MediaServerSample {
    let t0 = Instant::now();
    let server = server.trim_end_matches('/').to_owned();

    let client = match reqwest::Client::builder()
        .timeout(MEDIA_TIMEOUT)
        .redirect(reqwest::redirect::Policy::limited(3))
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            return MediaServerSample {
                server,
                primary,
                ok: false,
                mode: "head".into(),
                status: None,
                head_ms: Some(t0.elapsed().as_millis() as u64),
                upload_ms: None,
                get_ms: None,
                error: Some(format!("build client: {e}")),
            };
        }
    };

    let fut = client.head(&server).send();
    match tokio::time::timeout(MEDIA_TIMEOUT, fut).await {
        Ok(Ok(resp)) => {
            let mut status = resp.status().as_u16();
            let mut ok = resp.status().is_success() || resp.status().is_redirection();
            if status == 405 || status == 404 {
                match client.get(&server).send().await {
                    Ok(r) => {
                        status = r.status().as_u16();
                        ok = r.status().is_success() || r.status().is_redirection();
                    }
                    Err(_) => ok = false,
                }
            }
            let ms = t0.elapsed().as_millis() as u64;
            MediaServerSample {
                server,
                primary,
                ok,
                mode: "head".into(),
                status: Some(status),
                head_ms: Some(ms),
                upload_ms: None,
                get_ms: None,
                error: if ok {
                    None
                } else {
                    Some(format!("HTTP {status}"))
                },
            }
        }
        Ok(Err(e)) => MediaServerSample {
            server,
            primary,
            ok: false,
            mode: "head".into(),
            status: None,
            head_ms: Some(t0.elapsed().as_millis() as u64),
            upload_ms: None,
            get_ms: None,
            error: Some(e.to_string()),
        },
        Err(_) => MediaServerSample {
            server,
            primary,
            ok: false,
            mode: "head".into(),
            status: None,
            head_ms: Some(t0.elapsed().as_millis() as u64),
            upload_ms: None,
            get_ms: None,
            error: Some(format!("timed out after {}s", MEDIA_TIMEOUT.as_secs())),
        },
    }
}

async fn probe_upload(server: &str, primary: bool, keys: &nostr::Keys) -> MediaServerSample {
    let server = server.trim_end_matches('/').to_owned();
    let base = match Url::parse(&server) {
        Ok(u) => u,
        Err(e) => {
            return MediaServerSample {
                server,
                primary,
                ok: false,
                mode: "upload".into(),
                status: None,
                head_ms: None,
                upload_ms: None,
                get_ms: None,
                error: Some(format!("bad server url: {e}")),
            };
        }
    };

    let data = canary_payload();
    let client = BlossomClient::new(base);
    let t_upload = Instant::now();
    let upload = tokio::time::timeout(
        MEDIA_TIMEOUT,
        client.upload_blob(
            data.clone(),
            Some("application/octet-stream".into()),
            None,
            Some(keys),
        ),
    )
    .await;

    let descriptor = match upload {
        Ok(Ok(desc)) => desc,
        Ok(Err(e)) => {
            return MediaServerSample {
                server,
                primary,
                ok: false,
                mode: "upload".into(),
                status: None,
                head_ms: None,
                upload_ms: Some(t_upload.elapsed().as_millis() as u64),
                get_ms: None,
                error: Some(summarize_blossom_err(&e)),
            };
        }
        Err(_) => {
            return MediaServerSample {
                server,
                primary,
                ok: false,
                mode: "upload".into(),
                status: None,
                head_ms: None,
                upload_ms: Some(t_upload.elapsed().as_millis() as u64),
                get_ms: None,
                error: Some(format!("upload timed out after {}s", MEDIA_TIMEOUT.as_secs())),
            };
        }
    };
    let upload_ms = t_upload.elapsed().as_millis() as u64;

    let t_get = Instant::now();
    let get = tokio::time::timeout(
        MEDIA_TIMEOUT,
        client.get_blob(descriptor.sha256, None, None, None::<&nostr::Keys>),
    )
    .await;
    let get_ms = t_get.elapsed().as_millis() as u64;

    // Best-effort cleanup — failure must not fail the probe.
    let _ = tokio::time::timeout(
        Duration::from_secs(8),
        client.delete_blob(descriptor.sha256, None, keys),
    )
    .await;

    match get {
        Ok(Ok(bytes)) if bytes == data => MediaServerSample {
            server,
            primary,
            ok: true,
            mode: "upload".into(),
            status: Some(201),
            head_ms: None,
            upload_ms: Some(upload_ms),
            get_ms: Some(get_ms),
            error: None,
        },
        Ok(Ok(_)) => MediaServerSample {
            server,
            primary,
            ok: false,
            mode: "upload".into(),
            status: Some(200),
            head_ms: None,
            upload_ms: Some(upload_ms),
            get_ms: Some(get_ms),
            error: Some("GET body mismatch".into()),
        },
        Ok(Err(e)) => MediaServerSample {
            server,
            primary,
            ok: false,
            mode: "upload".into(),
            status: None,
            head_ms: None,
            upload_ms: Some(upload_ms),
            get_ms: Some(get_ms),
            error: Some(format!("GET failed: {}", summarize_blossom_err(&e))),
        },
        Err(_) => MediaServerSample {
            server,
            primary,
            ok: false,
            mode: "upload".into(),
            status: None,
            head_ms: None,
            upload_ms: Some(upload_ms),
            get_ms: Some(get_ms),
            error: Some(format!("GET timed out after {}s", MEDIA_TIMEOUT.as_secs())),
        },
    }
}

fn canary_payload() -> Vec<u8> {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut data = Vec::with_capacity(CANARY_BYTES);
    data.extend_from_slice(b"sonar-status-media-probe\n");
    data.extend_from_slice(nanos.to_le_bytes().as_slice());
    while data.len() < CANARY_BYTES {
        data.push((data.len() % 251) as u8);
    }
    data
}

fn summarize_blossom_err(err: &nostr_blossom::error::Error) -> String {
    let s = err.to_string();
    // Keep the status page desc short; full text stays in probe JSON.
    if let Some(rest) = s.strip_prefix("Failed to upload blob: ") {
        return rest.to_owned();
    }
    if s.len() > 120 {
        format!("{}…", &s[..117])
    } else {
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PRIMARY: &str = HEDWIG_BLOSSOM_SERVER;

    #[test]
    fn service_mapping_ok_omits_state() {
        let r = MediaProbeReport {
            ok: true,
            state: ServiceState::Ok,
            primary: PRIMARY.into(),
            mode: "upload".into(),
            servers: vec![
                MediaServerSample {
                    server: PRIMARY.into(),
                    primary: true,
                    ok: true,
                    mode: "upload".into(),
                    status: Some(201),
                    head_ms: None,
                    upload_ms: Some(116),
                    get_ms: Some(35),
                    error: None,
                },
                MediaServerSample {
                    server: PUBLIC_BLOSSOM_COMPARE.into(),
                    primary: false,
                    ok: true,
                    mode: "upload".into(),
                    status: Some(201),
                    head_ms: None,
                    upload_ms: Some(135),
                    get_ms: Some(37),
                    error: None,
                },
            ],
        };
        let s = r.to_service();
        assert_eq!(s.id, "media");
        assert!(s.state.is_none());
        assert!(s.desc.contains("primary"));
        assert!(s.desc.contains("push.sonar.hedwig.sh"));
        assert!(s.desc.contains("candidate"));
        assert!(s.desc.contains("nostr.download"));
        assert!(s.desc.contains("upload 116 ms"));
        assert!(s.desc.contains("upload 135 ms"));
    }

    #[test]
    fn service_mapping_down_includes_error() {
        let r = MediaProbeReport {
            ok: false,
            state: ServiceState::Down,
            primary: PRIMARY.into(),
            mode: "head".into(),
            servers: vec![MediaServerSample {
                server: PRIMARY.into(),
                primary: true,
                ok: false,
                mode: "head".into(),
                status: Some(503),
                head_ms: Some(100),
                upload_ms: None,
                get_ms: None,
                error: Some("HTTP 503".into()),
            }],
        };
        let s = r.to_service();
        assert_eq!(s.state, Some(ServiceState::Down));
        assert!(s.desc.contains("fail: HTTP 503"));
    }

    #[test]
    fn servers_to_probe_dedupes_primary() {
        let list = blossom_servers_to_probe(
            "https://push.sonar.hedwig.sh/",
            &[
                "https://nostr.download".into(),
                "https://push.sonar.hedwig.sh".into(),
            ],
        );
        assert_eq!(list.len(), 2);
        assert!(list[0].1);
        assert_eq!(list[0].0, "https://push.sonar.hedwig.sh");
        assert!(!list[1].1);
        assert_eq!(list[1].0, "https://nostr.download");
    }

    #[test]
    fn short_host_strips_scheme() {
        assert_eq!(
            short_host("https://push.sonar.hedwig.sh/"),
            "push.sonar.hedwig.sh"
        );
    }
}
