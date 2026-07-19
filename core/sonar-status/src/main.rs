//! Sonar status tracer + Nostr publisher.
//!
//! Probes:
//! - public Sonar client bootstrap relays (WebSocket open RTT)
//! - optional HTTP health URLs
//! - optional Marmot chat path (KeyPackage publish + fetch) when a probe nsec is set
//!
//! Publishes a replaceable event (kind 30078, d=sonar-status) that the marketing
//! site (`web/src/lib/status-nostr.js`) REQs when `STATUS_PUBKEY_HEX` matches.

mod chat;
mod groups;
mod media;
mod schema;
mod stickers;

use std::env;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use chrono::{SecondsFormat, Utc};
use clap::{Parser, Subcommand};
use futures_util::{SinkExt, StreamExt};
use nostr::prelude::*;
use nostr_sdk::Client as NostrClient;
use thiserror::Error;
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use ::url::Url;

use chat::{load_probe_secret, probe_marmot_keypackage, ChatProbeReport};
use groups::{load_groups_result, payments_coming_soon, GroupsProbeResult};
use media::{
    default_blossom_compare, probe_blossom_servers, MediaProbeReport,
};
use stickers::{probe_sticker_index, StickerProbeReport};
use schema::{
    website_view, IncidentLevel, IncidentUpdate, ServiceState, StatusIncident, StatusPayload,
    StatusRelay, StatusService,
};

/// Replaceable parameterized event kind for the Sonar status document.
/// Must match `web/src/lib/status-data.js` `STATUS_EVENT_KIND`.
const STATUS_EVENT_KIND: u16 = 30078;
/// `d` tag — must match `web/src/lib/status-data.js` `STATUS_EVENT_D`.
const STATUS_EVENT_D: &str = "sonar-status";
/// Parameterized event kind for per-incident history.
/// Must match `web/src/lib/status-incidents.js` `INCIDENT_KIND`.
const INCIDENT_EVENT_KIND: u16 = 30080;
/// `d` tag prefix for incident events.
const INCIDENT_EVENT_D_PREFIX: &str = "sonar-incident-";

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

