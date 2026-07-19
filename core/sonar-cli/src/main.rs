use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use clap::{Args, Parser, Subcommand, ValueEnum};
use nostr::prelude::*;
use nostr_blossom::prelude::*;
use nostr_sdk::Client as NostrClient;
use serde::{Deserialize, Serialize};
use sonar_core::client::{MediaUpload, SonarClient, DEFAULT_BLOSSOM_SERVER};
use sonar_core::identity::Identity;
use sonar_core::marmot::DeliveryState;
use sonar_core::GroupId;
use sonar_stickers::signal::{
    import_signal_pack_with_options, ImportedSignalPack, ImportedSignalSticker, SignalImportOptions,
};
use sonar_stickers::{
    build_pack_tags, PackAddress, Sticker, StickerError, StickerPack, STICKER_PACK_KIND,
};

const CONFIG_VERSION: u32 = 1;
const CONFIG_FILE: &str = "config.json";
const SEEN_FILE: &str = "seen.json";
const DB_DIR: &str = "marmot";
const DB_FILE: &str = "marmot.sqlite";
const ACK_MESSAGE_WINDOW: usize = 32;
const DEFAULT_STICKERS_SITE_URL: &str = "https://hedwig-corp.github.io/bitchat-to-sonar/stickers";
const DEFAULT_RELAYS: [&str; 3] = [
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.primal.net",
];

