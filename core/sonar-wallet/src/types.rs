use std::path::PathBuf;

use zeroize::Zeroizing;

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
    ///
    /// Wrapped in [`Zeroizing`] so copies are wiped on drop; this only limits
    /// how long the bytes sit in the heap, it is not a substitute for the
    /// caller keeping custody in the platform keychain/keystore.
    pub seed: Zeroizing<Vec<u8>>,
    pub network: Network,
    /// Backend service key (e.g. the Breez API key), if the backend needs one.
    pub api_key: Option<String>,
    /// Directory the backend owns for its local database/cache.
    ///
    /// Must be **dedicated to this one wallet** (account and network), not a
    /// shared container root: [`WalletBackend::wipe_local_storage`] deletes
    /// this directory recursively, and Breez itself nests per-network and
    /// per-fingerprint subdirectories underneath it, so a base directory
    /// shared between accounts would take the other account's state with it.
    ///
    /// [`WalletBackend::wipe_local_storage`]: crate::WalletBackend::wipe_local_storage
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
    /// Terminal failure: the money came back (or never left).
    Failed,
    /// Failed in flight, but the funds are recoverable and awaiting an
    /// explicit refund. Distinct from [`PaymentStatus::Failed`] because
    /// showing "failed" on recoverable money loses it in practice — the user
    /// stops looking for it.
    Refundable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaymentLookupStatus {
    Pending,
    Complete,
    Failed,
    Refundable,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaymentLookup {
    pub status: PaymentLookupStatus,
    pub id: Option<String>,
    pub fees_sats: Option<u64>,
}

impl PaymentLookup {
    pub fn unknown() -> Self {
        Self {
            status: PaymentLookupStatus::Unknown,
            id: None,
            fees_sats: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Payment {
    /// Stable identifier for this payment, unique within the wallet and
    /// unchanged across its pending → settled transitions, so hosts can dedupe
    /// ledger rows by it.
    pub id: String,
    /// Net amount moved, **excluding** fees, for the whole lifetime of the
    /// payment. Backends must normalize to this: some report a fee-inclusive
    /// payer amount while a send is in flight and a fee-exclusive receiver
    /// amount once it settles, which would make the displayed figure change
    /// under the user between "Sending" and "Sent".
    pub amount_sats: u64,
    /// Fees paid by this wallet, reported separately from `amount_sats`.
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

impl DestinationKind {
    /// Whether [`WalletCapabilities`] says this kind is payable, so `send`
    /// can refuse up front with [`crate::WalletError::Unsupported`] instead of
    /// letting the backend fail with an opaque parse error deep in its stack.
    pub fn is_supported_by(self, caps: &WalletCapabilities) -> bool {
        match self {
            DestinationKind::Bolt11 => caps.bolt11_send,
            DestinationKind::Bolt12Offer => caps.bolt12_send,
            DestinationKind::LightningAddress => caps.lightning_address_send,
            DestinationKind::LnurlPay => caps.lnurl_send,
            // Unclassified input is the backend's call, not ours.
            DestinationKind::Unknown => true,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            DestinationKind::Bolt11 => "BOLT11 invoice",
            DestinationKind::Bolt12Offer => "BOLT12 offer",
            DestinationKind::LightningAddress => "Lightning address",
            DestinationKind::LnurlPay => "LNURL-pay",
            DestinationKind::Unknown => "unrecognized destination",
        }
    }
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

/// How to be paid. Backends declare support through
/// [`WalletCapabilities`]; a mint-based (ecash) backend would add its own
/// variant rather than pretending to mint a BOLT12 offer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum ReceiveMethod {
    Bolt12Offer,
    Bolt11Invoice,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ReceiveRequest {
    pub method: ReceiveMethod,
    /// `None` requests an amountless destination, which not every method
    /// supports (a BOLT11 invoice generally needs an amount).
    pub amount_sats: Option<u64>,
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrackedReceive {
    pub id: String,
    pub request: String,
    pub amount_sats: u64,
    pub expires_at_secs: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrackedReceiveState {
    Pending,
    Settled { amount_sats: u64 },
}

impl ReceiveRequest {
    /// The reusable, amountless BOLT12 offer — the common case.
    pub fn offer() -> Self {
        Self {
            method: ReceiveMethod::Bolt12Offer,
            amount_sats: None,
            description: None,
        }
    }
}

/// A priced, ready-to-execute send. Produced by
/// [`WalletBackend::prepare_send`] so callers can show the fee and get
/// confirmation before any money moves.
///
/// `token` carries whatever the backend needs to execute exactly this quote
/// without re-deriving it; treat it as opaque.
#[derive(Debug, Clone)]
pub struct PreparedSend {
    pub destination: Destination,
    /// Net amount that will reach the payee.
    pub amount_sats: u64,
    /// Fee this wallet will pay, when the backend can quote one up front.
    pub fees_sats: Option<u64>,
    pub token: PreparedSendToken,
}

/// Opaque backend handle for a prepared send.
#[derive(Debug, Clone)]
pub enum PreparedSendToken {
    /// Backend re-derives the send from the destination at execution time.
    None,
    /// Backend-serialized quote (e.g. a Breez `PrepareSendResponse`).
    Opaque(String),
}

/// What a backend can do. Callers must consult this instead of assuming the
/// Breez shape: an ecash backend has no node lifecycle and no webhook.
///
/// Construct with struct-update syntax over [`Default`] (everything false):
///
/// ```
/// # use sonar_wallet::WalletCapabilities;
/// let caps = WalletCapabilities {
///     bolt12_send: true,
///     bolt12_receive: true,
///     ..Default::default()
/// };
/// ```
///
/// so that adding a capability here stays source-compatible with backends in
/// other crates. (`#[non_exhaustive]` would be the usual tool, but it forbids
/// struct literals cross-crate entirely, which would leave out-of-tree
/// backends unable to declare capabilities at all.)
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WalletCapabilities {
    /// Can pay RAW LNURL-pay destinations (`lnurl1…` bech32 / lud-17 URLs).
    /// Deliberately separate from `lightning_address_send`: CDK routes
    /// addresses but not raw LNURL, Breez currently routes neither — a single
    /// flag either hides working support or advertises a deterministic
    /// failure to hosts gating their payment UI.
    pub lnurl_send: bool,
    /// Can pay Lightning addresses (user@domain, LUD-16/BIP-353).
    pub lightning_address_send: bool,
    /// connect/disconnect map to a real node/session start-stop that hosts
    /// must drive from app lifecycle (foreground gating, background close).
    pub node_lifecycle: bool,
    /// Supports offline-payment webhook registration (Breez NDS path).
    pub webhook: bool,
    pub fiat_rates: bool,
    pub bolt11_send: bool,
    pub bolt12_send: bool,
    pub bolt12_receive: bool,
    pub bolt11_receive: bool,
}
