//! Wallet FFI: the Cashu (CDK) wallet and the Breez→Cashu migration engine.
//!
//! Why the asymmetry — Cashu is a real Rust object here, Breez is a foreign
//! trait the hosts implement: `breez-sdk-liquid` ships a forked
//! `libsqlite3-sys` that links plain sqlite3, which cannot coexist in one
//! binary with sonar-core's SQLCipher. So Breez can never enter this crate.
//! Both apps already integrate Breez natively (SonarWalletKit on Apple,
//! `WalletBridge` on Compose); they implement [`HostMigrationSource`] over
//! that existing integration and the Rust engine drives it.
//!
//! Call shape for hosts:
//!
//! ```text
//! let wallet = SonarCashuWallet::open(nsec, mint_url, dir)   // NUT-13 restore on fresh store
//! let engine = SonarMigration::new(source, wallet, limits)
//! let plan   = engine.plan(...)      // no funds move; fee is visible here
//!   ...show custody consent + fee, get the user's explicit yes...
//! let paid   = engine.execute(plan)  // the ONE spending call
//! let done   = engine.resume(...)    // safe to re-run after a crash
//! ```

use std::sync::Arc;

use sonar_wallet::{
    cashu_wallet_seed, nsec_to_secret, Balance, Destination, Payment, PaymentLookup,
    PaymentLookupStatus, PreparedSend, PreparedSendToken, ReceiveMethod, ReceiveRequest,
    Result as WalletResult, WalletBackend, WalletCapabilities, WalletError, WalletEventListener,
    Zeroizing,
};
use sonar_wallet_cdk::CdkWallet;
use sonar_wallet_migrate::{
    MigrationAttempt, MigrationAttemptState as CoreMigrationAttemptState, MigrationEngine,
    MigrationJournal, MigrationLimits, Settlement,
};

use crate::{FfiResult, SonarFfiError};

impl From<WalletError> for SonarFfiError {
    fn from(e: WalletError) -> Self {
        SonarFfiError::Core(e.to_string())
    }
}

impl From<sonar_wallet_migrate::MigrateError> for SonarFfiError {
    fn from(e: sonar_wallet_migrate::MigrateError) -> Self {
        SonarFfiError::Core(e.to_string())
    }
}

/// Balance snapshot, sats.
#[derive(uniffi::Record)]
pub struct WalletBalance {
    pub confirmed_sats: u64,
    pub pending_receive_sats: u64,
    pub pending_send_sats: u64,
}

impl From<Balance> for WalletBalance {
    fn from(b: Balance) -> Self {
        Self {
            confirmed_sats: b.confirmed_sats,
            pending_receive_sats: b.pending_receive_sats,
            pending_send_sats: b.pending_send_sats,
        }
    }
}

/// A priced send from the host's wallet: what the engine asked for, and what
/// the host's backend quoted. `token` is opaque — the host hands it back to
/// its own `send`, so it can be a quote id, a serialized prepare-response, or
/// anything else the host needs to execute exactly this quote.
#[derive(uniffi::Record)]
pub struct HostSendQuote {
    pub amount_sats: u64,
    pub fees_sats: Option<u64>,
    pub token: String,
}

/// A payment the host's wallet made.
#[derive(uniffi::Record)]
pub struct HostPayment {
    pub id: String,
    pub amount_sats: u64,
    pub fees_sats: Option<u64>,
    /// True only when the host's backend reports the payment as settled.
    pub complete: bool,
}

#[derive(uniffi::Enum)]
pub enum HostPaymentLookupStatus {
    Pending,
    Complete,
    Failed,
    Refundable,
    Unknown,
}

#[derive(uniffi::Record)]
pub struct HostPaymentLookup {
    pub status: HostPaymentLookupStatus,
    pub id: Option<String>,
    pub fees_sats: Option<u64>,
}