#[derive(Debug, thiserror::Error)]
enum CliError {
    #[error("{0}")]
    Message(String),
    #[error("io: {0}")]
    Io(#[from] io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("hex: {0}")]
    Hex(#[from] hex::FromHexError),
    #[error("sonar: {0}")]
    Sonar(#[from] sonar_core::Error),
    #[error("sticker: {0}")]
    Sticker(#[from] StickerError),
    #[error("nostr: {0}")]
    Nostr(#[from] nostr::types::url::Error),
}

type Result<T> = std::result::Result<T, CliError>;

#[derive(Parser, Debug)]
#[command(name = "sonar-cli")]
#[command(about = "Headless Sonar/Marmot messaging for agents")]
struct Cli {
    /// Agent home directory. Defaults to SONAR_CLI_HOME or a platform data dir.
    #[arg(long, global = true)]
    home: Option<PathBuf>,
    /// Override configured relays. Repeat to use more than one.
    #[arg(long = "relay", global = true)]
    relays: Vec<String>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Create a persistent agent identity and encrypted Marmot database key.
    Init(InitArgs),
    /// Print the local agent identity.
    Identity,
    /// Publish this agent's Marmot KeyPackage so peers can start DMs.
    Publish,
    /// Import a Signal sticker pack, upload assets, and publish a Sonar sticker pack.
    Post(PostArgs),
    /// Send an encrypted text or media message (voice/image/video) to a peer.
    Send(SendArgs),
    /// Download and decrypt an inbound media blob to a file or stdout.
    Fetch(FetchArgs),
    /// Poll for inbound encrypted messages and print JSON lines.
    Listen(ListenArgs),
    /// Print known Marmot groups.
    Groups,
    /// Print messages for all groups or one group.
    Messages(MessagesArgs),
}

#[derive(Args, Debug)]
struct InitArgs {
    /// Import an existing nsec1... or 64-char secret key. Prefer --nsec-file.
    #[arg(long, conflicts_with_all = ["nsec_file", "nsec_env"])]
    nsec: Option<String>,
    /// Read an existing nsec1... or 64-char secret key from a local file.
    #[arg(long, conflicts_with_all = ["nsec", "nsec_env"])]
    nsec_file: Option<PathBuf>,
    /// Read an existing nsec1... or 64-char secret key from an environment variable.
    #[arg(long, conflicts_with_all = ["nsec", "nsec_file"])]
    nsec_env: Option<String>,
    /// Replace an existing config.
    #[arg(long)]
    force: bool,
}

#[derive(Args, Debug)]
struct SendArgs {
    /// Recipient npub1... or 64-char hex public key.
    #[arg(long)]
    to: String,
    /// Plaintext message body. Mutually exclusive with --file/--stdin.
    #[arg(long)]
    text: Option<String>,
    /// Path to a media file to send (voice/image/video). Mutually exclusive
    /// with --text/--stdin. Repeat --file to send several photos as ONE album
    /// message (a single event carrying every attachment).
    #[arg(long)]
    file: Vec<PathBuf>,
    /// Read media bytes from stdin (requires --kind and --mime).
    #[arg(long)]
    stdin: bool,
    /// Media kind: voice, audio, image, or video. Required with --file/--stdin.
    #[arg(long, value_enum)]
    kind: Option<MediaKind>,
    /// Optional caption attached to a media send.
    #[arg(long, default_value = "")]
    caption: String,
    /// Override the MIME type. Defaults to the file extension, then the kind.
    /// Required with --stdin (a pipe has no extension to sniff).
    #[arg(long)]
    mime: Option<String>,
    /// Blossom server that hosts the encrypted blob.
    #[arg(long, default_value = DEFAULT_BLOSSOM_SERVER)]
    blossom: String,
    /// Group name if a new 1:1 Marmot group must be created.
    #[arg(long, default_value = "Sonar agent DM")]
    group_name: String,
    /// Keep this CLI process alive until a relay acknowledges the new message
    /// and the MIP-05 push gift-wrap has been published. Default on: process
    /// exit otherwise cancels the background push task before Transponder sees
    /// it (apps stay alive, so they do not need this). Pass --no-wait-for-ack
    /// only for local-echo timing tests.
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    wait_for_ack: bool,
    /// Bound for publish-ack wait. Defaults to 15 seconds.
    #[arg(long)]
    ack_timeout_secs: Option<u64>,
    /// Extra settle time after publish ACK so the MIP-05 push task can finish
    /// publishing kind-446 to the transponder before the process exits.
    #[arg(long, default_value_t = 3)]
    push_settle_secs: u64,
}

/// Media kind drives the default MIME type when none is given explicitly.
#[derive(Clone, Debug, ValueEnum)]
enum MediaKind {
    /// Voice note (defaults to audio/mp4 / AAC — playable by iOS AVAudioPlayer).
    Voice,
    /// Generic audio clip (defaults to audio/mpeg).
    Audio,
    /// Still image (defaults to image/png).
    Image,
    /// Video clip (defaults to video/mp4).
    Video,
}

#[derive(Args, Debug)]
struct FetchArgs {
    /// Group id hex whose media key decrypts the blob.
    #[arg(long)]
    group: String,
    /// Encrypted blob URL (a message's media[].url).
    #[arg(long)]
    url: String,
    /// Write decrypted bytes to this path. If omitted (and not --stdout), a name
    /// is derived from the URL in the current directory (often extension-less;
    /// prefer `--out` for a usable file type).
    #[arg(long)]
    out: Option<PathBuf>,
    /// Write decrypted bytes to stdout (binary). The JSON summary goes to stderr.
    #[arg(long)]
    stdout: bool,
}

#[derive(Args, Debug)]
struct PostArgs {
    /// Signal sticker link from signal.art/addstickers.
    signal_link: String,
    /// Blossom server that will host the sticker images.
    #[arg(long, default_value = DEFAULT_BLOSSOM_SERVER)]
    blossom: String,
    /// Public stickers page URL. Defaults to SONAR_STICKERS_SITE_URL or the bundled web route.
    #[arg(long)]
    site_url: Option<String>,
    /// Accept invalid TLS certificates when fetching encrypted Signal CDN blobs.
    #[arg(long)]
    accept_invalid_signal_certs: bool,
    /// Continue when a Signal pack references an unavailable sticker asset.
    #[arg(long)]
    skip_missing_signal_stickers: bool,
}

#[derive(Args, Debug)]
struct ListenArgs {
    /// Run one sync/drain cycle and exit.
    #[arg(long)]
    once: bool,
    /// Maximum runtime in seconds. Omit for an unbounded listener.
    #[arg(long)]
    timeout_secs: Option<u64>,
    /// Periodic sync interval for relay catch-up.
    #[arg(long, default_value_t = 30)]
    poll_secs: u64,
    /// Do not publish this agent's KeyPackage at startup.
    #[arg(long)]
    no_publish: bool,
}

#[derive(Args, Debug)]
struct MessagesArgs {
    /// Optional group id hex. Omit to print messages from every known group.
    #[arg(long)]
    group: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
struct AgentConfig {
    version: u32,
    nsec: String,
    db_key_hex: String,
    relays: Vec<String>,
}

#[derive(Debug, Default, Deserialize, Serialize)]
struct SeenState {
    message_ids: BTreeSet<String>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Output {
    Identity {
        npub: String,
        pubkey_hex: String,
        home: String,
        config_path: String,
    },
    Published {
        npub: String,
        relays: Vec<String>,
    },
    Sent {
        to: String,
        group_id: String,
    },
    SentMedia {
        to: String,
        group_id: String,
        kind: String,
        mime: String,
        filename: String,
        size_bytes: usize,
        blossom_server: String,
    },
    SentAlbum {
        to: String,
        group_id: String,
        /// Number of attachments packed into the single album message.
        count: usize,
        filenames: Vec<String>,
        total_bytes: usize,
        blossom_server: String,
    },
    Fetched {
        group_id: String,
        url: String,
        bytes: usize,
        out: String,
    },
    PostedStickerPack {
        title: String,
        address: String,
        event_id: String,
        author_npub: String,
        sticker_count: usize,
        relays: Vec<String>,
        blossom_server: String,
        website_url: String,
        skipped_signal_sticker_ids: Vec<u32>,
    },
    Group {
        id: String,
        name: String,
        members: Vec<String>,
    },
    Message {
        group_id: String,
        id: String,
        sender: String,
        /// Caption or text body (may be empty for a pure media message).
        content: String,
        created_at_secs: u64,
        mine: bool,
        /// Decrypted media references (MIP-04 imeta). Omitted when empty so
        /// plain-text messages keep their pre-existing JSON shape.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        media: Vec<MediaRefOut>,
    },
}

/// A decrypted media attachment rendered in `listen`/`messages` JSON output.
#[derive(Debug, Serialize)]
struct MediaRefOut {
    /// Encrypted blob URL (pass it to `fetch --url`).
    url: String,
    mime: String,
    /// image | voice | audio | video | file (derived from the MIME type).
    kind: String,
    filename: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    height: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    duration_ms: Option<u64>,
}

#[tokio::main]
async fn main() {
    // Surface relay subscription rejections and transport warnings to callers.
    // stdout remains newline-delimited JSON; diagnostics stay on stderr.
    // Default WARN keeps stdout JSON clean; set RUST_LOG=info (or
    // sonar_core=info) when diagnosing push-token / relay publish paths.
    let filter = std::env::var("RUST_LOG").unwrap_or_else(|_| "warn".to_owned());
    let _ = tracing_subscriber::fmt()
        .with_max_level(match filter.as_str() {
            "trace" => tracing::Level::TRACE,
            "debug" => tracing::Level::DEBUG,
            "info" => tracing::Level::INFO,
            "error" => tracing::Level::ERROR,
            _ if filter.contains("info") || filter.contains("debug") || filter.contains("trace") => {
                if filter.contains("trace") {
                    tracing::Level::TRACE
                } else if filter.contains("debug") {
                    tracing::Level::DEBUG
                } else {
                    tracing::Level::INFO
                }
            }
            _ => tracing::Level::WARN,
        })
        .with_target(false)
        .with_ansi(false)
        .without_time()
        .with_writer(io::stderr)
        .try_init();
    if let Err(err) = run(Cli::parse()).await {
        eprintln!("sonar-cli: {err}");
        std::process::exit(1);
    }
}

async fn run(cli: Cli) -> Result<()> {
    let home = resolve_home(cli.home)?;
    match cli.command {
        Command::Init(args) => {
            let output = init(home, cli.relays, args)?;
            print_json(&output)?;
            Ok(())
        }
        Command::Identity => {
            let loaded = LoadedConfig::load(home, cli.relays)?;
            print_json(&identity_output(&loaded)?)?;
            Ok(())
        }
        Command::Publish => {
            let loaded = LoadedConfig::load(home, cli.relays)?;
            let client = loaded.connect().await?;
            client.publish_key_package().await?;
            let relays = loaded.relay_strings();
            print_json(&Output::Published {
                npub: client.identity().npub(),
                relays,
            })?;
            Ok(())
        }
        Command::Post(args) => {
            let loaded = LoadedConfig::load(home, cli.relays)?;
            let output = post_sticker_pack(&loaded, args).await?;
            print_json(&output)?;
            Ok(())
        }
        Command::Send(args) => {
            // Validate all arguments before any network side effect: a usage
            // mistake must not trigger relay connect, sync, or group creation.
            let payload_sources = [args.text.is_some(), !args.file.is_empty(), args.stdin]
                .iter()
                .filter(|b| **b)
                .count();
            if payload_sources != 1 {
                return Err(CliError::Message(
                    "provide exactly one of --text, --file, or --stdin".to_owned(),
                ));
            }
            if args.text.is_none() && args.kind.is_none() {
                return Err(CliError::Message(
                    "--kind is required for media sends".to_owned(),
                ));
            }
            if args.stdin && args.mime.is_none() {
                return Err(CliError::Message(
                    "--stdin requires --mime (a pipe has no extension to sniff)".to_owned(),
                ));
            }
            if args.wait_for_ack && args.ack_timeout_secs == Some(0) {
                return Err(CliError::Message(
                    "--ack-timeout-secs must be greater than zero".to_owned(),
                ));
            }

            let loaded = LoadedConfig::load(home, cli.relays)?;
            let client = loaded.connect().await?;
            client.sync().await?;
            let peer = PublicKey::parse(&args.to)
                .map_err(|e| CliError::Message(format!("recipient pubkey: {e}")))?;
            let group_id = match find_dm_group(&client, peer)? {
                Some(group_id) => group_id,
                None => client.start_dm(peer, &args.group_name).await?,
            };
            let message_ids_before = args
                .wait_for_ack
                .then(|| outbound_message_ids(&client, &group_id))
                .transpose()?;
            let to_npub = peer.to_bech32().expect("valid public key encodes as npub");
            let output = if let Some(text) = args.text.as_deref() {
                client.send_text(&group_id, text).await?;
                Output::Sent {
                    to: to_npub,
                    group_id: hex::encode(group_id.as_slice()),
                }
            } else {
                let mut payloads = resolve_media_payloads(&args)?;
                let group_id_hex = hex::encode(group_id.as_slice());
                if payloads.len() == 1 {
                    let (data, filename, mime, kind) = payloads.remove(0);
                    let size = data.len();
                    client
                        .send_media(
                            &group_id,
                            data,
                            &filename,
                            &mime,
                            &args.caption,
                            &args.blossom,
                        )
                        .await?;
                    Output::SentMedia {
                        to: to_npub,
                        group_id: group_id_hex,
                        kind: media_kind_label(&kind).to_owned(),
                        mime,
                        filename,
                        size_bytes: size,
                        blossom_server: args.blossom.clone(),
                    }
                } else {
                    // Multiple --file paths → one album message (N imeta tags on
                    // a single event). Albums are photos-only: the iOS/Compose
                    // renderers show every attachment for all-image albums but
                    // fall back to the first item otherwise, so a non-image album
                    // would hide attachments 2..N on receipt. Reject those here;
                    // send non-image media one file per message instead.
                    if let Some(bad) = payloads.iter().find(|p| !p.2.starts_with("image/")) {
                        return Err(CliError::Message(format!(
                            "album sends (multiple --file) are images only; \"{}\" is {}. \
                             Send non-image media one file per message.",
                            bad.1, bad.2
                        )));
                    }
                    let count = payloads.len();
                    let total_bytes: usize = payloads.iter().map(|p| p.0.len()).sum();
                    let filenames: Vec<String> = payloads.iter().map(|p| p.1.clone()).collect();
                    let items: Vec<MediaUpload> = payloads
                        .into_iter()
                        .map(|(data, filename, mime, _)| MediaUpload {
                            data,
                            filename,
                            mime,
                        })
                        .collect();
                    client
                        .send_media_multi(&group_id, items, &args.caption, &args.blossom)
                        .await?;
                    Output::SentAlbum {
                        to: to_npub,
                        group_id: group_id_hex,
                        count,
                        filenames,
                        total_bytes,
                        blossom_server: args.blossom.clone(),
                    }
                }
            };
            if let Some(message_ids_before) = message_ids_before {
                wait_for_new_outbound_ack(
                    &client,
                    &group_id,
                    &message_ids_before,
                    Duration::from_secs(args.ack_timeout_secs.unwrap_or(15)),
                )
                .await?;
                // MIP-05 push is spawned after publish ACK. Keep the Tokio
                // runtime + relay pool alive long enough for the gift-wrap
                // publish; exiting immediately cancels that task and the
                // phone never receives a Transponder wake.
                if args.push_settle_secs > 0 {
                    tokio::time::sleep(Duration::from_secs(args.push_settle_secs)).await;
                }
            }
            print_json(&output)?;
            Ok(())
        }
        Command::Fetch(args) => {
            let loaded = LoadedConfig::load(home, cli.relays)?;
            let client = loaded.connect().await?;
            let group_id = parse_group_id_hex(&args.group)?;
            let plaintext = client.fetch_media(&group_id, &args.url).await?;
            if args.stdout {
                io::stdout()
                    .lock()
                    .write_all(&plaintext)
                    .map_err(CliError::Io)?;
                let summary = Output::Fetched {
                    group_id: args.group.clone(),
                    url: args.url.clone(),
                    bytes: plaintext.len(),
                    out: "<stdout>".to_owned(),
                };
                serde_json::to_writer(io::stderr().lock(), &summary).map_err(CliError::Json)?;
                writeln!(io::stderr().lock()).map_err(CliError::Io)?;
            } else {
                let out = args
                    .out
                    .clone()
                    .unwrap_or_else(|| PathBuf::from(default_media_filename(&args.url)));
                if let Some(parent) = out.parent().filter(|p| !p.as_os_str().is_empty()) {
                    if !parent.exists() {
                        fs::create_dir_all(parent).map_err(|e| {
                            CliError::Message(format!("create {}: {e}", parent.display()))
                        })?;
                    }
                }
                fs::write(&out, &plaintext)
                    .map_err(|e| CliError::Message(format!("write {}: {e}", out.display())))?;
                print_json(&Output::Fetched {
                    group_id: args.group.clone(),
                    url: args.url.clone(),
                    bytes: plaintext.len(),
                    out: out.display().to_string(),
                })?;
            }
            Ok(())
        }
        Command::Listen(args) => {
            let loaded = LoadedConfig::load(home, cli.relays)?;
            listen(loaded, args).await
        }
        Command::Groups => {
            let loaded = LoadedConfig::load(home, cli.relays)?;
            let client = loaded.connect().await?;
            client.sync().await?;
            print_groups(&client)?;
            Ok(())
        }
        Command::Messages(args) => {
            let loaded = LoadedConfig::load(home, cli.relays)?;
            let client = loaded.connect().await?;
            client.sync().await?;
            print_messages(&client, args.group.as_deref())?;
            Ok(())
        }
    }
}

async fn post_sticker_pack(loaded: &LoadedConfig, args: PostArgs) -> Result<Output> {
    let identity = loaded.identity()?;
    let imported = import_signal_pack_with_options(
        &args.signal_link,
        SignalImportOptions {
            accept_invalid_certs: args.accept_invalid_signal_certs,
            skip_failed_stickers: args.skip_missing_signal_stickers,
        },
    )
    .await?;
    let skipped_signal_sticker_ids = imported.skipped_sticker_ids.clone();
    let pack = upload_imported_signal_pack(&identity, &args.blossom, imported).await?;
    let event = EventBuilder::new(Kind::Custom(STICKER_PACK_KIND), "")
        .tags(build_pack_tags(&pack))
        .sign_with_keys(identity.keys())
        .map_err(|e| CliError::Message(format!("sign sticker pack event: {e}")))?;
    let nostr = NostrClient::new(identity.keys().clone());
    for relay in &loaded.relays {
        nostr
            .add_relay(relay.clone())
            .await
            .map_err(|e| CliError::Message(format!("add relay {relay}: {e}")))?;
    }
    nostr.connect().await;
    nostr
        .send_event(&event)
        .await
        .map_err(|e| CliError::Message(format!("publish sticker pack: {e}")))?;

    let relays = loaded.relay_strings();
    let site_url = args
        .site_url
        .or_else(|| env::var("SONAR_STICKERS_SITE_URL").ok())
        .unwrap_or_else(|| DEFAULT_STICKERS_SITE_URL.to_owned());
    let website_url = sticker_pack_website_url(&site_url, &pack.address.coordinate(), &relays);

    Ok(Output::PostedStickerPack {
        title: pack.title,
        address: pack.address.coordinate(),
        event_id: event.id.to_hex(),
        author_npub: identity.npub(),
        sticker_count: pack.stickers.len(),
        relays,
        blossom_server: args.blossom,
        website_url,
        skipped_signal_sticker_ids,
    })
}

async fn upload_imported_signal_pack(
    identity: &Identity,
    blossom_server: &str,
    imported: ImportedSignalPack,
) -> Result<StickerPack> {
    let mut uploaded = Vec::with_capacity(imported.stickers.len());
    for sticker in &imported.stickers {
        let url = upload_sticker_blob(identity, blossom_server, sticker).await?;
        uploaded.push(sticker_from_import(sticker, url)?);
    }

    let cover = match &imported.cover {
        Some(cover) => {
            let url = upload_sticker_blob(identity, blossom_server, cover).await?;
            Some(Sticker::new(
                "cover",
                url,
                cover.sha256.clone(),
                cover.mime.clone(),
                None,
                None,
                Some("Sticker pack cover".to_owned()),
                short_emoji(cover.emoji.as_deref()),
            )?)
        }
        None => uploaded.first().cloned(),
    };
    let address = PackAddress::new(
        identity.public_key().to_hex(),
        format!("signal-{}", imported.pack_id),
    )?;
    StickerPack::new(
        address,
        truncate_chars(&imported.title, 80),
        signal_description(imported.author.as_deref()),
        cover,
        uploaded,
        None,
    )
    .map_err(CliError::Sticker)
}

async fn upload_sticker_blob(
    identity: &Identity,
    blossom_server: &str,
    sticker: &ImportedSignalSticker,
) -> Result<String> {
    let base = Url::parse(blossom_server)
        .map_err(|e| CliError::Message(format!("bad Blossom server URL {blossom_server}: {e}")))?;
    let descriptor = BlossomClient::new(base)
        .upload_blob(
            sticker.bytes.clone(),
            Some(sticker.mime.clone()),
            None,
            Some(identity.keys()),
        )
        .await
        .map_err(|e| CliError::Message(format!("upload sticker {}: {e}", sticker.id)))?;
    Ok(descriptor.url.to_string())
}

fn sticker_from_import(sticker: &ImportedSignalSticker, url: String) -> Result<Sticker> {
    Sticker::new(
        sticker.shortcode.clone(),
        url,
        sticker.sha256.clone(),
        sticker.mime.clone(),
        None,
        None,
        Some(sticker_alt(sticker)),
        short_emoji(sticker.emoji.as_deref()),
    )
    .map_err(CliError::Sticker)
}

fn sticker_alt(sticker: &ImportedSignalSticker) -> String {
    match sticker.emoji.as_deref() {
        Some(emoji) if !emoji.is_empty() => format!("Signal sticker {} {emoji}", sticker.id),
        _ => format!("Signal sticker {}", sticker.id),
    }
}

fn signal_description(author: Option<&str>) -> Option<String> {
    match author.map(str::trim).filter(|s| !s.is_empty()) {
        Some(author) => Some(truncate_chars(
            &format!("Imported from a Signal sticker pack by {author}."),
            500,
        )),
        None => Some("Imported from a Signal sticker pack.".to_owned()),
    }
}

fn short_emoji(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| truncate_chars(s, 8))
}

fn truncate_chars(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect::<String>()
}

fn sticker_pack_website_url(site_url: &str, address: &str, relays: &[String]) -> String {
    let mut url = site_url.trim().trim_end_matches('/').to_owned();
    let separator = if url.contains('?') { '&' } else { '?' };
    url.push(separator);
    url.push_str("a=");
    url.push_str(&encode_query_component(address));
    for relay in relays {
        url.push_str("&relay=");
        url.push_str(&encode_query_component(relay));
    }
    url
}

fn encode_query_component(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(byte as char);
        } else {
            out.push('%');
            out.push(hex_digit(byte >> 4));
            out.push(hex_digit(byte & 0x0f));
        }
    }
    out
}

fn hex_digit(nibble: u8) -> char {
    match nibble {
        0..=9 => (b'0' + nibble) as char,
        10..=15 => (b'A' + (nibble - 10)) as char,
        _ => unreachable!("nibble masked to four bits"),
    }
}

fn init(home: PathBuf, relay_overrides: Vec<String>, args: InitArgs) -> Result<Output> {
    ensure_private_dir(&home)?;
    let config_path = home.join(CONFIG_FILE);
    if config_path.exists() && !args.force {
        return Err(CliError::Message(format!(
            "{} already exists; pass --force to replace it",
            config_path.display()
        )));
    }
    let identity = match init_secret(&args)? {
        Some(secret) => Identity::import(&secret)?,
        None => Identity::generate(),
    };
    let relays = if relay_overrides.is_empty() {
        DEFAULT_RELAYS.iter().map(|r| (*r).to_owned()).collect()
    } else {
        validate_relay_strings(relay_overrides)?
    };
    let config = AgentConfig {
        version: CONFIG_VERSION,
        nsec: identity.export_nsec(),
        db_key_hex: random_hex_32()?,
        relays,
    };
    write_private_json(&config_path, &config)?;
    Ok(Output::Identity {
        npub: identity.npub(),
        pubkey_hex: identity.public_key().to_hex(),
        home: home.display().to_string(),
        config_path: config_path.display().to_string(),
    })
}

async fn listen(loaded: LoadedConfig, args: ListenArgs) -> Result<()> {
    let client = loaded.connect().await?;
    if !args.no_publish {
        client.publish_key_package().await?;
    }
    let seen_path = loaded.home.join(SEEN_FILE);
    let mut seen = load_seen(&seen_path)?;
    let start = Instant::now();
    loop {
        client.sync().await?;
        emit_unseen_messages(&client, &seen_path, &mut seen)?;
        if args.once {
            return Ok(());
        }
        if let Some(timeout_secs) = args.timeout_secs {
            if start.elapsed() >= Duration::from_secs(timeout_secs) {
                return Ok(());
            }
        }
        let wait_secs = next_wait_secs(start, args.timeout_secs, args.poll_secs);
        if client.wait_for_marmot_event(wait_secs).await {
            client.drain_pending_marmot().await?;
            emit_unseen_messages(&client, &seen_path, &mut seen)?;
        }
    }
}

fn print_groups(client: &SonarClient) -> Result<()> {
    for group in client.groups()? {
        let members = client
            .members(&group.mls_group_id)?
            .into_iter()
            .map(|pk| pk.to_bech32().expect("valid public key encodes as npub"))
            .collect();
        print_json(&Output::Group {
            id: hex::encode(group.mls_group_id.as_slice()),
            name: group.name,
            members,
        })?;
    }
    Ok(())
}

fn print_messages(client: &SonarClient, group_filter: Option<&str>) -> Result<()> {
    let wanted = group_filter.map(parse_group_id_hex).transpose()?;
    let mut matched = false;
    let groups = client.groups()?;
    for group in groups {
        if wanted
            .as_ref()
            .is_some_and(|want| want != &group.mls_group_id)
        {
            continue;
        }
        matched = true;
        for msg in client.messages(&group.mls_group_id)? {
            print_json(&message_output(&msg))?;
        }
    }
    if group_filter.is_some() && !matched {
        return Err(CliError::Message("group not found".to_owned()));
    }
    Ok(())
}

fn emit_unseen_messages(
    client: &SonarClient,
    seen_path: &Path,
    seen: &mut SeenState,
) -> Result<()> {
    let mut changed = false;
    for group in client.groups()? {
        let mut messages = client.messages(&group.mls_group_id)?;
        messages.sort_by_key(|m| m.created_at);
        for msg in messages {
            let id = msg.id.to_hex();
            if !seen.message_ids.insert(id) {
                continue;
            }
            changed = true;
            if !msg.mine {
                print_json(&message_output(&msg))?;
            }
        }
    }
    if changed {
        write_private_json(seen_path, seen)?;
    }
    Ok(())
}

fn message_output(msg: &sonar_core::marmot::ChatMessage) -> Output {
    let media = msg
        .media
        .iter()
        .map(|m| MediaRefOut {
            url: m.url.clone(),
            mime: m.mime_type.clone(),
            kind: media_kind_from_mime(&m.mime_type).to_owned(),
            filename: m.filename.clone(),
            width: m.width,
            height: m.height,
            duration_ms: m.duration_ms,
        })
        .collect();
    Output::Message {
        group_id: hex::encode(msg.group_id.as_slice()),
        id: msg.id.to_hex(),
        sender: msg
            .sender
            .to_bech32()
            .expect("valid public key encodes as npub"),
        content: msg.content.clone(),
        created_at_secs: msg.created_at.as_secs(),
        mine: msg.mine,
        media,
    }
}

fn find_dm_group(client: &SonarClient, peer: PublicKey) -> Result<Option<GroupId>> {
    let me = client.identity().public_key();
    for group in client.groups()? {
        let members: BTreeSet<PublicKey> =
            client.members(&group.mls_group_id)?.into_iter().collect();
        if members.len() == 2 && members.contains(&me) && members.contains(&peer) {
            return Ok(Some(group.mls_group_id));
        }
    }
    Ok(None)
}

fn outbound_message_ids(client: &SonarClient, group_id: &GroupId) -> Result<BTreeSet<String>> {
    Ok(client
        .messages_page(group_id, ACK_MESSAGE_WINDOW, 0)?
        .into_iter()
        .filter(|message| message.mine)
        .map(|message| message.id.to_hex())
        .collect())
}

/// Wait for the exact local row created by this `send` invocation to reach a
/// terminal outbox state. This keeps the short-lived CLI runtime alive long
/// enough for its background publisher, without changing app send semantics.
async fn wait_for_new_outbound_ack(
    client: &SonarClient,
    group_id: &GroupId,
    message_ids_before: &BTreeSet<String>,
    timeout: Duration,
) -> Result<String> {
    let started = Instant::now();
    let mut message_id: Option<String> = None;
    loop {
        let messages = client.messages_page(group_id, ACK_MESSAGE_WINDOW, 0)?;
        if message_id.is_none() {
            let new_ids: Vec<String> = messages
                .iter()
                .filter(|message| message.mine)
                .map(|message| message.id.to_hex())
                .filter(|id| !message_ids_before.contains(id))
                .collect();
            match new_ids.as_slice() {
                [id] => message_id = Some(id.clone()),
                [] => {}
                _ => {
                    return Err(CliError::Message(
                        "multiple outbound messages appeared while waiting for relay acknowledgement"
                            .to_owned(),
                    ));
                }
            }
        }

        if let Some(id) = message_id.as_deref() {
            if let Some(message) = messages.iter().find(|message| message.id.to_hex() == id) {
                match message.delivery_state {
                    DeliveryState::Sent => return Ok(id.to_owned()),
                    DeliveryState::Failed => {
                        return Err(CliError::Message(format!(
                            "all relays failed to accept message {id}; it remains in the local outbox for retry"
                        )));
                    }
                    DeliveryState::Pending | DeliveryState::Received => {}
                }
            }
        }

        if started.elapsed() >= timeout {
            let detail = message_id
                .as_deref()
                .map(|id| format!("message {id}"))
                .unwrap_or_else(|| "the new outbound message".to_owned());
            return Err(CliError::Message(format!(
                "timed out after {}s waiting for a relay acknowledgement for {detail}; it remains in the local outbox for retry",
                timeout.as_secs()
            )));
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

/// A resolved media attachment ready to send: (plaintext bytes, filename, MIME, kind).
type MediaPayload = (Vec<u8>, String, String, MediaKind);

/// Read + classify the media payload(s) for a send from `--file` or `--stdin`.
///
/// `--stdin` yields exactly one payload; one or more `--file` paths each yield a
/// payload (an album send when >1). MIME resolution order per file: explicit
/// `--mime` > file extension sniff > the kind default. `--stdin` has no extension
/// to sniff, so `--mime` is required there. All arguments are validated with no
/// I/O side effects beyond reading the named files / stdin.
fn resolve_media_payloads(args: &SendArgs) -> Result<Vec<MediaPayload>> {
    let kind = args
        .kind
        .as_ref()
        .ok_or_else(|| CliError::Message("--kind is required for media sends".to_owned()))?
        .clone();

    if args.stdin {
        let mime = args.mime.as_deref().ok_or_else(|| {
            CliError::Message(
                "--stdin requires --mime (a pipe has no extension to sniff)".to_owned(),
            )
        })?;
        let mut data = Vec::new();
        io::stdin()
            .read_to_end(&mut data)
            .map_err(|e| CliError::Message(format!("read stdin: {e}")))?;
        if data.is_empty() {
            return Err(CliError::Message("stdin was empty".to_owned()));
        }
        let filename = format!("stdin-media.{}", mime_extension(mime).unwrap_or("bin"));
        return Ok(vec![(data, filename, mime.to_owned(), kind)]);
    }

    if args.file.is_empty() {
        return Err(CliError::Message(
            "internal: media send without --file/--stdin".to_owned(),
        ));
    }
    let mut payloads = Vec::with_capacity(args.file.len());
    for path in &args.file {
        let data = fs::read(path)
            .map_err(|e| CliError::Message(format!("read {}: {e}", path.display())))?;
        if data.is_empty() {
            return Err(CliError::Message(format!(
                "file is empty: {}",
                path.display()
            )));
        }
        let filename = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("media")
            .to_owned();
        let mime = args
            .mime
            .clone()
            .or_else(|| sniff_mime(path).map(str::to_owned))
            .unwrap_or_else(|| default_mime_for_kind(&kind).to_owned());
        payloads.push((data, filename, mime, kind.clone()));
    }
    Ok(payloads)
}

/// Default MIME for a media kind, used when neither `--mime` nor a known
/// extension is supplied.
fn default_mime_for_kind(kind: &MediaKind) -> &'static str {
    match kind {
        MediaKind::Voice => "audio/mp4",
        MediaKind::Audio => "audio/mpeg",
        MediaKind::Image => "image/png",
        MediaKind::Video => "video/mp4",
    }
}

/// Lowercased label for a kind, used in send JSON output.
fn media_kind_label(kind: &MediaKind) -> &'static str {
    match kind {
        MediaKind::Voice => "voice",
        MediaKind::Audio => "audio",
        MediaKind::Image => "image",
        MediaKind::Video => "video",
    }
}

/// Best-effort kind for an inbound MIME type. Audio/ogg & Opus are treated as
/// voice notes (the canonical agent voice format); other audio is "audio".
fn media_kind_from_mime(mime: &str) -> &'static str {
    let lower = mime.to_ascii_lowercase();
    if lower.starts_with("image/") {
        "image"
    } else if lower.starts_with("video/") {
        "video"
    } else if lower == "audio/ogg" || lower == "audio/opus" || lower.contains("opus") {
        "voice"
    } else if lower.starts_with("audio/") {
        "audio"
    } else {
        "file"
    }
}

/// Sniff a MIME type from a path extension. Returns `None` for unknown/absent.
fn sniff_mime(path: &Path) -> Option<&'static str> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    Some(match ext.as_str() {
        "ogg" | "opus" => "audio/ogg",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "aac" => "audio/aac",
        "wav" => "audio/wav",
        "flac" => "audio/flac",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "gif" => "image/gif",
        "mp4" | "m4v" => "video/mp4",
        "webm" => "video/webm",
        "mov" => "video/quicktime",
        _ => return None,
    })
}

/// Inverse of [`sniff_mime`] for a couple of common types, used to name the
/// `--stdin` output filename.
fn mime_extension(mime: &str) -> Option<&'static str> {
    Some(match mime.to_ascii_lowercase().as_str() {
        "audio/ogg" | "audio/opus" => "ogg",
        "audio/mpeg" => "mp3",
        "audio/aac" | "audio/mp4" => "m4a",
        "audio/wav" => "wav",
        "audio/flac" => "flac",
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "video/mp4" => "mp4",
        "video/webm" => "webm",
        "video/quicktime" => "mov",
        _ => return None,
    })
}

