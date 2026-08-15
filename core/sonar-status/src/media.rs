//! Blossom media storage probe for Sonar status.
//!
//! Compares the app default Blossom server against a public fallback
//! (`https://nostr.download`) so `/status` can show real upload latency —
//! the path that matters for media send — not only a HEAD reachability ping.
//!
//! When a probe nsec is available, each server gets a BUD-02 upload + GET +
//! best-effort delete of a tiny canary blob. Without a probe nsec, callers
//! should fail closed (do not publish Ok from HEAD-only) — HEAD cannot prove
//! authenticated MIP-04 upload works.

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use nostr::Url;
use nostr_blossom::prelude::*;
use serde::Serialize;
use sonar_core::client::ENCRYPTED_BLOB_MIME_TYPE;
use sonar_core::identity::Identity;

use crate::schema::{ServiceState, StatusService};

/// Soft latency budget for Blossom upload (ms). Above this → degraded.
const MEDIA_UPLOAD_DEGRADED_MS: u64 = 5_000;
/// Soft latency budget for HEAD-only mode (ms).
const MEDIA_HEAD_DEGRADED_MS: u64 = 5_000;
/// Hard timeout per single HTTP/Blossom op (upload PUT, GET, or HEAD).
const MEDIA_TIMEOUT: Duration = Duration::from_secs(20);
/// Cap on compare hosts so a bad env list cannot stretch the cron forever.
const MAX_COMPARE_HOSTS: usize = 2;
/// Wall-clock budget for non-primary (compare) hosts — primary keeps the full
/// [`MEDIA_TIMEOUT`] per op; a hung compare must not stretch publish to ~48s.
const COMPARE_HOST_BUDGET: Duration = Duration::from_secs(12);
/// Canary payload size (~4 KiB) — enough to exercise the PUT body path without
/// dominating cron runtime.
const CANARY_BYTES: usize = 4_096;
/// GET body slack over canary size (reject oversized / DoS responses).
const CANARY_GET_MAX_BYTES: usize = CANARY_BYTES + 64;