/// Why a host-side wallet call failed, in a form UniFFI can carry BACK across
/// the boundary.
///
/// This must NOT be `#[uniffi(flat_error)]`. A flat error cannot be lifted out
/// of a foreign trait: when the host throws one, UniFFI aborts the entire
/// outer call with the opaque message "Can't lift flat errors", and the Rust
/// side never sees an `Err` at all. That is not merely a bad message — it
/// makes every host failure unrecoverable, because the engine's own retry
/// logic never runs. A real Pixel drain failed exactly this way: Breez
/// refused the whole balance with "Cannot pay: not enough funds",
/// `plan_drain`'s step-down never fired, and the user saw
/// "Can't lift flat errors".
///
/// [`InsufficientFunds`](Self::InsufficientFunds) is a distinct variant rather
/// than a message because the engine branches on it: it is the signal to plan
/// a smaller amount, and a string could not be matched on safely.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum HostWalletError {
    /// The wallet cannot afford this amount plus its fee. The engine responds
    /// by stepping the amount down, so hosts should prefer this over
    /// `Failed` whenever the backend says so.
    #[error("insufficient funds")]
    InsufficientFunds,
    /// Anything else, carrying the host's own message.
    ///
    /// The field is `reason`, not `message`: UniFFI maps this variant to a
    /// Kotlin subclass of `Exception`, and a field called `message` collides
    /// with `Throwable.message` — the generated bindings then fail to compile.
    #[error("{reason}")]
    Failed { reason: String },
}

/// The migration SOURCE, implemented by the host over its existing native
/// Breez integration. Deliberately minimal — the engine needs exactly these
/// four operations, so hosts do not have to mirror the whole `WalletBackend`
/// trait over the FFI boundary.
///
/// Implementations are called from a Rust thread and MUST block until done.
/// Failures are reported by throwing [`HostWalletError`]; see the note there
/// on why this deliberately is not the flat `SonarFfiError` used elsewhere in
/// this FFI surface.
#[uniffi::export(with_foreign)]
pub trait HostMigrationSource: Send + Sync {
    /// Confirmed spendable balance, sats.
    fn balance_sats(&self) -> Result<u64, HostWalletError>;
    /// Price paying `invoice` for `amount_sats` WITHOUT paying it.
    fn prepare(&self, invoice: String, amount_sats: u64) -> Result<HostSendQuote, HostWalletError>;
    /// Pay a previously prepared quote. Called at most once per token.
    fn send(&self, token: String, note: String) -> Result<HostPayment, HostWalletError>;
    /// Reconcile an ambiguous or pending send by its BOLT11 payment hash.
    fn lookup_payment(&self, payment_hash: String) -> Result<HostPaymentLookup, HostWalletError>;
}

impl From<HostWalletError> for WalletError {
    fn from(err: HostWalletError) -> Self {
        match err {
            // Preserved as the typed variant: the migration engine matches on
            // it to plan a smaller amount.
            HostWalletError::InsufficientFunds => WalletError::InsufficientFunds,
            HostWalletError::Failed { reason } => WalletError::Backend(reason),
        }
    }
}

/// Adapts the host's minimal source to the full `WalletBackend` the engine
/// consumes. Everything the engine does not call is `Unsupported` — the
/// engine only ever touches balance / parse / prepare_send / send.
struct HostSourceBackend {
    host: Arc<dyn HostMigrationSource>,
}

impl WalletBackend for HostSourceBackend {
    fn capabilities(&self) -> WalletCapabilities {
        WalletCapabilities {
            bolt11_send: true,
            ..Default::default()
        }
    }

    fn connect(&self) -> WalletResult<()> {
        // The host owns its wallet's lifecycle; by the time it hands us a
        // source it is already connected.
        Ok(())
    }

    fn disconnect(&self) -> WalletResult<()> {
        Ok(())
    }

    fn is_connected(&self) -> bool {
        true
    }

    fn balance(&self) -> WalletResult<Balance> {
        let confirmed = self
            .host
            .balance_sats()
            // Map through From<HostWalletError>, NOT to_string(): the engine
            // branches on InsufficientFunds to plan a smaller amount,
            // and stringifying it here silently disables that.
            .map_err(WalletError::from)?;
        Ok(Balance {
            confirmed_sats: confirmed,
            ..Balance::default()
        })
    }

    fn receive(&self, _request: &ReceiveRequest) -> WalletResult<String> {
        Err(WalletError::Unsupported(
            "the migration source is send-only".into(),
        ))
    }

    fn parse_destination(&self, input: &str) -> WalletResult<Destination> {
        // The engine only ever feeds this a BOLT11 invoice minted by the
        // destination moments earlier; classify locally rather than making the
        // host round-trip its parser.
        Ok(sonar_wallet::classify_destination(input))
    }

    fn prepare_send(
        &self,
        destination: &Destination,
        amount_sats: Option<u64>,
    ) -> WalletResult<PreparedSend> {
        let amount = amount_sats.ok_or_else(|| {
            WalletError::InvalidDestination("migration always supplies an amount".into())
        })?;
        let quote = self
            .host
            .prepare(destination.raw.clone(), amount)
            // Map through From<HostWalletError>, NOT to_string(): the engine
            // branches on InsufficientFunds to plan a smaller amount,
            // and stringifying it here silently disables that.
            .map_err(WalletError::from)?;
        Ok(PreparedSend {
            destination: destination.clone(),
            amount_sats: quote.amount_sats,
            fees_sats: quote.fees_sats,
            token: PreparedSendToken::Opaque(quote.token),
        })
    }