/// Derive a default output filename from a blob URL's last path segment.
fn default_media_filename(url: &str) -> String {
    let last = url.rsplit('/').next().unwrap_or("media");
    let name = last
        .split('?')
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or("media");
    name.to_owned()
}

struct LoadedConfig {
    home: PathBuf,
    config_path: PathBuf,
    config: AgentConfig,
    relays: Vec<RelayUrl>,
}

impl LoadedConfig {
    fn load(home: PathBuf, relay_overrides: Vec<String>) -> Result<Self> {
        let config_path = home.join(CONFIG_FILE);
        let bytes = fs::read(&config_path)
            .map_err(|e| CliError::Message(format!("read {}: {e}", config_path.display())))?;
        let mut config: AgentConfig = serde_json::from_slice(&bytes)?;
        if config.version != CONFIG_VERSION {
            return Err(CliError::Message(format!(
                "unsupported config version {}",
                config.version
            )));
        }
        if !relay_overrides.is_empty() {
            config.relays = validate_relay_strings(relay_overrides)?;
        } else {
            config.relays = validate_relay_strings(config.relays)?;
        }
        let relays = config
            .relays
            .iter()
            .map(|r| RelayUrl::parse(r).map_err(CliError::Nostr))
            .collect::<Result<Vec<_>>>()?;
        Ok(Self {
            home,
            config_path,
            config,
            relays,
        })
    }