/// Relays the official White Noise Android client bootstraps against — kept in
/// sync with `MarmotClient.bootstrapRelays` in marmot-protocol/whitenoise-android.
///
/// Sonar's own traffic does not use these, but Marmot interop with the official
/// White Noise clients depends on them, so they are monitored as part of the
/// relay network row: if they go down, our relay row degrades like any other.
///
/// Reachability only. The chat/sticker probes *publish* events, and those writes
/// stay on `DEFAULT_RELAYS` — we monitor third-party infrastructure, we do not
/// write to it to fill in a status page.
const WHITENOISE_RELAYS: &[&str] = &[
    "wss://relay.us.whitenoise.chat",
    "wss://relay.eu.whitenoise.chat",
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
    /// Comma-separated wss:// relays to RTT-probe (defaults to client bootstrap set).
    #[arg(long, env = "SONAR_STATUS_PROBE_RELAYS")]
    relays: Option<String>,
    /// Comma-separated White Noise interop relays to RTT-probe (defaults to the
    /// official whitenoise-android bootstrap set).
    #[arg(long, env = "SONAR_STATUS_WHITENOISE_RELAYS")]
    whitenoise_relays: Option<String>,
    /// Path to a previous status document used to merge incident history.
    #[arg(long)]
    previous: Option<PathBuf>,
    /// Run Marmot KeyPackage chat probe (requires probe nsec).
    #[arg(long, env = "SONAR_STATUS_CHAT_PROBE")]
    chat_probe: bool,
    /// Probe identity nsec1… / hex (prefer --probe-nsec-file).
    #[arg(long, env = "SONAR_STATUS_PROBE_NSEC", conflicts_with = "probe_nsec_file")]
    probe_nsec: Option<String>,
    /// Read probe nsec from a local file (0600 recommended).
    #[arg(long, conflicts_with = "probe_nsec")]
    probe_nsec_file: Option<PathBuf>,
    /// Run sticker pack directory probe (REQ kind 30031 on bootstrap relays).
    #[arg(long, env = "SONAR_STATUS_STICKER_PROBE")]
    sticker_probe: bool,
    /// Run Blossom media probe (BUD-02 upload when probe nsec is set; else HEAD).
    #[arg(long, env = "SONAR_STATUS_MEDIA_PROBE")]
    media_probe: bool,
    /// Primary Blossom server to probe (defaults to sonar-core DEFAULT_BLOSSOM_SERVER).
    #[arg(long, env = "SONAR_STATUS_BLOSSOM_SERVER")]
    blossom_server: Option<String>,
    /// Extra Blossom servers to compare against the primary (comma-separated).
    /// Defaults to https://nostr.download when unset.
    #[arg(long, env = "SONAR_STATUS_BLOSSOM_COMPARE")]
    blossom_compare: Option<String>,
    /// Path to Hermes groups-probe result JSON.
    #[arg(long, env = "SONAR_STATUS_GROUPS_RESULT")]
    groups_result: Option<PathBuf>,
    /// Include payments row as coming soon.
    #[arg(long, env = "SONAR_STATUS_PAYMENTS_COMING_SOON")]
    payments_coming_soon: bool,
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
    /// White Noise interop relays to RTT-probe (comma-separated; defaults to the
    /// official whitenoise-android bootstrap set).
    #[arg(long, env = "SONAR_STATUS_WHITENOISE_RELAYS")]
    whitenoise_relays: Option<String>,
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
    /// Also publish a per-incident Nostr event (kind 30080) for each incident.
    #[arg(long, env = "SONAR_STATUS_PUBLISH_INCIDENTS", default_value_t = true)]
    publish_incidents: bool,
    /// Run Marmot KeyPackage chat probe (requires probe nsec).
    #[arg(long, env = "SONAR_STATUS_CHAT_PROBE")]
    chat_probe: bool,
    /// Probe identity nsec1… / hex (prefer --probe-nsec-file).
    #[arg(long, env = "SONAR_STATUS_PROBE_NSEC", conflicts_with = "probe_nsec_file")]
    probe_nsec: Option<String>,
    /// Read probe nsec from a local file (0600 recommended).
    #[arg(long, conflicts_with = "probe_nsec")]
    probe_nsec_file: Option<PathBuf>,
    /// Run sticker pack directory probe (REQ kind 30031 on bootstrap relays).
    #[arg(long, env = "SONAR_STATUS_STICKER_PROBE")]
    sticker_probe: bool,
    /// Run Blossom media probe (BUD-02 upload when probe nsec is set; else HEAD).
    #[arg(long, env = "SONAR_STATUS_MEDIA_PROBE")]
    media_probe: bool,
    /// Primary Blossom server to probe (defaults to sonar-core DEFAULT_BLOSSOM_SERVER).
    #[arg(long, env = "SONAR_STATUS_BLOSSOM_SERVER")]
    blossom_server: Option<String>,
    /// Extra Blossom servers to compare against the primary (comma-separated).
    /// Defaults to https://nostr.download when unset.
    #[arg(long, env = "SONAR_STATUS_BLOSSOM_COMPARE")]
    blossom_compare: Option<String>,
    /// Path to Hermes groups-probe result JSON.
    #[arg(long, env = "SONAR_STATUS_GROUPS_RESULT")]
    groups_result: Option<PathBuf>,
    /// Include payments row as coming soon.
    #[arg(long, env = "SONAR_STATUS_PAYMENTS_COMING_SOON")]
    payments_coming_soon: bool,
}

