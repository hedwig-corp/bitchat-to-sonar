//! Cashu (CDK) backend for the `sonar-wallet` interface.
//!
//! Custody model differs from the Breez backend and the difference is the
//! point: ecash proofs are bearer instruments held locally, the MINT holds the
//! Lightning side. Restorability comes from NUT-13 — proof secrets derive
//! deterministically from the wallet seed, which derives from the account nsec
//! (`sonar_wallet::cashu_wallet_seed`, HKDF domain `sonar-cashu-v1`, distinct
//! from the Breez domain by design: separate funds domains must not share key
//! material).
//!
//! Payment mapping onto Cashu:
//! - `receive` = a MINT quote: the mint issues an invoice/offer; when paid,
//!   the background watcher mints proofs and emits `PaymentReceived`.
//! - `prepare_send`/`send` = a MELT quote then its execution — CDK's own
//!   prepare/confirm melt API maps 1:1 onto the trait's fee-preview seam, and
//!   the melt quote id is the prepared-send token (single-use is enforced by
//!   the quote's state in CDK's store, so no parked-quote map exists here).
//!
//! The lifecycle discipline is inherited from the Breez island's review
//! history, simplified where CDK genuinely is simpler: teardown is dropping an
//! `Arc` plus aborting the watcher task — infallible — so the failed-teardown
//! retention states (`disconnecting`/`defunct`) have nothing to represent.
//! What remains: one mutex owns the lifecycle, operational accessors expose
//! only established sessions, host callbacks run on a dedicated OS thread,
//! and `connect` never reports someone else's in-flight attempt as success.

use std::collections::HashMap;
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cdk::amount::SplitTarget;
use cdk::nuts::nut00::KnownMethod;
use cdk::nuts::{CurrencyUnit, MeltOptions, MeltQuoteState, MintQuoteState, PaymentMethod};
use cdk::wallet::{Wallet, WalletBuilder};
use cdk::Amount;
use sonar_wallet::{
    classify_destination, guard_wipe_path, resolve_send_amount, Balance, Destination,
    DestinationKind, ExchangeRate, ListenerRegistry, Payment, PaymentStatus, PreparedSend,
    PreparedSendToken, ReceiveMethod, ReceiveRequest, Result, WalletBackend, WalletCapabilities,
    WalletConfig, WalletError, WalletEvent, WalletEventListener,
};

/// File name of the redb store inside the working dir — also the wipe guard's
/// notion of "our artifact".
const DB_FILE: &str = "cashu.redb";

/// How often the watcher polls pending mint quotes. Mint quotes are the only
/// state that changes without us acting (a payer pays the invoice), and mints
/// expose no push channel over plain HTTP.
const WATCH_INTERVAL: Duration = Duration::from_secs(5);

/// Connection state; one mutex, same discipline as the Breez backend.
#[derive(Default)]
struct Lifecycle {
    wallet: Option<Arc<Wallet>>,
    /// A connect is between "claimed the slot" and "committed or abandoned".
    connecting: bool,
    /// Bumped by every disconnect; a connect that raced it abandons.
    generation: u64,
}

impl Lifecycle {
    /// The established session — the ONE predicate operational code may use.
    fn established(&self) -> Option<(Arc<Wallet>, u64)> {
        if self.connecting {
            return None;
        }
        self.wallet.clone().map(|w| (w, self.generation))
    }
}

