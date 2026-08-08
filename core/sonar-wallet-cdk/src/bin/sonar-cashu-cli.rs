//! Headless proof for the CDK backend, and the driver for the live migration
//! test. Conventions match `sonar-wallet-cli`: newline-JSON on stdout, tracing
//! on stderr, secrets from the environment only (argv is visible in `ps` and
//! lands in shell history), `derive` prints a fingerprint unless explicitly
//! asked for the full seed.

use std::path::PathBuf;
use std::sync::Arc;

use clap::{Args, Parser, Subcommand};
use serde_json::json;
use sonar_wallet::{
    cashu_wallet_seed, nsec_to_secret, Network, Payment, ReceiveMethod, ReceiveRequest,
    WalletBackend, WalletConfig, WalletError, WalletEvent, WalletEventListener, Zeroizing,
};
use sonar_wallet_cdk::CdkWallet;

#[derive(Parser)]
#[command(
    name = "sonar-cashu-cli",
    about = "Headless Cashu (CDK) wallet driver for the sonar-wallet interface"
)]
struct Cli {
    /// Cashu mint URL (e.g. https://mint.example). Required for wallet
    /// commands; capabilities and derive answer without it.
    #[arg(long, global = true)]
    mint: Option<String>,
    /// Working directory for the wallet database.
    #[arg(long, global = true, default_value = "~/.sonar-cashu")]
    dir: String,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Print backend capabilities (no secret, no mint needed).
    Capabilities,
    /// Print a fingerprint of the derived wallet seed.
    Derive,
    /// Balance in sats.
    Balance,
    /// Create something a payer can pay: a BOLT11 invoice (requires
    /// --amount-sats) or a BOLT12 offer (--bolt12).
    Receive(ReceiveArgs),
    /// Price a send without paying it.
    Quote(SendArgs),
    /// Pay a destination (prepare, enforce the cap, execute).
    Send(SendArgs),
    /// Recent payments, newest first.
    Payments,
    /// Poll pending mint quotes once (mints paid ones).
    Sync,
    /// Stream wallet events until Enter (or a signal).
    Listen,
}

#[derive(Args)]
struct ReceiveArgs {
    #[arg(long)]
    amount_sats: Option<u64>,
    /// Request a reusable BOLT12 offer instead of a BOLT11 invoice.
    #[arg(long)]
    bolt12: bool,
    #[arg(long)]
    description: Option<String>,
}

#[derive(Args)]
struct SendArgs {
    destination: String,
    /// Amount in sats. Required for amountless destinations.
    #[arg(long)]
    amount_sats: Option<u64>,
    /// Abort if the quoted fee reserve exceeds this (fail-closed: also aborts
    /// if the backend quotes no fee at all).
    #[arg(long)]
    max_fee_sats: Option<u64>,
}

struct StdoutListener;
impl WalletEventListener for StdoutListener {
    fn on_event(&self, event: WalletEvent) {
        println!("{}", json!({ "event": format!("{event:?}") }));
    }
}

fn payment_json(p: &Payment) -> String {
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
    .to_string()
}

fn expand_home(path: &str) -> PathBuf {
    let home = std::env::var_os("HOME");
    match (path, home) {
        ("~", Some(home)) => PathBuf::from(home),
        (p, Some(home)) => match p.strip_prefix("~/") {
            Some(rest) => PathBuf::from(home).join(rest),
            None => PathBuf::from(p),
        },
        (p, None) => PathBuf::from(p),
    }
}

fn enforce_fee_cap(max: Option<u64>, quoted: Option<u64>) -> Result<(), WalletError> {
    if let Some(max) = max {
        match quoted {
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
    Ok(())
}

fn main() -> Result<(), WalletError> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .init();
    let cli = Cli::parse();

    // Static metadata answers before any secret is loaded.
    if let Command::Capabilities = cli.command {
        let c = CdkWallet::CAPABILITIES;
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

    // Secrets from the environment only.
    let nsec = Zeroizing::new(std::env::var("SONAR_NSEC").map_err(|_| {
        WalletError::InvalidInput("set $SONAR_NSEC to an nsec1… or 64-char hex key".into())
    })?);
    let secret = Zeroizing::new(nsec_to_secret(&nsec)?);
    let seed = Zeroizing::new(cashu_wallet_seed(&secret).to_vec());

    if matches!(cli.command, Command::Derive) {
        // The seed IS the wallet (NUT-13); print a fingerprint only, unless
        // the operator explicitly opts into dumping funds-controlling
        // material into scrollback.
        let full = hex::encode(&seed[..]);
        if std::env::var("SONAR_WALLET_UNSAFE_DUMP_SEED").as_deref() == Ok("1") {
            println!("{}", json!({ "cashu_seed_hex": full }));
        } else {
            println!(
                "{}",
                json!({
                    "cashu_seed_prefix": &full[..8],
                    "note": "set SONAR_WALLET_UNSAFE_DUMP_SEED=1 to print the full seed",
                })
            );
        }
        return Ok(());
    }

    let mint = cli.mint.clone().ok_or_else(|| {
        WalletError::InvalidInput("--mint <url> is required for wallet commands".into())
    })?;
    let wallet = CdkWallet::new(
        WalletConfig {
            seed,
            network: Network::Mainnet,
            api_key: None,
            working_dir: expand_home(&cli.dir),
        },
        &mint,
    )?;

    wallet.connect()?;
    let result = run(&wallet, &cli.command);
    let _ = wallet.disconnect();
    result
}

fn run(wallet: &CdkWallet, command: &Command) -> Result<(), WalletError> {
    match command {
        Command::Capabilities | Command::Derive => unreachable!("handled before connect"),
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
        Command::Receive(args) => {
            let request = ReceiveRequest {
                method: if args.bolt12 {
                    ReceiveMethod::Bolt12Offer
                } else {
                    ReceiveMethod::Bolt11Invoice
                },
                amount_sats: args.amount_sats,
                description: args.description.clone(),
            };
            let destination = wallet.receive(&request)?;
            println!("{}", json!({ "destination": destination }));
            println!(
                "{}",
                json!({
                    "note": "keep this process's store; run `sync` after the payer pays to mint the proofs"
                })
            );
        }
        Command::Quote(args) => {
            let destination = wallet.parse_destination(&args.destination)?;
            let prepared = wallet.prepare_send(&destination, args.amount_sats)?;
            enforce_fee_cap(args.max_fee_sats, prepared.fees_sats)?;
            println!(
                "{}",
                json!({
                    "amount_sats": prepared.amount_sats,
                    "fees_sats": prepared.fees_sats,
                })
            );
        }
        Command::Send(args) => {
            let destination = wallet.parse_destination(&args.destination)?;
            let prepared = wallet.prepare_send(&destination, args.amount_sats)?;
            println!(
                "{}",
                json!({
                    "quote": {
                        "amount_sats": prepared.amount_sats,
                        "fees_sats": prepared.fees_sats,
                    }
                })
            );
            enforce_fee_cap(args.max_fee_sats, prepared.fees_sats)?;
            let payment = wallet.send(&prepared, "")?;
            println!("{}", payment_json(&payment));
        }
        Command::Payments => {
            for payment in wallet.list_recent_payments(50)? {
                println!("{}", payment_json(&payment));
            }
        }
        Command::Sync => {
            wallet.sync_wallet()?;
            let b = wallet.balance()?;
            println!(
                "{}",
                json!({ "synced": true, "confirmed_sats": b.confirmed_sats })
            );
        }
        Command::Listen => {
            wallet.add_event_listener(Arc::new(StdoutListener));
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
