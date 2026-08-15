//! Headless Breez→Cashu migration driver — the real-backend proof of
//! `sonar_wallet_migrate::MigrationEngine`, and the vehicle for the 2-shot
//! live test. Both backends run in THIS process (the island is the only place
//! breez-rust and cdk can link together).
//!
//! Spending discipline: `quote` never spends; `migrate` requires BOTH
//! `--max-fee-sats` (fail-closed) and `--accept-custody-change`, prints the
//! fee, pays once, then watches settlement. `settle`/`status` never spend and
//! are the crash-resume path.

use std::path::PathBuf;

use clap::{Args, Parser, Subcommand};
use serde_json::json;
use sonar_wallet::{
    cashu_wallet_seed, nsec_to_secret, wallet_entropy, Network, ReceiveMethod, ReceiveRequest,
    WalletBackend, WalletConfig, WalletError, Zeroizing,
};
use sonar_wallet_breez::BreezWallet;
use sonar_wallet_cdk::CdkWallet;
use sonar_wallet_migrate::{MigrationEngine, MigrationLimits, Settlement};

#[derive(Parser)]
#[command(
    name = "sonar-migrate-cli",
    about = "Migrate funds from the Breez Liquid wallet to a Cashu mint (single shot)"
)]
struct Cli {
    /// Cashu mint URL (destination).
    #[arg(long, global = true)]
    mint: Option<String>,
    /// Breez wallet working directory.
    #[arg(long, global = true, default_value = "~/.sonar-wallet")]
    breez_dir: String,
    /// Cashu wallet working directory.
    #[arg(long, global = true, default_value = "~/.sonar-cashu")]
    cashu_dir: String,
    /// SIMULATION ONLY: drive the migration FROM a Cashu mint instead of the
    /// Breez Lightning wallet, so the engine can be exercised end to end
    /// against throwaway mints without touching real funds. Everything
    /// downstream of the source is identical to a production run — the engine
    /// only ever sees two `dyn WalletBackend`s.
    #[arg(long, global = true)]
    source_mint: Option<String>,
    /// Working directory for the `--source-mint` wallet. Must differ from
    /// --cashu-dir: same-account stores are bound to one mint each.
    #[arg(long, global = true, default_value = "~/.sonar-cashu-source")]
    source_cashu_dir: String,
    /// Use testnet (refused by the Breez backend; present for parity).
    #[arg(long, global = true)]
    testnet: bool,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Both balances, no network writes — the resume/status primitive.
    Status,
    /// Price the migration without spending: prints amount + source fee.
    Quote(QuoteArgs),
    /// Plan, gate, pay ONCE, then watch settlement.
    Migrate(MigrateArgs),
    /// Resume settlement watching after a crash or a Pending outcome.
    Settle(SettleArgs),
    /// SIMULATION ONLY (requires --source-mint): mint sats into the simulated
    /// source wallet so a migration has something to move. Receives only — it
    /// never spends. Against a fake-backend mint the quote settles itself; any
    /// other mint will simply wait for the printed invoice to be paid.
    SimFund(SimFundArgs),
}

#[derive(Args)]
struct QuoteArgs {
    /// Exact amount; omit to quote a whole-balance drain.
    #[arg(long)]
    amount_sats: Option<u64>,
    /// Destination per-shot maximum (mint.hedwig.sh: 500000).
    #[arg(long, default_value_t = 500_000)]
    dest_max_sats: u64,
}

#[derive(Args)]
struct MigrateArgs {
    /// Exact amount; omit to drain the whole balance.
    #[arg(long)]
    amount_sats: Option<u64>,
    /// REQUIRED fail-closed cap on the source fee.
    #[arg(long)]
    max_fee_sats: u64,
    /// Destination per-shot maximum (mint.hedwig.sh: 500000).
    #[arg(long, default_value_t = 500_000)]
    dest_max_sats: u64,
    /// Acknowledge the custody change: Breez is self-custodial; Cashu proofs
    /// are bearer instruments and the MINT holds the Lightning side.
    #[arg(long)]
    accept_custody_change: bool,
    /// Settlement polls (~5s of destination sync each) before reporting
    /// Pending instead of Settled.
    #[arg(long, default_value_t = 24)]
    settle_polls: u32,
}

