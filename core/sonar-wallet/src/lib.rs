//! Backend-agnostic Lightning wallet interface for Sonar (BOLT12-first).
//!
//! This crate defines the contract every wallet backend implements
//! ([`WalletBackend`]) plus the shared pure helpers: the nsec→wallet seed
//! derivation (byte-identical to the iOS `SonarWalletDerivation` and the
//! Kotlin `WalletSeed`) and destination classification. The first backend is
//! Breez SDK Liquid, which lives in the separate `sonar-wallet-breez` build
//! island (see the workspace `exclude` comment in `core/Cargo.toml` for why it
//! cannot be a workspace member); future backends (e.g. Cashu via CDK)
//! implement the same trait and only the capabilities they have.
//!
//! What this crate deliberately does NOT do:
//! - Own seed custody. The account key and derived entropy are handed in by
//!   the caller ([`WalletConfig::seed`]); keychain/keystore storage stays with
//!   the host platform (Account Key Durability Rule).
//! - Fiat display formatting or display preferences (show-fiat, chosen
//!   currency). Those are UI state; only rate *fetching* crosses this
//!   interface.
//! - Any networking of its own. Backends bring their own I/O.

mod destination;
mod error;
mod listeners;
mod mock;
mod seed;
mod traits;
mod types;
mod wipe;

pub use destination::{classify_destination, resolve_send_amount};
pub use error::{Result, WalletError};
pub use listeners::ListenerRegistry;
pub use mock::MockWallet;
pub use seed::{
    cashu_wallet_seed, entropy_hex, nsec_to_secret, wallet_entropy, CASHU_SEED_INFO, SEED_INFO,
    SEED_SALT,
};
pub use traits::{prepare_and_send, supports_receive, WalletBackend, WalletEventListener};
pub use types::{
    Balance, Destination, DestinationKind, ExchangeRate, Network, Payment, PaymentStatus,
    PreparedSend, PreparedSendToken, ReceiveMethod, ReceiveRequest, WalletCapabilities,
    WalletConfig, WalletEvent,
};
pub use wipe::guard_wipe_path;
/// Re-exported so backends can build a [`WalletConfig`] without taking their
/// own `zeroize` dependency (and risking a different major version).
pub use zeroize::Zeroizing;
