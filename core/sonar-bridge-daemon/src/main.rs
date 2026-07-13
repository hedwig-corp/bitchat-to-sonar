mod account;
mod protocol;
mod secret_store;
mod spool;
mod store;

use std::collections::HashSet;
use std::env;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;

use nostr::RelayUrl;
use protocol::{Request, Response, MAX_FRAME_BYTES, PROTOCOL_VERSION};

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("sonar bridge daemon: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let args = Args::parse(env::args().skip(1))?;
    if args.command == "version" {
        println!(
            "sonar-bridge-daemon {} protocol {}",
            env!("CARGO_PKG_VERSION"),
            PROTOCOL_VERSION
        );
        return Ok(());
    }
    if !matches!(args.command.as_str(), "init" | "serve") {
        return Err("command must be init, serve, or version".into());
    }
    let state_dir = args.state_dir.ok_or("--state-dir is required")?;
    let master_key_path = args
        .master_key_file
        .ok_or("--master-key-file is required")?;
    let master_key = secret_store::load_master_key(&master_key_path)?;
    let secrets = secret_store::load_or_create(&state_dir, &master_key)?;

    if args.command == "init" {
        println!(
            "{}",
            serde_json::json!({
                "version": 1,
                "account_id": secrets.account_id,
                "npub": secrets.identity.npub(),
                "pubkey_hex": secrets.identity.public_key().to_hex()
            })
        );
        return Ok(());
    }
    let relays = args
        .relays
        .iter()
        .map(|relay| RelayUrl::parse(relay).map_err(|_| format!("invalid relay URL: {relay}")))
        .collect::<Result<Vec<_>, _>>()?;
    let blossom_server = args
        .blossom_server
        .unwrap_or_else(|| "https://nostr.download".into());
    let mut media_hosts = args
        .media_hosts
        .into_iter()
        .map(|host| host.to_ascii_lowercase())
        .collect::<HashSet<_>>();
    if media_hosts.is_empty() {
        if let Ok(url) = nostr::Url::parse(&blossom_server) {
            if let Some(host) = url.host_str() {
                media_hosts.insert(host.to_ascii_lowercase());
            }
        }
    }
    let account = account::Account::open(
        state_dir,
        secrets,
        master_key,
        relays,
        blossom_server,
        media_hosts,
    )
    .await?;

    let (tx, mut rx) = tokio::sync::mpsc::channel::<Result<Request, String>>(64);
    std::thread::spawn(move || {
        let stdin = io::stdin();
        for line in stdin.lock().lines() {
            let item = match line {
                Ok(line) if line.len() <= MAX_FRAME_BYTES => serde_json::from_str(&line)
                    .map_err(|error| format!("invalid JSON request: {error}")),
                Ok(_) => Err("request frame exceeds 1 MiB".into()),
                Err(error) => Err(format!("read request: {error}")),
            };
            if tx.blocking_send(item).is_err() {
                break;
            }
        }
    });

    let stdout = io::stdout();
    let mut output = io::BufWriter::new(stdout.lock());
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(2));
    // Tokio intervals tick immediately once. Consume that tick so daemon
    // hydration never runs ahead of the first `hello`/local-ready response.
    interval.tick().await;
    loop {
        tokio::select! {
            _ = interval.tick() => account.tick().await,
            item = rx.recv() => {
                let Some(item) = item else { break };
                let request = match item {
                    Ok(request) => request,
                    Err(error) => {
                        writeln!(output, "{}", serde_json::json!({"v": PROTOCOL_VERSION, "id": "", "ok": false, "error": {"code": "bad_frame", "message": error, "retryable": false}})).map_err(|e| e.to_string())?;
                        output.flush().map_err(|e| e.to_string())?;
                        continue;
                    }
                };
                let response = if request.v != PROTOCOL_VERSION {
                    Response::failure(&request.id, "version_mismatch", "unsupported protocol version", false)
                } else if request.method == "shutdown" {
                    let response = Response::success(&request.id, serde_json::json!({"stopping": true}));
                    writeln!(output, "{}", serde_json::to_string(&response).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
                    output.flush().map_err(|e| e.to_string())?;
                    break;
                } else {
                    match account.handle(&request.method, request.params).await {
                        Ok(value) => Response::success(&request.id, value),
                        Err(error) => Response::failure(&request.id, error.code, error.message, error.retryable),
                    }
                };
                writeln!(output, "{}", serde_json::to_string(&response).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
                output.flush().map_err(|e| e.to_string())?;
            }
        }
    }
    Ok(())
}

struct Args {
    command: String,
    state_dir: Option<PathBuf>,
    master_key_file: Option<PathBuf>,
    relays: Vec<String>,
    blossom_server: Option<String>,
    media_hosts: Vec<String>,
}

impl Args {
    fn parse(args: impl Iterator<Item = String>) -> Result<Self, String> {
        let mut args = args.peekable();
        let command = args.next().unwrap_or_else(|| "version".into());
        let mut parsed = Self {
            command,
            state_dir: None,
            master_key_file: None,
            relays: Vec::new(),
            blossom_server: None,
            media_hosts: Vec::new(),
        };
        while let Some(flag) = args.next() {
            let value = args
                .next()
                .ok_or_else(|| format!("{flag} requires a value"))?;
            match flag.as_str() {
                "--state-dir" => parsed.state_dir = Some(value.into()),
                "--master-key-file" => parsed.master_key_file = Some(value.into()),
                "--relay" => parsed.relays.push(value),
                "--blossom-server" => parsed.blossom_server = Some(value),
                "--media-host" => parsed.media_hosts.push(value),
                _ => return Err(format!("unknown option: {flag}")),
            }
        }
        Ok(parsed)
    }
}
