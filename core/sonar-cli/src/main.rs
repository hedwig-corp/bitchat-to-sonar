use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use clap::{Args, Parser, Subcommand};
use nostr::prelude::*;
use nostr_blossom::prelude::*;
use nostr_sdk::Client as NostrClient;
use serde::{Deserialize, Serialize};
use sonar_core::client::{SonarClient, DEFAULT_BLOSSOM_SERVER};
use sonar_core::identity::Identity;
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
    /// Send an encrypted Sonar/Marmot text message to a public key.
    Send(SendArgs),
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
    /// Plaintext message body.
    #[arg(long)]
    text: String,
    /// Group name if a new 1:1 Marmot group must be created.
    #[arg(long, default_value = "Sonar agent DM")]
    group_name: String,
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
        content: String,
        created_at_secs: u64,
        mine: bool,
    },
}

#[tokio::main]
async fn main() {
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
            let loaded = LoadedConfig::load(home, cli.relays)?;
            let client = loaded.connect().await?;
            client.sync().await?;
            let peer = PublicKey::parse(&args.to)
                .map_err(|e| CliError::Message(format!("recipient pubkey: {e}")))?;
            let group_id = match find_dm_group(&client, peer)? {
                Some(group_id) => group_id,
                None => client.start_dm(peer, &args.group_name).await?,
            };
            client.send_text(&group_id, &args.text).await?;
            print_json(&Output::Sent {
                to: peer.to_bech32().expect("valid public key encodes as npub"),
                group_id: hex::encode(group_id.as_slice()),
            })?;
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

    #[test]
    fn website_url_encodes_address_and_relays() {
        let url = sticker_pack_website_url(
            "https://example.com/stickers/",
            "30030:abc:def",
            &[
                "wss://relay.example.com".to_owned(),
                "wss://nos.lol".to_owned(),
            ],
        );
        assert_eq!(
            url,
            "https://example.com/stickers?a=30030%3Aabc%3Adef&relay=wss%3A%2F%2Frelay.example.com&relay=wss%3A%2F%2Fnos.lol"
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
