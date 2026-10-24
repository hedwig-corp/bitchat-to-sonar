//! # bitchat-protocol
//!
//! The bitchat BLE mesh wire protocol as one tested, platform-neutral crate:
//! the binary packet format (v1/v2, compression, source routes, PKCS#7
//! padding), the TLV payloads (announce, authenticated peer state, private
//! message, file transfer, fragments), the Ed25519 packet signature preimage,
//! peer-id derivation, and the Noise XX session with bitchat's explicit-nonce
//! transport framing and sliding replay window.
//!
//! The reference implementations are
//! [permissionlesstech/bitchat](https://github.com/permissionlesstech/bitchat)
//! (`localPackages/BitFoundation`, `bitchat/Protocols`, `bitchat/Noise`) and
//! [permissionlesstech/bitchat-android](https://github.com/permissionlesstech/bitchat-android)
//! (`protocol/`, `model/`, `noise/`). Where the two disagree, `SPEC.md`
//! records the difference and which behaviour this crate follows. Byte-exact
//! vectors generated from those implementations live in `vectors/` and are
//! replayed by `tests/vectors.rs`.
//!
//! Design rules:
//!
//! * No I/O, no clocks, no logging. Callers pass bytes in and get bytes or a
//!   typed [`Error`] out. Nothing here panics on untrusted input.
//! * Sign what you send, verify what you received. A decoded [`Packet`] keeps
//!   its payload bytes exactly as they arrived ([`packet::WirePayload`]), so a
//!   signature preimage never depends on re-running a DEFLATE encoder that
//!   may differ from the sender's.
//! * Randomness comes from the OS CSPRNG and a failure is an error, never a
//!   zeroed buffer.
#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub mod announce;
pub mod compression;
mod error;
pub mod file_packet;
pub mod fragment;
pub mod nip17;
pub mod noise;
pub mod packet;
pub mod padding;
pub mod peer_id;
pub mod peer_state;
pub mod private_message;
pub mod signing;
pub mod sonar;
pub mod types;

pub use announce::{Announce, PeerCapabilities, UnknownTlv};
pub use error::{Error, Result};
pub use file_packet::FilePacket;
pub use fragment::{Fragment, Reassembler};
pub use packet::{Packet, WirePayload, BROADCAST_RECIPIENT};
pub use peer_state::AuthenticatedPeerState;
pub use private_message::PrivateMessage;
pub use signing::MeshSigner;
pub use types::{flags, limits, msg_type, noise_payload, MessageType, NoisePayloadType};