    async fn connect(&self) -> Result<SonarClient> {
        ensure_private_dir(&self.home)?;
        let db_dir = self.home.join(DB_DIR);
        ensure_private_dir(&db_dir)?;
        let identity = self.identity()?;
        let db_key = parse_db_key(&self.config.db_key_hex)?;
        SonarClient::connect(identity, self.relays.clone(), db_dir.join(DB_FILE), db_key)
            .await
            .map_err(CliError::Sonar)
    }

    fn identity(&self) -> Result<Identity> {
        Identity::import(&self.config.nsec).map_err(CliError::Sonar)
    }

    fn relay_strings(&self) -> Vec<String> {
        self.relays.iter().map(|r| r.to_string()).collect()
    }
}

fn identity_output(loaded: &LoadedConfig) -> Result<Output> {
    let identity = Identity::import(&loaded.config.nsec)?;
    Ok(Output::Identity {
        npub: identity.npub(),
        pubkey_hex: identity.public_key().to_hex(),
        home: loaded.home.display().to_string(),
        config_path: loaded.config_path.display().to_string(),
    })
}

fn parse_db_key(hex_key: &str) -> Result<[u8; 32]> {
    let bytes = hex::decode(hex_key)?;
    bytes.try_into().map_err(|_| {
        CliError::Message("config db_key_hex must decode to exactly 32 bytes".to_owned())
    })
}

