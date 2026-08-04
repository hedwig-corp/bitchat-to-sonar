use thiserror::Error;

pub type Result<T> = std::result::Result<T, WalletError>;

/// Wallet errors surfaced across the interface.
///
/// Display strings are part of the contract: hosts (and later the FFI layer)
/// may match on them, so treat the text as stable, same discipline as
/// `sonar_core::Error`.
/// Marked `#[non_exhaustive]`: backends and hosts live in other crates, and a
/// new failure mode should not be a breaking change for their match arms.
#[derive(Debug, Error)]
#[non_exhaustive]
pub enum WalletError {
    #[error("wallet is not connected")]
    NotConnected,
    /// Another lifecycle operation holds the slot. Distinct from
    /// [`WalletError::NotConnected`] because the caller should retry shortly
    /// rather than treat the wallet as unavailable.
    #[error("wallet is busy: {0}")]
    Busy(String),
    #[error("unsupported by this wallet backend: {0}")]
    Unsupported(String),
    #[error("invalid destination: {0}")]
    InvalidDestination(String),
    #[error("insufficient funds")]
    InsufficientFunds,
    #[error("invalid input: {0}")]
    InvalidInput(String),
    #[error("backend error: {0}")]
    Backend(String),
    #[error("network error: {0}")]
    Network(String),
}
