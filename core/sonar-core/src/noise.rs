//! Noise XX session for the BLE mesh transport — re-exported from
//! [`bitchat_protocol::noise`], which implements bitchat's explicit-nonce
//! transport framing (`[u32 BE nonce][ct || tag]`) and the 1024-message
//! sliding replay window the reference clients use. See
//! `core/bitchat-protocol/SPEC.md` §Noise.

pub use bitchat_protocol::noise::{
    NoiseHandshake, NoiseKeypair, NoiseSession, MAX_NONCE, PARAMS, REPLAY_WINDOW_SIZE,
};

impl From<bitchat_protocol::Error> for crate::Error {
    fn from(e: bitchat_protocol::Error) -> Self {
        crate::Error::Storage(format!("bitchat protocol: {e}"))
    }
}
