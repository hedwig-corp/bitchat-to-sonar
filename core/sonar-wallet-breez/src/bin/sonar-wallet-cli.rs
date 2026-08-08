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
    WalletError, WalletEvent, WalletEventListener, Zeroizing,
};
use sonar_wallet_breez::BreezWallet;

#[derive(Parser)]
#[command(
    name = "sonar-wallet-cli",
    about = "Sonar wallet interface (Breez backend)"
)]
struct Cli {
    /// Working directory for the wallet database.
    #[arg(long, global = true, default_value = "~/.sonar-wallet")]
    dir: String,
    /// Use testnet instead of mainnet.
    #[arg(long, global = true)]
    testnet: bool,
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
    /// Price a send without paying it.
    Quote(SendArgs),
    /// Pay a destination.
    Send(SendArgs),
    /// Force a sync with the network.
    Sync,
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
    /// Abort if the quoted fee exceeds this.
    #[arg(long)]
    max_fee_sats: Option<u64>,
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
    let home = std::env::var_os("HOME");
    match (path, home) {
        // Bare `~` too, not just `~/x` — otherwise `--dir ~` creates a literal
        // `./~` directory, which the wipe guard then refuses as relative.
        ("~", Some(home)) => PathBuf::from(home),
        (p, Some(home)) => match p.strip_prefix("~/") {
            Some(rest) => PathBuf::from(home).join(rest),
            None => PathBuf::from(p),
        },
        (p, None) => PathBuf::from(p),
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

    // Capabilities are static backend metadata: discovery must not require a
    // funds-controlling secret, so answer before any secret is loaded.
    if let Command::Capabilities = cli.command {
        let c = BreezWallet::CAPABILITIES;
        println!(
            "{}",
            json!({
                "node_lifecycle": c.node_lifecycle,
                "webhook": c.webhook,
                "fiat_rates": c.fiat_rates,
                "lnurl_send": c.lnurl_send,
                "bolt11_send": c.bolt11_send,
                "bolt12_send": c.bolt12_send,
                "bolt12_receive": c.bolt12_receive,
                "bolt11_receive": c.bolt11_receive,
            })
        );
        return Ok(());
    }

    // Secrets come from the environment only. Never accept them as arguments:
    // argv is visible to every local user via `ps` and lands in shell history
    // and CI logs.
    let nsec = Zeroizing::new(std::env::var("SONAR_NSEC").map_err(|_| {
        WalletError::InvalidInput("set $SONAR_NSEC to an nsec1… or 64-char hex key".into())
    })?);
    let api_key = std::env::var("BREEZ_API_KEY").ok();
    let secret = Zeroizing::new(nsec_to_secret(&nsec)?);

    if matches!(cli.command, Command::Derive) {
        // The entropy IS the wallet — printing it to stdout would put
        // funds-controlling material into terminal scrollback and CI logs, so
        // show a fingerprint unless the operator explicitly asks otherwise.
        let full = entropy_hex(&secret);
        if std::env::var("SONAR_WALLET_UNSAFE_DUMP_SEED").as_deref() == Ok("1") {
            println!("{}", json!({ "entropy_hex": full }));
        } else {
            println!(
                "{}",
                json!({
                    "entropy_prefix": &full[..8],
                    "note": "set SONAR_WALLET_UNSAFE_DUMP_SEED=1 to print the full seed",
                })
            );
        }
        return Ok(());
    }

    let working_dir = expand_home(&cli.dir);
    let wallet = BreezWallet::new(WalletConfig {
        seed: Zeroizing::new(wallet_entropy(&secret).to_vec()),
        network: if cli.testnet {
            Network::Testnet
        } else {
            Network::Mainnet
        },
        api_key,
        working_dir,
    })?;

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
            let prepared = wallet.prepare_send(&destination, args.amount_sats)?;
            // Show the quote before moving money, and let the caller cap it.
            println!(
                "{}",
                json!({
                    "quote": {
                        "amount_sats": prepared.amount_sats,
                        "fees_sats": prepared.fees_sats,
                    }
                })
            );
            if let Some(max) = args.max_fee_sats {
                match prepared.fees_sats {
                    Some(fees) if fees <= max => {}
                    Some(fees) => {
                        return Err(WalletError::Backend(format!(
                            "quoted fee {fees} sats exceeds --max-fee-sats {max}"
                        )));
                    }
                    // The user asked for a hard ceiling; a quote with no fee
                    // figure cannot honour it, so fail closed rather than pay
                    // an unbounded, undisclosed fee.
                    None => {
                        return Err(WalletError::Backend(format!(
                            "backend quoted no fee, cannot honour --max-fee-sats {max}"
                        )));
                    }
                }
            }
            let payment = wallet.send(&prepared, &args.note)?;
            println!("{}", payment_json(&payment));
        }
        Command::Quote(args) => {
            let destination = wallet.parse_destination(&args.destination)?;
            let prepared = wallet.prepare_send(&destination, args.amount_sats)?;
            // Same fail-closed cap semantics as `send`: automation uses this
            // as a preflight, and a success exit with a fee above (or absent
            // from) the requested ceiling would be a false green light.
            if let Some(max) = args.max_fee_sats {
                match prepared.fees_sats {
                    Some(fees) if fees <= max => {}
                    Some(fees) => {
                        return Err(WalletError::Backend(format!(
                            "quoted fee {fees} sats exceeds --max-fee-sats {max}"
                        )));
                    }
                    None => {
                        return Err(WalletError::Backend(format!(
                            "backend quoted no fee, cannot honour --max-fee-sats {max}"
                        )));
                    }
                }
            }
            println!(
                "{}",
                json!({
                    "amount_sats": prepared.amount_sats,
                    "fees_sats": prepared.fees_sats,
                })
            );
        }
        Command::Sync => {
            wallet.sync_wallet()?;
            println!("{}", json!({ "synced": true }));
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
            // Blocking on stdin rather than parking forever: Ctrl-C would kill
            // the process before the caller's `disconnect()` runs and leave the
            // wallet database locked, which is a poor look for the binary whose
            // job is to prove the lifecycle.
            //
            // A closed/redirected stdin returns Ok(0) immediately, which would
            // turn `listen … &` or `listen < /dev/null` into a silent no-op
            // that exits 0. Park instead, and let the operator stop it with a
            // signal — the DB lock is released by the OS either way, and this
            // is the only shape that actually listens.
            tracing::info!("listening for wallet events; press Enter (or send a signal) to stop");
            let mut line = String::new();
            if let Ok(0) = std::io::stdin().read_line(&mut line) {
                tracing::info!("stdin is not interactive; parking until signalled");
                loop {
                    std::thread::park();
                }
            }
        }
    }
    Ok(())
}