pub struct CdkWallet {
    config: WalletConfig,
    mint_url: String,
    /// Option only so Drop can move it out; Some for the whole normal lifetime.
    runtime: Option<tokio::runtime::Runtime>,
    state: Mutex<Lifecycle>,
    listeners: Arc<ListenerRegistry>,
    events_tx: mpsc::Sender<WalletEvent>,
    /// Aborted on disconnect; watches pending mint quotes.
    watcher: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl CdkWallet {
    /// This backend's capabilities are static metadata; discovery must not
    /// require constructing a wallet (i.e. holding a seed).
    ///
    /// `node_lifecycle` is false: `connect` is a local store open plus one
    /// mint round-trip, and hosts need not foreground-gate it the way they
    /// must gate a Breez node.
    pub const CAPABILITIES: WalletCapabilities = WalletCapabilities {
        node_lifecycle: false,
        webhook: false,
        fiat_rates: false,
        lnurl_send: true,
        bolt11_send: true,
        bolt12_send: true,
        bolt12_receive: true,
        bolt11_receive: true,
    };

    pub fn new(config: WalletConfig, mint_url: &str) -> Result<Self> {
        if config.seed.len() < 64 {
            // The CDK builder takes exactly 64 bytes and NUT-13 derives proof
            // secrets from them; a 32-byte Breez-style seed here would slice
            // out of bounds below — refuse loudly instead.
            return Err(WalletError::InvalidInput(
                "cashu wallet seed must be 64 bytes (use sonar_wallet::cashu_wallet_seed)".into(),
            ));
        }
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| WalletError::Backend(format!("tokio runtime: {e}")))?;

        // Host callbacks run here, off the runtime, so they may re-enter the
        // backend (the documented reaction to `Synced` is re-querying state).
        let listeners = Arc::new(ListenerRegistry::new());
        let (events_tx, events_rx) = mpsc::channel::<WalletEvent>();
        let dispatch_listeners = listeners.clone();
        std::thread::Builder::new()
            .name("sonar-cashu-events".into())
            .spawn(move || {
                while let Ok(event) = events_rx.recv() {
                    dispatch_listeners.dispatch(&event);
                }
            })
            .map_err(|e| WalletError::Backend(format!("event thread: {e}")))?;

        Ok(Self {
            config,
            mint_url: mint_url.to_string(),
            runtime: Some(runtime),
            state: Mutex::new(Lifecycle::default()),
            listeners,
            events_tx,
            watcher: Mutex::new(None),
        })
    }

    fn state(&self) -> std::sync::MutexGuard<'_, Lifecycle> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The owned runtime; taken only during drop.
    fn rt(&self) -> &tokio::runtime::Runtime {
        self.runtime
            .as_ref()
            .expect("runtime is only taken during drop")
    }

    fn wallet(&self) -> Result<Arc<Wallet>> {
        self.state()
            .established()
            .map(|(w, _)| w)
            .ok_or(WalletError::NotConnected)
    }

    fn emit(&self, event: WalletEvent) {
        let _ = self.events_tx.send(event);
    }

    fn seed64(&self) -> [u8; 64] {
        // The caller hands us the 32-byte account secret's derived entropy?
        // No — for CDK the config seed IS the 64-byte cashu seed; enforce it.
        // (Constructors in this crate's CLI derive it via
        // `sonar_wallet::cashu_wallet_seed`.)
        let mut out = [0u8; 64];
        out.copy_from_slice(&self.config.seed[..64]);
        out
    }

    fn build_wallet(&self) -> Result<Wallet> {
        let mint_url: cdk::mint_url::MintUrl = self
            .mint_url
            .parse()
            .map_err(|e| WalletError::InvalidInput(format!("mint url: {e}")))?;
        std::fs::create_dir_all(&self.config.working_dir)
            .map_err(|e| WalletError::Backend(format!("create working dir: {e}")))?;
        let db_path = self.config.working_dir.join(DB_FILE);
        let localstore = cdk_redb::WalletRedbDatabase::new(&db_path)
            .map_err(|e| WalletError::Backend(format!("open {}: {e}", db_path.display())))?;
        WalletBuilder::new()
            .mint_url(mint_url)
            .unit(CurrencyUnit::Sat)
            .localstore(Arc::new(localstore))
            .seed(self.seed64())
            .build()
            .map_err(|e| WalletError::Backend(format!("build wallet: {e}")))
    }