fn parse_group_id_hex(hex_id: &str) -> Result<GroupId> {
    let bytes = hex::decode(hex_id)?;
    if bytes.is_empty() {
        return Err(CliError::Message("group id cannot be empty".to_owned()));
    }
    Ok(GroupId::from_slice(&bytes))
}

fn init_secret(args: &InitArgs) -> Result<Option<String>> {
    if let Some(secret) = &args.nsec {
        return Ok(Some(secret.trim().to_owned()));
    }
    if let Some(path) = &args.nsec_file {
        let secret = fs::read_to_string(path)
            .map_err(|e| CliError::Message(format!("read {}: {e}", path.display())))?;
        return Ok(Some(secret.trim().to_owned()));
    }
    if let Some(var) = &args.nsec_env {
        let secret = env::var(var)
            .map_err(|e| CliError::Message(format!("read environment variable {var}: {e}")))?;
        return Ok(Some(secret.trim().to_owned()));
    }
    Ok(None)
}

fn next_wait_secs(start: Instant, timeout_secs: Option<u64>, poll_secs: u64) -> u64 {
    let poll_secs = poll_secs.max(1);
    let Some(timeout_secs) = timeout_secs else {
        return poll_secs;
    };
    let total = Duration::from_secs(timeout_secs);
    let Some(remaining) = total.checked_sub(start.elapsed()) else {
        return 1;
    };
    poll_secs.min(remaining.as_secs().max(1))
}

