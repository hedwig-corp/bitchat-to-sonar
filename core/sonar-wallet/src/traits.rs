use std::sync::Arc;
use std::time::Duration;

use crate::error::{Result, WalletError};
use crate::types::{
    Balance, Destination, ExchangeRate, Payment, PaymentLookup, PreparedSend, ReceiveMethod,
    ReceiveRequest, TrackedReceive, TrackedReceiveState, WalletCapabilities, WalletEvent,
};

/// Host-side observer for wallet events. Callbacks are synchronous and must
/// be cheap/non-blocking; they can be invoked from a backend-owned thread.
/// Mirrors the sonar-ffi callback-interface shape so it can be exported over
/// UniFFI unchanged when the FFI surface lands.
///
/// Backends must invoke listeners from a thread that is free to re-enter the
/// backend — a listener reacting to [`WalletEvent::Synced`] by calling
/// [`WalletBackend::balance`] is the documented usage and must not deadlock
/// or panic.
pub trait WalletEventListener: Send + Sync {
    fn on_event(&self, event: WalletEvent);
}

/// The wallet contract every backend implements.
///
/// Sync and object-safe by design (repo convention: traits are sync, the FFI
/// layer is blocking); async backends own their runtime internally, like
/// `SonarNode` in sonar-ffi does. Methods may be called from any OS thread,
/// but they BLOCK — never call them from inside an async executor (a tokio
/// task, a Swift/Kotlin coroutine bridged onto one): a blocking bridge nested
/// in a runtime panics or starves it, same as any blocking I/O would. The
/// intended callers are the FFI hosts, which invoke from plain threads.
///
/// Lifecycle rules (0xdead10cc lineage — hosts call these from app-lifecycle
/// hooks):
/// - `connect` is idempotent: calling it while connected is a cheap no-op Ok.
/// - `disconnect` is idempotent and must be fast; it must not wait for
///   long-running sync work, and in particular must not block behind an
///   in-flight `connect`.
/// - a failed `disconnect` must leave the backend able to retry teardown; it
///   must never drop its only handle to a node that is still running, or the
///   next `connect` opens a second node over the same database.
/// - `disconnect` does NOT wait for in-flight operations. An operation that
///   straddles a teardown may fail with a backend error, and a send in that
///   window is settled by the payment protocol itself — its true outcome is
///   reconciled from the backend's persistent payment store on the next
///   connect (this is why payment ids must be stable). Deferring teardown
///   behind a slow send is the exact background-kill shape the fast-close
///   rule above exists to prevent.
///
/// Capability-gated methods default to [`WalletError::Unsupported`] so
/// backends implement only what they have; callers gate on
/// [`WalletBackend::capabilities`] first.
pub trait WalletBackend: Send + Sync {
    fn capabilities(&self) -> WalletCapabilities;

    fn connect(&self) -> Result<()>;
    fn disconnect(&self) -> Result<()>;
    fn is_connected(&self) -> bool;

    fn balance(&self) -> Result<Balance>;

    /// Ask the backend to reconcile with the network now. Hosts need this on
    /// the push-wake path, where the app is awake specifically to settle a
    /// payment and cannot wait for the next scheduled sync.
    fn sync_wallet(&self) -> Result<()> {
        Err(WalletError::Unsupported("explicit sync".into()))
    }

    /// Create something the payer can pay.
    fn receive(&self, request: &ReceiveRequest) -> Result<String>;

    /// The reusable amountless BOLT12 offer — stable per wallet, so callers
    /// may cache the returned string.
    fn receive_offer(&self) -> Result<String> {
        self.receive(&ReceiveRequest::offer())
    }

    /// Parse/classify a user-supplied destination. Backends should refine the
    /// pure [`crate::classify_destination`] result with their own parser
    /// (amounts, notes) when they can.
    ///
    /// Must work while disconnected for destinations that can be classified
    /// offline: hosts validate pasted input before the node is up (on iOS the
    /// node is foreground-gated).
    fn parse_destination(&self, input: &str) -> Result<Destination>;

    /// Price a send without moving money. `amount_sats` settles an amountless
    /// destination; `None` means "use the amount encoded in the destination".
    /// Backends resolve the two through [`crate::resolve_send_amount`], which
    /// refuses both the no-amount-anywhere case and a caller amount that
    /// contradicts the destination — never silently pay one of two
    /// disagreeing figures.
    ///
    /// Split from [`WalletBackend::send`] so hosts can show the fee and take
    /// confirmation first. Breez Liquid sends are chain swaps whose fees are
    /// not knowable up front, so a wallet that cannot preview them cannot
    /// reach Signal-quality payment UX without changing this trait.
    fn prepare_send(
        &self,
        destination: &Destination,
        amount_sats: Option<u64>,
    ) -> Result<PreparedSend>;

    /// Execute a previously prepared send.
    fn send(&self, prepared: &PreparedSend, note: &str) -> Result<Payment>;

    /// Most recent payments, newest first.
    fn list_recent_payments(&self, limit: u32) -> Result<Vec<Payment>>;

    /// Reconcile a source payment by the BOLT11 payment hash. Implementations
    /// must return `Unknown` rather than guessing when their durable payment
    /// store cannot establish the outcome.
    fn lookup_payment(&self, _payment_hash: &str) -> Result<PaymentLookup> {
        Ok(PaymentLookup::unknown())
    }

    fn fetch_fiat_rates(&self) -> Result<Vec<ExchangeRate>> {
        Err(WalletError::Unsupported("fiat rates".into()))
    }

    fn register_webhook(&self, _url: &str) -> Result<()> {
        Err(WalletError::Unsupported("webhook".into()))
    }

    fn unregister_webhook(&self) -> Result<()> {
        Err(WalletError::Unsupported("webhook".into()))
    }

    /// Register a listener; returns an id for [`WalletBackend::remove_event_listener`].
    fn add_event_listener(&self, listener: Arc<dyn WalletEventListener>) -> u64;
    fn remove_event_listener(&self, id: u64);

    /// Destroy backend-local state (database/cache) under the working dir.
    /// Must never touch the seed or anything outside the working dir; with the
    /// seed, the wallet must be fully recoverable afterwards.
    ///
    /// The wallet must be disconnected first; implementations return
    /// [`WalletError::Backend`] rather than pulling the database out from
    /// under a live backend.
    fn wipe_local_storage(&self) -> Result<()>;
}

/// Destination-side exact receive tracking. A migration settles only when the
/// specific quote created during planning is issued; aggregate balance changes
/// are deliberately not evidence for this contract.
pub trait TrackedReceiveBackend: Send + Sync {
    fn create_tracked_receive(&self, request: &ReceiveRequest) -> Result<TrackedReceive>;

    fn reconcile_tracked_receive(
        &self,
        id: &str,
        request_timeout: Duration,
    ) -> Result<TrackedReceiveState>;
}

/// Convenience for the common "prepare then immediately send" path, used by
/// callers that have already taken confirmation (or have none to take).
pub fn prepare_and_send(
    backend: &dyn WalletBackend,
    destination: &Destination,
    amount_sats: Option<u64>,
    note: &str,
) -> Result<Payment> {
    let prepared = backend.prepare_send(destination, amount_sats)?;
    backend.send(&prepared, note)
}

/// Whether a backend supports a given receive method, for callers gating UI.
pub fn supports_receive(caps: &WalletCapabilities, method: ReceiveMethod) -> bool {
    match method {
        ReceiveMethod::Bolt12Offer => caps.bolt12_receive,
        ReceiveMethod::Bolt11Invoice => caps.bolt11_receive,
    }
}