    /// One pass of the pending-mint-quote watcher; also the body of
    /// `sync_wallet`. Returns how many quotes were minted.
    async fn poll_mint_quotes(wallet: &Wallet, events: &mpsc::Sender<WalletEvent>) -> usize {
        let mut minted = 0;
        let quotes = match wallet.get_active_mint_quotes().await {
            Ok(quotes) => quotes,
            Err(_) => return 0,
        };
        for quote in quotes {
            let state = match wallet.check_mint_quote_status(&quote.id).await {
                Ok(updated) => updated.state,
                Err(_) => continue,
            };
            if state != MintQuoteState::Paid {
                continue;
            }
            match wallet.mint(&quote.id, SplitTarget::default(), None).await {
                Ok(proofs) => {
                    minted += 1;
                    let amount_sats = proofs.iter().map(|p| u64::from(p.amount)).sum::<u64>();
                    let _ = events.send(WalletEvent::PaymentReceived {
                        payment: Payment {
                            id: quote.id.clone(),
                            amount_sats,
                            fees_sats: Some(0),
                            incoming: true,
                            timestamp_secs: now_secs(),
                            status: PaymentStatus::Complete,
                            preimage: None,
                            note: None,
                        },
                    });
                }
                Err(e) => {
                    tracing::warn!("minting paid quote {} failed: {e}", quote.id);
                }
            }
        }
        if minted > 0 {
            let _ = events.send(WalletEvent::Synced);
        }
        minted
    }
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl Drop for CdkWallet {
    fn drop(&mut self) {
        // Same hazard as the Breez backend: dropping the owned multi-thread
        // runtime from async context panics, and returning early would not
        // stop the field drop. Move it out; abort the watcher first so the
        // runtime has nothing long-lived left.
        if let Some(handle) = self
            .watcher
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
        {
            handle.abort();
        }
        let Some(runtime) = self.runtime.take() else {
            return;
        };
        if tokio::runtime::Handle::try_current().is_ok() {
            runtime.shutdown_background();
        }
        // In a blocking context the normal drop of `runtime` here is fine:
        // nothing blocking is left on it.
    }
}

impl WalletBackend for CdkWallet {
    fn capabilities(&self) -> WalletCapabilities {
        Self::CAPABILITIES
    }

    fn connect(&self) -> Result<()> {
        let started_at = {
            let mut state = self.state();
            if state.connecting {
                return Err(WalletError::Busy("a connect is already in progress".into()));
            }
            if state.wallet.is_some() {
                return Ok(());
            }
            state.connecting = true;
            state.generation
        };

        // Store open + mint probe with the lock released.
        let opened = (|| {
            let wallet = self.build_wallet()?;
            // One round-trip proves the mint is reachable and caches its
            // info/keysets; without this, "connected" would be a lie the
            // first send exposes.
            self.rt()
                .block_on(wallet.load_mint_info())
                .map_err(|e| WalletError::Network(format!("mint unreachable: {e}")))?;
            Ok(Arc::new(wallet))
        })();

        let wallet = match opened {
            Ok(wallet) => wallet,
            Err(e) => {
                self.state().connecting = false;
                return Err(e);
            }
        };

        {
            let mut state = self.state();
            state.connecting = false;
            if state.generation != started_at {
                // A disconnect landed while we were connecting; it wins.
                // Teardown here is just dropping the Arc — infallible — so
                // no retention states are needed.
                return Ok(());
            }
            state.wallet = Some(wallet.clone());
        }

        // Start the mint-quote watcher (the equivalent of the Breez event
        // forwarder; spawning cannot fail, so no rollback path exists).
        let events = self.events_tx.clone();
        let watch_wallet = wallet.clone();
        let handle = self.rt().spawn(async move {
            let mut tick = tokio::time::interval(WATCH_INTERVAL);
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tick.tick().await;
                CdkWallet::poll_mint_quotes(&watch_wallet, &events).await;
            }
        });
        if let Some(old) = self
            .watcher
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .replace(handle)
        {
            old.abort();
        }

        // Identity re-check and emit share the critical section, so hosts
        // never see Connected after a disconnect that beat us here.
        {
            let state = self.state();
            let still_ours = state
                .wallet
                .as_ref()
                .is_some_and(|published| Arc::ptr_eq(published, &wallet));
            if still_ours {
                self.emit(WalletEvent::Connected);
            }
        }
        Ok(())
    }