#[derive(Parser, Debug)]
struct IdentityArgs {
    #[arg(long, env = "SONAR_STATUS_NSEC", conflicts_with_all = ["nsec_file"])]
    nsec: Option<String>,
    #[arg(long, conflicts_with = "nsec")]
    nsec_file: Option<PathBuf>,
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

#[derive(Debug, Default)]
struct ProbeOptions {
    chat_probe: bool,
    probe_nsec: Option<String>,
    probe_nsec_file: Option<PathBuf>,
    sticker_probe: bool,
    media_probe: bool,
    blossom_server: Option<String>,
    blossom_compare: Option<String>,
    groups_result: Option<PathBuf>,
    payments_coming_soon: bool,
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
            let opts = ProbeOptions {
                // Chat only when explicitly requested — probe nsec is also used
                // for BUD-02 media auth and must not imply KeyPackage traffic.
                chat_probe: args.chat_probe,
                probe_nsec: args.probe_nsec,
                probe_nsec_file: args.probe_nsec_file.or_else(|| {
                    env::var_os("SONAR_STATUS_PROBE_NSEC_FILE").map(PathBuf::from)
                }),
                sticker_probe: args.sticker_probe,
                media_probe: args.media_probe,
                blossom_server: args.blossom_server,
                blossom_compare: args.blossom_compare,
                groups_result: args.groups_result,
                payments_coming_soon: args.payments_coming_soon,
            };
            let payload = build_payload(
                parse_list(args.relays.as_deref(), DEFAULT_RELAYS),
                parse_list(args.whitenoise_relays.as_deref(), WHITENOISE_RELAYS),
                &args.http_urls,
                args.previous.as_ref(),
                &opts,
            )
            .await?;
            print_json(&payload, args.pretty)?;
        }
        Command::Publish(args) => {
            let keys = load_keys(args.nsec.as_deref(), args.nsec_file.as_ref())?;
            let probe_relays = parse_list(args.probe_relays.as_deref(), DEFAULT_RELAYS);
            let whitenoise_relays = parse_list(args.whitenoise_relays.as_deref(), WHITENOISE_RELAYS);
            let publish_relays = parse_list(args.publish_relays.as_deref(), DEFAULT_PUBLISH_RELAYS);
            let opts = ProbeOptions {
                // Chat only when explicitly requested — probe nsec is also used
                // for BUD-02 media auth and must not imply KeyPackage traffic.
                chat_probe: args.chat_probe,
                probe_nsec: args.probe_nsec,
                probe_nsec_file: args.probe_nsec_file.or_else(|| {
                    env::var_os("SONAR_STATUS_PROBE_NSEC_FILE").map(PathBuf::from)
                }),
                sticker_probe: args.sticker_probe,
                media_probe: args.media_probe,
                blossom_server: args.blossom_server,
                blossom_compare: args.blossom_compare,
                groups_result: args.groups_result,
                payments_coming_soon: args.payments_coming_soon,
            };
            let payload = build_payload(
                probe_relays,
                whitenoise_relays,
                &args.http_urls,
                args.previous.as_ref(),
                &opts,
            )
            .await?;
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
                println!(
                    "dry-run: not publishing ({} relays configured)",
                    publish_relays.len()
                );
                return Ok(());
            }

            let client = NostrClient::new(keys.clone());
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

