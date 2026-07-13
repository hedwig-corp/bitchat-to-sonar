//! Sonar status tracer + Nostr publisher.
//!
//! Probes public Nostr relays (WebSocket open RTT) and optional HTTP health
//! endpoints for Sonar-adjacent services, then either:
//!   - prints a website-compatible JSON status document, or
//!   - signs and publishes it as a replaceable event (kind 30078, d=sonar-status).
//!
//! The marketing site (`web/src/lib/status-nostr.js`) REQs that event and fills
//! the `/status` page when `STATUS_PUBKEY_HEX` matches this publisher.

use std::env;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use chrono::{SecondsFormat, Utc};
use clap::{Parser, Subcommand};
use futures_util::{SinkExt, StreamExt};
use nostr::prelude::*;
use nostr_sdk::Client as NostrClient;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use ::url::Url;

/// Replaceable parameterized event kind for the Sonar status document.
/// Must match `web/src/lib/status-data.js` `STATUS_EVENT_KIND`.
const STATUS_EVENT_KIND: u16 = 30078;
/// `d` tag — must match `web/src/lib/status-data.js` `STATUS_EVENT_D`.
const STATUS_EVENT_D: &str = "sonar-status";

/// Sonar client bootstrap relays — union of iOS `NostrRelayManager.defaultRelays`
/// and Android/JVM `SonarCore` defaults. Keep in sync with
/// `web/src/lib/status-data.js` seed relays.
const DEFAULT_RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://offchain.pub",
    "wss://nostr21.com",
    "wss://relay.kaleidoswap.com",
    "wss://nostr.relay.hedwig.sh",
];

/// Where the signed status document is published (must be readable by the site).
const DEFAULT_PUBLISH_RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://nostr.relay.hedwig.sh",
];