    fn disconnect(&self) -> Result<()> {
        // Infallible teardown: abort the watcher, drop the handle. The
        // generation bump makes any in-flight connect abandon its result.
        let cleared = {
            let mut state = self.state();
            state.generation = state.generation.wrapping_add(1);
            state.wallet.take().is_some()
        };
        if let Some(handle) = self
            .watcher
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
        {
            handle.abort();
        }
        if cleared {
            self.emit(WalletEvent::Disconnected);
        }
        Ok(())
    }

    fn is_connected(&self) -> bool {
        self.state().established().is_some()
    }

    fn balance(&self) -> Result<Balance> {
        let wallet = self.wallet()?;
        self.rt().block_on(async {
            let confirmed = wallet
                .total_balance()
                .await
                .map_err(|e| WalletError::Backend(e.to_string()))?;
            let pending = wallet
                .total_pending_balance()
                .await
                .map_err(|e| WalletError::Backend(e.to_string()))?;
            let reserved = wallet
                .total_reserved_balance()
                .await
                .map_err(|e| WalletError::Backend(e.to_string()))?;
            Ok(Balance {
                confirmed_sats: u64::from(confirmed),
                pending_receive_sats: u64::from(pending),
                pending_send_sats: u64::from(reserved),
            })
        })
    }

    fn sync_wallet(&self) -> Result<()> {
        let wallet = self.wallet()?;
        let events = self.events_tx.clone();
        self.rt()
            .block_on(async { CdkWallet::poll_mint_quotes(&wallet, &events).await });
        Ok(())
    }

    fn receive(&self, request: &ReceiveRequest) -> Result<String> {
        let wallet = self.wallet()?;
        let method = match request.method {
            ReceiveMethod::Bolt11Invoice => PaymentMethod::Known(KnownMethod::Bolt11),
            ReceiveMethod::Bolt12Offer => PaymentMethod::Known(KnownMethod::Bolt12),
            other => {
                return Err(WalletError::Unsupported(format!("receiving via {other:?}")));
            }
        };
        if request.method == ReceiveMethod::Bolt11Invoice && request.amount_sats.is_none() {
            return Err(WalletError::InvalidInput(
                "a BOLT11 invoice needs an amount".into(),
            ));
        }
        let amount = request.amount_sats.map(Amount::from);
        let description = request.description.clone();
        self.rt().block_on(async {
            let quote = wallet
                .mint_quote(method, amount, description, None)
                .await
                .map_err(|e| WalletError::Backend(e.to_string()))?;
            Ok(quote.request)
        })
    }

    fn parse_destination(&self, input: &str) -> Result<Destination> {
        // Pure classification only: a mint has no parser to refine with, and
        // amounts resolve at prepare time from the melt quote itself.
        let destination = classify_destination(input);
        if destination.raw.is_empty() {
            return Err(WalletError::InvalidDestination("empty input".into()));
        }
        Ok(destination)
    }

