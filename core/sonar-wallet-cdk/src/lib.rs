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

mod connector;
#[cfg(any(test, feature = "test-support"))]
pub mod test_mint;

use std::collections::HashMap;
use std::path::Path;
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cdk::amount::SplitTarget;
use cdk::nuts::nut00::KnownMethod;
use cdk::nuts::{CurrencyUnit, MeltOptions, MeltQuoteState, MintQuoteState, PaymentMethod, State};
use cdk::wallet::types::{
    MeltSagaState, TransactionDirection, TransactionId, TransactionStatus, WalletSagaState,
};
use cdk::wallet::{MintConnector, Wallet, WalletBuilder};
use cdk::Amount;
use sonar_wallet::{
    cashu_offer_key, classify_destination, guard_wipe_path, resolve_send_amount, Balance,
    Destination, DestinationKind, ExchangeRate, ListenerRegistry, Payment, PaymentStatus,
    PreparedSend, PreparedSendToken, ReceiveMethod, ReceiveRequest, Result, TrackedReceive,
    TrackedReceiveBackend, TrackedReceiveState, WalletBackend, WalletCapabilities, WalletConfig,
    WalletError, WalletEvent, WalletEventListener, Zeroizing,
};

/// File name of the redb store inside the working dir — also the wipe guard's
/// notion of "our artifact".
const DB_FILE: &str = "cashu.redb";

/// Prefix of the per-mint restore markers, written ONLY after a NUT-13
/// restore scan completes against that mint. Freshness must not be judged by
/// the store file existing (a first connect can create the file and then fail
/// transiently — keying on it would skip restoration forever), and must not
/// be directory-global either: the same seeded store reused against a second
/// mint still owes that mint its own scan. Absent marker for the configured
/// mint ⇒ restore runs (idempotent) until it succeeds once.
const RESTORED_MARKER_PREFIX: &str = "cashu.restored";

/// Prefix of the per-mint pointer to the wallet's published BOLT12 offer
/// (`cashu.offer.<hash8>`, JSON `{quote_id, offer, index}`). The offer is the
/// receive address hosts publish (Nostr descriptor, BIP-353, BLE); it must
/// be the same across calls and launches, and readable with no network.
const OFFER_POINTER_PREFIX: &str = "cashu.offer";

/// Prefix of the per-mint journal of ambiguous melts still being settled
/// (`cashu.unsettled.<hash8>`, JSON). It outlives the process on purpose: a
/// send reported Pending must not read Failed after a relaunch while the
/// mint may still pay it.
const UNSETTLED_PREFIX: &str = "cashu.unsettled";

/// Fingerprint of the seed that owns this store. Cashu proofs are BEARER
/// data: opening one account's store with another account's seed would let
/// the second see (and spend) the first's funds, and would suppress its own
/// NUT-13 restore because the markers look satisfied. The store is therefore
/// bound to its seed on creation and validated on every open.
const ACCOUNT_MARKER: &str = "cashu.account";

/// How often the watcher polls pending mint quotes. Mint quotes are the only
/// state that changes without us acting (a payer pays the invoice), and mints
/// expose no push channel over plain HTTP.
const WATCH_INTERVAL: Duration = Duration::from_secs(5);

/// Sats the mint owes us: paid into quotes but not yet minted, summed over
/// each quote's `amount_mintable()`.
fn quoted_pending_receive_sats(mintable: impl IntoIterator<Item = u64>) -> u64 {
    mintable.into_iter().fold(0u64, u64::saturating_add)
}

/// Exactly our artifacts, nothing prefix-shaped: `cashu.redb-backup` or
/// `cashu.restored-notes` in an over-broad `working_dir` are somebody's data,
/// and a loose `starts_with` would have handed them to `remove_dir_all` —
/// defeating the foreign-content protection the wipe guard exists for.
fn is_our_artifact(name: &str) -> bool {
    if matches!(
        name,
        DB_FILE
            | ACCOUNT_MARKER
            | "cashu.migration.v1.json"
            | "cashu.migration.v1.json.tmp"
            | "cashu.migration.v1.lock"
    ) {
        return true;
    }
    if let Some(suffix) = name
        .strip_prefix("cashu.migration.v1.json.")
        .and_then(|rest| rest.strip_suffix(".tmp"))
    {
        return !suffix.is_empty()
            && suffix
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-');
    }
    if let Some(stamp) = name
        .strip_prefix(DB_FILE)
        .and_then(|rest| rest.strip_prefix(".corrupt-"))
    {
        let parts: Vec<&str> = stamp.split('-').collect();
        return parts.len() <= 2
            && parts
                .iter()
                .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()));
    }
    let is_mint_tag =
        |suffix: &str| suffix.len() == 8 && suffix.chars().all(|c| c.is_ascii_hexdigit());
    for prefix in [OFFER_POINTER_PREFIX, UNSETTLED_PREFIX] {
        if let Some(rest) = name
            .strip_prefix(prefix)
            .and_then(|rest| rest.strip_prefix('.'))
        {
            return is_mint_tag(rest.strip_suffix(".tmp").unwrap_or(rest));
        }
    }
    name.strip_prefix(RESTORED_MARKER_PREFIX)
        .and_then(|rest| rest.strip_prefix('.'))
        .is_some_and(is_mint_tag)
}

/// Whether a NUT-13 restore scan is still owed.
///
/// A surviving `cashu.restored.<mint>` marker is not enough: if `cashu.redb`
/// is gone, CDK creates an empty store and the marker would otherwise skip
/// restore forever, presenting a zero balance over recoverable funds.
fn needs_nut13_restore(working_dir: &Path, restore_marker_name: &str) -> bool {
    !working_dir.join(restore_marker_name).exists() || !working_dir.join(DB_FILE).exists()
}

/// The redb store at `path`, shared by every wallet in this process.
///
/// redb keeps a second `Database` off a file with an OS file lock, but Rust's
/// std has no file locking on Android. There, a reconnect while an operation
/// still held the old wallet (a `sync` in flight when the app went to the
/// background) opened a second writer on the same file, and the store came
/// back "All roots are corrupted". Reuse the live handle instead — only while
/// it is still the file on disk, so a wiped and recreated store gets its own.
fn open_store(
    path: &Path,
) -> std::result::Result<Arc<cdk_redb::WalletRedbDatabase>, StoreOpenError> {
    type Open = Vec<(
        std::path::PathBuf,
        Option<(u64, u64)>,
        std::sync::Weak<cdk_redb::WalletRedbDatabase>,
    )>;
    static OPEN: Mutex<Open> = Mutex::new(Vec::new());
    let mut open = OPEN.lock().unwrap_or_else(|e| e.into_inner());
    open.retain(|(_, _, db)| db.strong_count() > 0);
    let identity = file_identity(path);
    if let Some(db) = open
        .iter()
        .filter(|(p, id, _)| p == path && id.is_some() && *id == identity)
        .find_map(|(_, _, db)| db.upgrade())
    {
        return Ok(db);
    }
    // Some damage makes redb panic while opening instead of returning an error.
    let db = match std::panic::catch_unwind(|| cdk_redb::WalletRedbDatabase::new(path)) {
        Ok(Ok(db)) => Arc::new(db),
        Ok(Err(e)) if is_unreadable(&e) => return Err(StoreOpenError::Unreadable(e.to_string())),
        Ok(Err(e)) => {
            return Err(StoreOpenError::Other(WalletError::Backend(format!(
                "open {}: {e}",
                path.display()
            ))))
        }
        Err(_) => {
            return Err(StoreOpenError::Unreadable(
                "redb panicked opening it".into(),
            ))
        }
    };
    open.push((path.to_path_buf(), file_identity(path), Arc::downgrade(&db)));
    Ok(db)
}

/// Why a proof store did not open.
enum StoreOpenError {
    /// Not a readable redb file any more: only NUT-13 can bring its funds back.
    Unreadable(String),
    /// Anything else (already open, permissions, a newer file format): never
    /// a reason to set the file aside.
    Other(WalletError),
}

/// redb's verdict that the file itself is damaged, as opposed to an error
/// opening a sound one.
fn is_unreadable(e: &cdk_redb::error::Error) -> bool {
    fn damaged(s: &redb::StorageError) -> bool {
        match s {
            redb::StorageError::Corrupted(_) => true,
            redb::StorageError::Io(io) => matches!(
                io.kind(),
                std::io::ErrorKind::InvalidData | std::io::ErrorKind::UnexpectedEof
            ),
            _ => false,
        }
    }
    match e {
        cdk_redb::error::Error::Database(d) => {
            matches!(&**d, redb::DatabaseError::Storage(s) if damaged(s))
        }
        cdk_redb::error::Error::Storage(s) => damaged(s),
        cdk_redb::error::Error::Redb(r) => matches!(&**r, redb::Error::Corrupted(_)),
        _ => false,
    }
}

/// Rename an unreadable store out of the way (`cashu.redb.corrupt-<secs>`),
/// kept for inspection; the wipe guard accepts the name.
fn set_aside_unreadable_store(db_path: &Path) -> Result<std::path::PathBuf> {
    let stamp = now_secs();
    for n in 0u32.. {
        let name = if n == 0 {
            format!("{DB_FILE}.corrupt-{stamp}")
        } else {
            format!("{DB_FILE}.corrupt-{stamp}-{n}")
        };
        let aside = db_path.with_file_name(name);
        if !aside.exists() {
            std::fs::rename(db_path, &aside).map_err(|e| {
                WalletError::Backend(format!("set aside {}: {e}", db_path.display()))
            })?;
            return Ok(aside);
        }
    }
    unreachable!("u32 names exhausted")
}

/// Device and inode: tells the same file from one recreated at its path.
#[cfg(unix)]
fn file_identity(path: &Path) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path).ok().map(|m| (m.dev(), m.ino()))
}

