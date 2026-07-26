use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Network {
    Mainnet,
    Testnet,
}

/// Everything a backend needs to open (or create) the wallet.
///
/// The seed is the nsec-derived entropy from [`crate::wallet_entropy`] —
/// custody stays with the caller; backends must never persist it outside
/// their own encrypted store, and [`WalletBackend::wipe_local_storage`]
/// must never be able to destroy the account key (only derived local state).
///
/// [`WalletBackend::wipe_local_storage`]: crate::WalletBackend::wipe_local_storage
#[derive(Clone)]
pub struct WalletConfig {
    /// Raw wallet seed bytes (>= 32). For Breez this goes into
    /// `ConnectRequest::seed` as-is — NOT via a BIP39 mnemonic, which would
    /// derive a different wallet and break restore.
    pub seed: Vec<u8>,
    pub network: Network,
    /// Backend service key (e.g. the Breez API key), if the backend needs one.
    pub api_key: Option<String>,
    /// Directory the backend may use for its local database/cache.
    pub working_dir: PathBuf,
}

impl std::fmt::Debug for WalletConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the seed or the API key.
        f.debug_struct("WalletConfig")
            .field("seed", &format_args!("[{} bytes]", self.seed.len()))
            .field("network", &self.network)
            .field("api_key", &self.api_key.as_ref().map(|_| "[redacted]"))
            .field("working_dir", &self.working_dir)
            .finish()
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Balance {
    pub confirmed_sats: u64,
    /// Incoming amounts not yet settled (e.g. Breez pending swap-ins, Cashu
    /// unminted quotes).
    pub pending_receive_sats: u64,
    /// Outgoing amounts not yet settled.
    pub pending_send_sats: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaymentStatus {
    Pending,
    Complete,
    Failed,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Payment {
    /// Backend payment id: tx id, else payment hash, else destination.
    pub id: String,
    pub amount_sats: u64,
    pub fees_sats: Option<u64>,
    pub incoming: bool,
    pub timestamp_secs: u64,
    pub status: PaymentStatus,
    pub preimage: Option<String>,
    pub note: Option<String>,
}

/// Destination classes the apps understand today. `Unknown` is parseable-maybe:
/// backends may still accept inputs this crate cannot classify.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DestinationKind {
    Bolt11,
    Bolt12Offer,
    LightningAddress,
    LnurlPay,
    Unknown,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Destination {
    /// The input as given (trimmed), suitable to hand back to the backend.
    pub raw: String,
    pub kind: DestinationKind,
    /// Amount encoded in the destination itself, when the backend's parser
    /// extracted one (e.g. a non-zero-amount BOLT11 invoice).
    pub amount_sats: Option<u64>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ExchangeRate {
    /// ISO 4217 code, upper-case ("USD").
    pub currency: String,
    /// Fiat units per whole BTC. A rate <= 0.0 must be treated as not live.
    pub per_btc: f64,
}

#[derive(Debug, Clone)]
pub enum WalletEvent {
    Connected,
    /// Backend finished a sync pass; hosts should re-query [`Balance`].
    Synced,
    PaymentReceived {
        payment: Payment,
    },
    PaymentSent {
        payment: Payment,
    },
    PaymentFailed {
        payment: Payment,
    },
    Disconnected,
}

/// What a backend can do. Callers must consult this instead of assuming the
/// Breez shape: an ecash backend has no node lifecycle and no webhook.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WalletCapabilities {
    /// connect/disconnect map to a real node/session start-stop that hosts
    /// must drive from app lifecycle (foreground gating, background close).
    pub node_lifecycle: bool,
    /// Supports offline-payment webhook registration (Breez NDS path).
    pub webhook: bool,
    pub fiat_rates: bool,
    pub bolt11_send: bool,
    pub bolt12_send: bool,
    pub bolt12_receive: bool,
}