    fn prepare_send(
        &self,
        destination: &Destination,
        amount_sats: Option<u64>,
    ) -> Result<PreparedSend> {
        if !destination.kind.is_supported_by(&self.capabilities()) {
            return Err(WalletError::Unsupported(format!(
                "sending to a {}",
                destination.kind.label()
            )));
        }
        let wallet = self.wallet()?;
        // Trait contract: never silently pay one of two disagreeing figures.
        let requested = resolve_send_amount(amount_sats, destination.amount_sats)?;

        let quote = self.rt().block_on(async {
            match destination.kind {
                DestinationKind::Bolt11 => {
                    // An amount-carrying invoice needs no options; an
                    // amountless one carries the caller's amount as msat.
                    let options = requested.map(|sats| MeltOptions::new_amountless(sats * 1_000));
                    wallet
                        .melt_quote(KnownMethod::Bolt11, destination.raw.clone(), options, None)
                        .await
                }
                DestinationKind::Bolt12Offer => {
                    let options = requested.map(|sats| MeltOptions::new_amountless(sats * 1_000));
                    wallet
                        .melt_quote(KnownMethod::Bolt12, destination.raw.clone(), options, None)
                        .await
                }
                DestinationKind::LightningAddress => {
                    let sats = requested.ok_or(cdk::Error::AmountUndefined)?;
                    wallet
                        .melt_lightning_address_quote(&destination.raw, sats * 1_000)
                        .await
                }
                // Raw LNURL-pay strings are not routed by CDK; addresses and
                // BIP-353 are. `lnurl_send: true` covers the address family.
                DestinationKind::LnurlPay | DestinationKind::Unknown => {
                    Err(cdk::Error::UnsupportedPaymentMethod)
                }
            }
        });
        let quote = quote.map_err(|e| match e {
            cdk::Error::InsufficientFunds => WalletError::InsufficientFunds,
            cdk::Error::UnsupportedPaymentMethod => {
                WalletError::Unsupported("this destination kind on a Cashu mint".into())
            }
            other => WalletError::Backend(other.to_string()),
        })?;

        let quoted_amount = u64::from(quote.amount);
        // A destination-carried amount the caller disagreed with was already
        // rejected by resolve_send_amount; still verify the mint's quote
        // against whichever figure the caller confirmed.
        if let Some(requested) = amount_sats {
            if quoted_amount != requested {
                return Err(WalletError::InvalidDestination(format!(
                    "mint quoted {quoted_amount} sats but {requested} sats was requested"
                )));
            }
        }
        Ok(PreparedSend {
            destination: destination.clone(),
            amount_sats: quoted_amount,
            fees_sats: Some(u64::from(quote.fee_reserve)),
            // The melt quote is persisted by CDK under this id and is
            // single-use by state — the store IS the parked-quote map.
            token: PreparedSendToken::Opaque(quote.id),
        })
    }

    fn send(&self, prepared: &PreparedSend, _note: &str) -> Result<Payment> {
        let wallet = self.wallet()?;
        let PreparedSendToken::Opaque(quote_id) = &prepared.token else {
            return Err(WalletError::InvalidInput(
                "this prepared send did not come from the CDK backend".into(),
            ));
        };
        let payment = self.rt().block_on(async {
            let prepared_melt = wallet
                .prepare_melt(quote_id, HashMap::new())
                .await
                .map_err(|e| WalletError::Backend(e.to_string()))?;
            let finalized = prepared_melt
                .confirm()
                .await
                .map_err(|e| WalletError::Backend(e.to_string()))?;
            let status = match finalized.state() {
                MeltQuoteState::Paid => PaymentStatus::Complete,
                MeltQuoteState::Pending | MeltQuoteState::Unpaid | MeltQuoteState::Unknown => {
                    PaymentStatus::Pending
                }
                MeltQuoteState::Failed => PaymentStatus::Failed,
            };
            Ok(Payment {
                id: quote_id.clone(),
                amount_sats: u64::from(finalized.amount()),
                fees_sats: Some(u64::from(finalized.fee_paid())),
                incoming: false,
                timestamp_secs: now_secs(),
                status,
                preimage: finalized.payment_proof().map(str::to_string),
                note: None,
            })
        })?;
        self.emit(WalletEvent::PaymentSent {
            payment: payment.clone(),
        });
        Ok(payment)
    }

    fn list_recent_payments(&self, limit: u32) -> Result<Vec<Payment>> {
        let wallet = self.wallet()?;
        self.rt().block_on(async {
            let transactions = wallet
                .list_transactions(None)
                .await
                .map_err(|e| WalletError::Backend(e.to_string()))?;
            let mut payments: Vec<Payment> = transactions
                .into_iter()
                .map(|tx| {
                    let incoming =
                        tx.direction == cdk::wallet::types::TransactionDirection::Incoming;
                    Payment {
                        id: tx.id().to_string(),
                        amount_sats: u64::from(tx.amount),
                        fees_sats: Some(u64::from(tx.fee)),
                        incoming,
                        timestamp_secs: tx.timestamp,
                        status: PaymentStatus::Complete,
                        preimage: None,
                        note: (!tx.memo.clone().unwrap_or_default().is_empty())
                            .then(|| tx.memo.clone().unwrap_or_default()),
                    }
                })
                .collect();
            payments.sort_by_key(|p| std::cmp::Reverse(p.timestamp_secs));
            payments.truncate(limit as usize);
            Ok(payments)
        })
    }