/// Elsewhere redb's own file lock refuses a second open: never share.
#[cfg(not(unix))]
fn file_identity(_path: &Path) -> Option<(u64, u64)> {
    None
}

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
    /// Replaces CDK's HTTP client; only ever set by tests (`with_connector`).
    connector: Option<Arc<dyn MintConnector + Send + Sync>>,
    budgets: Budgets,
    /// Serializes offer creation: two concurrent first calls must not mint
    /// two offers and publish whichever lost.
    offer_lock: Mutex<()>,
    /// Shared by the watcher, `sync_wallet` and `send`; outlives reconnects.
    reconciler: Arc<Reconciler>,
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
        // Raw LNURL is NOT routed (no CDK path for it); addresses are.
        lnurl_send: false,
        lightning_address_send: true,
        bolt11_send: true,
        bolt12_send: true,
        bolt12_receive: true,
        bolt11_receive: true,
    };

    pub fn new(config: WalletConfig, mint_url: &str) -> Result<Self> {
        if config.seed.len() != 64 {
            // Exactly 64: the CDK builder takes [u8; 64] and NUT-13 derives
            // proof secrets from them. Shorter would slice out of bounds;
            // LONGER would silently truncate, making distinct seeds that share
            // a 64-byte prefix open the same funds wallet.
            return Err(WalletError::InvalidInput(
                "cashu wallet seed must be exactly 64 bytes (use sonar_wallet::cashu_wallet_seed)"
                    .into(),
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

        let journal = config
            .working_dir
            .join(format!("{UNSETTLED_PREFIX}.{}", mint_tag(mint_url)));
        Ok(Self {
            config,
            mint_url: mint_url.to_string(),
            runtime: Some(runtime),
            state: Mutex::new(Lifecycle::default()),
            listeners,
            events_tx,
            watcher: Mutex::new(None),
            connector: None,
            budgets: Budgets::DEFAULT,
            offer_lock: Mutex::new(()),
            reconciler: Arc::new(Reconciler::with_journal(journal)),
        })
    }

    /// Shrink every mint deadline to `budget` so tests can exercise the
    /// timeout paths without waiting for production deadlines.
    #[cfg(any(test, feature = "test-support"))]
    pub fn set_test_budget(&mut self, budget: Duration) {
        self.budgets = Budgets {
            mint_call: budget,
            restore: budget,
            recovery: budget,
            send: budget,
            melt_grace: budget,
            melt_ttl_floor: budget,
            confirm_ttl_floor: budget,
            keyset_refresh: budget,
        };
    }

    /// Shrink only how long `send` waits before it reports the melt Pending.
    #[cfg(any(test, feature = "test-support"))]
    pub fn set_test_send_budget(&mut self, budget: Duration) {
        self.budgets.send = budget;
    }

    /// Set the quote lifetime `send` needs left to start a melt, and to
    /// confirm one (see [`Budgets::melt_ttl_floor`]).
    #[cfg(any(test, feature = "test-support"))]
    pub fn set_test_ttl_floors(&mut self, start: Duration, confirm: Duration) {
        self.budgets.melt_ttl_floor = start;
        self.budgets.confirm_ttl_floor = confirm;
    }

    /// Shrink only the grace an ambiguous, compensated melt waits before it
    /// is called Failed (see [`Budgets::melt_grace`]).
    #[cfg(any(test, feature = "test-support"))]
    pub fn set_test_melt_grace(&mut self, grace: Duration) {
        self.budgets.melt_grace = grace;
    }

    /// A wallet whose mint traffic goes to `connector` instead of HTTP — the
    /// seam that lets tests drive the real connect/watcher/send paths against
    /// [`test_mint::FakeMint`].
    #[cfg(any(test, feature = "test-support"))]
    pub fn with_connector(
        config: WalletConfig,
        mint_url: &str,
        connector: Arc<dyn MintConnector + Send + Sync>,
    ) -> Result<Self> {
        let mut wallet = Self::new(config, mint_url)?;
        wallet.connector = Some(connector);
        Ok(wallet)
    }

    /// Wait up to `remaining` for a send task whose melt is confirming.
    /// `None`: still running, so the caller stops listening and the task
    /// reports the outcome as an event. Money may be moving: the caller
    /// reports Pending, never an error, which would invite a retry that pays
    /// twice.
    fn await_confirm(
        &self,
        task: &mut tokio::task::JoinHandle<Result<Payment>>,
        handoff: &Mutex<SendHandoff>,
        remaining: Duration,
    ) -> Option<std::result::Result<Result<Payment>, tokio::task::JoinError>> {
        let waited = self
            .rt()
            .block_on(async { tokio::time::timeout(remaining, &mut *task).await });
        if let Ok(joined) = waited {
            return Some(joined);
        }
        let mut h = handoff.lock().unwrap_or_else(|e| e.into_inner());
        if h.finished {
            drop(h);
            return Some(self.rt().block_on(task));
        }
        h.caller_gone = true;
        None
    }

    /// Restore-completion marker for THIS mint (`cashu.restored.<hash8>`),
    /// so a shared store connecting to a second mint still runs that mint's
    /// NUT-13 scan.
    fn restore_marker_name(&self) -> String {
        format!("{RESTORED_MARKER_PREFIX}.{}", self.mint_tag())
    }

    /// Short per-mint tag for this store's per-mint files.
    fn mint_tag(&self) -> String {
        mint_tag(&self.mint_url)
    }

    fn offer_pointer_path(&self) -> std::path::PathBuf {
        self.config
            .working_dir
            .join(format!("{OFFER_POINTER_PREFIX}.{}", self.mint_tag()))
    }

    /// The published offer, from disk only. A corrupt pointer reads as
    /// absent: a new offer is safer than an error on every receive, and the
    /// old quote stays in the store (and keeps being minted).
    fn read_offer_pointer(&self) -> Option<OfferPointer> {
        let raw = std::fs::read(self.offer_pointer_path()).ok()?;
        let value: serde_json::Value = serde_json::from_slice(&raw).ok()?;
        Some(OfferPointer {
            quote_id: value.get("quote_id")?.as_str()?.to_string(),
            offer: value.get("offer")?.as_str()?.to_string(),
            index: u32::try_from(value.get("index")?.as_u64()?).ok()?,
        })
    }

    /// Atomic and durable: a torn pointer would re-publish a different offer.
    fn write_offer_pointer(&self, pointer: &OfferPointer) -> Result<()> {
        use std::io::Write;
        let path = self.offer_pointer_path();
        let tmp = path.with_extension(format!(
            "{}.tmp",
            path.extension()
                .and_then(|e| e.to_str())
                .unwrap_or_default()
        ));
        let body = serde_json::json!({
            "quote_id": pointer.quote_id,
            "offer": pointer.offer,
            "index": pointer.index,
        })
        .to_string();
        let write = || -> std::io::Result<()> {
            let mut file = std::fs::File::create(&tmp)?;
            file.write_all(body.as_bytes())?;
            file.sync_all()?;
            std::fs::rename(&tmp, &path)?;
            #[cfg(unix)]
            std::fs::File::open(&self.config.working_dir)?.sync_all()?;
            Ok(())
        };
        write().map_err(|e| WalletError::Backend(format!("write {}: {e}", path.display())))
    }

    /// The NUT-20 key for offer `index` — derived, never random, so the
    /// offer's quote can be re-adopted from the nsec (see
    /// `sonar_wallet::cashu_offer_key`).
    fn offer_secret(&self, index: u32) -> Result<cdk::nuts::SecretKey> {
        let mint_url: cdk::mint_url::MintUrl = self
            .mint_url
            .parse()
            .map_err(|e| WalletError::InvalidInput(format!("mint url: {e}")))?;
        // Borrow the zeroizing seed in place rather than copying it out.
        let seed: &[u8; 64] = self.config.seed[..]
            .try_into()
            .map_err(|_| WalletError::InvalidInput("cashu seed must be 64 bytes".into()))?;
        let key = Zeroizing::new(cashu_offer_key(seed, &mint_url.to_string(), index));
        cdk::nuts::SecretKey::from_slice(&key[..])
            .map_err(|e| WalletError::Backend(format!("offer key {index}: {e}")))
    }

    /// Ask the mint for a reusable, amountless BOLT12 quote locked to the
    /// derived key for `index`, store it, then publish the pointer. CDK's own
    /// `mint_quote` would draw a random NUT-20 key, which cannot be
    /// re-derived after the store is lost.
    fn create_offer(&self, wallet: &Wallet, index: u32) -> Result<OfferPointer> {
        use cdk::nuts::nut25::MintQuoteBolt12Request;
        let secret = self.offer_secret(index)?;
        let request = cdk::MintQuoteRequest::Bolt12(MintQuoteBolt12Request {
            amount: None,
            unit: CurrencyUnit::Sat,
            description: None,
            pubkey: secret.public_key(),
        });
        let connector = wallet.mint_connector();
        let response = self.rt().block_on(bounded(
            self.budgets.mint_call,
            connector.post_mint_quote(request),
        ))?;
        let cdk::MintQuoteResponse::Bolt12(offer) = response else {
            return Err(WalletError::Backend(
                "mint answered a BOLT12 quote request with another kind".into(),
            ));
        };
        let mut quote = cdk::wallet::types::MintQuote::new(
            offer.quote.clone(),
            wallet.mint_url.clone(),
            PaymentMethod::Known(KnownMethod::Bolt12),
            offer.amount,
            CurrencyUnit::Sat,
            offer.request.clone(),
            offer.expiry.unwrap_or(0),
            Some(secret),
        );
        quote.amount_paid = offer.amount_paid;
        quote.amount_issued = offer.amount_issued;
        quote.update_state_from_amounts();
        self.rt()
            .block_on(wallet.localstore.add_mint_quote(quote))
            .map_err(|e| WalletError::Backend(format!("store offer quote: {e}")))?;
        let pointer = OfferPointer {
            quote_id: offer.quote,
            offer: offer.request,
            index,
        };
        self.write_offer_pointer(&pointer)?;
        Ok(pointer)
    }

    /// Put the published offer's quote back in a store that lost it, with
    /// its re-derived key, so payments made to the offer meanwhile can still
    /// be minted.
    fn adopt_offer(&self, wallet: &Wallet, pointer: &OfferPointer) -> Result<()> {
        let mut quote = self.rt().block_on(bounded(
            self.budgets.mint_call,
            wallet.fetch_mint_quote(
                &pointer.quote_id,
                Some(PaymentMethod::Known(KnownMethod::Bolt12)),
            ),
        ))?;
        quote.secret_key = Some(self.offer_secret(pointer.index)?);
        self.rt()
            .block_on(wallet.localstore.add_mint_quote(quote))
            .map_err(|e| WalletError::Backend(format!("store adopted offer quote: {e}")))
    }

    /// Best-effort re-adoption after a restore scan: the case where the proof
    /// db was lost but the offer pointer survived.
    fn readopt_offer_if_lost(&self, wallet: &Wallet) {
        let Some(pointer) = self.read_offer_pointer() else {
            return;
        };
        match self
            .rt()
            .block_on(wallet.localstore.get_mint_quote(&pointer.quote_id))
        {
            Ok(Some(_)) => {}
            Ok(None) => {
                if let Err(e) = self.adopt_offer(wallet, &pointer) {
                    tracing::warn!(
                        "re-adopting offer quote {}: {e}",
                        quote_tag(&pointer.quote_id)
                    );
                }
            }
            Err(e) => tracing::warn!("reading offer quote {}: {e}", quote_tag(&pointer.quote_id)),
        }
    }

    /// Non-secret fingerprint of the account seed (domain-separated, so the
    /// marker never narrows a search for the seed itself).
    fn account_fingerprint(&self) -> String {
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        hasher.update(b"sonar-cashu-account-fingerprint-v1");
        hasher.update(&self.config.seed[..]);
        hex::encode(&hasher.finalize()[..8])
    }

    /// Bind a fresh store to this seed, or refuse to open one belonging to a
    /// different account.
    ///
    /// The initial claim is ATOMIC (`create_new` ⇒ `O_EXCL`): two processes
    /// with different seeds opening the same fresh dir would otherwise both
    /// see the marker missing and both write, letting the loser overwrite the
    /// winner's fingerprint — and once the winner's funds land, the loser's
    /// seed would pass this check and open somebody else's bearer proofs.
    /// Whoever loses the create race falls through to the compare path.
    fn check_account_binding(&self) -> Result<()> {
        use std::io::Write;
        let path = self.config.working_dir.join(ACCOUNT_MARKER);
        let db_path = self.config.working_dir.join(DB_FILE);
        let ours = self.account_fingerprint();

        // A crash while claiming a genuinely new directory can leave an
        // empty/partial marker but no proof database. There are no bearer
        // funds to misattribute yet, so remove only malformed claims and let
        // create_new retry. A complete different fingerprint still refuses.
        if path.exists() && !db_path.exists() {
            let existing = std::fs::read_to_string(&path).unwrap_or_default();
            if existing.trim().len() != ours.len() {
                std::fs::remove_file(&path).map_err(|e| {
                    WalletError::Backend(format!("remove partial {}: {e}", path.display()))
                })?;
            }
        }

        // An existing proof database with no marker is NOT ours to claim: a
        // database-only backup restore (or a lost sidecar) would otherwise be
        // adopted by whichever seed opened it first, handing one account's
        // bearer proofs to another. Only a genuinely new store self-claims;
        // adopting an existing one is an explicit, deliberate act.
        if !path.exists() && db_path.exists() {
            if std::env::var("SONAR_CASHU_ADOPT_UNBOUND_STORE").as_deref() != Ok("1") {
                return Err(WalletError::InvalidInput(format!(
                    "{} holds a wallet database with no account marker; refusing to adopt \
                     proofs that may belong to another account. If this store is yours, set \
                     SONAR_CASHU_ADOPT_UNBOUND_STORE=1 once to bind it to seed {ours}",
                    self.config.working_dir.display()
                )));
            }
            tracing::warn!(
                "adopting unbound store at {} for account {ours} (SONAR_CASHU_ADOPT_UNBOUND_STORE=1)",
                self.config.working_dir.display()
            );
        }

        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(mut file) => {
                // A partial claim (crash/ENOSPC mid-write) would leave a
                // marker nobody matches, bricking the directory — remove it so
                // the next attempt can claim cleanly.
                if let Err(e) = file
                    .write_all(ours.as_bytes())
                    .and_then(|_| file.sync_all())
                {
                    let _ = std::fs::remove_file(&path);
                    return Err(WalletError::Backend(format!("write account marker: {e}")));
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => {
                return Err(WalletError::Backend(format!(
                    "claim {}: {e}",
                    path.display()
                )))
            }
        }

        // Read back unconditionally: this is both the compare path for an
        // existing store and the confirmation that our own claim is the one
        // on disk.
        let existing = std::fs::read_to_string(&path)
            .map_err(|e| WalletError::Backend(format!("read {}: {e}", path.display())))?;
        if existing.trim() == ours {
            Ok(())
        } else {
            Err(WalletError::InvalidInput(format!(
                "{} belongs to a different account (store {}, seed {}); use a per-account working_dir",
                self.config.working_dir.display(),
                existing.trim(),
                ours
            )))
        }
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

    /// Build the CDK wallet; the flag reports whether a NUT-13 restore scan is
    /// owed (first run, post-wipe, a new device, a lost proof db, or an
    /// earlier scan that failed). The caller must then run it, or the trait's
    /// "fully recoverable with the seed" guarantee is a lie: for ecash the
    /// local store IS the funds.
    fn build_wallet(&self) -> Result<(Wallet, bool)> {
        let mint_url: cdk::mint_url::MintUrl = self
            .mint_url
            .parse()
            .map_err(|e| WalletError::InvalidInput(format!("mint url: {e}")))?;
        std::fs::create_dir_all(&self.config.working_dir)
            .map_err(|e| WalletError::Backend(format!("create working dir: {e}")))?;
        // Before touching the store: never open another account's proofs.
        self.check_account_binding()?;
        // Judge restore BEFORE opening: `WalletRedbDatabase::new` creates
        // cashu.redb, so asking afterwards can never see it missing, and a
        // surviving marker then skips NUT-13 forever over recoverable funds
        // (regressed once already, 33c5712f1).
        let marker = self.config.working_dir.join(self.restore_marker_name());
        let mut restore_owed =
            needs_nut13_restore(&self.config.working_dir, &self.restore_marker_name());
        if restore_owed && marker.exists() {
            // The proof db is gone but its marker survived. Drop the marker
            // now: if the restore below then fails, marker + (empty) db would
            // read as "restored" on every later connect.
            std::fs::remove_file(&marker).map_err(|e| {
                WalletError::Backend(format!("clear stale {}: {e}", marker.display()))
            })?;
        }
        let db_path = self.config.working_dir.join(DB_FILE);
        let localstore = match open_store(&db_path) {
            Ok(db) => db,
            Err(StoreOpenError::Other(e)) => return Err(e),
            Err(StoreOpenError::Unreadable(why)) => {
                // A damaged store used to fail every connect forever over
                // funds the seed can recover. Keep it for inspection, start
                // an empty one, and let NUT-13 below rebuild the funds.
                let aside = set_aside_unreadable_store(&db_path)?;
                tracing::warn!(
                    "proof store unreadable ({why}); moved to {} and rebuilt from the seed",
                    aside.display()
                );
                restore_owed = true;
                if marker.exists() {
                    std::fs::remove_file(&marker).map_err(|e| {
                        WalletError::Backend(format!("clear stale {}: {e}", marker.display()))
                    })?;
                }
                open_store(&db_path).map_err(|e| match e {
                    StoreOpenError::Other(e) => e,
                    StoreOpenError::Unreadable(why) => WalletError::Backend(format!(
                        "fresh store at {} is unreadable: {why}",
                        db_path.display()
                    )),
                })?
            }
        };
        // CDK's own client (or the test's fake mint), recording which melt
        // requests the mint never answered: see `connector`.
        let (inner, rebuild): (_, Option<connector::Rebuild>) = match &self.connector {
            Some(connector) => (connector.clone(), None),
            None => {
                let (url, store) = (mint_url.clone(), localstore.clone());
                (
                    connector::default_client(mint_url.clone(), localstore.clone()),
                    Some(Box::new(move || {
                        connector::default_client(url.clone(), store.clone())
                    })),
                )
            }
        };
        let client: Arc<dyn MintConnector + Send + Sync> = Arc::new(
            connector::RecordingConnector::new(inner, rebuild, self.reconciler.unanswered.clone()),
        );
        self.reconciler.set_mint(client.clone());
        let wallet = WalletBuilder::new()
            .mint_url(mint_url)
            .unit(CurrencyUnit::Sat)
            .localstore(localstore)
            .seed(self.seed64())
            .shared_client(client)
            .build()
            .map_err(|e| WalletError::Backend(format!("build wallet: {e}")))?;
        // cdk-redb creates `wallet_sagas` lazily, on the first saga WRITE,
        // but reads it unconditionally: on a store that has never minted or
        // melted, `finalize_pending_melts` and `recover_incomplete_sagas`
        // fail with "Table 'wallet_sagas' does not exist", so every sync
        // reported failure until the first payment. Deleting a saga that
        // cannot exist opens the table in a write txn, which creates it.
        self.rt()
            .block_on(wallet.localstore.delete_saga(&uuid::Uuid::nil()))
            .map_err(|e| WalletError::Backend(format!("prepare saga table: {e}")))?;
        Ok((wallet, restore_owed))
    }

    /// The outcome of an OUTGOING payment the history no longer (or never)
    /// shows: a melt that confirmed ambiguously and was then rolled back
    /// leaves no transaction, so a host settling a stuck "pending" row by id
    /// would wait forever. Asks the mint (bounded) about the local melt quote
    /// with this id. `None` when no such melt quote is stored.
    ///
    /// The mint's answer only counts for a melt CLOSED here. This resumes
    /// the melt's open saga (CDK finalizes or compensates it, or leaves it
    /// open), unless a running send is still confirming it, and reads the
    /// result: a saga still open, or an ambiguous confirm inside its grace
    /// window, is Pending. The stored quote was written before the confirm
    /// and still reads Unpaid, so an unreachable mint never turns it into
    /// Failed.
    pub fn outgoing_payment_outcome(&self, quote_id: &str) -> Result<Option<Payment>> {
        let wallet = self.wallet()?;
        let budget = self.budgets.mint_call;
        let reconciler = self.reconciler.clone();
        self.rt().block_on(async {
            let Some(local) = wallet
                .localstore
                .get_melt_quote(quote_id)
                .await
                .map_err(|e| WalletError::Backend(format!("read melt quote: {e}")))?
            else {
                return Ok(None);
            };
            let prepared = PreparedSend {
                destination: classify_destination(&local.request),
                amount_sats: u64::from(local.amount),
                fees_sats: Some(u64::from(local.fee_reserve)),
                expires_at_secs: (local.expiry != 0).then_some(local.expiry),
                token: PreparedSendToken::Opaque(local.id.clone()),
            };
            let pending = || Ok(Some(pending_payment(quote_id, &prepared, None)));
            // A send still preparing or confirming this quote reports it.
            if reconciler.is_unsettled(quote_id) || reconciler.is_sending(quote_id) {
                return pending();
            }
            // A running send reports its own melt; and unknown is not safe:
            // a store read that fails counts as open.
            match open_melt_sagas(&wallet, quote_id).await {
                Ok(ids) if !ids.iter().any(|id| reconciler.is_confirming(*id)) => {}
                _ => return pending(),
            }
            let checked = bounded(budget, wallet.check_melt_quote_status(quote_id)).await;
            if !matches!(melt_quote_open(&wallet, quote_id).await, Ok(false)) {
                return pending();
            }
            let (state, preimage) = match checked {
                Ok(quote) => (quote.state, quote.payment_proof),
                Err(_) if local.state == MeltQuoteState::Paid => {
                    (MeltQuoteState::Paid, local.payment_proof)
                }
                Err(_) => (MeltQuoteState::Unknown, None),
            };
            Ok(Some(resolved_melt_payment(
                quote_id, &prepared, state, preimage, None,
            )))
        })
    }

    /// The published offer's pointer, for the host to keep off the device.
    /// Its quote id exists nowhere else, so without a copy a reinstall
    /// publishes a new offer and payments to the old one stay at the mint.
    /// `None` until an offer exists. The quote id reveals the offer's
    /// received amounts to anyone who asks the mint: keep it encrypted.
    pub fn offer_backup(&self) -> Option<String> {
        let pointer = self.read_offer_pointer()?;
        Some(
            serde_json::json!({
                "v": 1,
                "mint": self.mint_url,
                "quote_id": pointer.quote_id,
                "offer": pointer.offer,
                "index": pointer.index,
            })
            .to_string(),
        )
    }

    /// Bring backed-up offers back after a reinstall. The newest becomes the
    /// published offer when this store has none (a local offer is never
    /// replaced), and every backed-up quote the store does not hold is
    /// re-adopted, so payments made to any of them are still minted. Backups
    /// for another mint, or that do not parse, are skipped. Needs `connect`;
    /// returns how many quotes were adopted.
    pub fn restore_offer_backups(&self, backups: &[String]) -> Result<u32> {
        let wallet = self.wallet()?;
        let mut pointers: Vec<OfferPointer> = Vec::new();
        for pointer in backups
            .iter()
            .filter_map(|b| parse_offer_backup(b, &self.mint_url))
        {
            if !pointers.iter().any(|p| p.quote_id == pointer.quote_id) {
                pointers.push(pointer);
            }
        }
        let Some(newest) = pointers.iter().max_by_key(|p| p.index) else {
            return Ok(0);
        };
        let _creating = self.offer_lock.lock().unwrap_or_else(|e| e.into_inner());
        if self.read_offer_pointer().is_none() {
            self.write_offer_pointer(newest)?;
        }
        let mut adopted = 0;
        for pointer in &pointers {
            let held = self
                .rt()
                .block_on(wallet.localstore.get_mint_quote(&pointer.quote_id))
                .map_err(|e| WalletError::Backend(format!("read offer quote: {e}")))?;
            if held.is_some() {
                continue;
            }
            match self.adopt_offer(&wallet, pointer) {
                Ok(()) => adopted += 1,
                Err(e) => tracing::warn!(
                    "adopting backed-up offer {}: {e}",
                    quote_tag(&pointer.quote_id)
                ),
            }
        }
        Ok(adopted)
    }

    /// A one-time BOLT11 invoice, with the id its payment will arrive under
    /// (the mint quote id, see `incoming_payment_id`), so a host can tell
    /// THIS invoice being paid from any other receive, and stop showing a
    /// paid invoice as payable. Returns `(invoice, payment_id)`.
    pub fn receive_bolt11(
        &self,
        amount_sats: u64,
        description: Option<String>,
    ) -> Result<(String, String)> {
        let quote = self.create_mint_quote(&ReceiveRequest {
            method: ReceiveMethod::Bolt11Invoice,
            amount_sats: Some(amount_sats),
            description,
        })?;
        Ok((quote.request, quote.id))
    }

    /// Ask the mint for a receive quote. An amountless BOLT12 offer is the
    /// normal receive primitive and carries no fixed amount; only a BOLT11
    /// invoice needs one.
    fn create_mint_quote(&self, request: &ReceiveRequest) -> Result<cdk::wallet::types::MintQuote> {
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
        self.rt().block_on(bounded(
            self.budgets.mint_call,
            wallet.mint_quote(
                method,
                request.amount_sats.map(Amount::from),
                request.description.clone(),
                None,
            ),
        ))
    }

    /// One pass of the pending-mint-quote watcher (best-effort: errors are
    /// logged and retried next tick, since the watcher must outlive transient
    /// mint hiccups).
    async fn poll_mint_quotes(
        wallet: &Wallet,
        events: &mpsc::Sender<WalletEvent>,
        budgets: Budgets,
        reconciler: &Reconciler,
    ) -> usize {
        match Self::poll_mint_quotes_strict(wallet, events, budgets, reconciler).await {
            Ok(minted) => minted,
            Err(e) => {
                tracing::warn!("mint-quote poll failed: {e}");
                0
            }
        }
    }

    /// Strict variant for explicit `sync_wallet`: the push-wake contract is
    /// "reconcile NOW or say you could not" — returning Ok over a failed poll
    /// would tell a host no retry is needed while an incoming payment sits
    /// unreconciled.
    async fn poll_mint_quotes_strict(
        wallet: &Wallet,
        events: &mpsc::Sender<WalletEvent>,
        budgets: Budgets,
        reconciler: &Reconciler,
    ) -> Result<usize> {
        // One pass at a time (the watcher tick vs a host's sync_wallet): the
        // status check that resumes a quote's open issue saga must never
        // meet another pass's mint of that quote still in flight.
        let _pass = reconciler.pass.lock().await;
        // The incoming (mint) and outgoing (melt) sides are reconciled
        // INDEPENDENTLY and their errors aggregated afterwards: a single
        // stale mint quote must not block finalizing an otherwise healthy
        // delayed melt on every pass, or its reserved proofs stay reserved
        // for as long as the bad quote exists.
        let mut errors: Vec<String> = Vec::new();
        let minted = match Self::reconcile_mint_quotes(wallet, events, budgets.mint_call).await {
            Ok(n) => n,
            Err(e) => {
                errors.push(e.to_string());
                0
            }
        };
        let settled = match Self::reconcile_pending_melts(
            wallet,
            events,
            budgets.mint_call,
            reconciler,
        )
        .await
        {
            Ok(n) => n,
            Err(e) => {
                errors.push(e.to_string());
                0
            }
        };
        let resolved = match Self::settle_unsettled_melts(wallet, events, budgets, reconciler).await
        {
            Ok(n) => n,
            Err(e) => {
                errors.push(e.to_string());
                0
            }
        };
        let changed = minted + settled + resolved;
        if changed > 0 {
            let _ = events.send(WalletEvent::Synced);
        }
        if errors.is_empty() {
            Ok(changed)
        } else {
            Err(WalletError::Network(errors.join("; ")))
        }
    }

    /// Ambiguous melts CDK had already closed when their confirm returned
    /// (see `settle_ambiguous_confirm`): the mint decides. An Unpaid answer is
    /// doubted for the grace window, and after it believed only once the
    /// melt's inputs are spent (see `retire_melt_inputs`), so a request that
    /// reaches the mint later still cannot be paid.
    async fn settle_unsettled_melts(
        wallet: &Wallet,
        events: &mpsc::Sender<WalletEvent>,
        budgets: Budgets,
        reconciler: &Reconciler,
    ) -> Result<usize> {
        let tracked = reconciler.unsettled_snapshot();
        if tracked.is_empty() {
            return Ok(0);
        }
        let mut settled = 0;
        let mut errors: Vec<String> = Vec::new();
        for (quote_id, melt) in tracked {
            let mut quote =
                match bounded(budgets.mint_call, wallet.check_melt_quote_status(&quote_id)).await {
                    Ok(quote) => quote,
                    Err(e) => {
                        errors.push(format!("melt {}: {e}", quote_tag(&quote_id)));
                        continue;
                    }
                };
            let state = quote.state;
            let status = match state {
                MeltQuoteState::Paid => PaymentStatus::Complete,
                MeltQuoteState::Failed => PaymentStatus::Failed,
                MeltQuoteState::Unpaid if melt.grace_over(budgets.melt_grace) => {
                    // The proofs must be ours again, not merely the saga gone.
                    if !matches!(
                        melt_operation_open(wallet, melt.operation_id).await,
                        Ok(false)
                    ) {
                        continue;
                    }
                    match retire_melt_inputs(wallet, reconciler, melt.operation_id, budgets).await {
                        Ok(InputsRetired::Spent) => {}
                        Ok(InputsRetired::NotYet) => continue,
                        Ok(InputsRetired::Unknown) => {
                            tracing::warn!(
                                "melt {}: inputs unknown (no history row); believing Unpaid \
                                 after the grace window",
                                quote_tag(&quote_id)
                            );
                        }
                        Err(e) => {
                            errors.push(format!("melt {}: {e}", quote_tag(&quote_id)));
                            continue;
                        }
                    }
                    // Read after the inputs were seen spent. A melt that spent
                    // them reads Pending or Paid from then on, so Unpaid now
                    // means its request can never be paid.
                    quote =
                        match bounded(budgets.mint_call, wallet.check_melt_quote_status(&quote_id))
                            .await
                        {
                            Ok(quote) => quote,
                            Err(e) => {
                                errors.push(format!("melt {}: {e}", quote_tag(&quote_id)));
                                continue;
                            }
                        };
                    match quote.state {
                        MeltQuoteState::Paid => PaymentStatus::Complete,
                        MeltQuoteState::Unpaid | MeltQuoteState::Failed => PaymentStatus::Failed,
                        _ => continue,
                    }
                }
                _ => continue,
            };
            if status == PaymentStatus::Complete {
                account_late_melt(wallet, &quote_id, quote.payment_proof.clone(), budgets).await;
            }
            reconciler.forget_unsettled(&quote_id);
            settled += 1;
            let payment = Payment {
                status,
                preimage: quote.payment_proof.clone(),
                ..pending_payment(&quote_id, &melt.prepared, melt.note.clone())
            };
            tracing::info!(
                "ambiguous melt {} settled {:?}",
                quote_tag(&quote_id),
                payment.status
            );
            let _ = events.send(payment_event(payment));
        }
        if errors.is_empty() {
            Ok(settled)
        } else {
            Err(WalletError::Network(errors.join("; ")))
        }
    }

    /// Incoming side: mint proofs for paid quotes.
    ///
    /// Walks every UNISSUED quote, not CDK's "active" list: that one keeps
    /// only `expiry > now`, and BOLT12 quotes carry no expiry (stored as 0),
    /// so a paid offer was never minted — and an invoice paid while the app
    /// slept past its expiry was stranded the same way. Minting keys on
    /// `amount_mintable()` because a reusable BOLT12 quote goes Issued and
    /// then Paid again with every new payment.
    async fn reconcile_mint_quotes(
        wallet: &Wallet,
        events: &mpsc::Sender<WalletEvent>,
        budget: Duration,
    ) -> Result<usize> {
        let mut minted = 0;
        let quotes = wallet
            .get_unissued_mint_quotes()
            .await
            .map_err(|e| WalletError::Network(format!("list mint quotes: {e}")))?;
        let now = now_secs();
        // Per-quote errors are isolated: one stale or pruned quote must not
        // stop every later quote from minting, now or on any future pass.
        let mut errors: Vec<String> = Vec::new();
        for quote in quotes {
            // A mint call that ran out of time (the mint may have signed
            // after we gave up) leaves the quote's issue saga open. CDK's
            // status check below resumes it and stores the proofs, but the
            // quote then reads issued, so nothing below announced them: the
            // host saw no receive and no balance change until it asked.
            let open_issue = open_issue_saga(wallet, &quote).await;
            let updated = match bounded(budget, wallet.check_mint_quote_status(&quote.id)).await {
                Ok(updated) => updated,
                Err(e) => {
                    errors.push(format!("quote {}: {e}", quote.id));
                    continue;
                }
            };
            if let Some(saga_id) = open_issue {
                if let Some(payment) = completed_issue_payment(wallet, saga_id, &updated).await {
                    tracing::info!(
                        "issue {saga_id} recovered for quote {}",
                        quote_tag(&updated.id)
                    );
                    minted += 1;
                    let _ = events.send(WalletEvent::PaymentReceived { payment });
                }
            }
            if updated.amount_mintable() == Amount::ZERO {
                if is_abandoned_invoice(&updated, now) {
                    // An unpaid invoice well past its expiry can never be
                    // paid; stop polling it on every pass forever.
                    if let Err(e) = wallet.localstore.remove_mint_quote(&updated.id).await {
                        tracing::warn!("prune expired mint quote {}: {e}", quote_tag(&updated.id));
                    }
                }
                continue;
            }
            match bounded(budget, wallet.mint(&quote.id, SplitTarget::default(), None)).await {
                Ok(proofs) => {
                    minted += 1;
                    let amount_sats = proofs.iter().map(|p| u64::from(p.amount)).sum::<u64>();
                    let id = incoming_payment_id(
                        &updated.id,
                        &updated.payment_method,
                        TransactionId::from_proofs(proofs.clone()).ok(),
                    );
                    let _ = events.send(WalletEvent::PaymentReceived {
                        payment: Payment {
                            id,
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
                    errors.push(format!("minting paid quote {}: {e}", quote.id));
                }
            }
        }
        if errors.is_empty() {
            Ok(minted)
        } else if minted > 0 {
            Err(WalletError::Network(format!(
                "minted {minted}, but: {}",
                errors.join("; ")
            )))
        } else {
            Err(WalletError::Network(errors.join("; ")))
        }
    }

    /// Outgoing side: a melt that confirmed as Pending (delayed Lightning
    /// payment, or a restart mid-send) is finalized here — otherwise the
    /// backend never learns its outcome and reserved proofs stay reserved
    /// indefinitely.
    ///
    /// Saga by saga, never CDK's `finalize_pending_melts`: that resumes every
    /// open melt, including one whose confirm a send is still awaiting. The
    /// mint reads such a melt Unpaid until it starts on the request, so CDK
    /// compensated the proofs of a payment the mint then made. A melt whose
    /// confirm is still running here is skipped; its send reports it.
    async fn reconcile_pending_melts(
        wallet: &Wallet,
        events: &mpsc::Sender<WalletEvent>,
        budget: Duration,
        reconciler: &Reconciler,
    ) -> Result<usize> {
        // This runs every watcher tick. With no melt in flight there is
        // nothing to finalize, so skip the full-history transaction read
        // below: the incomplete-saga table is tiny, the history is not.
        let open: Vec<(uuid::Uuid, String)> = wallet
            .localstore
            .get_incomplete_sagas()
            .await
            .map_err(|e| WalletError::Backend(format!("list sagas: {e}")))?
            .into_iter()
            .filter(|s| {
                s.mint_url == wallet.mint_url
                    && s.unit == wallet.unit
                    && matches!(
                        s.state,
                        WalletSagaState::Melt(
                            MeltSagaState::MeltRequested | MeltSagaState::PaymentPending
                        )
                    )
                    && !reconciler.is_confirming(s.id)
            })
            .filter_map(|s| match s.data {
                cdk::wallet::types::OperationData::Melt(data) => Some((s.id, data.quote_id)),
                _ => None,
            })
            .collect();
        if open.is_empty() {
            return Ok(0);
        }
        // Notes are read BEFORE finalizing, and a lookup failure aborts the
        // pass. Order matters: finalizing makes a melt terminal, so a later
        // pass may never return it again — swallowing the error here (it was
        // `unwrap_or_default`) would emit a note-less terminal event under
        // the same payment id, permanently overwriting the row the initial
        // send wrote, while still reporting the sync as successful. Failing
        // first keeps the whole thing retryable.
        let history = wallet
            .list_transactions(Some(TransactionDirection::Outgoing))
            .await
            .map_err(|e| WalletError::Backend(format!("list transactions: {e}")))?;
        let note_for = |quote_id: &str| {
            history
                .iter()
                .filter(|tx| tx.quote_id.as_deref() == Some(quote_id))
                .find_map(|tx| tx_note(tx.memo.as_ref(), &tx.metadata))
        };
        let mut settled = 0;
        let mut errors: Vec<String> = Vec::new();
        for (saga_id, quote_id) in open {
            // Resumes THIS saga: CDK finalizes it (Paid), compensates it
            // (Unpaid or Failed with no payment proof), or leaves it open.
            let quote = match bounded(budget, wallet.check_melt_quote_status(&quote_id)).await {
                Ok(quote) => quote,
                Err(e) => {
                    errors.push(format!("melt {}: {e}", quote_tag(&quote_id)));
                    continue;
                }
            };
            let still_open = wallet
                .localstore
                .get_saga(&saga_id)
                .await
                .map_err(|e| WalletError::Backend(format!("read saga: {e}")))?
                .is_some();
            if still_open {
                continue;
            }
            let status = match quote.state {
                MeltQuoteState::Paid => PaymentStatus::Complete,
                // CDK reports a melt the mint gave up on — and whose proofs
                // it has just compensated back into the wallet — as UNPAID.
                // Skipping it as "still in flight" left the app showing money
                // in flight forever, with no event to refresh the balance.
                MeltQuoteState::Failed | MeltQuoteState::Unpaid => PaymentStatus::Failed,
                MeltQuoteState::Pending | MeltQuoteState::Unknown => continue,
            };
            let fee_paid = match status {
                PaymentStatus::Complete => wallet
                    .list_transactions(Some(TransactionDirection::Outgoing))
                    .await
                    .ok()
                    .and_then(|rows| {
                        rows.into_iter()
                            .find(|tx| tx.saga_id == Some(saga_id))
                            .map(|tx| u64::from(tx.fee))
                    })
                    .unwrap_or(u64::from(quote.fee_reserve)),
                _ => 0,
            };
            settled += 1;
            let payment = Payment {
                id: quote_id.clone(),
                amount_sats: u64::from(quote.amount),
                fees_sats: Some(fee_paid),
                incoming: false,
                timestamp_secs: now_secs(),
                status,
                preimage: quote.payment_proof.clone(),
                note: note_for(&quote_id),
            };
            let _ = events.send(payment_event(payment));
        }
        if errors.is_empty() {
            Ok(settled)
        } else {
            Err(WalletError::Network(errors.join("; ")))
        }
    }
}

/// Fill in the amount a BOLT11 invoice itself encodes, when classification
/// left it empty. Round sub-sat amounts UP: the figure is shown to the user
/// and must never understate what will be paid. Leaves every other kind (and
/// undecodable input — the mint gives the authoritative verdict) untouched.
fn refine_bolt11_amount(destination: Destination) -> Destination {
    if destination.kind != DestinationKind::Bolt11 || destination.amount_sats.is_some() {
        return destination;
    }
    match bolt11_msat(&destination.raw) {
        Some(msat) => Destination {
            amount_sats: Some(msat.div_ceil(1_000)),
            ..destination
        },
        None => destination,
    }
}

/// The msat amount a BOLT11 invoice encodes, if it decodes and has one.
fn bolt11_msat(raw: &str) -> Option<u64> {
    use std::str::FromStr;
    lightning_invoice::Bolt11Invoice::from_str(raw)
        .ok()?
        .amount_milli_satoshis()
}

/// Whether the mint's quote agrees with the amount we confirmed. Exact,
/// except for a sub-sat BOLT11 invoice: its msat amount has two honest sat
/// figures (we round up for display, CDK mints floor), and either rounding
/// of the invoice's OWN amount is the same payment.
fn quote_agrees(quoted: u64, confirmed: u64, invoice_msat: Option<u64>) -> bool {
    if quoted == confirmed {
        return true;
    }
    match invoice_msat {
        Some(msat) if msat % 1_000 != 0 => {
            let honest = [msat / 1_000, msat.div_ceil(1_000)];
            honest.contains(&quoted) && honest.contains(&confirmed)
        }
        _ => false,
    }
}

/// The caller's note, wherever CDK persisted it: `send()` writes it into
/// `prepare_melt` metadata under "memo", while some paths surface it as the
/// transaction memo — history and delayed finalization must read both or a
/// restart erases notes.
fn tx_note(memo: Option<&String>, metadata: &HashMap<String, String>) -> Option<String> {
    memo.cloned().or_else(|| metadata.get("memo").cloned())
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Deadlines for mint I/O. A mint that accepts the connection and then never
/// answers must not stall the caller (or the watcher) indefinitely.
#[derive(Debug, Clone, Copy)]
struct Budgets {
    /// One round-trip: mint info, a quote, a status check, one mint.
    mint_call: Duration,
    /// A whole NUT-13 restore scan (many batched round-trips).
    restore: Duration,
    /// Recovering sagas a crash interrupted.
    recovery: Duration,
    /// How long `send` waits before reporting the melt Pending (or, if it
    /// never reached the irreversible step, Timeout).
    send: Duration,
    /// How long a melt whose confirm was ambiguous, and which CDK then
    /// compensated because the mint read it Unpaid, stays Pending before it
    /// is called Failed. Unpaid is also what a mint reports before it has
    /// started on a melt request still on its way, so it is only believed
    /// once that request can no longer be arriving.
    melt_grace: Duration,
    /// The least lifetime a melt quote must have left for `send` to start
    /// on it. Before the melt request reaches the mint the wallet still
    /// selects proofs (local), may refresh keyset metadata (one mint call)
    /// and may swap first (one mint call); a quote that expires on the way
    /// is refused by the mint. Less than this left, `send` answers
    /// `QuoteExpired` at once — nothing sent — and the caller re-quotes.
    melt_ttl_floor: Duration,
    /// The least lifetime left when a prepared melt is confirmed: the swap
    /// and the melt request are still to go. A preparation that finishes
    /// later is cancelled — no melt request was made — instead of confirmed
    /// into a quote about to expire.
    confirm_ttl_floor: Duration,
    /// How long keysets read from the mint before a melt are trusted (see
    /// [`warm_keysets`]).
    keyset_refresh: Duration,
}

impl Budgets {
    const DEFAULT: Self = Self {
        mint_call: Duration::from_secs(15),
        restore: Duration::from_secs(120),
        recovery: Duration::from_secs(30),
        send: Duration::from_secs(60),
        melt_grace: Duration::from_secs(60),
        // Two mint calls at `mint_call` (15 s) would be 30 s, but a mint that
        // slow fails the call on its own; 20 s covers the healthy path with
        // a wide margin and leaves 100 s of a 120 s production quote usable.
        melt_ttl_floor: Duration::from_secs(20),
        // The swap and the melt request: two healthy round trips with slack.
        confirm_ttl_floor: Duration::from_secs(10),
        // A fee preview and the send that follows it share one read.
        keyset_refresh: Duration::from_secs(60),
    };
}

/// Short per-mint tag for a store's per-mint files (`<prefix>.<hash8>`).
fn mint_tag(mint_url: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(mint_url.as_bytes());
    hex::encode(&digest[..4])
}

/// Reconciliation state the watcher, `sync_wallet` and `send` share.
struct Reconciler {
    /// One reconcile pass at a time.
    pass: tokio::sync::Mutex<()>,
    /// Ambiguous melts CDK had already closed when their confirm returned,
    /// by quote id, until the watcher settles them. Mirrored to `journal`.
    unsettled: Mutex<HashMap<String, UnsettledMelt>>,
    /// Where `unsettled` survives a relaunch; `None` in unit tests.
    journal: Option<std::path::PathBuf>,
    /// Melt requests the mint never answered, recorded by the connector.
    unanswered: Arc<connector::UnansweredMelts>,
    /// Melt operations whose confirm a send task is awaiting right now.
    confirming: Mutex<std::collections::HashSet<uuid::Uuid>>,
    /// Melt quotes a send task owns, from before its preparation until it
    /// ends: a lookup must not resume (and compensate) a melt the task is
    /// still preparing.
    sending: Mutex<std::collections::HashSet<String>>,
    /// Serializes melt preparations — `send`'s and `prepare_send`'s dry run
    /// — with each other and with balance reads, so a dry run's short-lived
    /// reservation is never seen as money leaving.
    prepare: tokio::sync::Mutex<()>,
    /// When a melt last read keysets from the mint (see [`warm_keysets`]).
    keysets_read: Mutex<Option<Instant>>,
    /// The connector the current wallet talks through, for the one mint call
    /// CDK's wallet does not offer: proof states by Y, for proofs the local
    /// store no longer holds. Set on every build.
    mint: Mutex<Option<Arc<dyn MintConnector + Send + Sync>>>,
}

impl Default for Reconciler {
    fn default() -> Self {
        Self {
            pass: tokio::sync::Mutex::new(()),
            unsettled: Mutex::new(HashMap::new()),
            journal: None,
            unanswered: Arc::new(connector::UnansweredMelts::default()),
            confirming: Mutex::new(std::collections::HashSet::new()),
            sending: Mutex::new(std::collections::HashSet::new()),
            prepare: tokio::sync::Mutex::new(()),
            keysets_read: Mutex::new(None),
            mint: Mutex::new(None),
        }
    }
}

/// Marks a melt quote as owned by a running send until dropped.
struct Sending {
    reconciler: Arc<Reconciler>,
    quote_id: String,
}

impl Drop for Sending {
    fn drop(&mut self) {
        self.reconciler
            .sending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.quote_id);
    }
}

/// Marks a melt operation as being confirmed until dropped.
struct Confirming<'a> {
    reconciler: &'a Reconciler,
    operation_id: uuid::Uuid,
}

impl Drop for Confirming<'_> {
    fn drop(&mut self) {
        self.reconciler
            .confirming
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.operation_id);
    }
}

impl Reconciler {
    /// A reconciler whose ambiguous melts are loaded from, and kept in,
    /// `journal`. An unreadable journal reads as empty (logged): the melts it
    /// held then settle through history and lookups, as before it existed.
    fn with_journal(journal: std::path::PathBuf) -> Self {
        let loaded = match std::fs::read(&journal) {
            Ok(raw) => serde_json::from_slice::<Vec<serde_json::Value>>(&raw)
                .map(|entries| {
                    entries
                        .iter()
                        .filter_map(UnsettledMelt::from_json)
                        .collect::<HashMap<_, _>>()
                })
                .unwrap_or_else(|e| {
                    tracing::warn!("unreadable {}: {e}", journal.display());
                    HashMap::new()
                }),
            Err(_) => HashMap::new(),
        };
        Self {
            unsettled: Mutex::new(loaded),
            journal: Some(journal),
            ..Self::default()
        }
    }

    fn unsettled(&self) -> std::sync::MutexGuard<'_, HashMap<String, UnsettledMelt>> {
        self.unsettled.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn set_mint(&self, mint: Arc<dyn MintConnector + Send + Sync>) {
        *self.mint.lock().unwrap_or_else(|e| e.into_inner()) = Some(mint);
    }

    fn mint(&self) -> Option<Arc<dyn MintConnector + Send + Sync>> {
        self.mint.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn is_unsettled(&self, quote_id: &str) -> bool {
        self.unsettled().contains_key(quote_id)
    }

    fn track_unsettled(&self, quote_id: &str, melt: UnsettledMelt) {
        let mut map = self.unsettled();
        map.insert(quote_id.to_string(), melt);
        self.save_journal(&map);
    }

    fn forget_unsettled(&self, quote_id: &str) {
        let mut map = self.unsettled();
        if map.remove(quote_id).is_some() {
            self.save_journal(&map);
        }
    }

    /// Atomic, best-effort (logged): the in-memory set still works for this
    /// process if the write fails.
    fn save_journal(&self, map: &HashMap<String, UnsettledMelt>) {
        use std::io::Write;
        let Some(path) = &self.journal else { return };
        let write = || -> std::io::Result<()> {
            if map.is_empty() {
                return match std::fs::remove_file(path) {
                    Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
                    _ => Ok(()),
                };
            }
            let body =
                serde_json::Value::Array(map.iter().map(|(id, melt)| melt.to_json(id)).collect())
                    .to_string();
            let tmp = path.with_extension(format!(
                "{}.tmp",
                path.extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or_default()
            ));
            let mut file = std::fs::File::create(&tmp)?;
            file.write_all(body.as_bytes())?;
            file.sync_all()?;
            std::fs::rename(&tmp, path)
        };
        if let Err(e) = write() {
            tracing::warn!("write {}: {e}", path.display());
        }
    }

    fn confirming(&self, operation_id: uuid::Uuid) -> Confirming<'_> {
        self.confirming
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(operation_id);
        Confirming {
            reconciler: self,
            operation_id,
        }
    }

    fn sending(self: &Arc<Self>, quote_id: &str) -> Sending {
        self.sending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(quote_id.to_string());
        Sending {
            reconciler: self.clone(),
            quote_id: quote_id.to_string(),
        }
    }

    fn is_sending(&self, quote_id: &str) -> bool {
        self.sending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains(quote_id)
    }

    fn is_confirming(&self, operation_id: uuid::Uuid) -> bool {
        self.confirming
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains(&operation_id)
    }

    fn unsettled_snapshot(&self) -> Vec<(String, UnsettledMelt)> {
        self.unsettled()
            .iter()
            .map(|(id, melt)| (id.clone(), melt.clone()))
            .collect()
    }
}

/// A melt whose confirm ended ambiguously after CDK had closed its saga.
#[derive(Clone)]
struct UnsettledMelt {
    operation_id: uuid::Uuid,
    prepared: PreparedSend,
    note: Option<String>,
    /// Wall clock, so the grace window survives a relaunch.
    since_ms: u64,
}

impl UnsettledMelt {
    fn to_json(&self, quote_id: &str) -> serde_json::Value {
        serde_json::json!({
            "quote_id": quote_id,
            "operation_id": self.operation_id.to_string(),
            "request": self.prepared.destination.raw,
            "amount_sats": self.prepared.amount_sats,
            "fees_sats": self.prepared.fees_sats,
            "note": self.note,
            "since_ms": self.since_ms,
        })
    }

    fn from_json(value: &serde_json::Value) -> Option<(String, Self)> {
        let quote_id = value.get("quote_id")?.as_str()?.to_string();
        let melt = Self {
            operation_id: uuid::Uuid::parse_str(value.get("operation_id")?.as_str()?).ok()?,
            prepared: PreparedSend {
                destination: classify_destination(value.get("request")?.as_str()?),
                amount_sats: value.get("amount_sats")?.as_u64()?,
                fees_sats: value.get("fees_sats").and_then(|v| v.as_u64()),
                expires_at_secs: None,
                token: PreparedSendToken::Opaque(quote_id.clone()),
            },
            note: value
                .get("note")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            since_ms: value.get("since_ms")?.as_u64()?,
        };
        Some((quote_id, melt))
    }

    /// The grace window has passed.
    fn grace_over(&self, grace: Duration) -> bool {
        now_ms().saturating_sub(self.since_ms)
            >= u64::try_from(grace.as_millis()).unwrap_or(u64::MAX)
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or(0)
}

/// How long past its expiry an unpaid BOLT11 invoice is still checked before
/// it is dropped from the store. Generous: a payment in flight at expiry can
/// still settle at the mint for a while.
const ABANDONED_INVOICE_GRACE_SECS: u64 = 3_600;

/// Run one mint call under a deadline. Must be awaited inside the wallet's
/// runtime: the timer is created here, not by the caller, because creating a
/// tokio `Sleep` outside a runtime panics with "no reactor running".
async fn bounded<T>(
    budget: Duration,
    call: impl std::future::Future<Output = std::result::Result<T, cdk::Error>>,
) -> Result<T> {
    match tokio::time::timeout(budget, call).await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(e)) => Err(WalletError::Network(e.to_string())),
        Err(_) => Err(WalletError::Timeout),
    }
}

/// An unpaid BOLT11 invoice more than [`ABANDONED_INVOICE_GRACE_SECS`] past
/// its expiry. BOLT12 quotes (no expiry) and paid quotes never qualify.
fn is_abandoned_invoice(quote: &cdk::wallet::types::MintQuote, now: u64) -> bool {
    quote.payment_method == PaymentMethod::Known(KnownMethod::Bolt11)
        && quote.state == MintQuoteState::Unpaid
        && quote.amount_paid == Amount::ZERO
        && quote.expiry != 0
        && now > quote.expiry.saturating_add(ABANDONED_INVOICE_GRACE_SECS)
}

/// An [`CdkWallet::offer_backup`] made for `mint`, or `None`.
fn parse_offer_backup(raw: &str, mint: &str) -> Option<OfferPointer> {
    let value: serde_json::Value = serde_json::from_str(raw).ok()?;
    if value.get("v")?.as_u64()? != 1 {
        return None;
    }
    let same_mint =
        value.get("mint")?.as_str()?.trim_end_matches('/') == mint.trim_end_matches('/');
    let pointer = OfferPointer {
        quote_id: value.get("quote_id")?.as_str()?.to_string(),
        offer: value.get("offer")?.as_str()?.to_string(),
        index: u32::try_from(value.get("index")?.as_u64()?).ok()?,
    };
    (same_mint && !pointer.quote_id.is_empty() && !pointer.offer.is_empty()).then_some(pointer)
}

/// The published offer (see [`OFFER_POINTER_PREFIX`]).
#[derive(Debug, Clone, PartialEq, Eq)]
struct OfferPointer {
    quote_id: String,
    offer: String,
    /// Derivation index of the quote's NUT-20 key; bumped on rotation.
    index: u32,
}

/// Who reports a send's outcome, and whether the melt may still be
/// confirmed, once the caller stops waiting (see `send`). Every transition is
/// made under its lock, so the caller's decision and the task's never race.
#[derive(Default)]
struct SendHandoff {
    /// The caller returned and is no longer listening: the task reports the
    /// outcome as an event.
    caller_gone: bool,
    /// The caller reported the send as not made (`QuoteExpired`): the task
    /// must cancel instead of confirming, and reports nothing.
    abandoned: bool,
    /// The melt reached `confirm` — the irreversible step.
    confirming: bool,
    /// The task ended while the caller was still waiting: the caller joins
    /// it for the result (the task emitted nothing).
    finished: bool,
}

fn map_melt_error(e: cdk::Error) -> WalletError {
    match e {
        cdk::Error::InsufficientFunds => WalletError::InsufficientFunds,
        // CDK checks the stored expiry before it reserves anything.
        cdk::Error::ExpiredQuote(..) => WalletError::QuoteExpired,
        other => WalletError::Backend(other.to_string()),
    }
}

/// A melt quote id as logs show it: 8 hex digits of its SHA-256. It tells
/// quotes apart in one log, and someone holding the full id can match it,
/// but the log never hands out the id — and with it the mint-side record
/// (amount, invoice). Not a prefix: cdk-mintd's ids are UUIDv7, whose
/// leading digits are a timestamp every quote within about a minute shares,
/// so a quote and its re-quote logged the same (#666 QA).
pub(crate) fn quote_tag(quote_id: &str) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(&Sha256::digest(quote_id.as_bytes())[..4])
}

/// How long a quote expiring at `expiry` (unix seconds) has left.
fn ttl_left(expiry: u64) -> Duration {
    Duration::from_millis(expiry.saturating_mul(1_000).saturating_sub(now_ms()))
}

/// What paying a melt quote costs on top of its amount, priced by CDK's own
/// melt preparation — the proof selection the send itself will make.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct MeltPrice {
    /// The Lightning fee reserve; what the payment does not use comes back.
    fee_reserve: u64,
    /// NUT-02 input fee of the melt's own inputs.
    input_fee: u64,
    /// NUT-02 input fee of the pre-melt swap's inputs; zero without a swap.
    swap_fee: u64,
    /// No exact, fee-free set of proofs exists, so the selected proofs are
    /// swapped before the melt. (Proofs on a retired, fee-charging keyset
    /// are melted directly instead when CDK's selection would not pay for
    /// its own swap — see [`prepare_funded_melt`].)
    swap: bool,
    /// Proofs the melt (or its swap) spends.
    inputs: usize,
    /// The unreserved proofs cover the amount and every fee.
    affordable: bool,
}

impl MeltPrice {
    fn of(melt: &cdk::wallet::PreparedMelt<'_>) -> Self {
        Self {
            fee_reserve: u64::from(melt.quote().fee_reserve),
            input_fee: u64::from(melt.input_fee()),
            swap_fee: u64::from(melt.swap_fee()),
            swap: melt.requires_swap(),
            inputs: melt.proofs().len() + melt.proofs_to_swap().len(),
            affordable: true,
        }
    }

    /// The most the payment can cost on top of its amount.
    fn max_fee(&self) -> u64 {
        self.fee_reserve
            .saturating_add(self.input_fee)
            .saturating_add(self.swap_fee)
    }
}

/// Keysets as the mint has them now, read under a mint-call deadline before
/// a melt is priced or sent.
///
/// CDK keeps keysets for an hour and counts the ones it loads from its own
/// database as fresh, so after the mint rotates its keyset a melt would
/// still build its swap and change outputs on the retired one. Against
/// cdk-mintd 0.18.1 (#666 QA) the swap was refused, retried and paid, then
/// the melt was refused InactiveKeyset: the send failed after paying the
/// swap fee, and the swap's saga stayed open. Reading the keysets first
/// prevents that and keeps CDK's own preparation local, so a hung mint
/// fails here, under the deadline, instead of stalling a payment.
///
/// `fetch_mint_info` reads the mint (info and keysets) and reports a
/// failure, where `KeysetLoadPolicy::Refresh` would quietly fall back to the
/// cache. One read serves `keyset_refresh` (60 s), so a fee preview and the
/// send after it cost one round trip, not two.
async fn warm_keysets(wallet: &Wallet, reconciler: &Reconciler, budgets: Budgets) -> Result<()> {
    let fresh = reconciler
        .keysets_read
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .is_some_and(|at| at.elapsed() < budgets.keyset_refresh);
    if fresh {
        return Ok(());
    }
    bounded(budgets.mint_call, wallet.fetch_mint_info()).await?;
    *reconciler
        .keysets_read
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = Some(Instant::now());
    Ok(())
}

/// CDK 0.18.1's `MeltSaga::prepare` reserves the melt quote before it
/// selects proofs, and a saga has no `Drop` compensation: when the
/// selection fails (`InsufficientFunds`, a store error) the quote stays
/// reserved by an operation that never wrote a saga, and every later
/// preparation of it fails `QuoteAlreadyInUse`. Release such a reservation.
/// With no saga under its operation id nothing can be using the quote;
/// callers hold the reconciler's `prepare` lock, so no other preparation in
/// this wallet is between its reservation and its saga.
async fn release_orphaned_quote_reservation(wallet: &Wallet, quote_id: &str) {
    let Ok(Some(quote)) = wallet.localstore.get_melt_quote(quote_id).await else {
        return;
    };
    let Some(operation) = quote
        .used_by_operation
        .as_deref()
        .and_then(|id| uuid::Uuid::parse_str(id).ok())
    else {
        return;
    };
    if !matches!(wallet.localstore.get_saga(&operation).await, Ok(None)) {
        return;
    }
    match wallet.localstore.release_melt_quote(&operation).await {
        Ok(()) => tracing::info!(
            "melt {}: released the quote reservation a failed preparation left",
            quote_tag(quote_id)
        ),
        Err(e) => tracing::warn!(
            "melt {}: releasing an orphaned quote reservation: {e}",
            quote_tag(quote_id)
        ),
    }
}

/// Whether a prepared melt's inputs pay for it: the proofs it melts as they
/// are, plus what its swap yields after the swap's own fee, must cover the
/// amount, the fee reserve and the melt's input fee.
fn melt_is_funded(melt: &cdk::wallet::PreparedMelt<'_>) -> bool {
    use cdk::nuts::nut00::ProofsMethods;
    let total = |proofs: &cdk::nuts::Proofs| proofs.total_amount().map_or(0, u64::from);
    let available = total(melt.proofs())
        .saturating_add(total(melt.proofs_to_swap()).saturating_sub(u64::from(melt.swap_fee())));
    let owed = u64::from(melt.quote().amount)
        .saturating_add(u64::from(melt.quote().fee_reserve))
        .saturating_add(u64::from(melt.input_fee()));
    available >= owed
}

/// Prepare a melt CDK can actually confirm.
///
/// CDK 0.18.1's proof selection (`Wallet::select_proofs_with_derivation_
/// indices`) takes every proof on an INACTIVE keyset first, and when those
/// alone cover the amount it returns early — without the `include_fees`
/// step every other path runs. Proofs on a retired, fee-charging keyset
/// (mint.hedwig.sh keeps one at 1000 ppk) are then selected as if free:
/// `prepare_melt` succeeds, prices the swap's real fee, and the confirm's
/// swap cannot produce the amount — the payment fails before any melt
/// request, leaving an UNPAID quote at the mint. That is the 2026-10-13
/// incident. When the selection does not pay for itself, keep CDK's choice
/// (it retires the inactive proofs), top it up with the largest other
/// unspent proofs until it covers its own input fee, and melt it directly.
async fn prepare_funded_melt<'a>(
    wallet: &'a Wallet,
    quote_id: &str,
    metadata: HashMap<String, String>,
) -> std::result::Result<cdk::wallet::PreparedMelt<'a>, cdk::Error> {
    use cdk::nuts::nut00::ProofsMethods;
    let melt = wallet.prepare_melt(quote_id, metadata.clone()).await?;
    if melt_is_funded(&melt) {
        return Ok(melt);
    }
    let owed = melt
        .quote()
        .amount
        .checked_add(melt.quote().fee_reserve)
        .ok_or(cdk::Error::AmountOverflow)?;
    let mut picked: cdk::nuts::Proofs = melt
        .proofs()
        .iter()
        .chain(melt.proofs_to_swap())
        .cloned()
        .collect();
    tracing::warn!(
        "melt {}: CDK selected {} proofs that do not cover their own input fee (swap fee {}); \
         topping the selection up and melting it directly",
        quote_tag(quote_id),
        picked.len(),
        melt.swap_fee()
    );
    melt.cancel().await?;
    let mut rest: cdk::nuts::Proofs = wallet
        .get_unspent_proofs()
        .await?
        .into_iter()
        .filter(|p| !picked.contains(p))
        .collect();
    // Largest first: the fewest extra proofs, so the least extra fee.
    rest.sort_by_key(|p| std::cmp::Reverse(p.amount));
    let mut rest = rest.into_iter();
    loop {
        let fee = wallet.get_proofs_fee(&picked).await?.total;
        let needed = owed.checked_add(fee).ok_or(cdk::Error::AmountOverflow)?;
        if picked.total_amount()? >= needed {
            break;
        }
        match rest.next() {
            Some(proof) => picked.push(proof),
            None => return Err(cdk::Error::InsufficientFunds),
        }
    }
    wallet.prepare_melt_proofs(quote_id, picked, metadata).await
}