    fn send(&self, prepared: &PreparedSend, note: &str) -> WalletResult<Payment> {
        let PreparedSendToken::Opaque(token) = &prepared.token else {
            return Err(WalletError::InvalidInput(
                "this prepared send did not come from the host source".into(),
            ));
        };
        let paid = self
            .host
            .send(token.clone(), note.to_string())
            // Map through From<HostWalletError>, NOT to_string(): the engine
            // branches on InsufficientFunds to plan a smaller amount,
            // and stringifying it here silently disables that.
            .map_err(WalletError::from)?;
        Ok(Payment {
            id: paid.id,
            amount_sats: paid.amount_sats,
            fees_sats: paid.fees_sats,
            incoming: false,
            timestamp_secs: 0,
            status: if paid.complete {
                sonar_wallet::PaymentStatus::Complete
            } else {
                sonar_wallet::PaymentStatus::Pending
            },
            preimage: None,
            note: (!note.is_empty()).then(|| note.to_string()),
        })
    }

    fn list_recent_payments(&self, _limit: u32) -> WalletResult<Vec<Payment>> {
        Ok(Vec::new())
    }

    fn lookup_payment(&self, payment_hash: &str) -> WalletResult<PaymentLookup> {
        let lookup = self
            .host
            .lookup_payment(payment_hash.to_string())
            .map_err(WalletError::from)?;
        Ok(PaymentLookup {
            status: match lookup.status {
                HostPaymentLookupStatus::Pending => PaymentLookupStatus::Pending,
                HostPaymentLookupStatus::Complete => PaymentLookupStatus::Complete,
                HostPaymentLookupStatus::Failed => PaymentLookupStatus::Failed,
                HostPaymentLookupStatus::Refundable => PaymentLookupStatus::Refundable,
                HostPaymentLookupStatus::Unknown => PaymentLookupStatus::Unknown,
            },
            id: lookup.id,
            fees_sats: lookup.fees_sats,
        })
    }

    fn add_event_listener(&self, _listener: Arc<dyn WalletEventListener>) -> u64 {
        0
    }

    fn remove_event_listener(&self, _id: u64) {}

    fn wipe_local_storage(&self) -> WalletResult<()> {
        Err(WalletError::Unsupported(
            "the host owns its own wallet storage".into(),
        ))
    }
}

/// The Cashu wallet, backed by `sonar-wallet-cdk`. Seeded from the account
/// nsec via the `sonar-cashu-v1` HKDF domain — a different domain from the
/// Breez seed, so the two funds domains share no key material while both stay
/// restorable from the account key alone.
#[derive(uniffi::Object)]
pub struct SonarCashuWallet {
    inner: CdkWallet,
    migration_journal: Arc<MigrationJournal>,
}

#[uniffi::export]
impl SonarCashuWallet {
    /// Open (or create) the Cashu wallet and connect to the mint. On a store
    /// that has never completed a NUT-13 restore against this mint, the
    /// restore scan runs here — that is what makes a reinstall or a wiped
    /// store recover funds instead of showing an empty balance.
    #[uniffi::constructor]
    pub fn open(nsec: String, mint_url: String, working_dir: String) -> FfiResult<Arc<Self>> {
        let secret = Zeroizing::new(nsec_to_secret(&nsec)?);
        let working_dir = std::path::PathBuf::from(working_dir);
        let migration_journal = Arc::new(MigrationJournal::new(
            &working_dir,
            secret.as_slice(),
            mint_url.as_bytes(),
        )?);
        let inner = CdkWallet::new(
            sonar_wallet::WalletConfig {
                seed: Zeroizing::new(cashu_wallet_seed(&secret).to_vec()),
                network: sonar_wallet::Network::Mainnet,
                api_key: None,
                working_dir,
            },
            &mint_url,
        )?;
        inner.connect()?;
        Ok(Arc::new(Self {
            inner,
            migration_journal,
        }))
    }

    pub fn balance(&self) -> FfiResult<WalletBalance> {
        Ok(self.inner.balance()?.into())
    }

    /// Reconcile with the mint now (mints paid quotes, finalizes melts).
    pub fn sync(&self) -> FfiResult<()> {
        Ok(self.inner.sync_wallet()?)
    }

