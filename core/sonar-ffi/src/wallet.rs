//! Wallet FFI: Sonar's Cashu (CDK) wallet, the app's wallet for everyone.
//!
//! Ecash proofs are bearer instruments held in a per-account local store; the
//! mint (`mint_url`) holds the Lightning side. The legacy Breez wallet never
//! enters this crate — its forked `libsqlite3-sys` links plain sqlite3, which
//! cannot share a binary with sonar-core's SQLCipher — so hosts keep it on
//! their native integrations.
//!
//! Call shape for hosts. Every method BLOCKS (mint round-trips, store I/O):
//! call from a background thread, never the UI thread.
//!
//! ```text
//! let wallet = SonarCashuWallet(nsec, mint_url, dir)  // local only, no network
//! wallet.set_listener(listener)                       // events on a wallet thread
//! wallet.connect()                                    // mint info, NUT-13 restore,
//!                                                     // crash recovery, watcher
//! wallet.receive_offer()                              // THE published offer; works offline
//! let quote = wallet.prepare_send(dest, amount)       // fee is known here — show it
//! let paid  = wallet.send(quote, note)                // Pending is not an error
//! ```

use std::sync::{Arc, Mutex};
use std::time::Duration;

use sonar_wallet::{
    cashu_wallet_seed, nsec_to_secret, Balance, Destination, DestinationKind, Payment,
    PaymentStatus, PreparedSend, PreparedSendToken, WalletBackend, WalletConfig, WalletError,
    WalletEvent, WalletEventListener, Zeroizing,
};
use sonar_wallet_cdk::CdkWallet;

/// Why a wallet call failed. Non-flat, with typed variants the hosts branch
/// on: `InsufficientFunds` sizes a send down, `NotConnected`/`Timeout`/
/// `Network` drive the reconnect UI. Fields are named `reason`, never
/// `message` — that name collides with `Throwable.message` in Kotlin.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum WalletFfiError {
    #[error("wallet is not connected")]
    NotConnected,
    #[error("wallet is busy: {reason}")]
    Busy { reason: String },
    #[error("not supported: {reason}")]
    Unsupported { reason: String },
    #[error("invalid destination: {reason}")]
    InvalidDestination { reason: String },
    #[error("insufficient funds")]
    InsufficientFunds,
    #[error("invalid input: {reason}")]
    InvalidInput { reason: String },
    #[error("network error: {reason}")]
    Network { reason: String },
    #[error("wallet operation timed out")]
    Timeout,
    #[error("wallet error: {reason}")]
    Backend { reason: String },
}

impl From<WalletError> for WalletFfiError {
    fn from(e: WalletError) -> Self {
        match e {
            WalletError::NotConnected => Self::NotConnected,
            WalletError::Busy(reason) => Self::Busy { reason },
            WalletError::Unsupported(reason) => Self::Unsupported { reason },
            WalletError::InvalidDestination(reason) => Self::InvalidDestination { reason },
            WalletError::InsufficientFunds => Self::InsufficientFunds,
            WalletError::InvalidInput(reason) => Self::InvalidInput { reason },
            WalletError::Network(reason) => Self::Network { reason },
            WalletError::Timeout => Self::Timeout,
            WalletError::Backend(reason) => Self::Backend { reason },
            // `WalletError` is non-exhaustive; a new variant is a backend
            // failure until this mapping learns it.
            other => Self::Backend {
                reason: other.to_string(),
            },
        }
    }
}

type WalletResult<T> = Result<T, WalletFfiError>;

/// Balance snapshot, sats.
#[derive(Debug, Clone, uniffi::Record)]
pub struct WalletBalance {
    /// Spendable now.
    pub confirmed_sats: u64,
    /// Paid to us at the mint, not yet minted into proofs.
    pub pending_receive_sats: u64,
    /// On its way out: inputs of an in-flight or prepared payment.
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WalletPaymentStatus {
    Pending,
    Complete,
    Failed,
    Refundable,
}

impl From<PaymentStatus> for WalletPaymentStatus {
    fn from(s: PaymentStatus) -> Self {
        match s {
            PaymentStatus::Pending => Self::Pending,
            PaymentStatus::Complete => Self::Complete,
            PaymentStatus::Failed => Self::Failed,
            PaymentStatus::Refundable => Self::Refundable,
        }
    }
}

/// One payment, incoming or outgoing. `id` is stable: a live result, its
/// later events, and history rows for the same payment share it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct WalletPayment {
    pub id: String,
    pub incoming: bool,
    /// Excluding fees.
    pub amount_sats: u64,
    pub fees_sats: Option<u64>,
    pub timestamp_secs: u64,
    pub status: WalletPaymentStatus,
    /// Lightning preimage of an outgoing payment: the proof of payment.
    pub preimage: Option<String>,
    pub note: Option<String>,
}

