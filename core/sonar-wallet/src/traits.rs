use std::sync::Arc;

use crate::error::{Result, WalletError};
use crate::types::{Balance, Destination, ExchangeRate, Payment, WalletCapabilities, WalletEvent};

/// Host-side observer for wallet events. Callbacks are synchronous and must
/// be cheap/non-blocking; they can be invoked from a backend-owned thread.
/// Mirrors the sonar-ffi callback-interface shape so it can be exported over
/// UniFFI unchanged when the FFI surface lands.
pub trait WalletEventListener: Send + Sync {
    fn on_event(&self, event: WalletEvent);
}

/// The wallet contract every backend implements.
///
/// Sync and object-safe by design (repo convention: traits are sync, the FFI
/// layer is blocking); async backends own their runtime internally, like
/// `SonarNode` in sonar-ffi does. All methods may be called from any thread.
///
/// Lifecycle rules (0xdead10cc lineage — hosts call these from app-lifecycle
/// hooks):
/// - `connect` is idempotent: calling it while connected is a cheap no-op Ok.
/// - `disconnect` is idempotent and must be fast; it must not wait for
///   long-running sync work.
///
/// Capability-gated methods (`fetch_fiat_rates`, `register_webhook`,
/// `unregister_webhook`) default to [`WalletError::Unsupported`] so backends
/// without the capability implement nothing; callers gate on
/// [`WalletBackend::capabilities`] first.
pub trait WalletBackend: Send + Sync {
    fn capabilities(&self) -> WalletCapabilities;

    fn connect(&self) -> Result<()>;
    fn disconnect(&self) -> Result<()>;
    fn is_connected(&self) -> bool;

    fn balance(&self) -> Result<Balance>;

    /// Amountless BOLT12 receive offer for this wallet. Stable per wallet, so
    /// callers may cache the returned string.
    fn receive_offer(&self) -> Result<String>;

    /// Parse/classify a user-supplied destination. Backends should refine the
    /// pure [`crate::classify_destination`] result with their own parser
    /// (amounts, notes) when they can.
    fn parse_destination(&self, input: &str) -> Result<Destination>;

    /// Pay a destination. `amount_sats` settles an amountless destination;
    /// `None` means "use the amount encoded in the destination". Backends must
    /// resolve the two through [`crate::resolve_send_amount`], which refuses
    /// both the no-amount-anywhere case and a caller amount that contradicts
    /// the destination — never silently pay one of two disagreeing figures.
    fn send(
        &self,
        destination: &Destination,
        amount_sats: Option<u64>,
        note: &str,
    ) -> Result<Payment>;

    /// Most recent payments, newest first.
    fn list_recent_payments(&self, limit: u32) -> Result<Vec<Payment>>;

    fn fetch_fiat_rates(&self) -> Result<Vec<ExchangeRate>> {
        Err(WalletError::Unsupported("fiat rates"))
    }

    fn register_webhook(&self, _url: &str) -> Result<()> {
        Err(WalletError::Unsupported("webhook"))
    }

    fn unregister_webhook(&self) -> Result<()> {
        Err(WalletError::Unsupported("webhook"))
    }

    /// Register a listener; returns an id for [`WalletBackend::remove_event_listener`].
    fn add_event_listener(&self, listener: Arc<dyn WalletEventListener>) -> u64;
    fn remove_event_listener(&self, id: u64);

    /// Destroy backend-local state (database/cache) under the working dir.
    /// Must never touch the seed or anything outside the working dir; with the
    /// seed, the wallet must be fully recoverable afterwards.
    fn wipe_local_storage(&self) -> Result<()>;
}