fn random_hex_32() -> Result<String> {
    let mut bytes = [0u8; 32];
    getrandom::getrandom(&mut bytes)
        .map_err(|e| CliError::Message(format!("secure random failed: {e}")))?;
    Ok(hex::encode(bytes))
}

fn validate_relay_strings(relays: Vec<String>) -> Result<Vec<String>> {
    if relays.is_empty() {
        return Err(CliError::Message(
            "at least one relay is required".to_owned(),
        ));
    }
    for relay in &relays {
        RelayUrl::parse(relay).map_err(CliError::Nostr)?;
    }
    Ok(relays)
}

fn resolve_home(home: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(home) = home {
        return Ok(home);
    }
    if let Ok(home) = env::var("SONAR_CLI_HOME") {
        return Ok(PathBuf::from(home));
    }
    if let Ok(data_home) = env::var("XDG_DATA_HOME") {
        return Ok(PathBuf::from(data_home).join("sonar-cli"));
    }
    let home = env::var("HOME")
        .map(PathBuf::from)
        .map_err(|_| CliError::Message("pass --home or set SONAR_CLI_HOME".to_owned()))?;
    #[cfg(target_os = "macos")]
    {
        Ok(home.join("Library/Application Support/Sonar CLI"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(home.join(".local/share/sonar-cli"))
    }
}

fn load_seen(path: &Path) -> Result<SeenState> {
    match fs::read(path) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes)?),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(SeenState::default()),
        Err(e) => Err(e.into()),
    }
}

