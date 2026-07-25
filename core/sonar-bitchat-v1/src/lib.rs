//! bitchat v1 — the complete, radio-neutral bitchat mesh implementation.
//!
//! Everything needed to BE a bitchat v1 mesh node except the radio itself:
//!
//! - [`mesh`]: the byte-for-byte wire protocol ported from the Swift reference
//!   (packet framing, PKCS#7 padding, announce TLVs, Ed25519 packet signing,
//!   fragmentation, file transfer, private/public message encodings).
//! - [`noise`]: Noise XX handshakes and transport sessions (the DM crypto).
//! - [`mesh_engine`]: the deterministic link state machine (announce/identity
//!   handling, dial policy, per-instance links, liveness, heartbeat, pending
//!   sends, relay, allowlist) driven by platform BLE drivers through an
//!   event → command interface.
//!
//! No BLE I/O, no clocks, no async: platform drivers (Android `MeshGatt`,
//! the desktop `sonar-ble` bridge, iOS later) own the radio and feed this
//! crate events. That keeps every protocol/state decision testable in-process
//! and fixed ONCE for all platforms.
//!
//! "v1" is the wire protocol generation this crate speaks; a future protocol
//! bump gets a sibling crate rather than in-place breakage.

pub mod mesh;
pub mod mesh_engine;
pub mod noise;

/// Errors from this crate (currently only the Noise layer fails fallibly; the
/// wire codec is `Option`-based like the Swift reference).
#[derive(Debug)]
pub enum Error {
    Noise(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Noise(msg) => write!(f, "{msg}"),
        }
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;