/// Previous public Blossom default — kept as the status compare target so
/// `/status` shows Hedwig vs the old public host.
pub const PUBLIC_BLOSSOM_COMPARE: &str = "https://nostr.download";

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
    /// Whether canary delete succeeded (upload mode only).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delete_ok: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delete_error: Option<String>,
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
            // Blossom storage latency (canary PUT/GET), not full MIP-04 send.
            name: "Media storage".into(),
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
        "Blossom storage probe produced no samples".into()
    } else {
        format!("Blossom storage · {}", parts.join(" · "))
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

/// Fail-closed report when `--media-probe` is set without a probe nsec.
/// HEAD reachability alone must not mark Media storage Ok.
pub fn media_probe_requires_nsec(primary: &str, reason: &str) -> MediaProbeReport {
    let primary = primary.trim_end_matches('/').to_owned();
    MediaProbeReport {
        ok: false,
        state: ServiceState::Degraded,
        primary: primary.clone(),
        mode: "upload".into(),
        servers: vec![MediaServerSample {
            server: primary,
            primary: true,
            ok: false,
            mode: "upload".into(),
            status: None,
            head_ms: None,
            upload_ms: None,
            get_ms: None,
            delete_ok: None,
            delete_error: None,
            error: Some(format!(
                "probe nsec required for BUD-02 media check ({reason})"
            )),
        }],
    }
}

/// Probe Blossom servers. With `probe_secret`, run BUD-02 upload+GET+delete;
/// otherwise HEAD/GET reachability only.
pub async fn probe_blossom_servers(
    primary: &str,
    compare: &[String],
    probe_secret: Option<&str>,
) -> MediaProbeReport {
    let mut servers = blossom_servers_to_probe(primary, compare);
    // Keep primary + at most MAX_COMPARE_HOSTS candidates.
    if servers.len() > 1 + MAX_COMPARE_HOSTS {
        servers.truncate(1 + MAX_COMPARE_HOSTS);
    }
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
                        delete_ok: None,
                        delete_error: None,
                        error: Some(format!("import probe identity: {e}")),
                    }],
                };
            }
        },
        None => None,
    };

    // Probe hosts concurrently. Compare hosts get a tighter wall-clock budget
    // so a hung candidate cannot stretch publish to the full per-op stack.
    let samples = {
        let futs: Vec<_> = servers
            .iter()
            .map(|(server, is_primary)| {
                let keys = keys.clone();
                let server = server.clone();
                let is_primary = *is_primary;
                async move {
                    let fut = async {
                        if let Some(ref keys) = keys {
                            probe_upload(&server, is_primary, keys).await
                        } else {
                            probe_head(&server, is_primary).await
                        }
                    };
                    if is_primary {
                        fut.await
                    } else {
                        match tokio::time::timeout(COMPARE_HOST_BUDGET, fut).await {
                            Ok(sample) => sample,
                            Err(_) => MediaServerSample {
                                server,
                                primary: false,
                                ok: false,
                                mode: mode.into(),
                                status: None,
                                head_ms: None,
                                upload_ms: None,
                                get_ms: None,
                                delete_ok: None,
                                delete_error: None,
                                error: Some(format!(
                                    "compare timed out after {}s",
                                    COMPARE_HOST_BUDGET.as_secs()
                                )),
                            },
                        }
                    }
                }
            })
            .collect();
        futures_util::future::join_all(futs).await
    };

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

    if let Ok(u) = Url::parse(&server) {
        if u.scheme() != "https" {
            return MediaServerSample {
                server,
                primary,
                ok: false,
                mode: "head".into(),
                status: None,
                head_ms: Some(t0.elapsed().as_millis() as u64),
                upload_ms: None,
                get_ms: None,
                delete_ok: None,
                delete_error: None,
                error: Some(format!("refusing non-https blossom server {}", u.scheme())),
            };
        }
    }

    let client = match reqwest::Client::builder()
        .timeout(MEDIA_TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
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
                delete_ok: None,
                delete_error: None,
                error: Some(format!("build client: {e}")),
            };
        }
    };

    // One deadline for HEAD and the 405/404 GET fallback. 3xx is failure
    // (redirects disabled — do not treat redirection as reachability).
    let reachability = async {
        let resp = client.head(&server).send().await?;
        let mut status = resp.status().as_u16();
        let mut ok = resp.status().is_success();
        if status == 405 || status == 404 {
            let r = client.get(&server).send().await?;
            status = r.status().as_u16();
            ok = r.status().is_success();
        }
        Ok::<_, reqwest::Error>((status, ok))
    };

    match tokio::time::timeout(MEDIA_TIMEOUT, reachability).await {
        Ok(Ok((status, ok))) => {
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
                delete_ok: None,
                delete_error: None,
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
            delete_ok: None,
            delete_error: None,
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
            delete_ok: None,
            delete_error: None,
            error: Some(format!("timed out after {}s", MEDIA_TIMEOUT.as_secs())),
        },
    }
}

fn upload_fail(
    server: String,
    primary: bool,
    upload_ms: Option<u64>,
    get_ms: Option<u64>,
    error: String,
) -> MediaServerSample {
    MediaServerSample {
        server,
        primary,
        ok: false,
        mode: "upload".into(),
        status: None,
        head_ms: None,
        upload_ms,
        get_ms,
        delete_ok: None,
        delete_error: None,
        error: Some(error),
    }
}

/// Require https + same host:port as the upload base (no open redirects / SSRF).
fn validate_canary_get_url(upload_base: &Url, blob_url: &Url) -> Result<(), String> {
    if blob_url.scheme() != "https" {
        return Err(format!(
            "refusing non-https descriptor.url scheme {}",
            blob_url.scheme()
        ));
    }
    let upload_host = upload_base.host_str().unwrap_or("");
    let blob_host = blob_url.host_str().unwrap_or("");
    if upload_host.is_empty() || blob_host != upload_host {
        return Err(format!(
            "descriptor.url host {blob_host:?} != upload host {upload_host:?}"
        ));
    }
    let upload_port = upload_base.port_or_known_default();
    let blob_port = blob_url.port_or_known_default();
    if upload_port != blob_port {
        return Err(format!(
            "descriptor.url port {blob_port:?} != upload port {upload_port:?}"
        ));
    }
    Ok(())
}

