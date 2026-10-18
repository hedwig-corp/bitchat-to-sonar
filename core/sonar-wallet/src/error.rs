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
    #[error("wallet operation timed out")]
    Timeout,
    #[error("tracked receive outcome is unknown: {0}")]
    UnknownReceive(String),
    /// The prepared send's quote expired, or was too close to expiry to be
    /// paid safely, before any payment request left the wallet. Nothing was
    /// sent; the caller may prepare a fresh quote for the same destination
    /// and amount and send that one, under the fee it already agreed to.
    #[error("the payment quote expired before it was sent")]
    QuoteExpired,
    /// Paying the prepared send would cost more in fees than `fees_sats` of
    /// the [`crate::PreparedSend`] the caller agreed to. Nothing was sent;
    /// `fees_sats` is the new fee to ask about.
    #[error("the fee for this payment is now up to {fees_sats} sats")]
    FeeChanged { fees_sats: u64 },
}
