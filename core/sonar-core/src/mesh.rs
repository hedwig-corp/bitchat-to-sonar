//! bitchat BLE mesh wire format — a thin facade over the [`bitchat_protocol`]
//! crate, which owns the codec, its upstream test vectors and its spec
//! (`core/bitchat-protocol/SPEC.md`). Nothing protocol-shaped should be added
//! here: put it in the crate, with a vector, and re-export it.
//!
//! The names below are the ones `mesh_engine`, `sonar-ffi` and the tests have
//! always used; they map 1:1 onto the crate's modules.

pub use bitchat_protocol::announce::{Announce, PeerCapabilities, UnknownTlv};
pub use bitchat_protocol::packet::{
    encrypted_packet, handshake_packet, Packet, PaddingPolicy, WirePayload, BROADCAST_RECIPIENT,
};
pub use bitchat_protocol::padding::{optimal_block_size, pad, unpad};
pub use bitchat_protocol::peer_id::{matches_claimed_peer_id, parse_peer_id, peer_id_from_noise_key};
pub use bitchat_protocol::peer_state::AuthenticatedPeerState;
pub use bitchat_protocol::private_message::{
    encode_delivered_plaintext, encode_private_message_plaintext, encode_read_receipt_plaintext,
    split_for_legacy, split_noise_plaintext, PrivateMessage, LEGACY_MAX_FIELD_BYTES,
};
pub use bitchat_protocol::signing::{
    ed25519_verify, sign_packet, signing_preimage, verify_packet, MeshSigner,
};
pub use bitchat_protocol::sonar::{self as sonar_announce, SonarAnnounce};
pub use bitchat_protocol::types::{flags, limits, msg_type, noise_payload, MessageType, NoisePayloadType};
pub use bitchat_protocol::{file_packet, fragment, Error as ProtocolError};

/// bitchat's NIP-17 rumor embedding (`bitchat1:` content), re-exported with
/// the field layout the client has always consumed.
pub use bitchat_protocol::nip17::PREFIX as BITCHAT_NIP17_PREFIX;

/// A private message recovered from a `bitchat1:` NIP-17 rumor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbeddedPrivateMessage {
    pub sender_id: [u8; 8],
    pub recipient_id: Option<[u8; 8]>,
    pub message_id: String,
    pub content: String,
    pub reply_to: Option<String>,
    pub timestamp: u64,
}

/// Encode a NIP-17 rumor content string compatible with iOS bitchat's
/// `NostrEmbeddedBitChat.encodePMForNostr`. Over Nostr the recipient is
/// always a Sonar/White Noise account, so the extended TLVs are used.
pub fn encode_nip17_private_message_content(
    sender_id: [u8; 8],
    recipient_id: Option<[u8; 8]>,
    timestamp: u64,
    msg: &PrivateMessage,
) -> Option<String> {
    bitchat_protocol::nip17::encode_content(sender_id, recipient_id, timestamp, msg, true).ok()
}

/// Decode a `bitchat1:` rumor; `None` for non-bitchat or malformed content.
pub fn decode_nip17_private_message_content(content: &str) -> Option<EmbeddedPrivateMessage> {
    let e = bitchat_protocol::nip17::decode_content(content).ok()?;
    Some(EmbeddedPrivateMessage {
        sender_id: e.sender_id,
        recipient_id: e.recipient_id,
        message_id: e.message.message_id,
        content: e.message.content,
        reply_to: e.message.reply_to,
        timestamp: e.timestamp,
    })
}

/// Radio-facing encode: the reference clients' padding policy (only Noise
/// frames are padded), as an `Option` for the engine's `let Some` style.
pub trait WireEncode {
    /// Encode for a GATT write/notify. `None` when the packet is
    /// unrepresentable (over a length field, too many hops).
    fn encode_wire(&self) -> Option<Vec<u8>>;
}

impl WireEncode for Packet {
    fn encode_wire(&self) -> Option<Vec<u8>> {
        self.encode_with(PaddingPolicy::NoiseOnly).ok()
    }
}
