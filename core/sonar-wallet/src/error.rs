use thiserror::Error;

pub type Result<T> = std::result::Result<T, WalletError>;

/// Wallet errors surfaced across the interface.
///
/// Display strings are part of the contract: hosts (and later the FFI layer)
/// may match on them, so treat the text as stable, same discipline as
/// `sonar_core::Error`.
#[derive(Debug, Error)]
pub enum WalletError {
    #[error("wallet is not connected")]
    NotConnected,
    #[error("unsupported by this wallet backend: {0}")]
    Unsupported(&'static str),
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