            // Publish per-incident history events.
            if args.publish_incidents {
                for (idx, incident) in payload.incidents.iter().enumerate().rev() {
                    let incident_content = serde_json::to_string(&incident)?;
                    let d_tag = format!("{INCIDENT_EVENT_D_PREFIX}{idx}");
                    let incident_event = EventBuilder::new(Kind::Custom(INCIDENT_EVENT_KIND), incident_content)
                        .tag(Tag::identifier(d_tag))
                        .tag(Tag::custom(
                            TagKind::Custom("title".into()),
                            [incident.title.as_str()],
                        ))
                        .tag(Tag::custom(
                            TagKind::Custom("level".into()),
                            [incident.level.as_str()],
                        ))
                        .tag(Tag::custom(
                            TagKind::Custom("client".into()),
                            ["sonar-status"],
                        ))
                        .sign_with_keys(&keys)?;
                    client
                        .send_event(&incident_event)
                        .await
                        .map_err(|e| Error::Msg(format!("publish incident {idx}: {e}")))?;
                    println!(
                        "published incident kind={INCIDENT_EVENT_KIND} d={INCIDENT_EVENT_D_PREFIX}{idx} id={}",
                        incident_event.id
                    );
                }
            }

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
    whitenoise_relay_urls: Vec<String>,
    http_urls: &[String],
    previous: Option<&PathBuf>,
    opts: &ProbeOptions,
) -> Result<StatusPayload> {
    // Everything we monitor and display. `relay_urls` is additionally the *write*
    // set for the chat/sticker probes below; the interop relays are never written
    // to, so the two lists stay separate here.
    let mut relay_probes = probe_relays(&relay_urls).await;
    relay_probes.extend(probe_relays(&whitenoise_relay_urls).await);

    let mut http_probes = Vec::new();
    for url in http_urls {
        http_probes.push(probe_http(url).await);
    }

    let chat_report = if opts.chat_probe {
        let secret = load_probe_secret(
            opts.probe_nsec.as_deref(),
            opts.probe_nsec_file.as_ref(),
            "SONAR_STATUS_PROBE_NSEC",
        )
        .map_err(Error::Msg)?;
        Some(probe_marmot_keypackage(&secret, &relay_urls).await)
    } else {
        None
    };

    let sticker_report = if opts.sticker_probe {
        Some(probe_sticker_index(&relay_urls).await)
    } else {
        None
    };

    let media_report = if opts.media_probe {
        let server = opts
            .blossom_server
            .as_deref()
            .unwrap_or(sonar_core::client::DEFAULT_BLOSSOM_SERVER);
        let compare = match opts.blossom_compare.as_deref() {
            Some(raw) if !raw.trim().is_empty() => parse_list(Some(raw), &[]),
            _ => default_blossom_compare(),
        };
        // Prefer the dedicated probe identity for BUD-02 auth. If the operator
        // enabled media without a probe nsec, fall back to HEAD-only.
        let probe_secret = load_probe_secret(
            opts.probe_nsec.as_deref(),
            opts.probe_nsec_file.as_ref(),
            "SONAR_STATUS_PROBE_NSEC",
        )
        .ok();
        Some(probe_blossom_servers(server, &compare, probe_secret.as_deref()).await)
    } else {
        None
    };

    let groups_report = if let Some(path) = &opts.groups_result {
        match load_groups_result(path) {
            Ok(r) => Some(r),
            Err(e) => {
                eprintln!("warning: groups result: {e}");
                None
            }
        }
    } else {
        None
    };

    let payments = if opts.payments_coming_soon {
        Some(payments_coming_soon())
    } else {
        None
    };

    let services = derive_services(
        &relay_probes,
        &http_probes,
        chat_report.as_ref(),
        sticker_report.as_ref(),
        media_report.as_ref(),
        groups_report.as_ref(),
        payments.as_ref(),
    );
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
        "chat": chat_report.as_ref().map(|c| serde_json::to_value(c).unwrap_or_default()),
        "stickers": sticker_report.as_ref().map(|s| serde_json::to_value(s).unwrap_or_default()),
        "media": media_report.as_ref().map(|m| serde_json::to_value(m).unwrap_or_default()),
        "groups": groups_report.as_ref().map(|g| serde_json::to_value(g).unwrap_or_default()),
    });

    Ok(StatusPayload {
        services,
        relays,
        incidents,
        updated_at: Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)),
        probe: Some(probe_meta),
    })
}

async fn probe_relays(urls: &[String]) -> Vec<RelayProbe> {
    let mut probes = Vec::with_capacity(urls.len());
    for url in urls {
        let region = region_for(url);
        let ms = probe_relay_ws(url).await;
        probes.push(RelayProbe {
            url: url.clone(),
            region,
            ms,
        });
    }
    probes
}