/// The price of a melt CDK cannot fund from the unreserved proofs: as if it
/// spent all of them, through a swap. That is what a caller's balance check
/// needs to refuse it with real figures, and what a "send max" subtracts.
async fn unfunded_melt_price(
    wallet: &Wallet,
    quote: &cdk::wallet::MeltQuote,
) -> std::result::Result<MeltPrice, cdk::Error> {
    let needed = quote
        .amount
        .checked_add(quote.fee_reserve)
        .ok_or(cdk::Error::AmountOverflow)?;
    let unspent = wallet.get_unspent_proofs().await?;
    let swap_fee = u64::from(wallet.get_proofs_fee(&unspent).await?.total);
    let active = wallet.active_keyset().await?;
    let amounts = wallet.get_keyset_fees_and_amounts_by_id(active.id).await?;
    let outputs = u64::try_from(needed.split(&amounts)?.len()).unwrap_or(u64::MAX);
    let input_fee = u64::from(wallet.get_keyset_count_fee(&active.id, outputs).await?);
    Ok(MeltPrice {
        fee_reserve: u64::from(quote.fee_reserve),
        input_fee,
        swap_fee,
        swap: true,
        inputs: unspent.len(),
        affordable: false,
    })
}

/// Price `quote` by running CDK's melt preparation dry: select and reserve
/// the proofs exactly as `send` will, read the fees, cancel. Nothing reaches
/// the mint, and the reservation lives only under the `prepare` lock.
async fn price_melt(
    wallet: &Wallet,
    reconciler: &Reconciler,
    budgets: Budgets,
    quote: &cdk::wallet::MeltQuote,
) -> Result<MeltPrice> {
    warm_keysets(wallet, reconciler, budgets).await?;
    let _prepare = reconciler.prepare.lock().await;
    match prepare_funded_melt(wallet, &quote.id, HashMap::new()).await {
        Ok(melt) => {
            let price = MeltPrice::of(&melt);
            if let Err(e) = melt.cancel().await {
                tracing::warn!("melt {}: cancelling the dry run: {e}", quote_tag(&quote.id));
            }
            Ok(price)
        }
        Err(cdk::Error::InsufficientFunds) => {
            release_orphaned_quote_reservation(wallet, &quote.id).await;
            unfunded_melt_price(wallet, quote)
                .await
                .map_err(|e| WalletError::Backend(format!("price melt: {e}")))
        }
        Err(e) => {
            release_orphaned_quote_reservation(wallet, &quote.id).await;
            Err(map_melt_error(e))
        }
    }
}