#[derive(Args)]
struct SimFundArgs {
    /// Amount to mint into the simulated source wallet.
    #[arg(long)]
    amount_sats: u64,
    /// Polls (~5s of source sync each) to wait for the quote to be issued.
    #[arg(long, default_value_t = 24)]
    polls: u32,
}

#[derive(Args)]
struct SettleArgs {
    /// Destination confirmed balance BEFORE the migration (from `status`).
    #[arg(long)]
    baseline_sats: u64,
    /// Amount expected to arrive.
    #[arg(long)]
    expected_sats: u64,
    #[arg(long, default_value_t = 24)]
    settle_polls: u32,
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

fn main() -> Result<(), WalletError> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .init();
    let cli = Cli::parse();

    // Secrets from the environment only (argv is world-readable via ps).
    let nsec = Zeroizing::new(std::env::var("SONAR_NSEC").map_err(|_| {
        WalletError::InvalidInput("set $SONAR_NSEC to an nsec1… or 64-char hex key".into())
    })?);
    let secret = Zeroizing::new(nsec_to_secret(&nsec)?);
    let api_key = std::env::var("BREEZ_API_KEY").ok();
    let mint = cli.mint.clone().ok_or_else(|| {
        WalletError::InvalidInput("--mint <url> is required (e.g. https://mint.hedwig.sh)".into())
    })?;
    let network = if cli.testnet {
        Network::Testnet
    } else {
        Network::Mainnet
    };

    // The source is chosen here and nowhere else: everything downstream takes
    // `&dyn WalletBackend`, so the simulated run exercises the same engine,
    // the same consent gates, and the same settlement loop as a real one.
    let source: Box<dyn WalletBackend> = match &cli.source_mint {
        Some(source_mint) => {
            let source_dir = expand_home(&cli.source_cashu_dir);
            if source_dir == expand_home(&cli.cashu_dir) {
                return Err(WalletError::InvalidInput(
                    "--source-cashu-dir must differ from --cashu-dir".into(),
                ));
            }
            if source_mint == &mint {
                return Err(WalletError::InvalidInput(
                    "--source-mint must differ from --mint: migrating a mint to itself proves \
                     nothing about the engine"
                        .into(),
                ));
            }
            eprintln!(
                "SIMULATION: source is the Cashu mint {source_mint}, not the Breez wallet. \
                 No Lightning funds move."
            );
            Box::new(CdkWallet::new(
                WalletConfig {
                    seed: Zeroizing::new(cashu_wallet_seed(&secret).to_vec()),
                    network,
                    api_key: None,
                    working_dir: source_dir,
                },
                source_mint,
            )?)
        }
        None => Box::new(BreezWallet::new(WalletConfig {
            seed: Zeroizing::new(wallet_entropy(&secret).to_vec()),
            network,
            api_key,
            working_dir: expand_home(&cli.breez_dir),
        })?),
    };
    let dest = CdkWallet::new(
        WalletConfig {
            seed: Zeroizing::new(cashu_wallet_seed(&secret).to_vec()),
            network,
            api_key: None,
            working_dir: expand_home(&cli.cashu_dir),
        },
        &mint,
    )?;

    source.connect()?;
    let result = (|| {
        dest.connect()?;
        let r = run(&cli, source.as_ref(), &dest);
        let _ = dest.disconnect();
        r
    })();
    // Always release the source node so its store is not left locked.
    let _ = source.disconnect();
    result
}