    fn fetch_fiat_rates(&self) -> Result<Vec<ExchangeRate>> {
        // Mints have no rate oracle; hosts keep whatever rate source they use.
        Err(WalletError::Unsupported("fiat rates".into()))
    }

    fn add_event_listener(&self, listener: Arc<dyn WalletEventListener>) -> u64 {
        self.listeners.add(listener)
    }

    fn remove_event_listener(&self, id: u64) {
        self.listeners.remove(id);
    }

    fn wipe_local_storage(&self) -> Result<()> {
        let state = self.state();
        if state.wallet.is_some() || state.connecting {
            return Err(WalletError::Backend(
                "disconnect before wiping local storage".into(),
            ));
        }
        let target = guard_wipe_path(&self.config.working_dir, |name| {
            name == DB_FILE || name.starts_with(DB_FILE)
        })?;
        if target.exists() {
            std::fs::remove_dir_all(&target)
                .map_err(|e| WalletError::Backend(format!("wipe {}: {e}", target.display())))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sonar_wallet::{Network, Zeroizing};
    use std::path::PathBuf;

    fn config() -> WalletConfig {
        WalletConfig {
            seed: Zeroizing::new(vec![7u8; 64]),
            network: Network::Mainnet,
            api_key: None,
            working_dir: PathBuf::from("/tmp/sonar-wallet-cdk-test"),
        }
    }

    fn wallet() -> CdkWallet {
        CdkWallet::new(config(), "https://mint.example.com").unwrap()
    }

    #[test]
    fn short_seed_is_rejected() {
        let mut cfg = config();
        cfg.seed = Zeroizing::new(vec![1u8; 16]);
        assert!(matches!(
            CdkWallet::new(cfg, "https://mint.example.com"),
            Err(WalletError::InvalidInput(_))
        ));
    }

    #[test]
    fn disconnected_wallet_reports_not_connected() {
        let w = wallet();
        assert!(!w.is_connected());
        assert!(matches!(w.balance(), Err(WalletError::NotConnected)));
        assert!(w.disconnect().is_ok());
    }

    #[test]
    fn setup_phase_is_not_operational_and_second_connect_is_busy() {
        let w = wallet();
        w.state().connecting = true;
        assert!(!w.is_connected());
        assert!(matches!(w.balance(), Err(WalletError::NotConnected)));
        assert!(matches!(w.connect(), Err(WalletError::Busy(_))));
    }

    #[test]
    fn wipe_refused_while_connecting_and_guarded_when_idle() {
        let w = wallet();
        w.state().connecting = true;
        assert!(matches!(
            w.wipe_local_storage(),
            Err(WalletError::Backend(_))
        ));
        w.state().connecting = false;
        // Idle wipe of an absent dir is a no-op success.
        assert!(w.wipe_local_storage().is_ok());
    }

    #[test]
    fn lnurl_raw_and_unknown_destinations_are_refused() {
        let w = wallet();
        // Even before connect, capability gating runs first for kinds the
        // backend cannot route.
        let unknown = Destination {
            raw: "bc1qxyz".into(),
            kind: DestinationKind::Unknown,
            amount_sats: None,
            note: None,
        };
        // Unknown passes capability gating (backend's call) but requires a
        // connection to consult the mint.
        assert!(matches!(
            w.prepare_send(&unknown, Some(10)),
            Err(WalletError::NotConnected)
        ));
    }

    #[test]
    fn fiat_rates_are_honestly_unsupported() {
        let w = wallet();
        assert!(matches!(
            w.fetch_fiat_rates(),
            Err(WalletError::Unsupported(_))
        ));
    }
}