async fn read_body_capped(
    mut resp: reqwest::Response,
    max_bytes: usize,
) -> Result<Vec<u8>, String> {
    if let Some(len) = resp.content_length() {
        if len as usize > max_bytes {
            return Err(format!("GET body too large: {len} bytes"));
        }
    }
    let mut body = Vec::new();
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|e| format!("GET body read: {e}"))?
    {
        if body.len() + chunk.len() > max_bytes {
            return Err("GET body exceeded size cap".into());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

async fn probe_upload(server: &str, primary: bool, keys: &nostr::Keys) -> MediaServerSample {
    let server = server.trim_end_matches('/').to_owned();
    let base = match Url::parse(&server) {
        Ok(u) => u,
        Err(e) => {
            return upload_fail(server, primary, None, None, format!("bad server url: {e}"));
        }
    };
    if base.scheme() != "https" {
        return upload_fail(
            server,
            primary,
            None,
            None,
            format!("refusing non-https blossom server {}", base.scheme()),
        );
    }
    let upload_base = base.clone();

    let data = canary_payload();
    let client = BlossomClient::new(base);
    let t_upload = Instant::now();
    let upload = tokio::time::timeout(
        MEDIA_TIMEOUT,
        client.upload_blob(
            data.clone(),
            Some(ENCRYPTED_BLOB_MIME_TYPE.into()),
            None,
            Some(keys),
        ),
    )
    .await;

    let descriptor = match upload {
        Ok(Ok(desc)) => desc,
        Ok(Err(e)) => {
            return upload_fail(
                server,
                primary,
                Some(t_upload.elapsed().as_millis() as u64),
                None,
                summarize_blossom_err(&e),
            );
        }
        Err(_) => {
            return upload_fail(
                server,
                primary,
                Some(t_upload.elapsed().as_millis() as u64),
                None,
                format!("upload timed out after {}s", MEDIA_TIMEOUT.as_secs()),
            );
        }
    };
    let upload_ms = t_upload.elapsed().as_millis() as u64;

    if let Err(e) = validate_canary_get_url(&upload_base, &descriptor.url) {
        // Upload already landed — still best-effort delete so a bad descriptor
        // URL cannot leave canaries on every cron tick.
        let (delete_ok, delete_error) = match tokio::time::timeout(
            Duration::from_secs(2),
            client.delete_blob(descriptor.sha256, None, keys),
        )
        .await
        {
            Ok(Ok(())) => (Some(true), None),
            Ok(Err(err)) => (Some(false), Some(summarize_blossom_err(&err))),
            Err(_) => (Some(false), Some("delete timed out after 2s".into())),
        };
        return MediaServerSample {
            server,
            primary,
            ok: false,
            mode: "upload".into(),
            status: None,
            head_ms: None,
            upload_ms: Some(upload_ms),
            get_ms: None,
            delete_ok,
            delete_error,
            error: Some(e),
        };
    }

    // Fetch the exact URL apps store (`descriptor.url`). Hardened like
    // sonar-core media download: https, no redirects, capped body.
    let http = match reqwest::Client::builder()
        .timeout(MEDIA_TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            return upload_fail(
                server,
                primary,
                Some(upload_ms),
                None,
                format!("build GET client: {e}"),
            );
        }
    };
    let blob_host = descriptor
        .url
        .host_str()
        .unwrap_or("unknown")
        .to_owned();
    let t_get = Instant::now();
    let get = tokio::time::timeout(MEDIA_TIMEOUT, http.get(descriptor.url.as_str()).send()).await;
    let get_ms = t_get.elapsed().as_millis() as u64;

    let (get_ok, get_status, get_error) = match get {
        Ok(Ok(resp)) => {
            let status = resp.status().as_u16();
            if !resp.status().is_success() {
                (
                    false,
                    Some(status),
                    Some(format!("GET {blob_host} HTTP {status}")),
                )
            } else {
                match read_body_capped(resp, CANARY_GET_MAX_BYTES).await {
                    Ok(bytes) if bytes == data => (true, Some(status), None),
                    Ok(_) => (false, Some(status), Some("GET body mismatch".into())),
                    Err(e) => (false, Some(status), Some(e)),
                }
            }
        }
        Ok(Err(e)) => (false, None, Some(format!("GET {blob_host} failed: {e}"))),
        Err(_) => (
            false,
            None,
            Some(format!("GET timed out after {}s", MEDIA_TIMEOUT.as_secs())),
        ),
    };

    // Cleanup is best-effort for probe ok/state, but delete outcome is recorded.
    let delete_budget = if get_ok {
        Duration::from_secs(8)
    } else {
        Duration::from_secs(2)
    };
    let (delete_ok, delete_error) = match tokio::time::timeout(
        delete_budget,
        client.delete_blob(descriptor.sha256, None, keys),
    )
    .await
    {
        Ok(Ok(())) => (Some(true), None),
        Ok(Err(e)) => (Some(false), Some(summarize_blossom_err(&e))),
        Err(_) => (
            Some(false),
            Some(format!("delete timed out after {}s", delete_budget.as_secs())),
        ),
    };

    MediaServerSample {
        server,
        primary,
        ok: get_ok,
        mode: "upload".into(),
        status: get_status,
        head_ms: None,
        upload_ms: Some(upload_ms),
        get_ms: Some(get_ms),
        delete_ok,
        delete_error,
        error: get_error,
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

/// Cap a status-page `desc` at 120 bytes without ever splitting a UTF-8
/// character.
///
/// This used to be `&s[..117]`, a raw byte index into a `String`: it panics
/// with "byte index 117 is not a char boundary" whenever byte 117 lands inside
/// a multi-byte character. Nothing routed through here carries non-ASCII today
/// — the only externally-influenced field is a Blossom server's `X-Reason`
/// header, and `HeaderValue::to_str` rejects any byte outside visible ASCII, so
/// a hostile header degrades to "Unknown reason" long before it reaches this
/// string — but a byte index is wrong by construction, and this runs inside a
/// long-lived publisher where a panic costs the status page until restart.
/// `str::floor_char_boundary` is still unstable, hence the walk.
fn truncate_desc(s: &str) -> String {
    const MAX_BYTES: usize = 120;
    const CUT: usize = 117;
    if s.len() <= MAX_BYTES {
        return s.to_owned();
    }
    let mut end = CUT;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &s[..end])
}

fn summarize_blossom_err(err: &nostr_blossom::error::Error) -> String {
    let s = err.to_string();
    // Keep the status page desc short; full text stays in probe JSON.
    if let Some(rest) = s.strip_prefix("Failed to upload blob: ") {
        return rest.to_owned();
    }
    truncate_desc(&s)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sonar_core::client::DEFAULT_BLOSSOM_SERVER;

    #[test]
    fn primary_matches_app_default_blossom() {
        assert_eq!(DEFAULT_BLOSSOM_SERVER, "https://push.sonar.hedwig.sh");
    }

    /// Regression: the truncation was a raw byte slice `&s[..117]`, so any
    /// error string over 120 bytes whose 117th byte fell inside a multi-byte
    /// character panicked the publisher instead of shortening the desc.
    #[test]
    fn truncate_desc_never_splits_a_char() {
        // Byte 117 lands mid-character: 116 ASCII bytes, then a 2-byte U+00BD.
        let mid = format!("{}\u{00bd}{}", "a".repeat(116), "b".repeat(40));
        assert!(mid.len() > 120 && !mid.is_char_boundary(117));
        let out = truncate_desc(&mid);
        assert_eq!(out, format!("{}…", "a".repeat(116)));

        // Also exercise a wider char and a fully multi-byte string.
        for s in [
            format!("{}\u{1f600}{}", "a".repeat(115), "b".repeat(40)),
            "\u{4e2d}".repeat(80),
        ] {
            let out = truncate_desc(&s);
            assert!(out.ends_with('…'), "expected ellipsis for {} bytes", s.len());
            assert!(out.len() <= 117 + '…'.len_utf8());
        }

        // Short strings pass through untouched, ellipsis-free.
        assert_eq!(truncate_desc("boom"), "boom");
        let exactly_120 = "c".repeat(120);
        assert_eq!(truncate_desc(&exactly_120), exactly_120);
    }

    #[test]
    fn service_mapping_ok_omits_state() {
        let r = MediaProbeReport {
            ok: true,
            state: ServiceState::Ok,
            primary: DEFAULT_BLOSSOM_SERVER.into(),
            mode: "upload".into(),
            servers: vec![
                MediaServerSample {
                    server: DEFAULT_BLOSSOM_SERVER.into(),
                    primary: true,
                    ok: true,
                    mode: "upload".into(),
                    status: Some(201),
                    head_ms: None,
                    upload_ms: Some(116),
                    get_ms: Some(35),
                    delete_ok: Some(true),
                    delete_error: None,
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
                    delete_ok: Some(true),
                    delete_error: None,
                    error: None,
                },
            ],
        };
        let s = r.to_service();
        assert_eq!(s.id, "media");
        assert_eq!(s.name, "Media storage");
        assert!(s.state.is_none());
        assert!(s.desc.starts_with("Blossom storage ·"));
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
            primary: DEFAULT_BLOSSOM_SERVER.into(),
            mode: "head".into(),
            servers: vec![MediaServerSample {
                server: DEFAULT_BLOSSOM_SERVER.into(),
                primary: true,
                ok: false,
                mode: "head".into(),
                status: Some(503),
                head_ms: Some(100),
                upload_ms: None,
                get_ms: None,
                delete_ok: None,
                delete_error: None,
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
            &format!("{DEFAULT_BLOSSOM_SERVER}/"),
            &[
                PUBLIC_BLOSSOM_COMPARE.into(),
                DEFAULT_BLOSSOM_SERVER.into(),
            ],
        );
        assert_eq!(list.len(), 2);
        assert!(list[0].1);
        assert_eq!(list[0].0, DEFAULT_BLOSSOM_SERVER);
        assert!(!list[1].1);
        assert_eq!(list[1].0, PUBLIC_BLOSSOM_COMPARE);
    }

    #[test]
    fn short_host_strips_scheme() {
        assert_eq!(
            short_host(&format!("{DEFAULT_BLOSSOM_SERVER}/")),
            "push.sonar.hedwig.sh"
        );
    }

    #[test]
    fn canary_get_url_requires_https_same_host() {
        let base = Url::parse(DEFAULT_BLOSSOM_SERVER).unwrap();
        let ok = Url::parse(&format!(
            "{DEFAULT_BLOSSOM_SERVER}/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ))
        .unwrap();
        assert!(validate_canary_get_url(&base, &ok).is_ok());

        let http = Url::parse("http://push.sonar.hedwig.sh/aa").unwrap();
        assert!(validate_canary_get_url(&base, &http).is_err());

        let other = Url::parse("https://evil.example/aa").unwrap();
        assert!(validate_canary_get_url(&base, &other).is_err());

        let other_port = Url::parse("https://push.sonar.hedwig.sh:9100/aa").unwrap();
        assert!(validate_canary_get_url(&base, &other_port).is_err());
    }

    #[test]
    fn media_probe_without_nsec_is_degraded_not_ok() {
        let r = media_probe_requires_nsec(DEFAULT_BLOSSOM_SERVER, "missing nsec");
        assert!(!r.ok);
        assert_eq!(r.state, ServiceState::Degraded);
        assert!(r.servers[0]
            .error
            .as_deref()
            .unwrap_or("")
            .contains("probe nsec required"));
    }
}
