//! Headless proof of the `sonar-wallet` interface against the Breez backend.
//!
//! This binary exists because `sonar-cli` cannot link Breez: it depends on
//! sonar-core → mdk-sqlite-storage → SQLCipher `libsqlite3-sys`, which
//! conflicts with the plain-SQLite `libsqlite3-sys` in breez's rusqlite fork
//! (`links = "sqlite3"`). See core/Cargo.toml.
//!
//! The wallet is derived from the account nsec exactly as the apps do:
//! HKDF-SHA256(secret, "sonar-wallet", "sonar-bolt12-v1") → raw Breez seed.
//!
//! stdout is newline-delimited JSON (sonar-cli convention); logs go to stderr.

use std::path::PathBuf;
use std::sync::Arc;

use clap::{Args, Parser, Subcommand};
use serde_json::json;
use sonar_wallet::{
    entropy_hex, nsec_to_secret, wallet_entropy, Network, Payment, WalletBackend, WalletConfig,
    WalletError, WalletEvent, WalletEventListener,
};
use sonar_wallet_breez::BreezWallet;

#[derive(Parser)]
#[command(
    name = "sonar-wallet-cli",
    about = "Sonar wallet interface (Breez backend)"
)]
struct Cli {
    /// Account key: `nsec1…` or 64-char hex. Falls back to $SONAR_NSEC.
    #[arg(long, global = true)]
    nsec: Option<String>,
    /// Breez API key. Falls back to $BREEZ_API_KEY.
    #[arg(long, global = true)]
    api_key: Option<String>,
    /// Working directory for the wallet database.
    #[arg(long, global = true, default_value = "~/.sonar-wallet")]
    dir: String,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Print the derived wallet entropy (hex) without connecting.
    Derive,
    /// Print capabilities of the backend.
    Capabilities,
    /// Connect and print the balance.
    Balance,
    /// Connect and print a BOLT12 receive offer.
    Offer,
    /// Classify/parse a destination.
    Parse(ParseArgs),
    /// Pay a destination.
    Send(SendArgs),
    /// List recent payments.
    History(HistoryArgs),
    /// Fetch fiat exchange rates.
    Rates,
    /// Connect and stream wallet events until interrupted.
    Listen,
}

#[derive(Args)]
struct ParseArgs {
    input: String,
}

#[derive(Args)]
struct SendArgs {
    destination: String,
    /// Amount in sats. Required for amountless destinations (BOLT12 offers).
    #[arg(long)]
    amount_sats: Option<u64>,
    #[arg(long, default_value = "")]
    note: String,
}

#[derive(Args)]
struct HistoryArgs {
    #[arg(long, default_value_t = 20)]
    limit: u32,
}

struct StderrListener;

impl WalletEventListener for StderrListener {
    fn on_event(&self, event: WalletEvent) {
        let described = match &event {
            WalletEvent::Connected => json!({ "event": "connected" }),
            WalletEvent::Synced => json!({ "event": "synced" }),
            WalletEvent::Disconnected => json!({ "event": "disconnected" }),
            WalletEvent::PaymentReceived { payment } => {
                json!({ "event": "payment_received", "payment": payment_json(payment) })
            }
            WalletEvent::PaymentSent { payment } => {
                json!({ "event": "payment_sent", "payment": payment_json(payment) })
            }
            WalletEvent::PaymentFailed { payment } => {
                json!({ "event": "payment_failed", "payment": payment_json(payment) })
            }
        };
        println!("{described}");
    }
}

fn payment_json(p: &Payment) -> serde_json::Value {
    json!({
        "id": p.id,
        "amount_sats": p.amount_sats,
        "fees_sats": p.fees_sats,
        "incoming": p.incoming,
        "timestamp_secs": p.timestamp_secs,
        "status": format!("{:?}", p.status),
        "preimage": p.preimage,
        "note": p.note,
    })
}

fn expand_home(path: &str) -> PathBuf {
    match path.strip_prefix("~/") {
        Some(rest) => match std::env::var_os("HOME") {
            Some(home) => PathBuf::from(home).join(rest),
            None => PathBuf::from(path),
        },
        None => PathBuf::from(path),
    }
}

fn main() -> Result<(), WalletError> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cli = Cli::parse();
    // Secrets are read from the environment by hand rather than via clap's
    // `env` feature, which would echo values into --help output.
    let nsec = cli
        .nsec
        .clone()
        .or_else(|| std::env::var("SONAR_NSEC").ok())
        .ok_or_else(|| WalletError::InvalidInput("missing --nsec (or $SONAR_NSEC)".into()))?;
    let api_key = cli
        .api_key
        .clone()
        .or_else(|| std::env::var("BREEZ_API_KEY").ok());
    let secret = nsec_to_secret(&nsec)?;

    if matches!(cli.command, Command::Derive) {
        println!("{}", json!({ "entropy_hex": entropy_hex(&secret) }));
        return Ok(());
    }

    let working_dir = expand_home(&cli.dir);
    let wallet = BreezWallet::new(WalletConfig {
        seed: wallet_entropy(&secret).to_vec(),
        network: Network::Mainnet,
        api_key,
        working_dir,
    })?;

    if let Command::Capabilities = cli.command {
        let c = wallet.capabilities();
        println!(
            "{}",
            json!({
                "node_lifecycle": c.node_lifecycle,
                "webhook": c.webhook,
                "fiat_rates": c.fiat_rates,
                "bolt11_send": c.bolt11_send,
                "bolt12_send": c.bolt12_send,
                "bolt12_receive": c.bolt12_receive,
            })
        );
        return Ok(());
    }

    wallet.connect()?;
    let result = run(&wallet, &cli.command);
    // Always release the node, even on error, so the DB is not left locked.
    let _ = wallet.disconnect();
    result
}

fn run(wallet: &BreezWallet, command: &Command) -> Result<(), WalletError> {
    match command {
        Command::Derive | Command::Capabilities => unreachable!("handled before connect"),
        Command::Balance => {
            let b = wallet.balance()?;
            println!(
                "{}",
                json!({
                    "confirmed_sats": b.confirmed_sats,
                    "pending_receive_sats": b.pending_receive_sats,
                    "pending_send_sats": b.pending_send_sats,
                })
            );
        }
        Command::Offer => {
            println!("{}", json!({ "offer": wallet.receive_offer()? }));
        }
        Command::Parse(args) => {
            let d = wallet.parse_destination(&args.input)?;
            println!(
                "{}",
                json!({
                    "raw": d.raw,
                    "kind": format!("{:?}", d.kind),
                    "amount_sats": d.amount_sats,
                    "note": d.note,
                })
            );
        }
        Command::Send(args) => {
            let destination = wallet.parse_destination(&args.destination)?;
            let payment = wallet.send(&destination, args.amount_sats, &args.note)?;
            println!("{}", payment_json(&payment));
        }
        Command::History(args) => {
            for payment in wallet.list_recent_payments(args.limit)? {
                println!("{}", payment_json(&payment));
            }
        }
        Command::Rates => {
            for rate in wallet.fetch_fiat_rates()? {
                println!(
                    "{}",
                    json!({ "currency": rate.currency, "per_btc": rate.per_btc })
                );
            }
        }
        Command::Listen => {
            wallet.add_event_listener(Arc::new(StderrListener));
            tracing::info!("listening for wallet events; Ctrl-C to stop");
            loop {
                std::thread::park();
            }
        }
    }
    Ok(())
}