fn print_json<T: Serialize>(value: &T) -> Result<()> {
    let stdout = io::stdout();
    let mut lock = stdout.lock();
    serde_json::to_writer(&mut lock, value)?;
    lock.write_all(b"\n")?;
    lock.flush()?;
    Ok(())
}

fn ensure_private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn write_private_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    if let Some(parent) = path.parent() {
        ensure_private_dir(parent)?;
    }
    let tmp = path.with_extension(format!("json.tmp.{}", std::process::id()));
    let bytes = serde_json::to_vec_pretty(value)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
    }
    #[cfg(not(unix))]
    {
        let mut file = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&tmp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
    }
    fs::rename(tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn init_creates_loadable_private_config() {
        let temp = tempfile::tempdir().expect("tempdir");
        let home = temp.path().join("agent");
        init(
            home.clone(),
            vec!["wss://relay.example.com".to_owned()],
            InitArgs {
                nsec: None,
                nsec_file: None,
                nsec_env: None,
                force: false,
            },
        )
        .expect("init succeeds");

        let loaded = LoadedConfig::load(home.clone(), Vec::new()).expect("config loads");
        assert_eq!(loaded.config.version, CONFIG_VERSION);
        assert_eq!(loaded.config.relays, ["wss://relay.example.com"]);
        assert_eq!(hex::decode(&loaded.config.db_key_hex).unwrap().len(), 32);
        let identity = Identity::import(&loaded.config.nsec).expect("identity imports");
        assert!(identity.npub().starts_with("npub1"));

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let dir_mode = fs::metadata(&home).unwrap().permissions().mode() & 0o777;
            let file_mode = fs::metadata(home.join(CONFIG_FILE))
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(dir_mode, 0o700);
            assert_eq!(file_mode, 0o600);
        }
    }

    #[test]
    fn init_refuses_to_overwrite_without_force() {
        let temp = tempfile::tempdir().expect("tempdir");
        let home = temp.path().join("agent");
        let args = InitArgs {
            nsec: None,
            nsec_file: None,
            nsec_env: None,
            force: false,
        };
        init(home.clone(), Vec::new(), args).expect("first init succeeds");
        let err = init(
            home,
            Vec::new(),
            InitArgs {
                nsec: None,
                nsec_file: None,
                nsec_env: None,
                force: false,
            },
        )
        .expect_err("second init fails");
        assert!(err.to_string().contains("already exists"));
    }

    #[test]
    fn seen_state_roundtrips() {
        let temp = tempfile::tempdir().expect("tempdir");
        let path = temp.path().join(SEEN_FILE);
        let mut seen = SeenState::default();
        seen.message_ids.insert("abc".to_owned());
        write_private_json(&path, &seen).expect("write seen");

        let loaded = load_seen(&path).expect("load seen");
        assert!(loaded.message_ids.contains("abc"));
    }

    #[test]
    fn relay_validation_rejects_empty_and_bad_values() {
        assert!(validate_relay_strings(Vec::new()).is_err());
        assert!(validate_relay_strings(vec!["not a relay".to_owned()]).is_err());
        assert!(validate_relay_strings(vec!["wss://relay.example.com".to_owned()]).is_ok());
    }

    #[test]
    fn init_secret_reads_from_file_and_env() {
        let temp = tempfile::tempdir().expect("tempdir");
        let key_path = temp.path().join("agent.nsec");
        fs::write(&key_path, "nsec-test\n").expect("write nsec");
        let from_file = init_secret(&InitArgs {
            nsec: None,
            nsec_file: Some(key_path),
            nsec_env: None,
            force: false,
        })
        .expect("file secret");
        assert_eq!(from_file.as_deref(), Some("nsec-test"));

        env::set_var("SONAR_CLI_TEST_NSEC", "nsec-env\n");
        let from_env = init_secret(&InitArgs {
            nsec: None,
            nsec_file: None,
            nsec_env: Some("SONAR_CLI_TEST_NSEC".to_owned()),
            force: false,
        })
        .expect("env secret");
        env::remove_var("SONAR_CLI_TEST_NSEC");
        assert_eq!(from_env.as_deref(), Some("nsec-env"));
    }

    #[test]
    fn next_wait_respects_timeout() {
        let start = Instant::now() - Duration::from_secs(8);
        assert_eq!(next_wait_secs(start, Some(10), 30), 1);
        assert_eq!(next_wait_secs(Instant::now(), None, 0), 1);
    }

    fn media_send_args(
        file: Option<PathBuf>,
        kind: Option<MediaKind>,
        mime: Option<String>,
    ) -> SendArgs {
        SendArgs {
            to: "npub".to_owned(),
            text: None,
            file: file.into_iter().collect(),
            stdin: false,
            kind,
            caption: String::new(),
            mime,
            blossom: DEFAULT_BLOSSOM_SERVER.to_owned(),
            group_name: "g".to_owned(),
            wait_for_ack: false,
            ack_timeout_secs: None,
            push_settle_secs: 0,
        }
    }

    #[test]
    fn media_kind_defaults_and_sniff() {
        assert_eq!(default_mime_for_kind(&MediaKind::Voice), "audio/mp4");
        assert_eq!(default_mime_for_kind(&MediaKind::Audio), "audio/mpeg");
        assert_eq!(default_mime_for_kind(&MediaKind::Image), "image/png");
        assert_eq!(default_mime_for_kind(&MediaKind::Video), "video/mp4");
        assert_eq!(media_kind_label(&MediaKind::Voice), "voice");
        assert_eq!(media_kind_label(&MediaKind::Video), "video");
        assert_eq!(sniff_mime(Path::new("a.png")), Some("image/png"));
        assert_eq!(sniff_mime(Path::new("a.JPEG")), Some("image/jpeg"));
        assert_eq!(sniff_mime(Path::new("clip.MP4")), Some("video/mp4"));
        assert_eq!(sniff_mime(Path::new("a.unknown")), None);
        assert_eq!(sniff_mime(Path::new("noext")), None);
        assert_eq!(mime_extension("audio/ogg"), Some("ogg"));
        assert_eq!(mime_extension("image/jpeg"), Some("jpg"));
        assert_eq!(mime_extension("application/pdf"), None);
    }

    #[test]
    fn media_kind_from_mime_classifies() {
        assert_eq!(media_kind_from_mime("audio/ogg"), "voice");
        assert_eq!(media_kind_from_mime("AUDIO/OPUS"), "voice");
        assert_eq!(media_kind_from_mime("audio/mpeg"), "audio");
        assert_eq!(media_kind_from_mime("image/png"), "image");
        assert_eq!(media_kind_from_mime("video/mp4"), "video");
        assert_eq!(media_kind_from_mime("application/pdf"), "file");
    }

    #[test]
    fn resolve_media_from_file_sniffs_mime() {
        let temp = tempfile::tempdir().expect("tempdir");
        let png = temp.path().join("pic.png");
        fs::write(&png, b"not-a-real-png").expect("write");
        let args = media_send_args(Some(png.clone()), Some(MediaKind::Image), None);
        let (data, filename, mime, _kind) =
            resolve_media_payloads(&args).expect("resolve").remove(0);
        assert_eq!(data, b"not-a-real-png");
        assert_eq!(filename, "pic.png");
        assert_eq!(mime, "image/png");
    }

    #[test]
    fn resolve_media_explicit_mime_overrides_sniff() {
        let temp = tempfile::tempdir().expect("tempdir");
        let png = temp.path().join("pic.png");
        fs::write(&png, b"x").expect("write");
        let args = media_send_args(
            Some(png),
            Some(MediaKind::Image),
            Some("image/webp".to_owned()),
        );
        let (_, _, mime, _) = resolve_media_payloads(&args).expect("resolve").remove(0);
        assert_eq!(mime, "image/webp");
    }

    #[test]
    fn resolve_media_kind_default_when_extension_unknown() {
        let temp = tempfile::tempdir().expect("tempdir");
        let clip = temp.path().join("voice");
        fs::write(&clip, b"y").expect("write");
        let args = media_send_args(Some(clip), Some(MediaKind::Voice), None);
        let (_, _, mime, kind) = resolve_media_payloads(&args).expect("resolve").remove(0);
        assert_eq!(mime, "audio/mp4");
        assert!(matches!(kind, MediaKind::Voice));
    }

    #[test]
    fn resolve_media_requires_kind() {
        let temp = tempfile::tempdir().expect("tempdir");
        let png = temp.path().join("pic.png");
        fs::write(&png, b"x").expect("write");
        let args = media_send_args(Some(png), None, None);
        let err = resolve_media_payloads(&args).unwrap_err();
        assert!(err.to_string().contains("--kind"));
    }

    #[test]
    fn resolve_media_rejects_empty_file() {
        let temp = tempfile::tempdir().expect("tempdir");
        let empty = temp.path().join("empty.png");
        fs::write(&empty, b"").expect("write");
        let args = media_send_args(Some(empty), Some(MediaKind::Image), None);
        let err = resolve_media_payloads(&args).unwrap_err();
        assert!(err.to_string().contains("empty"));
    }

    #[test]
    fn default_media_filename_from_url() {
        assert_eq!(
            default_media_filename("https://blossom.x/blobs/abc123.ogg"),
            "abc123.ogg"
        );
        assert_eq!(
            default_media_filename("https://blossom.x/blobs/abc?x=1"),
            "abc"
        );
        assert_eq!(default_media_filename("https://blossom.x/"), "media");
    }

    #[test]
    fn website_url_encodes_address_and_relays() {
        let url = sticker_pack_website_url(
            "https://example.com/stickers/",
            "30031:abc:def",
            &[
                "wss://relay.example.com".to_owned(),
                "wss://nos.lol".to_owned(),
            ],
        );
        assert_eq!(
            url,
            "https://example.com/stickers?a=30031%3Aabc%3Adef&relay=wss%3A%2F%2Frelay.example.com&relay=wss%3A%2F%2Fnos.lol"
        );
    }

    #[test]
    fn import_metadata_is_bounded_for_sticker_model() {
        let title = truncate_chars(&"x".repeat(100), 80);
        let emoji = short_emoji(Some("123456789"));
        assert_eq!(title.chars().count(), 80);
        assert_eq!(emoji.as_deref(), Some("12345678"));
    }
}