    /// A reusable BOLT12 offer for this wallet.
    pub fn receive_offer(&self) -> FfiResult<String> {
        Ok(self.inner.receive_offer()?)
    }

    /// A BOLT11 invoice for an exact amount.
    pub fn receive_invoice(&self, amount_sats: u64) -> FfiResult<String> {
        Ok(self.inner.receive(&ReceiveRequest {
            method: ReceiveMethod::Bolt11Invoice,
            amount_sats: Some(amount_sats),
            description: None,
        })?)
    }

    pub fn disconnect(&self) -> FfiResult<()> {
        Ok(self.inner.disconnect()?)
    }
}

/// What the user must see before consenting. Amounts in sats.
#[derive(uniffi::Record)]
pub struct MigrationQuote {
    /// Net amount that will arrive in the Cashu wallet.
    pub amount_sats: u64,
    /// Fee the source wallet will pay on top, when it can quote one.
    pub source_fee_sats: Option<u64>,
    /// Destination balance before the migration, retained for display only.
    /// Settlement uses the journaled exact quote id, never this aggregate.
    pub destination_baseline_sats: u64,
    /// Opaque handle for `execute`; single-use.
    pub plan_id: String,
}

#[derive(uniffi::Enum)]
pub enum MigrationOutcome {
    /// Funds are in the Cashu wallet.
    Settled { cashu_confirmed_sats: u64 },
    /// Paid, not yet visible. NOT a failure — the wallet keeps reconciling;
    /// call `settle` again (the same call is the crash-resume path).
    Pending { cashu_confirmed_sats: u64 },
}

impl From<Settlement> for MigrationOutcome {
    fn from(s: Settlement) -> Self {
        match s {
            Settlement::Settled { amount_sats } => MigrationOutcome::Settled {
                cashu_confirmed_sats: amount_sats,
            },
            Settlement::Pending { amount_sats } => MigrationOutcome::Pending {
                cashu_confirmed_sats: amount_sats,
            },
        }
    }
}

#[derive(uniffi::Enum)]
pub enum MigrationAttemptState {
    AwaitingConsent,
    Sending,
    PaymentUnknown,
    SourcePending,
    SourcePaid,
    MintPaid,
    Settled,
    SourceFailed,
    ExpiredUnsent,
}

#[derive(uniffi::Record)]
pub struct MigrationAttemptStatus {
    pub settlement_id: String,
    pub amount_sats: u64,
    pub fee_sats: Option<u64>,
    pub state: MigrationAttemptState,
    pub payment_hash: String,
}

impl From<MigrationAttempt> for MigrationAttemptStatus {
    fn from(attempt: MigrationAttempt) -> Self {
        Self {
            settlement_id: attempt.settlement_id,
            amount_sats: attempt.amount_sats,
            fee_sats: attempt.source_fee_sats,
            state: match attempt.state {
                CoreMigrationAttemptState::AwaitingConsent => {
                    MigrationAttemptState::AwaitingConsent
                }
                CoreMigrationAttemptState::Sending => MigrationAttemptState::Sending,
                CoreMigrationAttemptState::PaymentUnknown => MigrationAttemptState::PaymentUnknown,
                CoreMigrationAttemptState::SourcePending => MigrationAttemptState::SourcePending,
                CoreMigrationAttemptState::SourcePaid => MigrationAttemptState::SourcePaid,
                CoreMigrationAttemptState::MintPaid => MigrationAttemptState::MintPaid,
                CoreMigrationAttemptState::Settled => MigrationAttemptState::Settled,
                CoreMigrationAttemptState::SourceFailed => MigrationAttemptState::SourceFailed,
                CoreMigrationAttemptState::ExpiredUnsent => MigrationAttemptState::ExpiredUnsent,
            },
            payment_hash: attempt.payment_hash,
        }
    }
}

/// Drives one migration. Held by the host across the consent step: `plan` →
/// (consent UI) → `execute` → `resume`.
#[derive(uniffi::Object)]
pub struct SonarMigration {
    source: HostSourceBackend,
    dest: Arc<SonarCashuWallet>,
    limits: MigrationLimits,
    /// Only a plan created in this process can be executed because its source
    /// prepared-send token is intentionally not persisted. Restarted attempts
    /// remain available through the journal-backed `status` and `resume`.
    plan: std::sync::Mutex<Option<(String, sonar_wallet_migrate::MigrationPlan)>>,
}