/// One `send`'s melt, run as its own task (see `CdkWallet::send`).
struct MeltJob {
    wallet: Arc<Wallet>,
    reconciler: Arc<Reconciler>,
    quote_id: String,
    prepared: PreparedSend,
    note: Option<String>,
    metadata: HashMap<String, String>,
    budgets: Budgets,
    /// The quote's stored expiry (unix seconds), when it has one.
    expiry: Option<u64>,
}

impl MeltJob {
    /// Prepare the melt, decide under the handoff lock whether it may still
    /// be confirmed, then confirm it. Every error is raised before confirm,
    /// with the melt cancelled: no melt request was made. From confirm on
    /// the result is always a payment, Pending when ambiguous.
    async fn run(
        &self,
        handoff: &Mutex<SendHandoff>,
        confirm_started: tokio::sync::oneshot::Sender<()>,
    ) -> Result<Payment> {
        let wallet = &*self.wallet;
        let reconciler = &*self.reconciler;
        let quote_id = &self.quote_id;
        let tag = quote_tag(quote_id);

        if let Err(e) = warm_keysets(wallet, reconciler, self.budgets).await {
            tracing::warn!("melt {tag}: keyset metadata unavailable, nothing sent: {e}");
            return Err(e);
        }
        let prepare = reconciler.prepare.lock().await;
        let started = Instant::now();
        let melt = match prepare_funded_melt(wallet, quote_id, self.metadata.clone()).await {
            Ok(melt) => melt,
            Err(e) => {
                tracing::warn!(
                    "melt {tag}: preparation failed after {} ms, nothing sent: {e}",
                    started.elapsed().as_millis()
                );
                release_orphaned_quote_reservation(wallet, quote_id).await;
                return Err(map_melt_error(e));
            }
        };
        let price = MeltPrice::of(&melt);
        tracing::info!(
            "melt {tag}: prepared in {} ms: {} input proofs, swap first: {}, fee up to {} \
             (reserve {} + input fee {} + swap fee {})",
            started.elapsed().as_millis(),
            price.inputs,
            price.swap,
            price.max_fee(),
            price.fee_reserve,
            price.input_fee,
            price.swap_fee,
        );
        let operation_id = melt.operation_id();
        // Until this task ends, the watcher leaves this melt to it.
        let _confirming = reconciler.confirming(operation_id);
        let refusal = {
            let mut h = handoff.lock().unwrap_or_else(|e| e.into_inner());
            let lifetime = self.expiry.map(ttl_left);
            if h.abandoned {
                Some(WalletError::QuoteExpired)
            } else if lifetime.is_some_and(|left| left < self.budgets.confirm_ttl_floor) {
                tracing::warn!(
                    "melt {tag}: {} s of quote left after preparing, under the {} s a confirm \
                     needs",
                    lifetime.unwrap_or_default().as_secs(),
                    self.budgets.confirm_ttl_floor.as_secs()
                );
                Some(WalletError::QuoteExpired)
            } else if self
                .prepared
                .fees_sats
                .is_some_and(|agreed| price.max_fee() > agreed)
            {
                // The fee the caller agreed to is a promise: proofs that
                // changed since the quote (or a costlier selection) must not
                // raise it silently.
                Some(WalletError::FeeChanged {
                    fees_sats: price.max_fee(),
                })
            } else {
                h.confirming = true;
                None
            }
        };
        if let Some(refusal) = refusal {
            tracing::warn!("melt {tag}: cancelled before confirm, nothing sent: {refusal}");
            if let Err(e) = melt.cancel().await {
                tracing::warn!("melt {tag}: cancel: {e}");
            }
            return Err(refusal);
        }
        drop(prepare);
        let _ = confirm_started.send(());
        // From here on the payment is reported with what it can really cost.
        let prepared = PreparedSend {
            fees_sats: Some(price.max_fee()),
            ..self.prepared.clone()
        };
        let note = self.note.clone();
        tracing::info!("melt {tag}: confirming (swap first: {})", price.swap);
        // Prefer async: a mint that accepts the payment and keeps routing it
        // answers Pending at once instead of holding the request open; the
        // watcher finalizes it.
        let outcome = melt.confirm_prefer_async().await;
        // Read (and forget) whether the melt request went unanswered: CDK
        // reports a lost answer the mint then reads as Unpaid as
        // PaymentFailed too, after compensating the proofs.
        let request_lost = reconciler.unanswered.take(quote_id);
        let payment = match outcome {
            // The mint itself said the payment failed; CDK has compensated
            // the proofs.
            Err(cdk::Error::PaymentFailed) if !request_lost => {
                melt_outcome_payment(quote_id, &prepared, outcome, note)
            }
            // Anything else may be a request the mint has, or will have,
            // applied. A Failed here that the melt later contradicts invites
            // a second payment, so only a melt proven closed locally and
            // settled at the mint is called Failed; the rest is Pending, and
            // the watcher reports how it ends. Never re-quoted: the request
            // may have reached the mint.
            Err(e) => {
                tracing::warn!(
                    "melt {tag}: confirm error (request lost: {request_lost}), checking the \
                     mint: {e}"
                );
                settle_ambiguous_confirm(
                    wallet,
                    reconciler,
                    quote_id,
                    operation_id,
                    &prepared,
                    note,
                    request_lost,
                    self.budgets,
                )
                .await
            }
            outcome => melt_outcome_payment(quote_id, &prepared, outcome, note),
        };
        tracing::info!("melt {tag}: confirm ended {:?}", payment.status);
        Ok(payment)
    }
}

/// A melt that is (or may still be) in flight, reported with the figures
/// the caller consented to.
fn pending_payment(quote_id: &str, prepared: &PreparedSend, note: Option<String>) -> Payment {
    Payment {
        id: quote_id.to_string(),
        amount_sats: prepared.amount_sats,
        fees_sats: prepared.fees_sats,
        incoming: false,
        timestamp_secs: now_secs(),
        status: PaymentStatus::Pending,
        preimage: None,
        note,
    }
}

/// The payment a melt confirmation produced. Only a mint that says the
/// payment FAILED is a failure; any other confirm error is ambiguous — the
/// melt may have reached the mint — so it is Pending, for the watcher (or
/// saga recovery) to settle, never an error that invites a second payment.
/// A mint that accepted the melt asynchronously is Pending as well; the
/// watcher's `finalize_pending_melts` emits its outcome.
fn melt_outcome_payment(
    quote_id: &str,
    prepared: &PreparedSend,
    outcome: std::result::Result<cdk::wallet::MeltOutcome<'_>, cdk::Error>,
    note: Option<String>,
) -> Payment {
    let finalized = match outcome {
        Ok(cdk::wallet::MeltOutcome::Paid(finalized)) => finalized,
        Ok(cdk::wallet::MeltOutcome::Pending(_)) => {
            return pending_payment(quote_id, prepared, note);
        }
        Err(cdk::Error::PaymentFailed) => {
            return Payment {
                status: PaymentStatus::Failed,
                ..pending_payment(quote_id, prepared, note)
            };
        }
        Err(e) => {
            tracing::warn!(
                "melt {} confirm is ambiguous, reporting Pending: {e}",
                quote_tag(quote_id)
            );
            return pending_payment(quote_id, prepared, note);
        }
    };
    Payment {
        id: quote_id.to_string(),
        amount_sats: u64::from(finalized.amount()),
        fees_sats: Some(u64::from(finalized.fee_paid())),
        incoming: false,
        timestamp_secs: now_secs(),
        status: match finalized.state() {
            MeltQuoteState::Paid => PaymentStatus::Complete,
            MeltQuoteState::Failed => PaymentStatus::Failed,
            MeltQuoteState::Pending | MeltQuoteState::Unpaid | MeltQuoteState::Unknown => {
                PaymentStatus::Pending
            }
        },
        preimage: finalized.payment_proof().map(str::to_string),
        note,
    }
}

/// The payment the mint reports for a melt that is CLOSED locally — its
/// saga gone and no proofs held under it, so CDK either finalized it or
/// compensated its inputs back into the wallet: Paid is complete; Unpaid or
/// Failed never left the wallet; anything else stays Pending. Callers check
/// closedness first ([`melt_quote_open`]); an open melt is Pending whatever
/// its quote says, because it can still be paid.
fn resolved_melt_payment(
    quote_id: &str,
    prepared: &PreparedSend,
    state: MeltQuoteState,
    preimage: Option<String>,
    note: Option<String>,
) -> Payment {
    let status = match state {
        MeltQuoteState::Paid => PaymentStatus::Complete,
        MeltQuoteState::Unpaid | MeltQuoteState::Failed => PaymentStatus::Failed,
        MeltQuoteState::Pending | MeltQuoteState::Unknown => PaymentStatus::Pending,
    };
    Payment {
        status,
        preimage,
        ..pending_payment(quote_id, prepared, note)
    }
}

/// The issue saga a mint quote is reserved by, when one is still open.
async fn open_issue_saga(
    wallet: &Wallet,
    quote: &cdk::wallet::types::MintQuote,
) -> Option<uuid::Uuid> {
    let operation_id = uuid::Uuid::parse_str(quote.used_by_operation.as_deref()?).ok()?;
    let saga = wallet.localstore.get_saga(&operation_id).await.ok()??;
    matches!(saga.state, WalletSagaState::Issue(_)).then_some(saga.id)
}

/// The receive an open issue saga turned into, once CDK completed it: the
/// saga is gone and its transaction is Completed. Same id, amount and
/// shape the history and a normal mint give the payment.
async fn completed_issue_payment(
    wallet: &Wallet,
    saga_id: uuid::Uuid,
    quote: &cdk::wallet::types::MintQuote,
) -> Option<Payment> {
    if wallet.localstore.get_saga(&saga_id).await.ok()?.is_some() {
        return None;
    }
    let tx = wallet
        .list_transactions(Some(TransactionDirection::Incoming))
        .await
        .ok()?
        .into_iter()
        .find(|tx| tx.saga_id == Some(saga_id) && tx.status == TransactionStatus::Completed)?;
    Some(Payment {
        id: incoming_payment_id(
            &quote.id,
            &quote.payment_method,
            Some(TransactionId::new(tx.ys.clone())),
        ),
        amount_sats: u64::from(tx.amount),
        fees_sats: Some(0),
        incoming: true,
        timestamp_secs: now_secs(),
        status: PaymentStatus::Complete,
        preimage: None,
        note: None,
    })
}

/// Whether the melt `operation_id` is still unresolved in the local store:
/// its saga is open, or proofs are still reserved or pending under it. CDK
/// closes a melt saga only by finalizing it (Paid) or by compensating it,
/// which puts its inputs back to Unspent.
async fn melt_operation_open(wallet: &Wallet, operation_id: uuid::Uuid) -> Result<bool> {
    let saga = wallet
        .localstore
        .get_saga(&operation_id)
        .await
        .map_err(|e| WalletError::Backend(format!("read saga: {e}")))?;
    if saga.is_some() {
        return Ok(true);
    }
    let held = wallet
        .localstore
        .get_proofs(
            Some(wallet.mint_url.clone()),
            Some(wallet.unit.clone()),
            Some(vec![State::Reserved, State::Pending, State::PendingSpent]),
            None,
        )
        .await
        .map_err(|e| WalletError::Backend(format!("read proofs: {e}")))?;
    Ok(held
        .iter()
        .any(|p| p.used_by_operation == Some(operation_id)))
}

/// The ids of open melt sagas naming `quote_id`.
async fn open_melt_sagas(wallet: &Wallet, quote_id: &str) -> Result<Vec<uuid::Uuid>> {
    let sagas = wallet
        .localstore
        .get_incomplete_sagas()
        .await
        .map_err(|e| WalletError::Backend(format!("list sagas: {e}")))?;
    Ok(sagas
        .iter()
        .filter(|s| {
            matches!(s.state, WalletSagaState::Melt(_)) && s.quote_id.as_deref() == Some(quote_id)
        })
        .map(|s| s.id)
        .collect())
}

/// [`melt_operation_open`] for a melt quote, whose operation id is only
/// known from an open saga naming it or from the quote's reservation.
async fn melt_quote_open(wallet: &Wallet, quote_id: &str) -> Result<bool> {
    if !open_melt_sagas(wallet, quote_id).await?.is_empty() {
        return Ok(true);
    }
    let reserved_by = wallet
        .localstore
        .get_melt_quote(quote_id)
        .await
        .map_err(|e| WalletError::Backend(format!("read melt quote: {e}")))?
        .and_then(|q| q.used_by_operation)
        .and_then(|op| uuid::Uuid::parse_str(&op).ok());
    match reserved_by {
        Some(operation_id) => melt_operation_open(wallet, operation_id).await,
        None => Ok(false),
    }
}

/// Whether a compensated melt's inputs are out of its request's reach.
#[derive(Debug, PartialEq)]
enum InputsRetired {
    /// Every input reads Spent at the mint.
    Spent,
    /// An input is still spendable, or held by another payment of ours.
    NotYet,
    /// The melt's history row is gone (a rebuilt store): inputs unknown.
    Unknown,
}

/// CDK compensated this melt, so its inputs are Unspent here again and the
/// mint has never seen them spent: a melt request still on its way would be
/// paid with them, over the Failed the grace window would call. Spend them
/// first, in a swap to ourselves (same balance, fresh proofs, less any input
/// fee): the mint refuses a melt whose inputs are spent. Inputs another
/// payment of ours already spent are out of reach the same way. The mint's
/// proof states decide, not the swap's result and not the local store,
/// which drops proofs once they are spent.
async fn retire_melt_inputs(
    wallet: &Wallet,
    reconciler: &Reconciler,
    operation_id: uuid::Uuid,
    budgets: Budgets,
) -> Result<InputsRetired> {
    let Some(mint) = reconciler.mint() else {
        return Ok(InputsRetired::NotYet);
    };
    // CDK records the melt's inputs (the proofs its request carries) on the
    // melt's history row, which compensation keeps and marks Failed.
    let ys = wallet
        .list_transactions(Some(TransactionDirection::Outgoing))
        .await
        .map_err(|e| WalletError::Backend(format!("read history: {e}")))?
        .into_iter()
        .find(|tx| tx.saga_id == Some(operation_id))
        .map(|tx| tx.ys)
        .unwrap_or_default();
    if ys.is_empty() {
        return Ok(InputsRetired::Unknown);
    }
    let free: cdk::nuts::Proofs = wallet
        .localstore
        .get_proofs_by_ys(ys.clone())
        .await
        .map_err(|e| WalletError::Backend(format!("read proofs: {e}")))?
        .into_iter()
        .filter(|p| p.state == State::Unspent && p.used_by_operation.is_none())
        .map(|p| p.proof)
        .collect();
    if !free.is_empty() {
        let swapped = wallet.swap(None, SplitTarget::default(), free, None, false, false);
        if let Err(e) = bounded(budgets.mint_call, swapped).await {
            // "Already spent" here is an answer too; the states below say.
            tracing::info!("melt {operation_id}: retiring its inputs: {e}");
        }
    }
    let states = bounded(
        budgets.mint_call,
        mint.post_check_state(cdk::nuts::CheckStateRequest { ys }),
    )
    .await?
    .states;
    Ok(
        if !states.is_empty() && states.iter().all(|s| s.state == State::Spent) {
            InputsRetired::Spent
        } else {
            InputsRetired::NotYet
        },
    )
}

/// A melt the mint paid after CDK had compensated it: its inputs were put
/// back to Unspent locally but are spent at the mint. Drop them from the
/// balance, and turn the history row CDK marked Failed into a Completed one
/// carrying the preimage. Best-effort (logged): a missed pass leaves the
/// proofs to fail their next spend, which also marks them spent. The melt's
/// change is not recovered here — its saga, which held the change outputs,
/// is gone — but it is derived from the seed, so a NUT-13 restore finds it.
async fn account_late_melt(
    wallet: &Wallet,
    quote_id: &str,
    preimage: Option<String>,
    budgets: Budgets,
) {
    match wallet.get_unspent_proofs().await {
        Ok(unspent) if !unspent.is_empty() => {
            if let Err(e) = bounded(budgets.mint_call, wallet.check_proofs_spent(unspent)).await {
                tracing::warn!(
                    "late melt {}: proof states not synced: {e}",
                    quote_tag(quote_id)
                );
            }
        }
        Ok(_) => {}
        Err(e) => tracing::warn!("late melt {}: read proofs: {e}", quote_tag(quote_id)),
    }
    let rows = match wallet
        .list_transactions(Some(TransactionDirection::Outgoing))
        .await
    {
        Ok(rows) => rows,
        Err(e) => {
            tracing::warn!("late melt {}: read history: {e}", quote_tag(quote_id));
            return;
        }
    };
    for mut tx in rows.into_iter().filter(|tx| {
        tx.quote_id.as_deref() == Some(quote_id) && tx.status == TransactionStatus::Failed
    }) {
        tx.status = TransactionStatus::Completed;
        if preimage.is_some() {
            tx.payment_proof = preimage.clone();
        }
        if let Err(e) = wallet.localstore.add_transaction(tx).await {
            tracing::warn!(
                "late melt {}: history row not updated: {e}",
                quote_tag(quote_id)
            );
        }
    }
}

/// A confirm that did not end in the mint declaring the payment failed:
/// any other error, or `PaymentFailed` over a melt request the mint never
/// answered (`request_lost`). CDK has already handled it before handing the
/// error back: it finalizes a melt the mint reports Paid, compensates one it
/// reports Unpaid or Failed (with no payment proof), and leaves it open when
/// the mint cannot be reached or still has it in flight.
///
/// - Open locally (saga, or proofs still held): Pending. The watcher's
///   finalize pass settles it. The stored quote is NOT consulted: it was
///   written before the confirm and still reads Unpaid.
/// - Closed and the mint says Paid: Complete (a compensation the mint then
///   paid is accounted for).
/// - Closed and the mint says Failed: Failed.
/// - Closed and the mint says Unpaid: Failed when the mint answered the
///   request (it refused it, or the error came before any request). After a
///   lost request, Pending for the grace window: a melt request still
///   travelling to the mint reads Unpaid until the mint starts on it, and
///   would then be paid over the compensation. The watcher decides once the
///   window has passed and the melt's inputs are spent.
/// - Mint unreachable: Pending, tracked the same way.
#[allow(clippy::too_many_arguments)]
async fn settle_ambiguous_confirm(
    wallet: &Wallet,
    reconciler: &Reconciler,
    quote_id: &str,
    operation_id: uuid::Uuid,
    prepared: &PreparedSend,
    note: Option<String>,
    request_lost: bool,
    budgets: Budgets,
) -> Payment {
    if !matches!(melt_operation_open(wallet, operation_id).await, Ok(false)) {
        return pending_payment(quote_id, prepared, note);
    }
    let checked = bounded(budgets.mint_call, wallet.check_melt_quote_status(quote_id)).await;
    match checked {
        Ok(quote) if quote.state == MeltQuoteState::Paid => {
            account_late_melt(wallet, quote_id, quote.payment_proof.clone(), budgets).await;
            resolved_melt_payment(
                quote_id,
                prepared,
                MeltQuoteState::Paid,
                quote.payment_proof,
                note,
            )
        }
        Ok(quote)
            if quote.state == MeltQuoteState::Failed
                || (quote.state == MeltQuoteState::Unpaid && !request_lost) =>
        {
            resolved_melt_payment(quote_id, prepared, MeltQuoteState::Failed, None, note)
        }
        _ => {
            reconciler.track_unsettled(
                quote_id,
                UnsettledMelt {
                    operation_id,
                    prepared: prepared.clone(),
                    note: note.clone(),
                    since_ms: now_ms(),
                },
            );
            pending_payment(quote_id, prepared, note)
        }
    }
}

fn payment_event(payment: Payment) -> WalletEvent {
    match payment.status {
        PaymentStatus::Failed => WalletEvent::PaymentFailed { payment },
        _ => WalletEvent::PaymentSent { payment },
    }
}