const WS_TIMEOUT: Duration = Duration::from_secs(4);
const HTTP_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, Error)]
enum Error {
    #[error("{0}")]
    Msg(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    NostrKey(#[from] nostr::key::Error),
    #[error(transparent)]
    NostrEvent(#[from] nostr::event::Error),
    #[error(transparent)]
    NostrBuilder(#[from] nostr::event::builder::Error),
    #[error(transparent)]
    NostrSdk(#[from] nostr_sdk::client::Error),
    #[error(transparent)]
    Url(#[from] url::ParseError),
    #[error(transparent)]
    Reqwest(#[from] reqwest::Error),
}

type Result<T> = std::result::Result<T, Error>;

#[derive(Parser, Debug)]
#[command(
    name = "sonar-status",
    about = "Probe Sonar systems and publish a Nostr status document for the website"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Run probes and print the status JSON document (website schema).
    Probe(ProbeArgs),
    /// Run probes, sign kind 30078, and publish to relays.
    Publish(PublishArgs),
    /// Print the public key for a configured nsec (hex + npub).
    Identity(IdentityArgs),
}

#[derive(Parser, Debug)]
struct ProbeArgs {
    /// Extra HTTP health URLs to probe as `http-<host>` services (GET).
    #[arg(long = "http", value_name = "URL")]
    http_urls: Vec<String>,
    /// Comma-separated wss:// relays to RTT-probe (defaults to public set).
    #[arg(long, env = "SONAR_STATUS_PROBE_RELAYS")]
    relays: Option<String>,
    /// Path to a previous status document used to merge incident history.
    #[arg(long)]
    previous: Option<PathBuf>,
    /// Pretty-print JSON.
    #[arg(long)]
    pretty: bool,
}

#[derive(Parser, Debug)]
struct PublishArgs {
    /// nsec1… or 64-char hex secret. Prefer --nsec-file / SONAR_STATUS_NSEC.
    #[arg(long, env = "SONAR_STATUS_NSEC", conflicts_with_all = ["nsec_file"])]
    nsec: Option<String>,
    /// Read nsec from a local file (0600 recommended).
    #[arg(long, conflicts_with = "nsec")]
    nsec_file: Option<PathBuf>,
    /// Relays to publish the status event to (comma-separated).
    #[arg(long, env = "SONAR_STATUS_PUBLISH_RELAYS")]
    publish_relays: Option<String>,
    /// Relays to RTT-probe for the document (comma-separated).
    #[arg(long, env = "SONAR_STATUS_PROBE_RELAYS")]
    probe_relays: Option<String>,
    /// Extra HTTP health URLs.
    #[arg(long = "http", value_name = "URL")]
    http_urls: Vec<String>,
    /// Path to previous status JSON for incident continuity.
    #[arg(long)]
    previous: Option<PathBuf>,
    /// Also write the published payload JSON to this path.
    #[arg(long)]
    out: Option<PathBuf>,
    /// Dry-run: probe + sign but do not send to relays.
    #[arg(long)]
    dry_run: bool,
}

#[derive(Parser, Debug)]
struct IdentityArgs {
    #[arg(long, env = "SONAR_STATUS_NSEC", conflicts_with_all = ["nsec_file"])]
    nsec: Option<String>,
    #[arg(long, conflicts_with = "nsec")]
    nsec_file: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum ServiceState {
    Ok,
    Degraded,
    Down,
}

impl ServiceState {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Degraded => "degraded",
            Self::Down => "down",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StatusService {
    id: String,
    name: String,
    desc: String,
    uptime: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    state: Option<ServiceState>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StatusRelay {
    url: String,
    region: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum IncidentLevel {
    Degraded,
    Maintenance,
    Down,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct IncidentUpdate {
    t: String,
    s: String,
    b: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StatusIncident {
    date: String,
    title: String,
    level: IncidentLevel,
    updates: Vec<IncidentUpdate>,
}

/// Website-compatible payload (`web/src/lib/status-nostr.js` schema).
#[derive(Debug, Clone, Serialize, Deserialize)]
struct StatusPayload {
    services: Vec<StatusService>,
    relays: Vec<StatusRelay>,
    incidents: Vec<StatusIncident>,
    /// Extra metadata for operators (ignored by the website parser).
    #[serde(skip_serializing_if = "Option::is_none")]
    updated_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    probe: Option<serde_json::Value>,
}

#[derive(Debug, Clone)]
struct RelayProbe {
    url: String,
    region: String,
    /// Open RTT ms, or None if unreachable.
    ms: Option<u64>,
}

#[derive(Debug, Clone)]
struct HttpProbe {
    id: String,
    name: String,
    url: String,
    ok: bool,
    status: Option<u16>,
    ms: Option<u64>,
    error: Option<String>,
}

#[tokio::main]
async fn main() {
    if let Err(e) = run().await {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Probe(args) => {
            let payload = build_payload(
                parse_list(args.relays.as_deref(), DEFAULT_RELAYS),
                &args.http_urls,
                args.previous.as_ref(),
            )
            .await?;
            print_json(&payload, args.pretty)?;
        }
        Command::Publish(args) => {
            let keys = load_keys(args.nsec.as_deref(), args.nsec_file.as_ref())?;
            let probe_relays = parse_list(args.probe_relays.as_deref(), DEFAULT_RELAYS);
            let publish_relays = parse_list(args.publish_relays.as_deref(), DEFAULT_PUBLISH_RELAYS);
            let payload =
                build_payload(probe_relays, &args.http_urls, args.previous.as_ref()).await?;
            if let Some(path) = &args.out {
                std::fs::write(path, serde_json::to_vec_pretty(&payload)?)?;
            }
            let content = serde_json::to_string(&website_view(&payload))?;
            let event = EventBuilder::new(Kind::Custom(STATUS_EVENT_KIND), content)
                .tag(Tag::identifier(STATUS_EVENT_D))
                .tag(Tag::custom(
                    TagKind::Custom("client".into()),
                    ["sonar-status"],
                ))
                .sign_with_keys(&keys)?;

            let npub = keys.public_key().to_bech32().unwrap_or_default();
            let pubkey_hex = keys.public_key().to_hex();
            println!(
                "signed kind={STATUS_EVENT_KIND} d={STATUS_EVENT_D} id={} pubkey={pubkey_hex} npub={npub}",
                event.id
            );

            if args.dry_run {
                println!("dry-run: not publishing ({} relays configured)", publish_relays.len());
                return Ok(());
            }

            let client = NostrClient::new(keys);
            for relay in &publish_relays {
                client
                    .add_relay(relay.clone())
                    .await
                    .map_err(|e| Error::Msg(format!("add relay {relay}: {e}")))?;
            }
            client.connect().await;
            client
                .send_event(&event)
                .await
                .map_err(|e| Error::Msg(format!("publish status event: {e}")))?;
            println!(
                "published to {} relay(s): {}",
                publish_relays.len(),
                publish_relays.join(", ")
            );
            println!(
                "website: set STATUS_PUBKEY_HEX={pubkey_hex} and STATUS_NPUB={npub} in web/src/lib/status-data.js"
            );
        }
        Command::Identity(args) => {
            let keys = load_keys(args.nsec.as_deref(), args.nsec_file.as_ref())?;
            println!("pubkey_hex={}", keys.public_key().to_hex());
            println!(
                "npub={}",
                keys.public_key().to_bech32().unwrap_or_default()
            );
        }
    }
    Ok(())
}

/// Strip operator-only fields so the website schema validator stays happy.
fn website_view(payload: &StatusPayload) -> StatusPayload {
    StatusPayload {
        services: payload.services.clone(),
        relays: payload.relays.clone(),
        incidents: payload.incidents.clone(),
        updated_at: None,
        probe: None,
    }
}

fn print_json(payload: &StatusPayload, pretty: bool) -> Result<()> {
    let view = website_view(payload);
    if pretty {
        println!("{}", serde_json::to_string_pretty(&view)?);
    } else {
        println!("{}", serde_json::to_string(&view)?);
    }
    Ok(())
}

fn load_keys(nsec: Option<&str>, nsec_file: Option<&PathBuf>) -> Result<Keys> {
    let secret = if let Some(path) = nsec_file {
        let raw = std::fs::read_to_string(path)
            .map_err(|e| Error::Msg(format!("read nsec file {}: {e}", path.display())))?;
        raw.trim().to_owned()
    } else if let Some(s) = nsec {
        s.trim().to_owned()
    } else if let Ok(s) = env::var("SONAR_STATUS_NSEC") {
        s.trim().to_owned()
    } else {
        return Err(Error::Msg(
            "missing secret: pass --nsec, --nsec-file, or SONAR_STATUS_NSEC".into(),
        ));
    };
    if secret.is_empty() {
        return Err(Error::Msg("empty nsec".into()));
    }
    Keys::parse(&secret).map_err(|e| Error::Msg(format!("parse nsec: {e}")))
}

fn parse_list(raw: Option<&str>, defaults: &[&str]) -> Vec<String> {
    match raw {
        Some(s) if !s.trim().is_empty() => s
            .split(|c: char| c == ',' || c.is_whitespace())
            .map(str::trim)
            .filter(|x| !x.is_empty())
            .map(|x| x.to_owned())
            .collect(),
        _ => defaults.iter().map(|s| (*s).to_owned()).collect(),
    }
}

async fn build_payload(
    relay_urls: Vec<String>,
    http_urls: &[String],
    previous: Option<&PathBuf>,
) -> Result<StatusPayload> {
    let mut relay_probes = Vec::with_capacity(relay_urls.len());
    for url in &relay_urls {
        let region = region_for(url);
        let ms = probe_relay_ws(url).await;
        relay_probes.push(RelayProbe {
            url: url.clone(),
            region,
            ms,
        });
    }

    let mut http_probes = Vec::new();
    for url in http_urls {
        http_probes.push(probe_http(url).await);
    }

    let services = derive_services(&relay_probes, &http_probes);
    let relays: Vec<StatusRelay> = relay_probes
        .iter()
        .map(|r| StatusRelay {
            url: r.url.clone(),
            region: r.region.clone(),
        })
        .collect();

    let previous_doc = match previous {
        Some(path) => {
            let raw = std::fs::read_to_string(path)
                .map_err(|e| Error::Msg(format!("read previous {}: {e}", path.display())))?;
            Some(serde_json::from_str::<StatusPayload>(&raw)?)
        }
        None => None,
    };

    let incidents = derive_incidents(&services, previous_doc.as_ref());

    let probe_meta = serde_json::json!({
        "relays": relay_probes.iter().map(|r| serde_json::json!({
            "url": r.url,
            "ms": r.ms,
            "ok": r.ms.is_some(),
        })).collect::<Vec<_>>(),
        "http": http_probes.iter().map(|h| serde_json::json!({
            "id": h.id,
            "url": h.url,
            "ok": h.ok,
            "status": h.status,
            "ms": h.ms,
            "error": h.error,
        })).collect::<Vec<_>>(),
    });

    Ok(StatusPayload {
        services,
        relays,
        incidents,
        updated_at: Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)),
        probe: Some(probe_meta),
    })
}

fn region_for(url: &str) -> String {
    match url {
        u if u.contains("damus") => "Global · CDN".into(),
        u if u.contains("nos.lol") => "EU · Germany".into(),
        u if u.contains("primal") => "US · East".into(),
        u if u.contains("offchain.pub") => "Global · iOS default".into(),
        u if u.contains("nostr21.com") => "Global · iOS default".into(),
        u if u.contains("kaleidoswap") => "Global · client default".into(),
        u if u.contains("hedwig") => "Hedwig · Sonar".into(),
        u if u.contains("snort") => "EU · UK".into(),
        u if u.contains("nostr.wine") => "US · Central".into(),
        u if u.contains("nostr.band") => "Global · Anycast".into(),
        _ => "Unknown".into(),
    }
}

async fn probe_relay_ws(url: &str) -> Option<u64> {
    let parsed = Url::parse(url).ok()?;
    if parsed.scheme() != "wss" && parsed.scheme() != "ws" {
        return None;
    }
    let t0 = Instant::now();
    let connect = connect_async(url);
    match timeout(WS_TIMEOUT, connect).await {
        Ok(Ok((mut ws, _))) => {
            let ms = t0.elapsed().as_millis() as u64;
            // Best-effort clean close.
            let _ = ws.send(Message::Close(None)).await;
            let _ = ws.close(None).await;
            // Drain briefly so the close completes without hanging the tool.
            let _ = timeout(Duration::from_millis(200), ws.next()).await;
            Some(ms)
        }
        _ => None,
    }
}

async fn probe_http(url: &str) -> HttpProbe {
    let host = Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(|h| h.to_owned()))
        .unwrap_or_else(|| "endpoint".into());
    let id = format!(
        "http-{}",
        host.chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
            .collect::<String>()
    );
    let name = format!("HTTP {host}");
    let client = match reqwest::Client::builder().timeout(HTTP_TIMEOUT).build() {
        Ok(c) => c,
        Err(e) => {
            return HttpProbe {
                id,
                name,
                url: url.to_owned(),
                ok: false,
                status: None,
                ms: None,
                error: Some(e.to_string()),
            };
        }
    };
    let t0 = Instant::now();
    match client.get(url).send().await {
        Ok(resp) => {
            let status = resp.status().as_u16();
            let ms = t0.elapsed().as_millis() as u64;
            let ok = resp.status().is_success();
            HttpProbe {
                id,
                name,
                url: url.to_owned(),
                ok,
                status: Some(status),
                ms: Some(ms),
                error: if ok {
                    None
                } else {
                    Some(format!("HTTP {status}"))
                },
            }
        }
        Err(e) => HttpProbe {
            id,
            name,
            url: url.to_owned(),
            ok: false,
            status: None,
            ms: None,
            error: Some(e.to_string()),
        },
    }
}

fn derive_services(relays: &[RelayProbe], https: &[HttpProbe]) -> Vec<StatusService> {
    let total = relays.len().max(1);
    let reachable = relays.iter().filter(|r| r.ms.is_some()).count();
    let ratio = reachable as f64 / total as f64;
    let latencies: Vec<u64> = relays.iter().filter_map(|r| r.ms).collect();
    let median = median_u64(&latencies);

    let (relay_state, relay_uptime) = if reachable == 0 {
        (Some(ServiceState::Down), 0.0)
    } else if ratio < 0.5 || median.map(|m| m > 900).unwrap_or(false) {
        (Some(ServiceState::Degraded), 95.0 + ratio * 4.0)
    } else if ratio < 0.85 || median.map(|m| m > 450).unwrap_or(false) {
        (Some(ServiceState::Degraded), 98.0 + ratio * 1.5)
    } else {
        (None, 99.5 + ratio * 0.5)
    };

    // Only services we can actually observe today.
    // Application surfaces (DM/groups/media/…) require dedicated probes —
    // see docs/SONAR-STATUS.md § "Real service probes". Until those land,
    // do NOT invent mock degraded rows for them.
    let mut services = vec![StatusService {
        id: "relays".into(),
        name: "Nostr relay network (client defaults)".into(),
        desc: format!(
            "{reachable}/{total} Sonar bootstrap relays reachable · median {} ms",
            median.map(|m| m.to_string()).unwrap_or_else(|| "—".into())
        ),
        uptime: (relay_uptime * 100.0).round() / 100.0,
        state: relay_state,
    }];

    for h in https {
        let state = if h.ok {
            None
        } else if h.status.map(|s| s >= 500).unwrap_or(true) {
            Some(ServiceState::Down)
        } else {
            Some(ServiceState::Degraded)
        };
        services.push(StatusService {
            id: h.id.clone(),
            name: h.name.clone(),
            desc: format!("Health check {}", h.url),
            uptime: if h.ok { 99.9 } else { 90.0 },
            state,
        });
    }

    services
}


fn median_u64(vals: &[u64]) -> Option<u64> {
    if vals.is_empty() {
        return None;
    }
    let mut v = vals.to_vec();
    v.sort_unstable();
    Some(v[v.len() / 2])
}

fn derive_incidents(
    services: &[StatusService],
    previous: Option<&StatusPayload>,
) -> Vec<StatusIncident> {
    let mut incidents = previous
        .map(|p| p.incidents.clone())
        .unwrap_or_default();

    let worst = services
        .iter()
        .filter_map(|s| s.state.as_ref())
        .max_by_key(|s| match s {
            ServiceState::Down => 2,
            ServiceState::Degraded => 1,
            ServiceState::Ok => 0,
        });

    let now = Utc::now();
    let date = now.format("%b %-d, %Y").to_string();
    let t = now.format("%H:%M UTC").to_string();

    match worst {
        Some(ServiceState::Down) | Some(ServiceState::Degraded) => {
            let level = if matches!(worst, Some(ServiceState::Down)) {
                IncidentLevel::Down
            } else {
                IncidentLevel::Degraded
            };
            let title = if matches!(level, IncidentLevel::Down) {
                "Probe detected service outage"
            } else {
                "Probe detected degraded performance"
            };
            let detail = services
                .iter()
                .filter(|s| {
                    matches!(
                        s.state,
                        Some(ServiceState::Degraded) | Some(ServiceState::Down)
                    )
                })
                .map(|s| format!("{} ({})", s.name, s.state.as_ref().unwrap().as_str()))
                .collect::<Vec<_>>()
                .join(", ");

            // If the latest incident is still open for this title, prepend a monitoring update.
            if let Some(first) = incidents.first_mut() {
                if first.title == title {
                    first.updates.insert(
                        0,
                        IncidentUpdate {
                            t: t.clone(),
                            s: "Monitoring".into(),
                            b: format!("Still observing: {detail}"),
                        },
                    );
                    return incidents;
                }
            }

            incidents.insert(
                0,
                StatusIncident {
                    date,
                    title: title.into(),
                    level,
                    updates: vec![IncidentUpdate {
                        t,
                        s: "Investigating".into(),
                        b: format!("Automated probe reported: {detail}"),
                    }],
                },
            );
        }
        _ => {
            // Recover open auto-incidents.
            if let Some(first) = incidents.first_mut() {
                if first.title.starts_with("Probe detected") {
                    let already_resolved = first
                        .updates
                        .iter()
                        .any(|u| u.s == "Resolved" || u.s == "Completed");
                    if !already_resolved {
                        first.updates.insert(
                            0,
                            IncidentUpdate {
                                t,
                                s: "Resolved".into(),
                                b: "Automated probe reports services recovered.".into(),
                            },
                        );
                    }
                }
            }
        }
    }

    // Cap history for event size.
    incidents.truncate(20);
    incidents
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn website_view_strips_probe_meta() {
        let p = StatusPayload {
            services: vec![StatusService {
                id: "dm".into(),
                name: "DM".into(),
                desc: "d".into(),
                uptime: 99.9,
                state: None,
            }],
            relays: vec![],
            incidents: vec![],
            updated_at: Some("x".into()),
            probe: Some(serde_json::json!({"a": 1})),
        };
        let v = website_view(&p);
        assert!(v.probe.is_none());
        assert!(v.updated_at.is_none());
        let s = serde_json::to_string(&v).unwrap();
        assert!(s.contains("\"id\":\"dm\""));
        assert!(!s.contains("updated_at"));
    }

    #[test]
    fn derive_services_all_down() {
        let relays = vec![RelayProbe {
            url: "wss://example".into(),
            region: "x".into(),
            ms: None,
        }];
        let services = derive_services(&relays, &[]);
        let relays_svc = services.iter().find(|s| s.id == "relays").unwrap();
        assert_eq!(relays_svc.state, Some(ServiceState::Down));
        // No mock application rows until dedicated probes exist.
        assert!(services.iter().all(|s| s.id == "relays" || s.id.starts_with("http-")));
    }

    #[test]
    fn median_works() {
        assert_eq!(median_u64(&[10, 30, 20]), Some(20));
        assert_eq!(median_u64(&[]), None);
    }
}
