/// Every failure the protocol layer can report. The codec never panics on
/// untrusted bytes: malformed input is a `Decode` error, an unrepresentable
/// packet is an `Encode` error.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    /// The value cannot be represented on the wire (over a length field,
    /// too many route hops, missing required field, ...).
    #[error("bitchat encode: {0}")]
    Encode(&'static str),
    /// The bytes are not a well-formed frame for this codec.
    #[error("bitchat decode: {0}")]
    Decode(&'static str),
    /// Noise handshake / cipher failure (wrapped `snow` or AEAD error).
    #[error("noise: {0}")]
    Noise(String),
    /// A transport message carried a nonce that was already seen or is older
    /// than the replay window.
    #[error("noise: replayed or out-of-window nonce {0}")]
    Replay(u64),
    /// The 32-bit explicit nonce space of a session is exhausted; rekey.
    #[error("noise: nonce space exhausted")]
    NonceExhausted,
    /// Transport operation on a session that is still handshaking.
    #[error("noise: session not established")]
    NotEstablished,
    /// The OS CSPRNG failed. Never degrade to a deterministic value.
    #[error("os rng unavailable")]
    Rng,
}

/// Crate-wide result alias.
pub type Result<T> = core::result::Result<T, Error>;

impl From<snow::Error> for Error {
    fn from(e: snow::Error) -> Self {
        Error::Noise(format!("{e:?}"))
    }
}