#[uniffi::export]
impl SonarMigration {
    /// `dest_max_sats` is the mint's per-quote ceiling (mint.hedwig.sh: 500000)
    /// and `fee_cap_sats` is a fail-closed cap on the source fee — a quote
    /// above it, or a source that cannot quote a fee at all, refuses to plan.
    #[uniffi::constructor]
    pub fn new(
        source: Arc<dyn HostMigrationSource>,
        destination: Arc<SonarCashuWallet>,
        dest_max_sats: Option<u64>,
        fee_cap_sats: Option<u64>,
    ) -> Arc<Self> {
        Arc::new(Self {
            source: HostSourceBackend { host: source },
            dest: destination,
            limits: MigrationLimits {
                dest_max_sats,
                fee_cap_sats,
            },
            plan: std::sync::Mutex::new(None),
        })
    }

    /// Price the migration. Nothing is paid. `amount_sats = None` plans a
    /// whole-balance drain.
    pub fn plan(&self, amount_sats: Option<u64>) -> FfiResult<MigrationQuote> {
        let engine = MigrationEngine::new(
            &self.source,
            self.dest.inner_ref(),
            self.limits.clone(),
            &self.dest.migration_journal,
        );
        let baseline = self.dest.inner_ref().balance()?.confirmed_sats;
        let plan = match amount_sats {
            Some(a) => engine.plan_amount(a),
            None => engine.plan_drain(),
        }?;
        let quote = MigrationQuote {
            amount_sats: plan.amount_sats,
            source_fee_sats: plan.source_fee_sats,
            destination_baseline_sats: baseline,
            plan_id: plan.settlement_id.clone(),
        };
        *self.plan.lock().unwrap_or_else(|e| e.into_inner()) = Some((quote.plan_id.clone(), plan));
        Ok(quote)
    }

    /// Pay the planned migration. THE spending call — hosts must not reach it
    /// without explicit user consent to the custody change. Single-use: the
    /// plan is consumed, so a double-tap cannot pay twice.
    pub fn execute(&self, plan_id: String) -> FfiResult<HostPayment> {
        let taken = {
            let mut slot = self.plan.lock().unwrap_or_else(|e| e.into_inner());
            match slot.take() {
                Some((id, plan)) if id == plan_id => Some(plan),
                // Put a non-matching plan back; the caller passed a stale id.
                Some(other) => {
                    *slot = Some(other);
                    None
                }
                None => None,
            }
        };
        let plan = taken.ok_or_else(|| {
            SonarFfiError::InvalidInput(
                "no such migration plan (expired or already executed)".into(),
            )
        })?;
        let engine = MigrationEngine::new(
            &self.source,
            self.dest.inner_ref(),
            self.limits.clone(),
            &self.dest.migration_journal,
        );
        let payment = engine.execute_once(&plan)?;
        Ok(HostPayment {
            id: payment.id,
            amount_sats: payment.amount_sats,
            fees_sats: payment.fees_sats,
            complete: payment.status == sonar_wallet::PaymentStatus::Complete,
        })
    }

    /// Return the durable attempt, including one created before this process.
    pub fn status(&self) -> FfiResult<Option<MigrationAttemptStatus>> {
        let engine = MigrationEngine::new(
            &self.source,
            self.dest.inner_ref(),
            self.limits.clone(),
            &self.dest.migration_journal,
        );
        Ok(engine.status()?.map(MigrationAttemptStatus::from))
    }

    /// Reconcile the journaled source payment and exact destination quote.
    /// Safe to call any number of times, including after a crash.
    pub fn resume(&self, polls: u32) -> FfiResult<MigrationOutcome> {
        let engine = MigrationEngine::new(
            &self.source,
            self.dest.inner_ref(),
            self.limits.clone(),
            &self.dest.migration_journal,
        );
        let settlement_id = engine
            .status()?
            .ok_or_else(|| SonarFfiError::InvalidInput("no migration attempt".into()))?
            .settlement_id;
        Ok(engine
            .settle(&settlement_id, polls, std::time::Duration::from_secs(15))?
            .into())
    }

    /// Remove a consent/expired attempt only while no payment can have left.
    pub fn cancel_unspent(&self) -> FfiResult<()> {
        let engine = MigrationEngine::new(
            &self.source,
            self.dest.inner_ref(),
            self.limits.clone(),
            &self.dest.migration_journal,
        );
        engine.cancel_unspent()?;
        *self.plan.lock().unwrap_or_else(|e| e.into_inner()) = None;
        Ok(())
    }
}

impl SonarCashuWallet {
    fn inner_ref(&self) -> &CdkWallet {
        &self.inner
    }
}