/// The id hosts see for an incoming payment. A BOLT11 invoice is paid once,
/// so its quote id is the payment. A BOLT12 offer is ONE quote paid many
/// times: keying on the quote id alone would merge every payment to the
/// published offer into a single row, so each minting is qualified by the
/// transaction id of its proofs. History rebuilds the same id from the same
/// proofs (`Transaction::id()` hashes the same Ys).
fn incoming_payment_id(
    quote_id: &str,
    method: &PaymentMethod,
    transaction: Option<TransactionId>,
) -> String {
    match (method, transaction) {
        (PaymentMethod::Known(KnownMethod::Bolt12), Some(tx)) => format!("{quote_id}:{tx}"),
        _ => quote_id.to_string(),
    }
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

impl TrackedReceiveBackend for CdkWallet {
    fn confirmed_sats(&self) -> Result<u64> {
        WalletBackend::balance(self).map(|b| b.confirmed_sats)
    }

    fn create_tracked_receive(&self, request: &ReceiveRequest) -> Result<TrackedReceive> {
        let quote = self.create_mint_quote(request)?;
        let amount_sats = quote
            .amount
            .map(u64::from)
            .or(request.amount_sats)
            .ok_or_else(|| WalletError::InvalidInput("mint quote has no fixed amount".into()))?;
        Ok(TrackedReceive {
            id: quote.id,
            request: quote.request,
            amount_sats,
            expires_at_secs: (quote.expiry != 0).then_some(quote.expiry),
        })
    }

    fn reconcile_tracked_receive(
        &self,
        id: &str,
        request_timeout: Duration,
    ) -> Result<TrackedReceiveState> {
        let wallet = self.wallet()?;
        // `timeout` must be constructed inside `block_on`: creating the Sleep
        // outside this wallet's runtime panics with "no reactor running".
        self.rt()
            .block_on(async {
                tokio::time::timeout(request_timeout, async {
                    let quote = wallet
                        .check_mint_quote_status(id)
                        .await
                        .map_err(|e| WalletError::Network(format!("check mint quote {id}: {e}")))?;
                    match quote.state {
                        MintQuoteState::Unpaid => Ok(TrackedReceiveState::Pending),
                        MintQuoteState::Paid => {
                            let proofs = wallet
                                .mint(id, SplitTarget::default(), None)
                                .await
                                .map_err(|e| {
                                    WalletError::Network(format!("mint paid quote {id}: {e}"))
                                })?;
                            let amount_sats = proofs
                                .iter()
                                .map(|proof| u64::from(proof.amount))
                                .fold(0u64, u64::saturating_add);
                            Ok(TrackedReceiveState::Settled { amount_sats })
                        }
                        MintQuoteState::Issued => Ok(TrackedReceiveState::Settled {
                            amount_sats: u64::from(quote.amount_issued),
                        }),
                    }
                })
                .await
            })
            .map_err(|_| WalletError::Timeout)?
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
            let (wallet, restore_owed) = self.build_wallet()?;
            // One round-trip proves the mint is reachable and caches its
            // info/keysets; without this, "connected" would be a lie the
            // first send exposes.
            self.rt()
                .block_on(bounded(self.budgets.mint_call, wallet.load_mint_info()))
                .map_err(|e| match e {
                    WalletError::Timeout => WalletError::Timeout,
                    other => WalletError::Network(format!("mint unreachable: {other}")),
                })?;
            if restore_owed {
                // No valid restore marker: scan the mint for proofs the seed
                // already owns (NUT-13). This is what makes wipe → reconnect
                // (and new-device setup) actually recover funds instead of
                // presenting an empty balance over live money. The marker is
                // written only on success, so a transient failure here leaves
                // restoration pending for the next connect rather than
                // permanently skipped.
                let restored = self
                    .rt()
                    .block_on(bounded(self.budgets.restore, wallet.restore()))
                    .map_err(|e| match e {
                        WalletError::Timeout => WalletError::Timeout,
                        other => WalletError::Backend(format!("NUT-13 restore: {other}")),
                    })?;
                tracing::info!(
                    "NUT-13 restore recovered {} sats unspent ({} pending)",
                    u64::from(restored.unspent),
                    u64::from(restored.pending),
                );
                std::fs::write(
                    self.config.working_dir.join(self.restore_marker_name()),
                    b"1",
                )
                .map_err(|e| WalletError::Backend(format!("write restore marker: {e}")))?;
                // The proof db was lost; if the offer pointer survived, pull
                // its quote back so payments made to it can still be minted.
                self.readopt_offer_if_lost(&wallet);
            }
            // Finish or roll back whatever a crash interrupted (a melt, swap,
            // or mint mid-flight): CDK leaves those proofs Reserved/Pending
            // until this runs, and says to call it on startup. It runs HERE,
            // before the wallet is published, so no send of ours can be in
            // flight on this store while it compensates. Best-effort: a mint
            // outage must not make the funds we do hold unreachable, and the
            // next connect retries.
            match self.rt().block_on(bounded(
                self.budgets.recovery,
                wallet.recover_incomplete_sagas(),
            )) {
                Ok(report) => {
                    if report.recovered + report.compensated + report.failed > 0 {
                        tracing::info!(
                            "saga recovery: {} recovered, {} compensated, {} failed",
                            report.recovered,
                            report.compensated,
                            report.failed
                        );
                    }
                }
                Err(e) => tracing::warn!("saga recovery deferred to the next connect: {e}"),
            }
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
        let budgets = self.budgets;
        let reconciler = self.reconciler.clone();
        let handle = self.rt().spawn(async move {
            // First tick DELAYED, not immediate: a disconnect racing the
            // install below aborts this task at its first await, and an
            // immediate tick would let it poll — and mint, and emit — before
            // the identity check ever runs.
            let start = tokio::time::Instant::now() + WATCH_INTERVAL;
            let mut tick = tokio::time::interval_at(start, WATCH_INTERVAL);
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tick.tick().await;
                CdkWallet::poll_mint_quotes(&watch_wallet, &events, budgets, &reconciler).await;
            }
        });
        {
            // Install only while OUR wallet is still the published one — a
            // disconnect that landed between publish and here found no watcher
            // to abort, so installing unconditionally would leave an orphan
            // task polling the mint (and minting!) after `Disconnected`.
            // Lock order: state → watcher, everywhere.
            let state = self.state();
            let still_ours = state
                .wallet
                .as_ref()
                .is_some_and(|published| Arc::ptr_eq(published, &wallet));
            let mut watcher = self.watcher.lock().unwrap_or_else(|e| e.into_inner());
            if still_ours {
                if let Some(old) = watcher.replace(handle) {
                    old.abort();
                }
            } else {
                handle.abort();
                return Ok(());
            }
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
            // Never read a fee preview's dry-run reservation as money leaving.
            let _prepare = self.reconciler.prepare.lock().await;
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
            // The Balance contract names Cashu unminted quotes as pending
            // receives; CDK's pending-proof balance does not see a quote that
            // has no proofs yet, so add what the mint owes us. Local store
            // only (no network). Unpaid quotes (just-issued invoices) owe
            // nothing and must not inflate the figure; paid BOLT12 offers
            // (no expiry, no fixed amount) and invoices paid past expiry do.
            let quoted = quoted_pending_receive_sats(
                wallet
                    .get_unissued_mint_quotes()
                    .await
                    .map_err(|e| WalletError::Backend(e.to_string()))?
                    .iter()
                    .map(|q| u64::from(q.amount_mintable())),
            );
            // CDK's Pending proofs are the INPUTS of an in-flight melt: money
            // on its way out, not in. Counting them as pending receive showed
            // a send as incoming. They and the Reserved proofs of a prepared
            // melt are both outgoing.
            Ok(Balance {
                confirmed_sats: u64::from(confirmed),
                pending_receive_sats: quoted,
                pending_send_sats: u64::from(pending).saturating_add(u64::from(reserved)),
            })
        })
    }

    fn sync_wallet(&self) -> Result<()> {
        let wallet = self.wallet()?;
        let events = self.events_tx.clone();
        self.rt().block_on(async {
            CdkWallet::poll_mint_quotes_strict(&wallet, &events, self.budgets, &self.reconciler)
                .await
        })?;
        Ok(())
    }

    fn receive(&self, request: &ReceiveRequest) -> Result<String> {
        Ok(self.create_mint_quote(request)?.request)
    }

    /// The ONE offer hosts publish. Stable across calls and launches, and
    /// answered from disk when the mint is unreachable. Rotates only when the
    /// quote behind it has expired; the old quote stays in the store and is
    /// still minted, so late payers are not lost. (A mint that forgets the
    /// quote cannot be told apart from an outage — mints report both with a
    /// generic error — so that case does not rotate.)
    fn receive_offer(&self) -> Result<String> {
        let wallet = match self.wallet() {
            Ok(wallet) => wallet,
            Err(e) => return self.read_offer_pointer().map(|p| p.offer).ok_or(e),
        };
        let _creating = self.offer_lock.lock().unwrap_or_else(|e| e.into_inner());
        let Some(pointer) = self.read_offer_pointer() else {
            return Ok(self.create_offer(&wallet, 0)?.offer);
        };
        let local = self
            .rt()
            .block_on(wallet.localstore.get_mint_quote(&pointer.quote_id))
            .map_err(|e| WalletError::Backend(format!("read offer quote: {e}")))?;
        match local {
            Some(quote) if quote.expiry != 0 && quote.expiry <= now_secs() => {
                let next = pointer
                    .index
                    .checked_add(1)
                    .ok_or_else(|| WalletError::Backend("offer index exhausted".into()))?;
                Ok(self.create_offer(&wallet, next)?.offer)
            }
            Some(_) => Ok(pointer.offer),
            None => {
                if let Err(e) = self.adopt_offer(&wallet, &pointer) {
                    tracing::warn!(
                        "re-adopting offer quote {}: {e}",
                        quote_tag(&pointer.quote_id)
                    );
                }
                Ok(pointer.offer)
            }
        }
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
        // An offline-classified destination carries no amount even for an
        // amount-bearing BOLT11 invoice (the pure classifier decodes nothing),
        // and rejecting `prepare_send(invoice, None)` for it would make the
        // advertised BOLT11 path unable to pay a normal fixed-amount invoice.
        // Decode locally — same crate CDK itself uses — before resolving.
        let destination = &refine_bolt11_amount(destination.clone());
        // Trait contract: never silently pay one of two disagreeing figures.
        // BOLT12 offers are the one kind where "no amount anywhere" is not
        // ours to reject: the offer itself may fix the amount, we carry no
        // offer decoder, and the mint reads it during the quote — the
        // post-quote equality check below still catches any disagreement.
        let requested = if destination.kind == DestinationKind::Bolt12Offer
            && destination.amount_sats.is_none()
        {
            amount_sats
        } else {
            resolve_send_amount(amount_sats, destination.amount_sats)?
        };

        let budget = self.budgets.mint_call;
        let quote = self.rt().block_on(async {
            let quote = async {
                match destination.kind {
                    DestinationKind::Bolt11 => {
                        // An amount-carrying invoice needs no options; an
                        // amountless one carries the caller's amount as msat.
                        let options = if destination.amount_sats.is_none() {
                            requested.map(|sats| MeltOptions::new_amountless(sats * 1_000))
                        } else {
                            None
                        };
                        wallet
                            .melt_quote(KnownMethod::Bolt11, destination.raw.clone(), options, None)
                            .await
                    }
                    DestinationKind::Bolt12Offer => {
                        let options =
                            requested.map(|sats| MeltOptions::new_amountless(sats * 1_000));
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
            };
            tokio::time::timeout(budget, quote).await
        });
        let quote = quote.map_err(|_| WalletError::Timeout)?;
        let quote = quote.map_err(|e| match e {
            cdk::Error::InsufficientFunds => WalletError::InsufficientFunds,
            cdk::Error::UnsupportedPaymentMethod => {
                WalletError::Unsupported("this destination kind on a Cashu mint".into())
            }
            other => WalletError::Backend(other.to_string()),
        })?;

        let quoted_amount = u64::from(quote.amount);
        // No-disagreement contract, applied to the MINT as well: verify its
        // quote against whichever figure we hold — the caller's argument or
        // the amount decoded from the destination itself. A buggy or
        // dishonest mint must not be able to re-price a fixed invoice.
        let invoice_msat = (destination.kind == DestinationKind::Bolt11)
            .then(|| bolt11_msat(&destination.raw))
            .flatten();
        if let Some(confirmed) = amount_sats.or(destination.amount_sats) {
            if !quote_agrees(quoted_amount, confirmed, invoice_msat) {
                return Err(WalletError::InvalidDestination(format!(
                    "mint quoted {quoted_amount} sats but the confirmed amount is {confirmed} sats"
                )));
            }
        }
        // The fee reserve is not the whole fee. The melt also pays the
        // mint's input fees on the proofs it spends — and on a swap first,
        // which CDK makes whenever no exact fee-free set exists (always,
        // with proofs left on a fee-charging retired keyset). Pricing only
        // the reserve let hosts approve a send CDK then refused with
        // InsufficientFunds after the quote existed: no melt, an UNPAID
        // quote at the mint, and "amount plus fee exceeds your balance" for
        // a send the sheet had shown as affordable.
        let price =
            self.rt()
                .block_on(price_melt(&wallet, &self.reconciler, self.budgets, &quote))?;
        let spendable = self
            .rt()
            .block_on(wallet.get_unspent_proofs())
            .ok()
            .and_then(|p| cdk::nuts::nut00::ProofsMethods::total_amount(&p).ok())
            .map_or(0, u64::from);
        let expires_at_secs = (quote.expiry != 0).then_some(quote.expiry);
        tracing::info!(
            "melt {}: quoted {} {quoted_amount} sats, fee up to {} (reserve {} + input fee {} + \
             swap fee {}), {} input proofs, swap first: {}, spendable {spendable}, affordable: {}, \
             expires in {} s",
            quote_tag(&quote.id),
            destination.kind.label(),
            price.max_fee(),
            price.fee_reserve,
            price.input_fee,
            price.swap_fee,
            price.inputs,
            price.swap,
            price.affordable,
            expires_at_secs.map_or(0, |e| ttl_left(e).as_secs()),
        );
        Ok(PreparedSend {
            destination: destination.clone(),
            amount_sats: quoted_amount,
            fees_sats: Some(price.max_fee()),
            expires_at_secs,
            // The melt quote is persisted by CDK under this id and is
            // single-use by state — the store IS the parked-quote map.
            token: PreparedSendToken::Opaque(quote.id),
        })
    }

    fn send(&self, prepared: &PreparedSend, note: &str) -> Result<Payment> {
        let wallet = self.wallet()?;
        let PreparedSendToken::Opaque(quote_id) = &prepared.token else {
            return Err(WalletError::InvalidInput(
                "this prepared send did not come from the CDK backend".into(),
            ));
        };
        let tag = quote_tag(quote_id);
        let note = (!note.is_empty()).then(|| note.to_string());
        let mut metadata = HashMap::new();
        if let Some(note) = &note {
            // CDK surfaces transaction metadata; the "memo" key keeps
            // list_recent_payments consistent with what we return here.
            metadata.insert("memo".to_string(), note.clone());
        }

        // The quote's expiry as stored when the mint issued it. A host's
        // `expires_at_secs` is a copy for display; this one is enforced.
        let expiry = self
            .rt()
            .block_on(wallet.localstore.get_melt_quote(quote_id))
            .map_err(|e| WalletError::Backend(format!("read melt quote: {e}")))?
            .map(|q| q.expiry)
            .filter(|&e| e != 0);
        let lifetime = expiry.map(ttl_left);
        if let Some(left) = lifetime {
            if left < self.budgets.melt_ttl_floor {
                // Nothing has been asked of the mint for this quote; the
                // caller re-quotes the same destination and amount.
                tracing::warn!(
                    "melt {tag}: {} s of quote left, under the {} s needed: not starting, \
                     QuoteExpired",
                    left.as_secs(),
                    self.budgets.melt_ttl_floor.as_secs()
                );
                return Err(WalletError::QuoteExpired);
            }
            tracing::info!(
                "melt {tag}: send started, quote expires in {} s",
                left.as_secs()
            );
        }

        // The melt runs as its own task, so a caller that stops waiting does
        // not cancel it: dropping a melt mid-flight is a crash as far as CDK
        // is concerned, and the payment may already be on its way. The
        // handoff decides who reports the outcome — see `SendHandoff`.
        let handoff = Arc::new(Mutex::new(SendHandoff::default()));
        let (confirm_tx, confirm_rx) = tokio::sync::oneshot::channel::<()>();
        let job = MeltJob {
            wallet: wallet.clone(),
            reconciler: self.reconciler.clone(),
            quote_id: quote_id.clone(),
            prepared: prepared.clone(),
            note: note.clone(),
            metadata,
            budgets: self.budgets,
            expiry,
        };
        let mut task = {
            let handoff = handoff.clone();
            let events = self.events_tx.clone();
            self.rt().spawn(async move {
                let _sending = job.reconciler.sending(&job.quote_id);
                let result = job.run(&handoff, confirm_tx).await;
                let report = {
                    let mut h = handoff.lock().unwrap_or_else(|e| e.into_inner());
                    if !h.caller_gone {
                        h.finished = true;
                    }
                    h.caller_gone && !h.abandoned
                };
                if report {
                    // The caller was told Pending: every ending is an event.
                    // An error here was raised before confirm — nothing left
                    // the wallet.
                    let payment = match &result {
                        Ok(payment) => payment.clone(),
                        Err(e) => {
                            tracing::warn!(
                                "melt {}: ended before confirm after the caller stopped \
                                 waiting ({e}); reporting it Failed",
                                quote_tag(&job.quote_id)
                            );
                            Payment {
                                status: PaymentStatus::Failed,
                                ..pending_payment(&job.quote_id, &job.prepared, job.note.clone())
                            }
                        }
                    };
                    let _ = events.send(payment_event(payment));
                }
                result
            })
        };

        // Preparation is local and normally takes milliseconds; the caller
        // waits for it as long as the quote can still be confirmed, capped
        // by the send budget. Sonar's own budget never cancels a melt that
        // can still be paid: past it the send is reported Pending and the
        // task carries on, confirming only while the quote allows.
        let started = Instant::now();
        let budget = self.budgets.send;
        let confirmable = lifetime.map(|l| l.saturating_sub(self.budgets.confirm_ttl_floor));
        let preparing = confirmable.map_or(budget, |c| c.min(budget));
        let mut confirm_rx = confirm_rx;
        let prepared_phase = self.rt().block_on(async {
            tokio::time::timeout(preparing, async {
                tokio::select! {
                    biased;
                    joined = &mut task => Some(joined),
                    _ = &mut confirm_rx => None,
                }
            })
            .await
        });
        let joined = match prepared_phase {
            Ok(Some(joined)) => joined,
            Ok(None) => match self.await_confirm(
                &mut task,
                &handoff,
                budget.saturating_sub(started.elapsed()),
            ) {
                Some(joined) => joined,
                None => {
                    tracing::info!("melt {tag}: confirm still running at the send budget; Pending");
                    return Ok(pending_payment(quote_id, prepared, note));
                }
            },
            Err(_) => {
                let mut h = handoff.lock().unwrap_or_else(|e| e.into_inner());
                if h.finished {
                    drop(h);
                    self.rt().block_on(&mut task)
                } else if h.confirming {
                    drop(h);
                    match self.await_confirm(
                        &mut task,
                        &handoff,
                        budget.saturating_sub(started.elapsed()),
                    ) {
                        Some(joined) => joined,
                        None => return Ok(pending_payment(quote_id, prepared, note)),
                    }
                } else if confirmable.is_some_and(|c| c <= budget) {
                    // The quote can no longer be confirmed in time. The task
                    // cancels when its preparation returns; no melt request
                    // was made, so the caller may re-quote.
                    h.caller_gone = true;
                    h.abandoned = true;
                    tracing::warn!(
                        "melt {tag}: still preparing {} ms in, past the quote's confirm \
                         deadline: cancelled before any melt request, QuoteExpired",
                        started.elapsed().as_millis()
                    );
                    return Err(WalletError::QuoteExpired);
                } else {
                    // Sonar's wait budget, not the quote, ran out. The send
                    // goes on: it confirms while the quote allows and reports
                    // how it ends as an event.
                    h.caller_gone = true;
                    tracing::info!(
                        "melt {tag}: still preparing at the {} s send budget; reporting \
                         Pending, the send continues within the quote's lifetime",
                        budget.as_secs()
                    );
                    return Ok(pending_payment(quote_id, prepared, note));
                }
            }
        };
        let payment = joined.map_err(|e| WalletError::Backend(format!("send task: {e}")))??;
        // A finalized-but-failed melt must not be announced as sent; hosts
        // render the two very differently.
        self.emit(payment_event(payment.clone()));
        Ok(payment)
    }

    fn list_recent_payments(&self, limit: u32) -> Result<Vec<Payment>> {
        let wallet = self.wallet()?;
        let unsettled: std::collections::HashSet<String> = self
            .reconciler
            .unsettled_snapshot()
            .into_iter()
            .map(|(id, _)| id)
            .collect();
        self.rt().block_on(async {
            let transactions = wallet
                .list_transactions(None)
                .await
                .map_err(|e| WalletError::Backend(e.to_string()))?;
            // Outgoing rows must not all claim Complete: a melt still active
            // or pending is unresolved, and reporting it as paid after a
            // restart is the worst direction to be wrong in. Anything the
            // wallet no longer tracks has settled.
            let mut melt_states: HashMap<String, MeltQuoteState> = HashMap::new();
            for quote in wallet
                .get_active_melt_quotes()
                .await
                .map_err(|e| WalletError::Backend(e.to_string()))?
                .into_iter()
                .chain(
                    wallet
                        .get_pending_melt_quotes()
                        .await
                        .map_err(|e| WalletError::Backend(e.to_string()))?,
                )
            {
                melt_states.insert(quote.id.clone(), quote.state);
            }
            let mut payments: Vec<Payment> = transactions
                .into_iter()
                .map(|tx| {
                    let incoming =
                        tx.direction == cdk::wallet::types::TransactionDirection::Incoming;
                    // CDK 0.18 records a saga's transaction up front and
                    // marks it Failed when the operation is rolled back (a
                    // melt the mint refused or saga recovery compensated).
                    // That row must read Failed, never "Pending" from the
                    // quote's leftover Unpaid state.
                    let status = match tx.status {
                        // CDK compensated it, but the watcher still doubts
                        // the mint's Unpaid (the grace window): the send
                        // said Pending, and history must not say otherwise.
                        _ if !incoming
                            && tx.quote_id.as_ref().is_some_and(|q| unsettled.contains(q)) =>
                        {
                            PaymentStatus::Pending
                        }
                        TransactionStatus::Failed => PaymentStatus::Failed,
                        TransactionStatus::Pending => PaymentStatus::Pending,
                        TransactionStatus::Completed => {
                            match tx.quote_id.as_ref().and_then(|q| melt_states.get(q)) {
                                Some(MeltQuoteState::Paid) => PaymentStatus::Complete,
                                Some(MeltQuoteState::Failed) => PaymentStatus::Failed,
                                Some(_) => PaymentStatus::Pending,
                                // Untracked: settled (incoming rows only exist
                                // once their proofs are minted).
                                None => PaymentStatus::Complete,
                            }
                        }
                    };
                    // The proof-derived id, as live events compute it
                    // (`TransactionId::from_proofs` on the minted proofs).
                    // CDK 0.18's `tx.id()` switched saga-managed rows to the
                    // saga id; using it here would give one payment two ids
                    // and make hosts insert a duplicate row after a restart.
                    let proof_id = TransactionId::new(tx.ys.clone());
                    // Live returns and events identify a payment by its
                    // mint/melt QUOTE id (qualified per payment for a reusable
                    // BOLT12 offer); reconstructing history any other way
                    // would make hosts insert a duplicate row instead of
                    // updating the existing one.
                    let id = match (&tx.quote_id, incoming) {
                        (Some(quote_id), true) => incoming_payment_id(
                            quote_id,
                            tx.payment_method
                                .as_ref()
                                .unwrap_or(&PaymentMethod::Known(KnownMethod::Bolt11)),
                            Some(proof_id),
                        ),
                        (Some(quote_id), false) => quote_id.clone(),
                        (None, _) => proof_id.to_string(),
                    };
                    Payment {
                        id,
                        amount_sats: u64::from(tx.amount),
                        fees_sats: Some(u64::from(tx.fee)),
                        incoming,
                        timestamp_secs: tx.timestamp,
                        status,
                        // The preimage is the proof of an outgoing payment
                        // (chat ⚡PAYDONE carries it); CDK keeps it on the
                        // transaction, so history must not drop it.
                        preimage: tx.payment_proof.clone(),
                        note: tx_note(tx.memo.as_ref(), &tx.metadata).filter(|n| !n.is_empty()),
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
        let target = guard_wipe_path(&self.config.working_dir, is_our_artifact)?;
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
    use sonar_wallet::Network;
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

    /// A per-test scratch dir (tests run in parallel; shared paths collide).
    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "sonar-cdk-{name}-{}-{}",
            std::process::id(),
            now_secs()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn fake_wallet(dir: &Path) -> (CdkWallet, Arc<test_mint::FakeMint>) {
        let mint = Arc::new(test_mint::FakeMint::new());
        let mut cfg = config();
        cfg.working_dir = dir.to_path_buf();
        let wallet =
            CdkWallet::with_connector(cfg, "https://mint.example.com", mint.clone()).unwrap();
        (wallet, mint)
    }

    fn reopen(dir: &Path, mint: &Arc<test_mint::FakeMint>) -> CdkWallet {
        let mut cfg = config();
        cfg.working_dir = dir.to_path_buf();
        CdkWallet::with_connector(cfg, "https://mint.example.com", mint.clone()).unwrap()
    }

    /// Android has no redb file lock, so a second handle there wrote the same
    /// file and corrupted it; with a lock (this host) the second open is
    /// refused instead, which is how this test sees a second handle.
    #[test]
    fn a_reconnect_while_the_old_wallet_is_still_in_use_shares_its_store() {
        fn same(a: &Wallet, b: &Wallet) -> bool {
            std::ptr::eq(
                Arc::as_ptr(&a.localstore) as *const (),
                Arc::as_ptr(&b.localstore) as *const (),
            )
        }
        let dir = scratch("reconnect-shared-store");
        let (w, _mint) = fake_wallet(&dir);
        w.connect().unwrap();
        // What a `sync` in flight holds when the app goes to the background.
        let in_flight = w.wallet().unwrap();
        w.disconnect().unwrap();
        w.connect()
            .expect("the reconnect must reuse the open store, not open a second one");
        assert!(
            same(&in_flight, &w.wallet().unwrap()),
            "one store, one handle"
        );

        // A store wiped and recreated at the same path is another file.
        w.disconnect().unwrap();
        w.wipe_local_storage().unwrap();
        w.connect().unwrap();
        assert!(
            !same(&in_flight, &w.wallet().unwrap()),
            "a new file gets its own handle"
        );
        drop(in_flight);
    }

    #[test]
    fn fake_mint_bolt11_receive_mints_on_sync() {
        let dir = scratch("smoke");
        let (w, mint) = fake_wallet(&dir);
        w.connect().expect("connect against the fake mint");
        let invoice = w
            .receive(&ReceiveRequest {
                method: ReceiveMethod::Bolt11Invoice,
                amount_sats: Some(1_000),
                description: None,
            })
            .unwrap();
        assert!(invoice.starts_with("lnbc1fake"));
        let quote = mint.mint_quote_ids().pop().unwrap();
        mint.pay(&quote, 1_000);
        w.sync_wallet().unwrap();
        assert_eq!(w.balance().unwrap().confirmed_sats, 1_000);
        w.disconnect().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A host matches "this invoice was paid" by id, so the id
    /// `receive_bolt11` hands out must be the one the payment event and
    /// history carry.
    #[test]
    fn a_bolt11_invoice_is_paid_under_the_id_it_was_issued_with() {
        let dir = scratch("bolt11-id");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());

        let (invoice, payment_id) = w.receive_bolt11(210, None).unwrap();
        assert!(invoice.starts_with("lnbc"));
        mint.pay(&payment_id, 210);
        w.sync_wallet().unwrap();

        assert!(eventually(
            || recorder.received_ids() == vec![payment_id.clone()]
        ));
        let history: Vec<String> = w
            .list_recent_payments(10)
            .unwrap()
            .into_iter()
            .filter(|p| p.incoming)
            .map(|p| p.id)
            .collect();
        assert_eq!(history, vec![payment_id]);
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn receive_paid_bolt11(w: &CdkWallet, mint: &test_mint::FakeMint, sats: u64) {
        let before: std::collections::HashSet<String> = mint.mint_quote_ids().into_iter().collect();
        w.receive(&ReceiveRequest {
            method: ReceiveMethod::Bolt11Invoice,
            amount_sats: Some(sats),
            description: None,
        })
        .unwrap();
        let quote = mint
            .mint_quote_ids()
            .into_iter()
            .find(|id| !before.contains(id))
            .unwrap();
        mint.pay(&quote, sats);
        w.sync_wallet().unwrap();
    }

    /// R-050: the real connect path must re-run NUT-13 when cashu.redb is
    /// gone, even though the per-mint marker survived — and keep owing it
    /// after a failed attempt.
    #[test]
    fn connect_restores_again_after_proof_db_is_deleted() {
        let dir = scratch("nut13-db-deleted");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        receive_paid_bolt11(&w, &mint, 1_000);
        assert_eq!(w.balance().unwrap().confirmed_sats, 1_000);
        drop(w);
        assert!(dir.join(DB_FILE).exists());

        std::fs::remove_file(dir.join(DB_FILE)).unwrap();
        let restores_before = mint.calls("post_restore");

        // First reconnect: the restore itself fails.
        mint.fail_next("post_restore", 1);
        let w = reopen(&dir, &mint);
        assert!(w.connect().is_err(), "a failed restore must fail connect");
        drop(w);

        // Second reconnect: restore is still owed and brings the funds back.
        let w = reopen(&dir, &mint);
        w.connect().unwrap();
        assert!(
            mint.calls("post_restore") > restores_before + 1,
            "NUT-13 must run again on the reconnect after the failure"
        );
        assert_eq!(
            w.balance().unwrap().confirmed_sats,
            1_000,
            "a deleted proof db must not present 0 sats over recoverable funds"
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Damage a closed redb file in place: flag it for recovery and zero the
    /// user roots of both commit slots, which redb reports as `Corrupted`
    /// (the class of "All roots are corrupted" the Android store hit).
    fn corrupt_commit_roots(path: &Path) {
        use std::io::{Seek, SeekFrom, Write};
        flag_for_recovery(path);
        let mut f = std::fs::OpenOptions::new().write(true).open(path).unwrap();
        for slot in [64u64, 192] {
            f.seek(SeekFrom::Start(slot + 8)).unwrap();
            f.write_all(&[0u8; 40]).unwrap();
        }
    }

    /// Set redb's "recovery required" bit, as an unclean shutdown leaves it.
    fn flag_for_recovery(path: &Path) {
        use std::io::{Read, Seek, SeekFrom, Write};
        let mut f = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .unwrap();
        let mut god = [0u8; 1];
        f.seek(SeekFrom::Start(9)).unwrap();
        f.read_exact(&mut god).unwrap();
        f.seek(SeekFrom::Start(9)).unwrap();
        f.write_all(&[god[0] | 2]).unwrap();
    }

    fn quarantined(dir: &Path) -> Vec<String> {
        std::fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok()?.file_name().into_string().ok())
            .filter(|n| n.starts_with("cashu.redb.corrupt-"))
            .collect()
    }

    /// A proof store that no longer opened failed every connect forever, and
    /// the app read "Mint offline — retrying" over funds the seed can
    /// recover. It is set aside for inspection and rebuilt by NUT-13.
    #[test]
    fn a_corrupted_store_is_set_aside_and_rebuilt_from_the_seed() {
        let dir = scratch("corrupted-store-rebuilt");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        receive_paid_bolt11(&w, &mint, 1_000);
        w.disconnect().unwrap();
        drop(w);
        corrupt_commit_roots(&dir.join(DB_FILE));

        let w = reopen(&dir, &mint);
        w.connect()
            .expect("a store that no longer opens is rebuilt, not a dead end");
        assert_eq!(
            w.balance().unwrap().confirmed_sats,
            1_000,
            "NUT-13 restores the funds"
        );
        assert_eq!(
            quarantined(&dir).len(),
            1,
            "the damaged file is kept, not deleted"
        );

        // The set-aside file is ours: it never blocks a wipe.
        w.disconnect().unwrap();
        w.wipe_local_storage().unwrap();
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Some damage makes redb panic while opening instead of returning an
    /// error; that must rebuild the store too, never unwind out of connect.
    #[test]
    fn a_store_that_panics_redb_on_open_is_rebuilt_too() {
        use std::io::{Seek, SeekFrom, Write};
        let dir = scratch("panicking-store-rebuilt");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        receive_paid_bolt11(&w, &mint, 700);
        w.disconnect().unwrap();
        drop(w);
        {
            let path = dir.join(DB_FILE);
            flag_for_recovery(&path);
            let mut f = std::fs::OpenOptions::new().write(true).open(&path).unwrap();
            f.seek(SeekFrom::Start(4096)).unwrap();
            f.write_all(&[0u8; 4096]).unwrap();
        }

        let w = reopen(&dir, &mint);
        let connected = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| w.connect()));
        assert!(
            matches!(connected, Ok(Ok(()))),
            "connect must rebuild, not panic or fail: {connected:?}"
        );
        assert_eq!(w.balance().unwrap().confirmed_sats, 700);
        assert_eq!(quarantined(&dir).len(), 1);
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
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
    fn bolt11_amount_is_decoded_before_resolution() {
        // lightning-invoice's own 10-msat (100p) test vector: sub-sat rounds
        // UP so the shown figure never understates what will be paid.
        let invoice = "lnbc100p1psj9jhxdqud3jxktt5w46x7unfv9kz6mn0v3jsnp4q0d3p2sfluzdx45tqcsh2pu5qc7lgq0xs578ngs6s0s68ua4h7cvspp5q6rmq35js88zp5dvwrv9m459tnk2zunwj5jalqtyxqulh0l5gflssp5nf55ny5gcrfl30xuhzj3nphgj27rstekmr9fw3ny5989s300gyus9qyysgqcqpcrzjqw2sxwe993h5pcm4dxzpvttgza8zhkqxpgffcrf5v25nwpr3cmfg7z54kuqq8rgqqqqqqqq2qqqqq9qq9qrzjqd0ylaqclj9424x9m8h2vcukcgnm6s56xfgu3j78zyqzhgs4hlpzvznlugqq9vsqqqqqqqlgqqqqqeqq9qrzjqwldmj9dha74df76zhx6l9we0vjdquygcdt3kssupehe64g6yyp5yz5rhuqqwccqqyqqqqlgqqqqjcqq9qrzjqf9e58aguqr0rcun0ajlvmzq3ek63cw2w282gv3z5uupmuwvgjtq2z55qsqqg6qqqyqqqrtnqqqzq3cqygrzjqvphmsywntrrhqjcraumvc4y6r8v4z5v593trte429v4hredj7ms5z52usqq9ngqqqqqqqlgqqqqqqgq9qrzjq2v0vp62g49p7569ev48cmulecsxe59lvaw3wlxm7r982zxa9zzj7z5l0cqqxusqqyqqqqlgqqqqqzsqygarl9fh38s0gyuxjjgux34w75dnc6xp2l35j7es3jd4ugt3lu0xzre26yg5m7ke54n2d5sym4xcmxtl8238xxvw5h5h5j5r6drg6k6zcqj0fcwg";
        let classified = classify_destination(invoice);
        assert_eq!(classified.kind, DestinationKind::Bolt11);
        assert_eq!(classified.amount_sats, None, "classifier decodes nothing");
        let refined = refine_bolt11_amount(classified);
        assert_eq!(refined.amount_sats, Some(1), "10 msat rounds up to 1 sat");
        // Non-bolt11 and undecodable inputs pass through untouched.
        let offer = classify_destination("lno1qcp4256ypq");
        assert_eq!(refine_bolt11_amount(offer.clone()), offer);
        let garbage = Destination {
            raw: "lnbc-not-a-real-invoice".into(),
            kind: DestinationKind::Bolt11,
            amount_sats: None,
            note: None,
        };
        assert_eq!(refine_bolt11_amount(garbage.clone()), garbage);
    }

    #[test]
    fn a_store_refuses_a_different_account_seed() {
        // Cashu proofs are bearer data — the worst outcome here is one
        // account spending another's funds through a shared default dir.
        let dir = std::env::temp_dir().join("sonar-cdk-account-binding-test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let mut first = config();
        first.working_dir = dir.clone();
        let a = CdkWallet::new(first, "https://mint.example.com").unwrap();
        a.check_account_binding().expect("fresh store binds");
        a.check_account_binding().expect("same seed reopens");

        let mut second = config();
        second.working_dir = dir.clone();
        second.seed = Zeroizing::new(vec![9u8; 64]);
        let b = CdkWallet::new(second, "https://mint.example.com").unwrap();
        let err = b.check_account_binding().unwrap_err();
        assert!(
            matches!(err, WalletError::InvalidInput(ref m) if m.contains("different account")),
            "unexpected error: {err}"
        );
        assert_ne!(a.account_fingerprint(), b.account_fingerprint());

        // The claim is atomic, so the loser of a create race must not be able
        // to overwrite the winner's fingerprint: repeated binding attempts by
        // the second seed leave the marker untouched.
        let marker = dir.join(ACCOUNT_MARKER);
        let after_first = std::fs::read_to_string(&marker).unwrap();
        assert_eq!(after_first.trim(), a.account_fingerprint());
        let _ = b.check_account_binding();
        let _ = b.check_account_binding();
        assert_eq!(
            std::fs::read_to_string(&marker).unwrap().trim(),
            a.account_fingerprint(),
            "a losing seed must never rewrite the marker"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_existing_unbound_database_is_not_adopted() {
        // Restoring a database-only backup must not hand its bearer proofs to
        // whichever seed opens it first.
        let dir = std::env::temp_dir().join("sonar-cdk-unbound-store-test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(DB_FILE), b"pretend-proofs").unwrap();

        let mut cfg = config();
        cfg.working_dir = dir.clone();
        let w = CdkWallet::new(cfg, "https://mint.example.com").unwrap();
        let err = w.check_account_binding().unwrap_err();
        assert!(
            matches!(err, WalletError::InvalidInput(ref m) if m.contains("no account marker")),
            "unexpected error: {err}"
        );
        assert!(
            !dir.join(ACCOUNT_MARKER).exists(),
            "a refused adoption must not leave a claim behind"
        );

        // A genuinely new store (no database) still self-claims.
        let fresh = std::env::temp_dir().join("sonar-cdk-fresh-store-test");
        let _ = std::fs::remove_dir_all(&fresh);
        std::fs::create_dir_all(&fresh).unwrap();
        let mut cfg2 = config();
        cfg2.working_dir = fresh.clone();
        let w2 = CdkWallet::new(cfg2, "https://mint.example.com").unwrap();
        w2.check_account_binding().expect("fresh store self-claims");
        assert!(fresh.join(ACCOUNT_MARKER).exists());

        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&fresh);
    }

    #[test]
    fn partial_account_marker_without_database_is_recovered() {
        let dir = std::env::temp_dir().join("sonar-cdk-partial-account-marker-test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(ACCOUNT_MARKER), b"partial").unwrap();
        let mut cfg = config();
        cfg.working_dir = dir.clone();
        let wallet = CdkWallet::new(cfg, "https://mint.example.com").unwrap();
        wallet.check_account_binding().unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.join(ACCOUNT_MARKER))
                .unwrap()
                .trim(),
            wallet.account_fingerprint()
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn surviving_restore_marker_does_not_skip_nut13_when_proof_db_is_gone() {
        let dir = std::env::temp_dir().join("sonar-cdk-nut13-restore-gate-test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let marker = "cashu.restored.00c0ffee";
        std::fs::write(dir.join(marker), b"done").unwrap();
        assert!(
            needs_nut13_restore(&dir, marker),
            "missing cashu.redb must restore even if the mint marker survived"
        );
        std::fs::write(dir.join(DB_FILE), b"proofs").unwrap();
        assert!(
            !needs_nut13_restore(&dir, marker),
            "marker + proof db present ⇒ skip"
        );
        std::fs::remove_file(dir.join(marker)).unwrap();
        assert!(
            needs_nut13_restore(&dir, marker),
            "missing marker still restores even with a proof db"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn wipe_predicate_matches_exact_artifacts_only() {
        assert!(is_our_artifact("cashu.redb"));
        assert!(is_our_artifact("cashu.account"));
        assert!(is_our_artifact("cashu.restored.00c0ffee"));
        assert!(is_our_artifact("cashu.migration.v1.json"));
        assert!(is_our_artifact("cashu.migration.v1.json.tmp"));
        assert!(is_our_artifact("cashu.migration.v1.json.123.tmp"));
        assert!(is_our_artifact("cashu.migration.v1.lock"));
        assert!(is_our_artifact("cashu.unsettled.00c0ffee"));
        assert!(is_our_artifact("cashu.unsettled.00c0ffee.tmp"));
        for foreign in [
            "cashu.unsettled",
            "cashu.unsettled.00c0ffee.old",
            "cashu.unsettled.xyz",
            "cashu.redb-backup",
            "cashu.restored-notes",
            "cashu.restored.",
            "cashu.restored.xyz",
            "cashu.restored.00c0ffee.old",
            "cashu.migration.v1.json.backup",
            "cashu.migration.v1.json..tmp",
            "cashu.migration.v1.lock.old",
            "notes.txt",
        ] {
            assert!(!is_our_artifact(foreign), "must reject {foreign}");
        }
    }

    #[test]
    fn fiat_rates_are_honestly_unsupported() {
        let w = wallet();
        assert!(matches!(
            w.fetch_fiat_rates(),
            Err(WalletError::Unsupported(_))
        ));
    }

    #[derive(Default)]
    struct Recorder(Mutex<Vec<WalletEvent>>);

    impl WalletEventListener for Recorder {
        fn on_event(&self, event: WalletEvent) {
            self.0.lock().unwrap().push(event);
        }
    }

    impl Recorder {
        fn received_ids(&self) -> Vec<String> {
            self.0
                .lock()
                .unwrap()
                .iter()
                .filter_map(|e| match e {
                    WalletEvent::PaymentReceived { payment } => Some(payment.id.clone()),
                    _ => None,
                })
                .collect()
        }
    }

    /// Events are dispatched on their own thread; poll briefly.
    fn eventually(mut cond: impl FnMut() -> bool) -> bool {
        for _ in 0..300 {
            if cond() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        false
    }

    fn newest_quote(mint: &test_mint::FakeMint, before: &[String]) -> String {
        mint.mint_quote_ids()
            .into_iter()
            .find(|id| !before.contains(id))
            .expect("a new mint quote")
    }

    /// Rewrite a quote's LOCAL expiry, as if the app slept past it.
    fn set_local_expiry(w: &CdkWallet, id: &str, expiry: u64) {
        let wallet = w.wallet().unwrap();
        w.rt().block_on(async {
            let mut quote = wallet.localstore.get_mint_quote(id).await.unwrap().unwrap();
            quote.expiry = expiry;
            wallet.localstore.add_mint_quote(quote).await.unwrap();
        });
    }

    fn local_quote_exists(w: &CdkWallet, id: &str) -> bool {
        let wallet = w.wallet().unwrap();
        w.rt()
            .block_on(wallet.localstore.get_mint_quote(id))
            .unwrap()
            .is_some()
    }

    fn bolt11_receive(w: &CdkWallet, sats: u64) {
        w.receive(&ReceiveRequest {
            method: ReceiveMethod::Bolt11Invoice,
            amount_sats: Some(sats),
            description: None,
        })
        .unwrap();
    }

    /// The published offer is one BOLT12 quote with no expiry. Each payment
    /// to it must be minted (it was filtered out by `expiry > now`) and must
    /// surface as its own payment, in events and history alike.
    #[test]
    fn paid_bolt12_offer_is_minted_per_payment_with_distinct_ids() {
        let dir = scratch("bolt12-mint");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());

        let before = mint.mint_quote_ids();
        let offer = w.receive(&ReceiveRequest::offer()).unwrap();
        assert!(offer.starts_with("lno1"));
        let quote = newest_quote(&mint, &before);

        mint.pay(&quote, 300);
        w.sync_wallet().unwrap();
        assert_eq!(w.balance().unwrap().confirmed_sats, 300);
        mint.pay(&quote, 200);
        w.sync_wallet().unwrap();
        assert_eq!(w.balance().unwrap().confirmed_sats, 500);

        assert!(eventually(|| recorder.received_ids().len() == 2));
        let ids = recorder.received_ids();
        assert_ne!(ids[0], ids[1], "two payments to one offer are two payments");
        assert!(ids.iter().all(|id| id.starts_with(&quote)));

        let mut history: Vec<String> = w
            .list_recent_payments(10)
            .unwrap()
            .into_iter()
            .filter(|p| p.incoming)
            .map(|p| p.id)
            .collect();
        let mut live = ids.clone();
        history.sort();
        live.sort();
        assert_eq!(history, live, "history must rebuild the ids events used");
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn paid_but_unminted_bolt12_counts_as_pending_receive() {
        let dir = scratch("bolt12-pending");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let before = mint.mint_quote_ids();
        w.receive(&ReceiveRequest::offer()).unwrap();
        let quote = newest_quote(&mint, &before);

        mint.pay(&quote, 300);
        mint.fail_next("post_mint", 1);
        assert!(
            w.sync_wallet().is_err(),
            "strict sync reports the failed mint"
        );
        let balance = w.balance().unwrap();
        assert_eq!(balance.confirmed_sats, 0);
        assert_eq!(balance.pending_receive_sats, 300, "the mint owes us 300");

        w.sync_wallet().unwrap();
        let balance = w.balance().unwrap();
        assert_eq!(balance.confirmed_sats, 300);
        assert_eq!(balance.pending_receive_sats, 0);
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn invoice_paid_after_local_expiry_is_still_minted() {
        let dir = scratch("bolt11-expired-paid");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let before = mint.mint_quote_ids();
        bolt11_receive(&w, 1_000);
        let quote = newest_quote(&mint, &before);
        set_local_expiry(&w, &quote, now_secs() - 60);

        mint.pay(&quote, 1_000);
        w.sync_wallet().unwrap();
        assert_eq!(w.balance().unwrap().confirmed_sats, 1_000);
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// cdk-redb creates its saga table on first write but reads it on every
    /// sync; a wallet that has never paid or been paid must still sync.
    #[test]
    fn fresh_wallet_sync_succeeds_before_any_payment() {
        let dir = scratch("fresh-sync");
        let (w, _mint) = fake_wallet(&dir);
        w.connect().unwrap();
        w.sync_wallet()
            .expect("a new wallet's first sync must not fail");
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn abandoned_unpaid_invoice_is_pruned_but_recent_one_kept() {
        let dir = scratch("bolt11-prune");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let before = mint.mint_quote_ids();
        bolt11_receive(&w, 1_000);
        let abandoned = newest_quote(&mint, &before);
        let before = mint.mint_quote_ids();
        bolt11_receive(&w, 2_000);
        let recent = newest_quote(&mint, &before);

        set_local_expiry(
            &w,
            &abandoned,
            now_secs() - ABANDONED_INVOICE_GRACE_SECS - 60,
        );
        set_local_expiry(&w, &recent, now_secs() - 60);
        w.sync_wallet().unwrap();
        assert!(!local_quote_exists(&w, &abandoned));
        assert!(
            local_quote_exists(&w, &recent),
            "an invoice just past expiry may still settle"
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A real, signed BOLT11 invoice; each call has a distinct payment hash.
    fn test_invoice(msat: Option<u64>) -> String {
        use bitcoin::hashes::{sha256, Hash};
        use bitcoin::secp256k1::{Secp256k1, SecretKey};
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let key = SecretKey::from_slice(&[0x11; 32]).unwrap();
        let builder = lightning_invoice::InvoiceBuilder::new(lightning_invoice::Currency::Bitcoin)
            .description("sonar test".into())
            .payment_hash(sha256::Hash::hash(&n.to_be_bytes()))
            .payment_secret(lightning_invoice::PaymentSecret([42; 32]))
            .current_timestamp()
            .min_final_cltv_expiry_delta(144);
        let builder = match msat {
            Some(msat) => builder.amount_milli_satoshis(msat),
            None => builder,
        };
        builder
            .build_signed(|m| Secp256k1::new().sign_ecdsa_recoverable(m, &key))
            .unwrap()
            .to_string()
    }

    fn prepare(w: &CdkWallet, invoice: &str, sats: Option<u64>) -> Result<PreparedSend> {
        let destination = w.parse_destination(invoice)?;
        w.prepare_send(&destination, sats)
    }

    fn last_bolt11_options(mint: &test_mint::FakeMint) -> Option<MeltOptions> {
        match mint
            .melt_quote_requests()
            .pop()
            .expect("a melt quote request")
        {
            cdk::MeltQuoteRequest::Bolt11(r) => r.options,
            other => panic!("expected a BOLT11 melt quote, got {other:?}"),
        }
    }

    const PREIMAGE: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    #[test]
    fn fixed_amount_invoice_sends_no_melt_options() {
        let dir = scratch("melt-fixed");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        assert_eq!(prepared.amount_sats, 300);
        assert!(
            last_bolt11_options(&mint).is_none(),
            "a fixed invoice must not be quoted as amountless"
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn amountless_invoice_carries_the_callers_amount() {
        let dir = scratch("melt-amountless");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let prepared = prepare(&w, &test_invoice(None), Some(250)).unwrap();
        assert_eq!(prepared.amount_sats, 250);
        let options = last_bolt11_options(&mint).expect("amountless needs options");
        assert_eq!(u64::from(options.amount_msat()), 250_000);
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 1,500 msat: we show 2 sats (never understate), CDK's mint floors to 1.
    /// Both are this invoice's own amount; refusing left it unpayable.
    #[test]
    fn sub_sat_invoice_accepts_the_mints_floor() {
        let dir = scratch("melt-subsat");
        let (w, _mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let prepared = prepare(&w, &test_invoice(Some(1_500)), None).unwrap();
        assert_eq!(
            prepared.amount_sats, 1,
            "the mint's figure is what is charged"
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_mint_repricing_a_whole_sat_invoice_is_still_refused() {
        assert!(quote_agrees(300, 300, Some(300_000)));
        assert!(!quote_agrees(299, 300, Some(300_000)));
        assert!(quote_agrees(1, 2, Some(1_500)));
        assert!(!quote_agrees(3, 2, Some(1_500)));
        assert!(!quote_agrees(1, 2, None));
    }

    #[test]
    fn sent_payment_and_history_carry_the_preimage() {
        let dir = scratch("preimage");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        receive_paid_bolt11(&w, &mint, 1_000);
        mint.set_melt_outcome(test_mint::MeltOutcome::Paid {
            preimage: Some(PREIMAGE.into()),
        });
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        let payment = w.send(&prepared, "lunch").unwrap();
        assert_eq!(payment.status, PaymentStatus::Complete);
        assert_eq!(payment.preimage.as_deref(), Some(PREIMAGE));

        let outgoing = w
            .list_recent_payments(10)
            .unwrap()
            .into_iter()
            .find(|p| !p.incoming)
            .expect("the send is in history");
        assert_eq!(outgoing.id, payment.id);
        assert_eq!(
            outgoing.preimage.as_deref(),
            Some(PREIMAGE),
            "chat ⚡PAYDONE reads the proof from history after a restart"
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Money on its way out is pending SEND. CDK's Pending proofs are the
    /// inputs of an in-flight melt; counting them as pending receive showed
    /// a send as incoming.
    #[test]
    fn in_flight_melt_is_pending_send_not_pending_receive() {
        let dir = scratch("inflight-melt");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        receive_paid_bolt11(&w, &mint, 1_000);
        mint.set_melt_outcome(test_mint::MeltOutcome::Pending);
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        let payment = w.send(&prepared, "").unwrap();
        assert_eq!(payment.status, PaymentStatus::Pending);

        let balance = w.balance().unwrap();
        assert_eq!(balance.pending_receive_sats, 0, "a send is not incoming");
        assert!(balance.pending_send_sats >= 300, "{balance:?}");

        mint.resolve_melt(
            &payment.id,
            test_mint::MeltOutcome::Paid {
                preimage: Some(PREIMAGE.into()),
            },
        );
        w.sync_wallet().unwrap();
        assert_eq!(w.balance().unwrap().pending_send_sats, 0);
        assert!(eventually(|| recorder.0.lock().unwrap().iter().any(
            |e| matches!(
                e,
                WalletEvent::PaymentSent { payment: p }
                    if p.id == payment.id && p.status == PaymentStatus::Complete
            )
        )));
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A mint that refuses a melt with a generic error (seen live: "request
    /// already paid") left the proofs rolled back, but the send used to read
    /// as Pending forever — money "in flight" that never left. The mint's own
    /// quote state settles it.
    #[test]
    fn a_melt_the_mint_refuses_is_failed_not_in_flight() {
        let dir = scratch("melt-refused");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        receive_paid_bolt11(&w, &mint, 1_000);
        mint.set_melt_outcome(test_mint::MeltOutcome::Refused);
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        let payment = w.send(&prepared, "").unwrap();
        assert_eq!(payment.status, PaymentStatus::Failed, "the mint said no");
        let balance = w.balance().unwrap();
        assert_eq!(balance.confirmed_sats, 1_000, "nothing left the wallet");
        assert_eq!(balance.pending_send_sats, 0, "nothing in flight");
        assert!(eventually(|| recorder.0.lock().unwrap().iter().any(
            |e| matches!(
                e,
                WalletEvent::PaymentFailed { payment: p } if p.id == payment.id
            )
        )));
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A host settling a stuck row by id must get an answer even when the
    /// melt left no history (refused and rolled back), and a late Paid must
    /// read as Complete with its preimage.
    #[test]
    fn a_refused_melt_is_failed_in_history_and_lookup() {
        let dir = scratch("outgoing-outcome");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        receive_paid_bolt11(&w, &mint, 1_000);

        mint.set_melt_outcome(test_mint::MeltOutcome::Refused);
        let refused = w
            .send(
                &prepare(&w, &test_invoice(Some(200_000)), None).unwrap(),
                "",
            )
            .unwrap();
        // CDK 0.18 keeps the rolled-back melt in history (0.17 dropped it).
        // It must never read as in flight: history says Failed, and the
        // lookup a host uses for a stuck row says Failed too.
        let history = w.list_recent_payments(50).unwrap();
        let row = history
            .iter()
            .find(|p| p.id == refused.id)
            .expect("CDK 0.18 records the rolled-back melt");
        assert_eq!(
            row.status,
            PaymentStatus::Failed,
            "a rolled-back melt is Failed"
        );
        assert_eq!(
            w.balance().unwrap().confirmed_sats,
            1_000,
            "nothing left the wallet"
        );
        let outcome = w.outgoing_payment_outcome(&refused.id).unwrap().unwrap();
        assert_eq!(outcome.status, PaymentStatus::Failed);

        mint.set_melt_outcome(test_mint::MeltOutcome::Pending);
        let pending = w
            .send(
                &prepare(&w, &test_invoice(Some(300_000)), None).unwrap(),
                "",
            )
            .unwrap();
        assert_eq!(pending.status, PaymentStatus::Pending);
        mint.resolve_melt(
            &pending.id,
            test_mint::MeltOutcome::Paid {
                preimage: Some(PREIMAGE.into()),
            },
        );
        let outcome = w.outgoing_payment_outcome(&pending.id).unwrap().unwrap();
        assert_eq!(outcome.status, PaymentStatus::Complete);
        assert_eq!(outcome.preimage.as_deref(), Some(PREIMAGE));

        assert!(w
            .outgoing_payment_outcome("no-such-quote")
            .unwrap()
            .is_none());
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A melt the mint accepted asynchronously and then failed (seen live:
    /// the fake backend refused, the mint rolled back). CDK compensates the
    /// proofs and reports it UNPAID; the wallet must say Failed and refund
    /// the balance, not leave the payment in flight forever.
    #[test]
    fn a_pending_melt_the_mint_later_fails_is_reported_and_refunded() {
        let dir = scratch("melt-later-failed");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        receive_paid_bolt11(&w, &mint, 1_000);
        mint.set_melt_outcome(test_mint::MeltOutcome::Pending);
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        let payment = w.send(&prepared, "").unwrap();
        assert_eq!(payment.status, PaymentStatus::Pending);

        mint.resolve_melt(&payment.id, test_mint::MeltOutcome::Failed);
        w.sync_wallet().unwrap();
        let balance = w.balance().unwrap();
        assert_eq!(balance.confirmed_sats, 1_000, "the proofs came back");
        assert_eq!(balance.pending_send_sats, 0);
        assert!(
            eventually(|| recorder.0.lock().unwrap().iter().any(|e| matches!(
                e,
                WalletEvent::PaymentFailed { payment: p } if p.id == payment.id
            ))),
            "the host must learn the payment failed"
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A send that outlives its deadline is Pending — never an error, which
    /// would invite a second payment — and its outcome still arrives.
    #[test]
    fn send_past_its_deadline_is_pending_then_completes() {
        let dir = scratch("send-deadline");
        let (mut w, mint) = fake_wallet(&dir);
        w.set_test_budget(Duration::from_millis(400));
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        receive_paid_bolt11(&w, &mint, 1_000);
        mint.set_melt_outcome(test_mint::MeltOutcome::Paid {
            preimage: Some(PREIMAGE.into()),
        });
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        mint.delay("post_melt", Duration::from_millis(1_500));

        let payment = w.send(&prepared, "").expect("a slow melt is not an error");
        assert_eq!(payment.status, PaymentStatus::Pending);
        assert!(eventually(|| recorder.0.lock().unwrap().iter().any(
            |e| matches!(
                e,
                WalletEvent::PaymentSent { payment: p }
                    if p.id == payment.id
                        && p.status == PaymentStatus::Complete
                        && p.preimage.as_deref() == Some(PREIMAGE)
            )
        )));
        assert_eq!(mint.calls("post_melt"), 1, "exactly one payment");
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn sent_outcome(recorder: &Recorder, id: &str) -> Option<Payment> {
        recorder
            .0
            .lock()
            .unwrap()
            .iter()
            .rev()
            .find_map(|e| match e {
                WalletEvent::PaymentSent { payment } | WalletEvent::PaymentFailed { payment }
                    if payment.id == id && payment.status != PaymentStatus::Pending =>
                {
                    Some(payment.clone())
                }
                _ => None,
            })
    }

    /// The melt reached the mint, which paid it; the answer was lost and the
    /// mint could not be asked right after. CDK leaves the saga open, and the
    /// stored quote — written before the confirm — still reads Unpaid. A
    /// host's lookup of the row then came back Failed ("you were not
    /// charged") over a payment that went through, inviting a second one.
    #[test]
    fn a_lost_melt_answer_is_pending_in_lookups_until_the_mint_answers() {
        let dir = scratch("ambiguous-unreachable");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        receive_paid_bolt11(&w, &mint, 1_000);
        mint.set_melt_outcome(test_mint::MeltOutcome::Paid {
            preimage: Some(PREIMAGE.into()),
        });
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        mint.lose_next_melt_response(true);
        // CDK's status check inside confirm, then the host's lookup: the
        // mint answers neither.
        mint.fail_next("get_melt_quote_status", 2);

        let payment = w.send(&prepared, "").expect("never an error after confirm");
        assert_eq!(payment.status, PaymentStatus::Pending, "{payment:?}");
        let lookup = w.outgoing_payment_outcome(&payment.id).unwrap().unwrap();
        assert_eq!(
            lookup.status,
            PaymentStatus::Pending,
            "the saga is still open"
        );

        // A pass may still meet the unreachable mint; the next one settles.
        let _ = w.sync_wallet();
        let _ = w.sync_wallet();
        assert!(eventually(|| sent_outcome(&recorder, &payment.id)
            .is_some_and(
                |p| p.status == PaymentStatus::Complete && p.preimage.as_deref() == Some(PREIMAGE)
            )));
        assert!(w.balance().unwrap().confirmed_sats < 1_000);
        assert_eq!(mint.calls("post_melt"), 1, "exactly one payment");
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The melt request was still on its way when CDK asked the mint, which
    /// read Unpaid, so CDK compensated the proofs. The request then arrived
    /// and the mint paid it. The send must not have said Failed, and the
    /// late payment must reach the host and leave the balance.
    #[test]
    fn a_compensated_melt_the_mint_pays_late_is_pending_then_paid() {
        let dir = scratch("ambiguous-late-paid");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        receive_paid_bolt11(&w, &mint, 1_000);
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        mint.lose_next_melt_response(false);

        let payment = w.send(&prepared, "").expect("never an error after confirm");
        assert_eq!(payment.status, PaymentStatus::Pending, "{payment:?}");
        let history = w.list_recent_payments(50).unwrap();
        let row = history.iter().find(|p| p.id == payment.id);
        assert!(
            row.is_none_or(|p| p.status == PaymentStatus::Pending),
            "history agrees with the send: {row:?}"
        );
        assert_eq!(
            w.outgoing_payment_outcome(&payment.id)
                .unwrap()
                .unwrap()
                .status,
            PaymentStatus::Pending
        );
        w.sync_wallet().unwrap();
        assert!(
            sent_outcome(&recorder, &payment.id).is_none(),
            "Unpaid inside the grace window settles nothing"
        );

        assert!(
            mint.deliver_in_transit_melt(Some(PREIMAGE.into())),
            "the mint pays it"
        );
        w.sync_wallet().unwrap();
        assert!(eventually(|| sent_outcome(&recorder, &payment.id)
            .is_some_and(|p| p.status == PaymentStatus::Complete)));
        assert!(
            w.balance().unwrap().confirmed_sats <= 1_000 - 300,
            "the spent inputs left the balance: {:?}",
            w.balance().unwrap()
        );
        let row = w
            .list_recent_payments(50)
            .unwrap()
            .into_iter()
            .find(|p| p.id == payment.id)
            .expect("the melt is in history");
        assert_eq!(row.status, PaymentStatus::Complete, "{row:?}");
        assert_eq!(row.preimage.as_deref(), Some(PREIMAGE));
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The same lost request, but it never arrives: once the grace window
    /// has passed, the mint's Unpaid is believed and the send is Failed with
    /// the balance intact.
    #[test]
    fn a_compensated_melt_still_unpaid_after_the_grace_window_is_failed() {
        let dir = scratch("ambiguous-grace-failed");
        let (mut w, mint) = fake_wallet(&dir);
        w.set_test_melt_grace(Duration::from_millis(300));
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        receive_paid_bolt11(&w, &mint, 1_000);
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        mint.lose_next_melt_response(false);

        let payment = w.send(&prepared, "").unwrap();
        assert_eq!(payment.status, PaymentStatus::Pending);
        std::thread::sleep(Duration::from_millis(400));
        w.sync_wallet().unwrap();
        assert!(eventually(|| sent_outcome(&recorder, &payment.id)
            .is_some_and(|p| p.status == PaymentStatus::Failed)));
        assert_eq!(w.balance().unwrap().confirmed_sats, 1_000);
        assert_eq!(
            w.outgoing_payment_outcome(&payment.id)
                .unwrap()
                .unwrap()
                .status,
            PaymentStatus::Failed
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The lost request reaches the mint only after the grace window, when
    /// the send already reads Failed. It used to be paid over that Failed
    /// row, with its inputs still counted in the balance. The watcher now
    /// spends the inputs (into fresh proofs of ours) before it calls the send
    /// Failed, so the mint refuses the late request.
    #[test]
    fn a_melt_request_arriving_after_the_grace_window_cannot_be_paid() {
        let dir = scratch("ambiguous-grace-late-request");
        let (mut w, mint) = fake_wallet(&dir);
        w.set_test_melt_grace(Duration::from_millis(300));
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        receive_paid_bolt11(&w, &mint, 1_000);
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        mint.lose_next_melt_response(false);

        let payment = w.send(&prepared, "").unwrap();
        assert_eq!(payment.status, PaymentStatus::Pending);
        std::thread::sleep(Duration::from_millis(400));
        w.sync_wallet().unwrap();
        assert!(eventually(|| sent_outcome(&recorder, &payment.id)
            .is_some_and(|p| p.status == PaymentStatus::Failed)));

        assert!(
            !mint.deliver_in_transit_melt(Some(PREIMAGE.into())),
            "a request whose inputs are spent is refused"
        );
        w.sync_wallet().unwrap();
        assert_eq!(
            w.balance().unwrap().confirmed_sats,
            1_000,
            "the balance is whole, in proofs the mint still honours"
        );
        assert_eq!(
            w.outgoing_payment_outcome(&payment.id)
                .unwrap()
                .unwrap()
                .status,
            PaymentStatus::Failed
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A mint that issued after the wallet gave up on it: the quote reads
    /// issued, so the quote pass never mints it again, and the sats stayed
    /// out of the balance — with no receive event — until the next connect.
    #[test]
    fn a_mint_call_that_timed_out_is_recovered_on_the_next_pass() {
        let dir = scratch("mint-timeout-recovered");
        let (mut w, mint) = fake_wallet(&dir);
        w.set_test_budget(Duration::from_millis(500));
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        let before = mint.mint_quote_ids();
        bolt11_receive(&w, 400);
        let quote = newest_quote(&mint, &before);
        mint.pay(&quote, 400);
        mint.lose_next_mint_response();

        assert!(w.sync_wallet().is_err(), "the mint call ran out of time");
        assert_eq!(w.balance().unwrap().confirmed_sats, 0);
        let _ = w.sync_wallet();
        assert_eq!(
            w.balance().unwrap().confirmed_sats,
            400,
            "recovered without a reconnect"
        );
        assert!(eventually(|| recorder.received_ids().contains(&quote)));
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The ambiguous melt outlives the process: after a relaunch, history
    /// must not read Failed (CDK marked the compensated melt Failed) while the
    /// mint may still pay it, and a late payment must still be accounted for.
    #[test]
    fn an_ambiguous_melt_is_still_tracked_after_a_relaunch() {
        let dir = scratch("ambiguous-relaunch");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        receive_paid_bolt11(&w, &mint, 1_000);
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        mint.lose_next_melt_response(false);
        let payment = w.send(&prepared, "rent").unwrap();
        assert_eq!(payment.status, PaymentStatus::Pending);
        w.disconnect().unwrap();
        drop(w);

        assert!(
            mint.deliver_in_transit_melt(Some(PREIMAGE.into())),
            "the mint pays it"
        );
        let w = reopen(&dir, &mint);
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        let row = w
            .list_recent_payments(50)
            .unwrap()
            .into_iter()
            .find(|p| p.id == payment.id);
        assert!(
            row.as_ref()
                .is_none_or(|p| p.status != PaymentStatus::Failed),
            "a relaunch must not turn it Failed: {row:?}"
        );
        w.sync_wallet().unwrap();
        assert!(eventually(|| sent_outcome(&recorder, &payment.id)
            .is_some_and(
                |p| p.status == PaymentStatus::Complete && p.note.as_deref() == Some("rent")
            )));
        assert!(w.balance().unwrap().confirmed_sats <= 1_000 - 300);
        assert!(
            !dir.join(format!("{UNSETTLED_PREFIX}.{}", w.mint_tag()))
                .exists(),
            "a settled journal is removed"
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A pass that ran while a send still awaited its melt's answer resumed
    /// that melt too. The mint had not started on the request, read Unpaid,
    /// and CDK compensated the proofs of a payment the mint then made: the
    /// host saw Failed ("you were not charged") and the wallet counted spent
    /// proofs as its own.
    #[test]
    fn a_pass_during_a_confirm_in_flight_leaves_that_melt_alone() {
        let dir = scratch("pass-during-confirm");
        let (mut w, mint) = fake_wallet(&dir);
        w.set_test_budget(Duration::from_millis(500));
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        receive_paid_bolt11(&w, &mint, 1_000);
        mint.set_melt_outcome(test_mint::MeltOutcome::Paid {
            preimage: Some(PREIMAGE.into()),
        });
        mint.delay("post_melt", Duration::from_millis(1_500));
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        let payment = w.send(&prepared, "").unwrap();
        assert_eq!(
            payment.status,
            PaymentStatus::Pending,
            "outlived its budget"
        );

        let _ = w.sync_wallet();
        assert!(
            sent_outcome(&recorder, &payment.id).is_none(),
            "the pass settled a melt still in flight"
        );
        assert!(
            w.balance().unwrap().pending_send_sats > 0,
            "its proofs are still held: {:?}",
            w.balance().unwrap()
        );

        assert!(eventually(|| sent_outcome(&recorder, &payment.id)
            .is_some_and(|p| p.status == PaymentStatus::Complete)));
        let balance = w.balance().unwrap();
        assert_eq!(balance.confirmed_sats, 1_000 - 300 - 2, "{balance:?}");
        assert_eq!(balance.pending_send_sats, 0, "{balance:?}");
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn connect_fails_fast_on_a_hung_mint_and_recovers_later() {
        let dir = scratch("hung-mint");
        let (mut w, mint) = fake_wallet(&dir);
        w.set_test_budget(Duration::from_millis(300));
        mint.hang("get_mint_info");
        let started = std::time::Instant::now();
        assert!(matches!(w.connect(), Err(WalletError::Timeout)));
        assert!(started.elapsed() < Duration::from_secs(5));
        assert!(!w.is_connected());
        mint.unhang("get_mint_info");
        w.connect().expect("the next connect succeeds");
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A crash at the irreversible step leaves the melt's proofs reserved
    /// until saga recovery runs; connect must run it.
    #[test]
    fn connect_compensates_a_melt_interrupted_mid_flight() {
        let dir = scratch("saga-recovery");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        receive_paid_bolt11(&w, &mint, 1_000);
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        let PreparedSendToken::Opaque(quote_id) = prepared.token.clone() else {
            unreachable!()
        };

        // "Crash": drive CDK's melt and drop it while the mint holds the
        // request, before any answer — the payment never happened.
        mint.hang("post_melt");
        let wallet = w.wallet().unwrap();
        w.rt().block_on(async {
            let melt = wallet
                .prepare_melt(&quote_id, HashMap::new())
                .await
                .unwrap();
            let _ = tokio::time::timeout(Duration::from_millis(200), melt.confirm()).await;
        });
        assert!(
            w.balance().unwrap().confirmed_sats < 1_000,
            "the interrupted melt holds its inputs"
        );
        drop(wallet);
        drop(w);

        mint.unhang("post_melt");
        let w = reopen(&dir, &mint);
        w.connect().unwrap();
        let balance = w.balance().unwrap();
        assert_eq!(balance.confirmed_sats, 1_000, "{balance:?}");
        assert_eq!(balance.pending_send_sats, 0, "{balance:?}");
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn offer_quote_id(w: &CdkWallet) -> String {
        w.read_offer_pointer().expect("an offer pointer").quote_id
    }

    /// The offer is the receive address hosts publish; a new one per call
    /// (the old behaviour) would republish the descriptor on every read.
    #[test]
    fn receive_offer_is_stable_across_calls_reconnects_and_offline() {
        let dir = scratch("offer-stable");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let first = w.receive_offer().unwrap();
        assert!(first.starts_with("lno1"));
        assert_eq!(w.receive_offer().unwrap(), first);
        assert_eq!(mint.calls("post_mint_quote"), 1, "one offer, created once");
        drop(w);

        let offline = reopen(&dir, &mint);
        assert_eq!(
            offline.receive_offer().unwrap(),
            first,
            "the published offer is readable with no mint"
        );
        offline.connect().unwrap();
        assert_eq!(offline.receive_offer().unwrap(), first);
        assert_eq!(mint.calls("post_mint_quote"), 1);
        drop(offline);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The offer's quote id lives only in the local pointer file, so a
    /// reinstall (store and pointer both gone) published a NEW offer, and
    /// whatever was paid to the old one stayed at the mint, unclaimed. The
    /// pointer's backup brings the same offer back, and its payments with it.
    #[test]
    fn an_offer_backup_brings_the_offer_and_its_payments_back_after_a_reinstall() {
        let dir = scratch("offer-backup-original");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let offer = w.receive_offer().unwrap();
        let quote = mint.mint_quote_ids().pop().unwrap();
        let backup = w.offer_backup().expect("a published offer has a backup");
        drop(w);

        // Reinstalled without the backup: a different offer.
        let lost = scratch("offer-backup-lost");
        let w = reopen(&lost, &mint);
        w.connect().unwrap();
        assert_ne!(w.receive_offer().unwrap(), offer, "premise: the gap");
        drop(w);

        // Reinstalled with it: the same offer, and a payment made to it after
        // the reinstall is minted by the new store.
        let restored = scratch("offer-backup-restored");
        let w = reopen(&restored, &mint);
        w.connect().unwrap();
        assert_eq!(w.restore_offer_backups(&[backup]).unwrap(), 1);
        assert_eq!(w.receive_offer().unwrap(), offer);
        mint.pay(&quote, 300);
        w.sync_wallet().unwrap();
        assert_eq!(w.balance().unwrap().confirmed_sats, 300);
        drop(w);
        for d in [dir, lost, restored] {
            let _ = std::fs::remove_dir_all(d);
        }
    }

    /// A backup never replaces the offer a store already publishes, and one
    /// made for another mint, or that does not parse, is ignored.
    #[test]
    fn a_backup_never_replaces_the_local_offer_or_crosses_mints() {
        let dir = scratch("offer-backup-guards");
        let (w, _mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let offer = w.receive_offer().unwrap();
        let mine: serde_json::Value = serde_json::from_str(&w.offer_backup().unwrap()).unwrap();
        let other_quote = serde_json::json!({
            "v": 1, "mint": mine["mint"], "quote_id": "not-at-this-mint",
            "offer": "lno1someoneelse", "index": 7,
        });
        let other_mint = serde_json::json!({
            "v": 1, "mint": "https://other.example", "quote_id": "q", "offer": "lno1x", "index": 0,
        });
        let restored = w
            .restore_offer_backups(&[other_quote.to_string(), other_mint.to_string(), "{".into()])
            .unwrap();
        assert_eq!(restored, 0, "an unknown quote is not adopted");
        assert_eq!(w.receive_offer().unwrap(), offer, "the local offer stays");
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Payments made to the published offer while the proof store is gone
    /// must still be claimable: the quote is re-adopted with its re-derived
    /// NUT-20 key (the fake mint enforces the signature).
    #[test]
    fn offer_payments_survive_a_lost_proof_db() {
        let dir = scratch("offer-db-lost");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        w.receive_offer().unwrap();
        let quote = offer_quote_id(&w);
        mint.pay(&quote, 400);
        w.sync_wallet().unwrap();
        assert_eq!(w.balance().unwrap().confirmed_sats, 400);
        drop(w);

        std::fs::remove_file(dir.join(DB_FILE)).unwrap();
        mint.pay(&quote, 100); // paid while the store was gone

        let w = reopen(&dir, &mint);
        w.connect().unwrap();
        w.sync_wallet().unwrap();
        assert_eq!(
            w.balance().unwrap().confirmed_sats,
            500,
            "restored 400 plus the 100 paid to the offer meanwhile"
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn offer_rotates_only_when_expired_and_the_old_quote_still_mints() {
        let dir = scratch("offer-rotate");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        let first = w.receive_offer().unwrap();
        let old_quote = offer_quote_id(&w);

        set_local_expiry(&w, &old_quote, now_secs() + 3_600);
        assert_eq!(
            w.receive_offer().unwrap(),
            first,
            "not expired: no rotation"
        );

        set_local_expiry(&w, &old_quote, now_secs() - 1);
        let second = w.receive_offer().unwrap();
        assert_ne!(second, first);
        assert_eq!(w.read_offer_pointer().unwrap().index, 1);
        assert_eq!(w.receive_offer().unwrap(), second, "stable again");

        mint.pay(&old_quote, 50); // a late payer used the old offer
        w.sync_wallet().unwrap();
        assert_eq!(w.balance().unwrap().confirmed_sats, 50);
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn offer_pointer_is_an_artifact_the_wipe_may_remove() {
        assert!(is_our_artifact("cashu.redb.corrupt-1790312350"));
        assert!(is_our_artifact("cashu.redb.corrupt-1790312350-2"));
        assert!(!is_our_artifact("cashu.redb.corrupt-"));
        assert!(!is_our_artifact("cashu.redb.corrupt-abc"));
        assert!(!is_our_artifact("cashu.redb.corrupt-1-2-3"));
        assert!(!is_our_artifact("cashu.redb.bak"));
        assert!(is_our_artifact("cashu.offer.00c0ffee"));
        assert!(is_our_artifact("cashu.offer.00c0ffee.tmp"));
        assert!(!is_our_artifact("cashu.offer.xyz"));
        assert!(!is_our_artifact("cashu.offer.00c0ffee.bak"));
        assert!(!is_our_artifact("cashu.offer"));
    }

    // ---- melt quote lifetime, fees and the send budget (2026-10-13) ----
    //
    // A 12,027-sat BOLT11 send through mint.hedwig.sh left two UNPAID melt
    // quotes and no melt request. That mint keeps a RETIRED keyset charging
    // 1000 ppk; CDK spends every proof on a retired keyset first, so each
    // one costs a sat the fee preview did not count.

    /// A wallet funded on a mint whose keyset charged `fee_ppk`, which has
    /// since been retired for a free one: every proof it holds is on the
    /// retired, fee-charging keyset. Each receive of 255 sats is 8 proofs.
    fn wallet_with_retired_fee_proofs(
        dir: &Path,
        fee_ppk: u64,
        receives: usize,
    ) -> (CdkWallet, Arc<test_mint::FakeMint>) {
        let mint = Arc::new(test_mint::FakeMint::with_input_fee(fee_ppk));
        let mut cfg = config();
        cfg.working_dir = dir.to_path_buf();
        let w = CdkWallet::with_connector(cfg, "https://mint.example.com", mint.clone()).unwrap();
        w.connect().unwrap();
        for _ in 0..receives {
            receive_paid_bolt11(&w, &mint, 255);
        }
        mint.rotate_keyset(0);
        // Re-read keysets on every use, so the wallet sees the rotation.
        w.wallet()
            .unwrap()
            .set_metadata_cache_ttl(Some(Duration::ZERO));
        (w, mint)
    }

    /// A valid BOLT12 offer (LDK's parse test vectors); CDK parses offers
    /// before quoting them.
    const OFFER: &str =
        "lno1pgx9getnwss8vetrw3hhyuc5qqtzzqhwcuj966ma9n9nqwqtl032xeyv6755yeflt235pmww58egx6rxry";

    fn unspent_proofs(w: &CdkWallet) -> usize {
        let wallet = w.wallet().unwrap();
        w.rt().block_on(wallet.get_unspent_proofs()).unwrap().len()
    }

    fn local_melt_quote(w: &CdkWallet, id: &str) -> cdk::wallet::MeltQuote {
        let wallet = w.wallet().unwrap();
        w.rt()
            .block_on(wallet.localstore.get_melt_quote(id))
            .unwrap()
            .expect("the melt quote is stored")
    }

    fn quote_id_of(prepared: &PreparedSend) -> &str {
        match &prepared.token {
            PreparedSendToken::Opaque(id) => id,
            PreparedSendToken::None => panic!("a CDK prepared send carries its quote id"),
        }
    }

    /// Nothing of a refused send may linger: no proof reserved or pending,
    /// no quote held by an operation, no open saga.
    fn assert_nothing_held(w: &CdkWallet, quote_id: &str, balance_before: u64) {
        let balance = w.balance().unwrap();
        assert_eq!(balance.confirmed_sats, balance_before, "{balance:?}");
        assert_eq!(balance.pending_send_sats, 0, "{balance:?}");
        assert_eq!(
            local_melt_quote(w, quote_id).used_by_operation,
            None,
            "the quote must not stay reserved"
        );
        let wallet = w.wallet().unwrap();
        let sagas = w
            .rt()
            .block_on(wallet.localstore.get_incomplete_sagas())
            .unwrap();
        assert!(sagas.is_empty(), "{} open sagas", sagas.len());
    }

    /// The incident, BOLT11: amount + fee reserve fits the balance with a
    /// ~20-sat margin, but the 40 proofs on the retired keyset cost 40 sats
    /// to spend. The fee preview used to be the reserve alone, the hosts'
    /// balance check passed, and CDK refused the melt after the quote
    /// existed. Now the preview carries the input fees, so the hosts refuse
    /// up front with the real figures — and a send attempted anyway fails
    /// typed, before any melt request, leaving nothing reserved.
    #[test]
    fn incident_near_exact_balance_with_retired_fee_proofs_is_refused_up_front() {
        let dir = scratch("incident-fee-keyset");
        let (w, mint) = wallet_with_retired_fee_proofs(&dir, 1_000, 5);
        let balance = w.balance().unwrap().confirmed_sats;
        assert_eq!(balance, 1_275);
        let proofs = u64::try_from(unspent_proofs(&w)).unwrap();
        assert!(proofs > 20, "{proofs} proofs");
        // reserve 2: amount + reserve is 20 sats under the balance, fewer
        // than the 1-sat-per-proof cost of the retired-keyset proofs.
        let amount = balance - 2 - 20;
        let prepared = prepare(&w, &test_invoice(Some(amount * 1_000)), None).unwrap();
        let fee = prepared.fees_sats.expect("a fee is quoted");
        assert!(
            fee > 2 + 20,
            "the fee must count the retired-keyset proofs' input fees, got {fee}"
        );
        // The hosts' affordability check (CashuWalletService / Engine).
        assert!(
            prepared.amount_sats + fee > balance,
            "amount {} + fee {fee} must not look affordable from {balance}",
            prepared.amount_sats
        );
        let quote_id = quote_id_of(&prepared).to_string();
        assert_nothing_held(&w, &quote_id, balance);

        // A host that sends anyway gets a typed refusal, before any melt.
        let sent = w.send(&prepared, "");
        assert!(
            matches!(sent, Err(WalletError::InsufficientFunds)),
            "{sent:?}"
        );
        assert_eq!(mint.calls("post_melt"), 0, "no melt request was made");
        assert_eq!(mint.calls("post_swap"), 0, "no swap either");
        assert_eq!(
            mint.melt_quote_state(&quote_id),
            Some(MeltQuoteState::Unpaid)
        );
        // CDK 0.18.1 leaves the quote reserved after a failed preparation;
        // the wallet releases it.
        assert_nothing_held(&w, &quote_id, balance);
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// With room for the input fees the same wallet pays: CDK swaps the
    /// retired-keyset proofs (paying their fee) and melts fresh ones. The
    /// fake mint refuses any swap or melt that underpays a fee, so a paid
    /// melt proves the quoted fee covered the real cost.
    #[test]
    fn retired_fee_proofs_are_swapped_then_paid_when_the_fee_fits() {
        let dir = scratch("fee-keyset-pays");
        let (w, mint) = wallet_with_retired_fee_proofs(&dir, 1_000, 5);
        let balance = w.balance().unwrap().confirmed_sats;
        let proofs = u64::try_from(unspent_proofs(&w)).unwrap();
        // Room for the reserve and a sat for every proof, plus 10.
        let amount = balance - 2 - proofs - 10;
        let prepared = prepare(&w, &test_invoice(Some(amount * 1_000)), None).unwrap();
        let fee = prepared.fees_sats.unwrap();
        assert!(prepared.amount_sats + fee <= balance, "fee {fee}");
        assert!(fee > 2, "input fees are part of the fee, got {fee}");

        let payment = w.send(&prepared, "").unwrap();
        assert_eq!(payment.status, PaymentStatus::Complete);
        assert_eq!(mint.calls("post_melt"), 1, "exactly one payment");
        assert_eq!(
            w.balance().unwrap().pending_send_sats,
            0,
            "nothing left reserved"
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The same send from a wallet that has not yet seen the rotation: CDK's
    /// own metadata cache, not the zero TTL `wallet_with_retired_fee_proofs`
    /// sets. CDK keeps keysets for an hour, and keysets loaded from its
    /// database count as fresh, so nothing re-reads them until the mint
    /// refuses an output. Found against a real cdk-mintd 0.18.1 (#666 QA,
    /// QA-165): the pre-melt swap was refused InactiveKeyset, CDK refreshed
    /// and retried it (paying its fee), then sent the melt's change outputs
    /// on the retired keyset. The mint refused the melt, the send ended
    /// Failed with nothing paid, and the refused swap's saga stayed open,
    /// failing recovery on every later connect. The first send after any
    /// rotation must pay like the second one does.
    #[test]
    fn a_send_right_after_a_keyset_rotation_pays_and_leaves_no_saga() {
        let dir = scratch("rotation-stale-keysets");
        let mint = Arc::new(test_mint::FakeMint::with_input_fee(1_000));
        let mut cfg = config();
        cfg.working_dir = dir.clone();
        let w = CdkWallet::with_connector(cfg, "https://mint.example.com", mint.clone()).unwrap();
        w.connect().unwrap();
        for _ in 0..5 {
            receive_paid_bolt11(&w, &mint, 255);
        }
        mint.rotate_keyset(0);
        let balance = w.balance().unwrap().confirmed_sats;
        let proofs = u64::try_from(unspent_proofs(&w)).unwrap();
        // Room for the reserve and a sat for every proof, plus 10.
        let amount = balance - 2 - proofs - 10;
        let prepared = prepare(&w, &test_invoice(Some(amount * 1_000)), None).unwrap();
        let fee = prepared.fees_sats.unwrap();
        assert!(prepared.amount_sats + fee <= balance, "fee {fee}");

        let payment = w.send(&prepared, "").unwrap();
        assert_eq!(payment.status, PaymentStatus::Complete, "{payment:?}");
        assert_eq!(
            mint.melt_quote_state(quote_id_of(&prepared)),
            Some(MeltQuoteState::Paid)
        );
        let wallet = w.wallet().unwrap();
        let sagas = w
            .rt()
            .block_on(wallet.localstore.get_incomplete_sagas())
            .unwrap();
        assert!(sagas.is_empty(), "{} open sagas", sagas.len());
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Proofs a send in flight holds are not spendable. A second send that
    /// only the TOTAL could cover is refused by the hosts' check, because
    /// the balance and the price both count unreserved proofs only.
    #[test]
    fn proofs_held_by_a_send_in_flight_are_not_spendable() {
        let dir = scratch("reserved-not-spendable");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        receive_paid_bolt11(&w, &mint, 1_000);
        mint.set_melt_outcome(test_mint::MeltOutcome::Pending);
        let first = prepare(&w, &test_invoice(Some(600_000)), None).unwrap();
        assert_eq!(w.send(&first, "").unwrap().status, PaymentStatus::Pending);

        let balance = w.balance().unwrap();
        // 1,000 - 600 - 2 reserve; the fake mint returns no change.
        assert_eq!(balance.confirmed_sats, 398, "{balance:?}");
        assert!(balance.pending_send_sats >= 600, "{balance:?}");
        // 397 + 2 fits the 1,000 total but not the 398 unreserved sats.
        let second = prepare(&w, &test_invoice(Some(397_000)), None).unwrap();
        assert!(
            second.amount_sats + second.fees_sats.unwrap() > balance.confirmed_sats,
            "397 sats cannot be paid from {} unreserved sats",
            balance.confirmed_sats
        );
        assert!(matches!(
            w.send(&second, ""),
            Err(WalletError::InsufficientFunds)
        ));
        assert_eq!(mint.calls("post_melt"), 1, "only the first send melted");
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The fee preview runs CDK's preparation dry: it must leave no trace.
    #[test]
    fn a_fee_preview_holds_nothing() {
        let dir = scratch("preview-holds-nothing");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        receive_paid_bolt11(&w, &mint, 1_000);
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        assert_eq!(
            prepared.fees_sats,
            Some(2),
            "reserve only on a fee-free keyset"
        );
        assert_nothing_held(&w, quote_id_of(&prepared), 1_000);
        // An unaffordable preview (CDK's selection fails) holds nothing either.
        let too_much = prepare(&w, &test_invoice(Some(5_000_000)), None).unwrap();
        assert_nothing_held(&w, quote_id_of(&too_much), 1_000);
        assert_eq!(mint.calls("post_melt"), 0);
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_prepared_send_carries_its_quote_expiry() {
        let dir = scratch("quote-expiry");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        mint.set_melt_quote_ttl(120);
        let before = now_secs();
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        let expiry = prepared.expires_at_secs.expect("a melt quote expires");
        assert!(
            (before + 119..=now_secs() + 120).contains(&expiry),
            "expiry {expiry}"
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A quote with less life left than a melt needs is not started on:
    /// typed `QuoteExpired`, no melt request, nothing held — the caller
    /// re-quotes. BOLT11 and BOLT12 alike.
    #[test]
    fn a_quote_too_close_to_expiry_is_refused_before_any_melt() {
        for (kind, destination, sats) in [
            ("bolt11", test_invoice(Some(300_000)), None),
            ("bolt12", OFFER.to_string(), Some(300)),
        ] {
            let dir = scratch(&format!("near-expiry-{kind}"));
            let (mut w, mint) = fake_wallet(&dir);
            // A melt needs 20 s of quote to start (the default); a 1 s
            // confirm floor isolates that check from the confirm deadline.
            w.set_test_ttl_floors(Duration::from_secs(20), Duration::from_secs(1));
            w.connect().unwrap();
            receive_paid_bolt11(&w, &mint, 1_000);
            // This mint's quotes live 5 s.
            mint.set_melt_quote_ttl(5);
            let prepared = prepare(&w, &destination, sats).unwrap();
            let quote_id = quote_id_of(&prepared).to_string();
            assert!(
                matches!(w.send(&prepared, ""), Err(WalletError::QuoteExpired)),
                "{kind}"
            );
            assert_eq!(mint.calls("post_melt"), 0, "{kind}");
            assert_eq!(
                mint.melt_quote_state(&quote_id),
                Some(MeltQuoteState::Unpaid),
                "{kind}"
            );
            assert_nothing_held(&w, &quote_id, 1_000);
            drop(w);
            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    /// An already expired quote (the app slept on the sheet) is refused
    /// before CDK sees it; CDK's own refusal maps to the same typed error.
    #[test]
    fn an_expired_quote_is_refused_before_any_melt() {
        let dir = scratch("expired-quote");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        receive_paid_bolt11(&w, &mint, 1_000);
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        let quote_id = quote_id_of(&prepared).to_string();
        let wallet = w.wallet().unwrap();
        let mut quote = local_melt_quote(&w, &quote_id);
        quote.expiry = now_secs() - 1;
        w.rt()
            .block_on(wallet.localstore.add_melt_quote(quote))
            .unwrap();
        assert!(matches!(
            w.send(&prepared, ""),
            Err(WalletError::QuoteExpired)
        ));
        assert_eq!(mint.calls("post_melt"), 0);
        assert_nothing_held(&w, &quote_id, 1_000);
        assert!(matches!(
            map_melt_error(cdk::Error::ExpiredQuote(1, 2)),
            WalletError::QuoteExpired
        ));
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The old shape of the incident's other suspect: a preparation slower
    /// than the send budget made `send` answer Timeout and CANCEL a melt the
    /// quote still allowed. Now the budget only stops the waiting: the send
    /// is Pending, the melt is confirmed once prepared, and its outcome
    /// arrives as an event.
    #[test]
    fn a_preparation_slower_than_the_send_budget_still_pays() {
        let dir = scratch("slow-prepare-pays");
        let (mut w, mint) = fake_wallet(&dir);
        w.set_test_send_budget(Duration::from_millis(300));
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        receive_paid_bolt11(&w, &mint, 1_000);
        mint.set_melt_outcome(test_mint::MeltOutcome::Paid {
            preimage: Some(PREIMAGE.into()),
        });
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        // Stale keyset metadata the mint is slow to give: the preparation
        // takes ~1 s, past the budget.
        w.wallet()
            .unwrap()
            .set_metadata_cache_ttl(Some(Duration::ZERO));
        mint.delay_next("get_mint_keysets", Duration::from_secs(1));

        let payment = w
            .send(&prepared, "")
            .expect("a slow preparation is not an error");
        assert_eq!(payment.status, PaymentStatus::Pending);
        assert!(eventually(|| sent_outcome(&recorder, &payment.id)
            .is_some_and(
                |p| p.status == PaymentStatus::Complete && p.preimage.as_deref() == Some(PREIMAGE)
            )));
        assert_eq!(mint.calls("post_melt"), 1, "exactly one payment");
        assert_eq!(mint.calls("post_melt_quote"), 1, "never re-quoted");
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A lookup while that slow preparation runs must not resume — and
    /// compensate — the melt under the send.
    #[test]
    fn a_lookup_during_a_slow_preparation_is_pending_and_leaves_it_alone() {
        let dir = scratch("slow-prepare-lookup");
        let (mut w, mint) = fake_wallet(&dir);
        w.set_test_send_budget(Duration::from_millis(200));
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        receive_paid_bolt11(&w, &mint, 1_000);
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        w.wallet()
            .unwrap()
            .set_metadata_cache_ttl(Some(Duration::ZERO));
        mint.delay_next("get_mint_keysets", Duration::from_millis(1_500));

        let payment = w.send(&prepared, "").unwrap();
        assert_eq!(payment.status, PaymentStatus::Pending);
        let looked_up = w.outgoing_payment_outcome(&payment.id).unwrap().unwrap();
        assert_eq!(looked_up.status, PaymentStatus::Pending);
        assert!(eventually(|| sent_outcome(&recorder, &payment.id)
            .is_some_and(|p| p.status == PaymentStatus::Complete)));
        assert_eq!(mint.calls("post_melt"), 1);
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A preparation that outlives the quote's confirm deadline is cancelled,
    /// never confirmed into an expiring quote: the caller gets
    /// `QuoteExpired` (re-quote) and no melt request is ever made.
    #[test]
    fn a_preparation_past_the_quote_deadline_is_cancelled_not_melted() {
        let dir = scratch("slow-prepare-expires");
        let (mut w, mint) = fake_wallet(&dir);
        // Confirming needs 4 s of quote left. The quote lives 6 s and the
        // preparation takes 3 s: at confirm time the mint would still take
        // the melt, but the wallet must not bet the payment on it.
        w.set_test_ttl_floors(Duration::from_secs(1), Duration::from_secs(4));
        w.connect().unwrap();
        let recorder = Arc::new(Recorder::default());
        w.add_event_listener(recorder.clone());
        receive_paid_bolt11(&w, &mint, 1_000);
        mint.set_melt_quote_ttl(6);
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        let quote_id = quote_id_of(&prepared).to_string();
        w.wallet()
            .unwrap()
            .set_metadata_cache_ttl(Some(Duration::ZERO));
        mint.delay_next("get_mint_keysets", Duration::from_secs(3));

        assert!(matches!(
            w.send(&prepared, ""),
            Err(WalletError::QuoteExpired)
        ));
        // Let the abandoned task finish its (cancelled) preparation.
        std::thread::sleep(Duration::from_secs(4));
        assert_eq!(mint.calls("post_melt"), 0, "never melted");
        assert_nothing_held(&w, &quote_id, 1_000);
        assert!(
            sent_outcome(&recorder, &quote_id).is_none(),
            "a send reported as not made raises no event"
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `fees_sats` on the prepared send is the fee the caller agreed to. A
    /// melt that would cost more is cancelled before confirm, with the new
    /// fee to ask about.
    #[test]
    fn a_melt_costing_more_than_the_agreed_fee_is_refused_before_confirm() {
        let dir = scratch("fee-above-consent");
        let (w, mint) = wallet_with_retired_fee_proofs(&dir, 1_000, 2);
        let balance = w.balance().unwrap().confirmed_sats;
        let mut prepared = prepare(&w, &test_invoice(Some(100_000)), None).unwrap();
        let real = prepared.fees_sats.unwrap();
        prepared.fees_sats = Some(2); // the reserve alone: the old preview
        let quote_id = quote_id_of(&prepared).to_string();
        match w.send(&prepared, "") {
            Err(WalletError::FeeChanged { fees_sats }) => assert_eq!(fees_sats, real),
            other => panic!("expected FeeChanged, got {other:?}"),
        }
        assert_eq!(mint.calls("post_melt"), 0);
        assert_eq!(mint.calls("post_swap"), 0);
        assert_nothing_held(&w, &quote_id, balance);
        // Agreeing to the real fee pays it.
        prepared.fees_sats = Some(real);
        assert_eq!(
            w.send(&prepared, "").unwrap().status,
            PaymentStatus::Complete
        );
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// After the melt request may have reached the mint, nothing is retried
    /// or re-quoted: the send is Pending, and sending the same prepared
    /// send again cannot make a second melt request.
    #[test]
    fn an_ambiguous_melt_is_never_requoted_or_sent_twice() {
        let dir = scratch("ambiguous-no-requote");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        receive_paid_bolt11(&w, &mint, 1_000);
        // The mint applied the melt and is still routing it; its answer is
        // lost and it cannot be asked: the outcome is unknown.
        mint.set_melt_outcome(test_mint::MeltOutcome::Pending);
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        mint.lose_next_melt_response(true);
        mint.fail_next("get_melt_quote_status", 50);
        let payment = w.send(&prepared, "").unwrap();
        assert_eq!(payment.status, PaymentStatus::Pending);
        assert!(w.send(&prepared, "").is_err(), "the quote is in use");
        assert_eq!(mint.calls("post_melt"), 1, "one melt request");
        assert_eq!(mint.calls("post_melt_quote"), 1, "never re-quoted");
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// BOLT12 keeps working: priced, expiring, paid once.
    #[test]
    fn a_bolt12_send_is_priced_and_paid_once() {
        let dir = scratch("bolt12-send");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        receive_paid_bolt11(&w, &mint, 1_000);
        let prepared = prepare(&w, OFFER, Some(300)).unwrap();
        assert_eq!(prepared.amount_sats, 300);
        assert_eq!(prepared.fees_sats, Some(2));
        assert!(prepared.expires_at_secs.is_some());
        let payment = w.send(&prepared, "").unwrap();
        assert_eq!(payment.status, PaymentStatus::Complete);
        assert_eq!(mint.calls("post_melt"), 1);
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn logs_name_a_quote_by_a_short_digest() {
        let id = "8f3a1c2d-9b7e-4c1a-a5d2-0e9f8b7c6d5e";
        let tag = quote_tag(id);
        assert_eq!(tag.len(), 8);
        assert!(tag.chars().all(|c| c.is_ascii_hexdigit()), "{tag}");
        assert_eq!(tag, quote_tag(id), "one quote, one tag");
        assert!(!id.contains(&tag), "the tag gives away no part of the id");
        assert_ne!(quote_tag("melt1"), quote_tag("melt2"));
    }

    /// A fee preview and the send after it read the mint's keysets once:
    /// the read before a melt is shared for `keyset_refresh`.
    #[test]
    fn a_preview_and_its_send_read_the_keysets_once() {
        let dir = scratch("keysets-read-once");
        let (w, mint) = fake_wallet(&dir);
        w.connect().unwrap();
        receive_paid_bolt11(&w, &mint, 1_000);
        let before = mint.calls("get_mint_keysets");
        let prepared = prepare(&w, &test_invoice(Some(300_000)), None).unwrap();
        assert_eq!(
            w.send(&prepared, "").unwrap().status,
            PaymentStatus::Complete
        );
        assert_eq!(mint.calls("get_mint_keysets") - before, 1);
        drop(w);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// cdk-mintd 0.18.1 names quotes by UUIDv7, whose first 8 hex digits are
    /// the top of a millisecond timestamp: every quote a mint issues within
    /// ~65 s shares them. These two are QA-166's run against a real mint
    /// (#666 QA), 40 ms apart: the quote refused QuoteExpired and its
    /// re-quote, which paid. Both logged as `melt 01a1406b`, so the log
    /// could not say which one was sent. Updating this to pass means
    /// changing `logs_name_a_quote_by_a_short_prefix` too.
    #[test]
    fn a_quote_and_its_requote_get_different_log_tags() {
        let expired = "01a1406b-ee7d-73cc-aae6-a8b6aaa30098";
        let requoted = "01a1406b-eea4-77ca-ab0f-db1d985b2e79";
        for id in [expired, requoted] {
            let tag = quote_tag(id);
            assert!(tag.len() <= 8, "{tag:?} is too long for a log tag");
            assert!(tag.len() < id.len(), "{tag:?} is the whole id");
        }
        assert_ne!(quote_tag(expired), quote_tag(requoted));
    }
}