impl From<Payment> for WalletPayment {
    fn from(p: Payment) -> Self {
        Self {
            id: p.id,
            incoming: p.incoming,
            amount_sats: p.amount_sats,
            fees_sats: p.fees_sats,
            timestamp_secs: p.timestamp_secs,
            status: p.status.into(),
            preimage: p.preimage,
            note: p.note,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WalletDestinationKind {
    Bolt11,
    Bolt12Offer,
    LightningAddress,
    LnurlPay,
    Unknown,
}

impl From<DestinationKind> for WalletDestinationKind {
    fn from(k: DestinationKind) -> Self {
        match k {
            DestinationKind::Bolt11 => Self::Bolt11,
            DestinationKind::Bolt12Offer => Self::Bolt12Offer,
            DestinationKind::LightningAddress => Self::LightningAddress,
            DestinationKind::LnurlPay => Self::LnurlPay,
            DestinationKind::Unknown => Self::Unknown,
        }
    }
}

impl From<WalletDestinationKind> for DestinationKind {
    fn from(k: WalletDestinationKind) -> Self {
        match k {
            WalletDestinationKind::Bolt11 => Self::Bolt11,
            WalletDestinationKind::Bolt12Offer => Self::Bolt12Offer,
            WalletDestinationKind::LightningAddress => Self::LightningAddress,
            WalletDestinationKind::LnurlPay => Self::LnurlPay,
            WalletDestinationKind::Unknown => Self::Unknown,
        }
    }
}

/// A one-time BOLT11 invoice from `receive_invoice`. Its payment arrives as
/// an incoming `WalletPayment` whose `id` equals `payment_id`, so a host can
/// tell this invoice was paid (and stop showing it as payable).
#[derive(Debug, Clone, uniffi::Record)]
pub struct WalletInvoice {
    pub invoice: String,
    pub payment_id: String,
}

/// A destination classified offline (no mint round-trip).
#[derive(Debug, Clone, uniffi::Record)]
pub struct WalletDestination {
    pub raw: String,
    pub kind: WalletDestinationKind,
    /// Present when the destination fixes its own amount.
    pub amount_sats: Option<u64>,
}

/// A priced send, from `prepare_send`: what the user is agreeing to. Pass it
/// back unchanged to `send`. `fees_sats` is the mint's fee RESERVE — the most
/// the payment can cost on top of `amount_sats`; unused reserve returns.
#[derive(Debug, Clone, uniffi::Record)]
pub struct WalletPreparedSend {
    pub quote_id: String,
    pub destination: String,
    pub kind: WalletDestinationKind,
    pub amount_sats: u64,
    pub fees_sats: Option<u64>,
}

impl WalletPreparedSend {
    fn into_core(self) -> PreparedSend {
        PreparedSend {
            destination: Destination {
                raw: self.destination,
                kind: self.kind.into(),
                amount_sats: Some(self.amount_sats),
                note: None,
            },
            amount_sats: self.amount_sats,
            fees_sats: self.fees_sats,
            token: PreparedSendToken::Opaque(self.quote_id),
        }
    }
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum CashuWalletEvent {
    Connected,
    Disconnected,
    /// State changed without a payment the host tracks (e.g. a pending
    /// melt settled, or the offer rotated): re-read balance and offer.
    Synced,
    PaymentReceived {
        payment: WalletPayment,
    },
    /// Also emitted with `status: Pending` while a send is in flight; a later
    /// event with the same `id` carries the outcome.
    PaymentSent {
        payment: WalletPayment,
    },
    PaymentFailed {
        payment: WalletPayment,
    },
}

impl From<WalletEvent> for CashuWalletEvent {
    fn from(e: WalletEvent) -> Self {
        match e {
            WalletEvent::Connected => Self::Connected,
            WalletEvent::Disconnected => Self::Disconnected,
            WalletEvent::Synced => Self::Synced,
            WalletEvent::PaymentReceived { payment } => Self::PaymentReceived {
                payment: payment.into(),
            },
            WalletEvent::PaymentSent { payment } => Self::PaymentSent {
                payment: payment.into(),
            },
            WalletEvent::PaymentFailed { payment } => Self::PaymentFailed {
                payment: payment.into(),
            },
        }
    }
}

/// Host observer for wallet events. Called on the wallet's own event
/// thread, never the caller's; hop to the UI thread before touching UI.
/// May call back into the wallet.
#[uniffi::export(callback_interface)]
pub trait CashuWalletListener: Send + Sync {
    fn on_event(&self, event: CashuWalletEvent);
}

struct ForeignListener(Box<dyn CashuWalletListener>);

impl WalletEventListener for ForeignListener {
    fn on_event(&self, event: WalletEvent) {
        self.0.on_event(event.into());
    }
}

/// Sonar's Cashu wallet for one account at one mint.
///
/// `working_dir` MUST be per account (the store refuses another account's
/// seed): hosts use `<root>/sonar-cashu/<sha256(nsec)[:16] hex>/mainnet`.
#[derive(uniffi::Object)]
pub struct SonarCashuWallet {
    inner: CdkWallet,
    listener_id: Mutex<Option<u64>>,
}

impl SonarCashuWallet {
    fn from_parts(inner: CdkWallet) -> Arc<Self> {
        Arc::new(Self {
            inner,
            listener_id: Mutex::new(None),
        })
    }

    fn config(nsec: &str, working_dir: &str) -> WalletResult<WalletConfig> {
        if working_dir.trim().is_empty() {
            return Err(WalletFfiError::InvalidInput {
                reason: "working_dir must not be empty".into(),
            });
        }
        let secret = Zeroizing::new(nsec_to_secret(nsec)?);
        Ok(WalletConfig {
            seed: Zeroizing::new(cashu_wallet_seed(&secret).to_vec()),
            network: sonar_wallet::Network::Mainnet,
            api_key: None,
            working_dir: working_dir.into(),
        })
    }
}

#[uniffi::export]
impl SonarCashuWallet {
    /// Local only: derives the seed and binds the object to its store. No
    /// network and no store I/O happen until `connect`.
    #[uniffi::constructor]
    pub fn new(nsec: String, mint_url: String, working_dir: String) -> WalletResult<Arc<Self>> {
        let config = Self::config(&nsec, &working_dir)?;
        Ok(Self::from_parts(CdkWallet::new(config, &mint_url)?))
    }

    /// Open the store and reach the mint: loads mint info, runs a NUT-13
    /// restore when one is owed (new device, wipe, lost store), recovers
    /// payments a crash interrupted, and starts the payment watcher.
    /// Idempotent; `Busy` while another connect is in flight. Bounded — a
    /// hung mint yields `Timeout`, never a stuck call.
    pub fn connect(&self) -> WalletResult<()> {
        Ok(self.inner.connect()?)
    }

    /// Stop the watcher and release the store. Infallible in practice. Do
    /// not call while a `send` is in flight on another thread.
    pub fn disconnect(&self) -> WalletResult<()> {
        Ok(self.inner.disconnect()?)
    }

    pub fn is_connected(&self) -> bool {
        self.inner.is_connected()
    }

    /// Local store read (no network). Requires `connect`.
    pub fn balance(&self) -> WalletResult<WalletBalance> {
        Ok(self.inner.balance()?.into())
    }

    /// Reconcile now: mint paid receives, settle pending sends. An error
    /// means reconciliation did not complete — retry later.
    pub fn sync(&self) -> WalletResult<()> {
        Ok(self.inner.sync_wallet()?)
    }

    /// THE wallet's receive offer (BOLT12, amountless, reusable) — the one
    /// hosts publish. Stable across calls and launches; answered from disk
    /// with no network once created. The first call needs `connect`.
    pub fn receive_offer(&self) -> WalletResult<String> {
        Ok(self.inner.receive_offer()?)
    }

    /// A one-off BOLT11 invoice for `amount_sats`, with the id its payment
    /// will carry.
    pub fn receive_invoice(
        &self,
        amount_sats: u64,
        description: Option<String>,
    ) -> WalletResult<WalletInvoice> {
        let (invoice, payment_id) = self.inner.receive_bolt11(amount_sats, description)?;
        Ok(WalletInvoice {
            invoice,
            payment_id,
        })
    }

    /// Classify what the user typed or scanned. Offline.
    pub fn parse_destination(&self, input: String) -> WalletResult<WalletDestination> {
        let d = self.inner.parse_destination(&input)?;
        Ok(WalletDestination {
            raw: d.raw,
            kind: d.kind.into(),
            amount_sats: d.amount_sats,
        })
    }

    /// Price a payment without paying: the mint quotes amount and fee
    /// reserve. `amount_sats` is required for amountless destinations and
    /// must agree with an amount the destination fixes.
    pub fn prepare_send(
        &self,
        destination: String,
        amount_sats: Option<u64>,
    ) -> WalletResult<WalletPreparedSend> {
        let parsed = self.inner.parse_destination(&destination)?;
        let prepared = self.inner.prepare_send(&parsed, amount_sats)?;
        let PreparedSendToken::Opaque(quote_id) = prepared.token else {
            return Err(WalletFfiError::Backend {
                reason: "prepared send carries no quote id".into(),
            });
        };
        Ok(WalletPreparedSend {
            quote_id,
            destination: prepared.destination.raw,
            kind: prepared.destination.kind.into(),
            amount_sats: prepared.amount_sats,
            fees_sats: prepared.fees_sats,
        })
    }

    /// Pay a prepared send — the one spending call. A result with
    /// `status: Pending` is NOT a failure: the payment may be routing, and
    /// its outcome arrives as an event with the same `id`. Never retry a
    /// Pending send with a new quote; that can pay twice.
    pub fn send(&self, prepared: WalletPreparedSend, note: String) -> WalletResult<WalletPayment> {
        Ok(self.inner.send(&prepared.into_core(), &note)?.into())
    }

    /// Most recent payments, newest first. Local store read.
    pub fn list_payments(&self, limit: u32) -> WalletResult<Vec<WalletPayment>> {
        Ok(self
            .inner
            .list_recent_payments(limit)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// The payment with this id: from history (the most recent 500), else —
    /// for an outgoing payment history does not show, such as a send the mint
    /// refused and the wallet rolled back — what the mint reports for its
    /// melt quote. `None` when the wallet knows nothing about the id.
    pub fn lookup_payment(&self, id: String) -> WalletResult<Option<WalletPayment>> {
        if let Some(found) = self
            .inner
            .list_recent_payments(500)?
            .into_iter()
            .find(|p| p.id == id)
        {
            return Ok(Some(found.into()));
        }
        Ok(self.inner.outgoing_payment_outcome(&id)?.map(Into::into))
    }

    /// Replace the event listener (one per wallet).
    pub fn set_listener(&self, listener: Box<dyn CashuWalletListener>) {
        let mut slot = self.listener_id.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(old) = slot.take() {
            self.inner.remove_event_listener(old);
        }
        *slot = Some(
            self.inner
                .add_event_listener(Arc::new(ForeignListener(listener))),
        );
    }

    pub fn clear_listener(&self) {
        if let Some(old) = self
            .listener_id
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
        {
            self.inner.remove_event_listener(old);
        }
    }

    /// Delete this wallet's local store. Refused while connected. Proofs
    /// the mint has signed stay restorable from the nsec (NUT-13); sats paid
    /// to a quote but not yet minted do not — only a panic wipe should call
    /// this.
    pub fn wipe_local_storage(&self) -> WalletResult<()> {
        Ok(self.inner.wipe_local_storage()?)
    }
}

/// A fiat exchange rate: fiat units per whole BTC.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FiatRate {
    /// ISO 4217, upper case.
    pub currency: String,
    pub per_btc: f64,
}

/// Fetch display rates from Yadio (`sonar_wallet::YADIO_BTC_RATES_URL`),
/// about 145 currencies. Blocking, bounded at 10s; call off the UI thread.
/// Independent of any wallet, so a legacy wallet's UI can use it too.
#[uniffi::export]
pub fn fetch_fiat_rates() -> WalletResult<Vec<FiatRate>> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| WalletFfiError::Backend {
            reason: format!("runtime: {e}"),
        })?;
    let body = runtime.block_on(async {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .map_err(|e| WalletFfiError::Backend {
                reason: format!("http client: {e}"),
            })?;
        let response = client
            .get(sonar_wallet::YADIO_BTC_RATES_URL)
            .send()
            .await
            .map_err(|e| WalletFfiError::Network {
                reason: e.to_string(),
            })?
            .error_for_status()
            .map_err(|e| WalletFfiError::Network {
                reason: e.to_string(),
            })?;
        response.text().await.map_err(|e| WalletFfiError::Network {
            reason: e.to_string(),
        })
    })?;
    Ok(sonar_wallet::parse_yadio(&body)?
        .into_iter()
        .map(|r| FiatRate {
            currency: r.currency,
            per_btc: r.per_btc,
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use sonar_wallet_cdk::test_mint::FakeMint;

    const NSEC_HEX: &str = "0000000000000000000000000000000000000000000000000000000000000001";

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "sonar-ffi-wallet-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn fake_wallet(dir: &std::path::Path) -> (Arc<SonarCashuWallet>, Arc<FakeMint>) {
        let mint = Arc::new(FakeMint::new());
        let config = SonarCashuWallet::config(NSEC_HEX, dir.to_str().unwrap()).unwrap();
        let inner =
            CdkWallet::with_connector(config, "https://mint.example.com", mint.clone()).unwrap();
        (SonarCashuWallet::from_parts(inner), mint)
    }

    #[derive(Default)]
    struct Collect(Mutex<Vec<CashuWalletEvent>>);

    impl CashuWalletListener for Arc<Collect> {
        fn on_event(&self, event: CashuWalletEvent) {
            self.0.lock().unwrap().push(event);
        }
    }

    #[test]
    fn construction_is_local_and_rejects_bad_input() {
        let dir = scratch("construct");
        let wallet = SonarCashuWallet::new(
            NSEC_HEX.into(),
            "https://mint.example.com".into(),
            dir.to_str().unwrap().into(),
        )
        .expect("no network needed to construct");
        assert!(!wallet.is_connected());
        assert!(matches!(
            wallet.balance(),
            Err(WalletFfiError::NotConnected)
        ));
        assert!(matches!(
            SonarCashuWallet::new("not-a-key".into(), "https://m".into(), "/tmp/x".into()),
            Err(WalletFfiError::InvalidInput { .. })
        ));
        assert!(matches!(
            SonarCashuWallet::new(NSEC_HEX.into(), "https://m".into(), " ".into()),
            Err(WalletFfiError::InvalidInput { .. })
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The host-facing path end to end: listener delivery, the stable offer,
    /// a received payment, history lookup.
    #[test]
    fn receive_through_the_ffi_reaches_the_listener_and_history() {
        let dir = scratch("receive");
        let (wallet, mint) = fake_wallet(&dir);
        let events = Arc::new(Collect::default());
        wallet.set_listener(Box::new(events.clone()));
        wallet.connect().unwrap();

        let offer = wallet.receive_offer().unwrap();
        assert_eq!(wallet.receive_offer().unwrap(), offer, "stable");
        let quote = mint.mint_quote_ids().pop().unwrap();
        mint.pay(&quote, 700);
        wallet.sync().unwrap();
        assert_eq!(wallet.balance().unwrap().confirmed_sats, 700);

        let received = (0..300).find_map(|_| {
            let found = events.0.lock().unwrap().iter().find_map(|e| match e {
                CashuWalletEvent::PaymentReceived { payment } => Some(payment.clone()),
                _ => None,
            });
            if found.is_none() {
                std::thread::sleep(Duration::from_millis(10));
            }
            found
        });
        let received = received.expect("PaymentReceived reached the host listener");
        assert_eq!(received.amount_sats, 700);
        assert!(received.incoming);
        let looked_up = wallet.lookup_payment(received.id.clone()).unwrap().unwrap();
        assert_eq!(looked_up.id, received.id);

        wallet.clear_listener();
        wallet.disconnect().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The Receive sheet stops showing a one-time invoice once it is paid,
    /// by matching the incoming payment's id against `payment_id`.
    #[test]
    fn a_paid_invoice_arrives_under_its_payment_id() {
        let dir = scratch("invoice-id");
        let (wallet, mint) = fake_wallet(&dir);
        let events = Arc::new(Collect::default());
        wallet.set_listener(Box::new(events.clone()));
        wallet.connect().unwrap();

        let issued = wallet.receive_invoice(210, None).unwrap();
        assert!(issued.invoice.starts_with("lnbc"));
        mint.pay(&issued.payment_id, 210);
        wallet.sync().unwrap();

        let received = (0..300).find_map(|_| {
            let found = events.0.lock().unwrap().iter().find_map(|e| match e {
                CashuWalletEvent::PaymentReceived { payment } => Some(payment.clone()),
                _ => None,
            });
            if found.is_none() {
                std::thread::sleep(Duration::from_millis(10));
            }
            found
        });
        let received = received.expect("PaymentReceived reached the host listener");
        assert_eq!(received.id, issued.payment_id);
        assert_eq!(received.amount_sats, 210);

        wallet.clear_listener();
        wallet.disconnect().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn insufficient_funds_stays_typed_across_the_boundary() {
        assert!(matches!(
            WalletFfiError::from(WalletError::InsufficientFunds),
            WalletFfiError::InsufficientFunds
        ));
        assert!(matches!(
            WalletFfiError::from(WalletError::Timeout),
            WalletFfiError::Timeout
        ));
    }
}