fn run(cli: &Cli, source: &dyn WalletBackend, dest: &CdkWallet) -> Result<(), WalletError> {
    let to_wallet_err = |e: sonar_wallet_migrate::MigrateError| WalletError::Backend(e.to_string());
    match &cli.command {
        Command::Status => {
            let engine = MigrationEngine::new(
                source,
                dest,
                MigrationLimits {
                    dest_max_sats: None,
                    fee_cap_sats: None,
                },
            );
            let (s, d) = engine.balances().map_err(to_wallet_err)?;
            println!(
                "{}",
                json!({
                    "breez": { "confirmed_sats": s.confirmed_sats, "pending_send_sats": s.pending_send_sats },
                    "cashu": { "confirmed_sats": d.confirmed_sats, "pending_receive_sats": d.pending_receive_sats },
                })
            );
        }
        Command::Quote(args) => {
            let engine = MigrationEngine::new(
                source,
                dest,
                MigrationLimits {
                    dest_max_sats: Some(args.dest_max_sats),
                    fee_cap_sats: None,
                },
            );
            let plan = match args.amount_sats {
                Some(a) => engine.plan_amount(a),
                None => engine.plan_drain(),
            }
            .map_err(to_wallet_err)?;
            println!(
                "{}",
                json!({
                    "amount_sats": plan.amount_sats,
                    "source_fee_sats": plan.source_fee_sats,
                    "note": "quote only; nothing was paid and the created mint invoice will expire unused",
                })
            );
        }
        Command::Migrate(args) => {
            if !args.accept_custody_change {
                return Err(WalletError::InvalidInput(
                    "migration changes the custody model: Breez is self-custodial, Cashu proofs \
                     are bearer instruments and the mint holds the Lightning side. Re-run with \
                     --accept-custody-change to proceed"
                        .into(),
                ));
            }
            let engine = MigrationEngine::new(
                source,
                dest,
                MigrationLimits {
                    dest_max_sats: Some(args.dest_max_sats),
                    fee_cap_sats: Some(args.max_fee_sats),
                },
            );
            let baseline = engine.balances().map_err(to_wallet_err)?.1.confirmed_sats;
            let plan = match args.amount_sats {
                Some(a) => engine.plan_amount(a),
                None => engine.plan_drain(),
            }
            .map_err(to_wallet_err)?;
            println!(
                "{}",
                json!({
                    "plan": {
                        "amount_sats": plan.amount_sats,
                        "source_fee_sats": plan.source_fee_sats,
                        "destination_baseline_sats": baseline,
                    }
                })
            );
            let payment = engine.execute(&plan).map_err(to_wallet_err)?;
            println!(
                "{}",
                json!({ "paid": { "id": payment.id, "amount_sats": payment.amount_sats, "fees_sats": payment.fees_sats, "status": format!("{:?}", payment.status) } })
            );
            let outcome = engine
                .settle(baseline, plan.amount_sats, args.settle_polls)
                .map_err(to_wallet_err)?;
            print_settlement(&outcome, baseline, plan.amount_sats);
        }
        Command::SimFund(args) => {
            if cli.source_mint.is_none() {
                return Err(WalletError::InvalidInput(
                    "sim-fund requires --source-mint: it exists to fund a simulated source \
                     wallet, and must never be pointed at the real Breez wallet"
                        .into(),
                ));
            }
            let before = source.balance()?.confirmed_sats;
            let invoice = source.receive(&ReceiveRequest {
                method: ReceiveMethod::Bolt11Invoice,
                amount_sats: Some(args.amount_sats),
                description: Some("Sonar migration simulation funding".into()),
            })?;
            println!(
                "{}",
                json!({
                    "invoice": invoice,
                    "note": "pay this to fund the simulated source; a fake-backend mint settles it itself",
                })
            );
            // Same shape as the engine's settlement watch: sync, then look at
            // the confirmed balance. Nothing here spends.
            let mut confirmed = before;
            for _ in 0..args.polls {
                let _ = source.sync_wallet();
                confirmed = source.balance()?.confirmed_sats;
                if confirmed > before {
                    break;
                }
            }
            println!(
                "{}",
                json!({
                    "funded": confirmed > before,
                    "source_confirmed_sats": confirmed,
                    "gained_sats": confirmed.saturating_sub(before),
                })
            );
        }
        Command::Settle(args) => {
            let engine = MigrationEngine::new(
                source,
                dest,
                MigrationLimits {
                    dest_max_sats: None,
                    fee_cap_sats: None,
                },
            );
            let outcome = engine
                .settle(args.baseline_sats, args.expected_sats, args.settle_polls)
                .map_err(to_wallet_err)?;
            print_settlement(&outcome, args.baseline_sats, args.expected_sats);
        }
    }
    Ok(())
}

fn print_settlement(outcome: &Settlement, baseline: u64, expected: u64) {
    match outcome {
        Settlement::Settled {
            destination_confirmed_sats,
        } => println!(
            "{}",
            json!({ "settled": true, "cashu_confirmed_sats": destination_confirmed_sats })
        ),
        Settlement::Pending {
            destination_confirmed_sats,
        } => println!(
            "{}",
            json!({
                "settled": false,
                "cashu_confirmed_sats": destination_confirmed_sats,
                "resume": format!(
                    "funds not visible yet; the destination keeps reconciling — re-run: sonar-migrate-cli settle --baseline-sats {baseline} --expected-sats {expected}"
                ),
            })
        ),
    }
}