fn region_for(url: &str) -> String {
    match url {
        u if u.contains("relay.us.whitenoise.chat") => "US · White Noise".into(),
        u if u.contains("relay.eu.whitenoise.chat") => "EU · White Noise".into(),
        u if u.contains("whitenoise.chat") => "White Noise".into(),
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
            let _ = ws.send(Message::Close(None)).await;
            let _ = ws.close(None).await;
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

fn derive_services(
    relays: &[RelayProbe],
    https: &[HttpProbe],
    chat: Option<&ChatProbeReport>,
    stickers: Option<&StickerProbeReport>,
    media: Option<&MediaProbeReport>,
    groups: Option<&GroupsProbeResult>,
    payments: Option<&StatusService>,
) -> Vec<StatusService> {
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

    // Only services we can actually observe. Application rows appear only when
    // their probe ran — see docs/SONAR-STATUS.md.
    let mut services = vec![StatusService {
        id: "relays".into(),
        name: "Nostr relay network (Sonar + White Noise defaults)".into(),
        desc: format!(
            "{reachable}/{total} relays reachable · median {} ms",
            median.map(|m| m.to_string()).unwrap_or_else(|| "—".into())
        ),
        uptime: (relay_uptime * 100.0).round() / 100.0,
        state: relay_state,
    }];

    if let Some(report) = chat {
        services.push(report.to_service());
    }

    if let Some(report) = stickers {
        services.push(report.to_service());
    }

    if let Some(report) = media {
        services.push(report.to_service());
    }

    if let Some(report) = groups {
        services.push(report.to_service());
    }

    if let Some(svc) = payments {
        services.push(svc.clone());
    }

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
        .max_by_key(|s| s.rank());

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
        let services = derive_services(&relays, &[], None, None, None, None, None);
        let relays_svc = services.iter().find(|s| s.id == "relays").unwrap();
        assert_eq!(relays_svc.state, Some(ServiceState::Down));
        assert!(services.iter().all(|s| s.id == "relays" || s.id.starts_with("http-")));
    }

    /// The monitored set as `build_payload` assembles it: Sonar's own relays
    /// followed by the White Noise interop relays.
    fn monitored_relays(sonar_ms: Option<u64>, whitenoise_ms: Option<u64>) -> Vec<RelayProbe> {
        let mut relays: Vec<RelayProbe> = DEFAULT_RELAYS
            .iter()
            .map(|u| RelayProbe {
                url: (*u).into(),
                region: region_for(u),
                ms: sonar_ms,
            })
            .collect();
        relays.extend(WHITENOISE_RELAYS.iter().map(|u| RelayProbe {
            url: (*u).into(),
            region: region_for(u),
            ms: whitenoise_ms,
        }));
        relays
    }

    #[test]
    fn whitenoise_relays_are_monitored_as_part_of_the_relay_row() {
        let relays = monitored_relays(Some(250), Some(505));
        let services = derive_services(&relays, &[], None, None, None, None, None);

        // One relay row covering both sets — no separate interop row.
        let row = services.iter().find(|s| s.id == "relays").unwrap();
        assert_eq!(services.iter().filter(|s| s.id.starts_with("relays")).count(), 1);
        assert!(row.desc.contains("9/9"));
        assert_eq!(row.state, None);

        // Transatlantic RTT to two of nine relays must not drag the median into
        // a false "degraded" — the whole set is what is being judged.
        assert!(derive_incidents(&services, None).is_empty());
    }

    #[test]
    fn whitenoise_outage_degrades_the_relay_row() {
        // Treated as relays we use: if they go down, our row degrades.
        let relays = monitored_relays(Some(250), None);
        let services = derive_services(&relays, &[], None, None, None, None, None);
        let row = services.iter().find(|s| s.id == "relays").unwrap();
        assert!(row.desc.contains("7/9"));
        assert_eq!(row.state, Some(ServiceState::Degraded));
    }

    #[test]
    fn whitenoise_relays_are_labelled_by_region() {
        assert_eq!(region_for("wss://relay.us.whitenoise.chat"), "US · White Noise");
        assert_eq!(region_for("wss://relay.eu.whitenoise.chat"), "EU · White Noise");
    }

    #[test]
    fn derive_services_includes_chat_when_present() {
        let relays = vec![RelayProbe {
            url: "wss://example".into(),
            region: "x".into(),
            ms: Some(50),
        }];
        let chat = ChatProbeReport {
            ok: true,
            state: ServiceState::Ok,
            publish_ms: Some(10),
            fetch_ms: Some(20),
            total_ms: 30,
            npub: "npub1test".into(),
            pubkey_hex: "aa".into(),
            error: None,
        };
        let services = derive_services(&relays, &[], Some(&chat), None, None, None, None);
        assert!(services.iter().any(|s| s.id == "dm"));
        assert!(services.iter().any(|s| s.id == "relays"));
    }

    #[test]
    fn median_works() {
        assert_eq!(median_u64(&[10, 30, 20]), Some(20));
        assert_eq!(median_u64(&[]), None);
    }
}
