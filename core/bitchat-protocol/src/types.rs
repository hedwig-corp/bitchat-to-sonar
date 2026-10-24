//! Protocol constants: packet types, Noise payload types, header flags and
//! the per-type payload ceilings.

/// Outer packet types (`MessageType` in both reference clients). Values not
/// listed here pass through decoders untouched; stock clients ignore them.
pub mod msg_type {
    /// Identity announce: nickname + Noise static key + Ed25519 signing key.
    pub const ANNOUNCE: u8 = 0x01;
    /// Public (broadcast) chat message; payload is raw UTF-8.
    pub const MESSAGE: u8 = 0x02;
    /// "I'm leaving".
    pub const LEAVE: u8 = 0x03;
    /// Store-and-forward envelope carried by a trusted peer (iOS ≥ 1.7).
    pub const COURIER_ENVELOPE: u8 = 0x04;
    /// Noise XX handshake message (m1/m2/m3 told apart by the session state).
    pub const NOISE_HANDSHAKE: u8 = 0x10;
    /// Noise transport message; decrypted plaintext is `[NoisePayloadType][body]`.
    pub const NOISE_ENCRYPTED: u8 = 0x11;
    /// Fragment of a larger packet (see [`crate::fragment`]).
    pub const FRAGMENT: u8 = 0x20;
    /// GCS-filter sync request (neighbour-only).
    pub const REQUEST_SYNC: u8 = 0x21;
    /// Binary file / voice note / image; payload is a [`crate::FilePacket`].
    pub const FILE_TRANSFER: u8 = 0x22;
    /// Signed geohash bulletin-board post (iOS ≥ 1.7).
    pub const BOARD_POST: u8 = 0x23;
    /// Signed batch of one-time prekeys (iOS ≥ 1.7).
    pub const PREKEY_BUNDLE: u8 = 0x24;
    /// Group-encrypted broadcast (iOS ≥ 1.7).
    pub const GROUP_MESSAGE: u8 = 0x25;
    /// Directed echo request.
    pub const PING: u8 = 0x26;
    /// Directed echo reply.
    pub const PONG: u8 = 0x27;
    /// Nostr event carried over the mesh (gateway mode).
    pub const NOSTR_CARRIER: u8 = 0x28;
    /// Live push-to-talk frame; never gossip-synced.
    pub const VOICE_FRAME: u8 = 0x29;
    /// Identity-free presence announce (peer-id rotation draft; parsed and
    /// ignored by shipping clients).
    pub const ANNOUNCE_V2: u8 = 0x2C;
    /// Sonar discovery announce (`'S'`): Nostr identity + capabilities. Not a
    /// bitchat type on purpose — stock clients hit their unknown-type branch
    /// and relay it by TTL.
    pub const SONAR_ANNOUNCE: u8 = 0x53;
}

/// Typed view of [`msg_type`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[allow(missing_docs)]
pub enum MessageType {
    Announce,
    Message,
    Leave,
    CourierEnvelope,
    NoiseHandshake,
    NoiseEncrypted,
    Fragment,
    RequestSync,
    FileTransfer,
    BoardPost,
    PrekeyBundle,
    GroupMessage,
    Ping,
    Pong,
    NostrCarrier,
    VoiceFrame,
    AnnounceV2,
    SonarAnnounce,
}

impl MessageType {
    /// The known type for a raw byte, or `None` for anything else.
    pub fn from_u8(raw: u8) -> Option<Self> {
        use msg_type::*;
        Some(match raw {
            ANNOUNCE => Self::Announce,
            MESSAGE => Self::Message,
            LEAVE => Self::Leave,
            COURIER_ENVELOPE => Self::CourierEnvelope,
            NOISE_HANDSHAKE => Self::NoiseHandshake,
            NOISE_ENCRYPTED => Self::NoiseEncrypted,
            FRAGMENT => Self::Fragment,
            REQUEST_SYNC => Self::RequestSync,
            FILE_TRANSFER => Self::FileTransfer,
            BOARD_POST => Self::BoardPost,
            PREKEY_BUNDLE => Self::PrekeyBundle,
            GROUP_MESSAGE => Self::GroupMessage,
            PING => Self::Ping,
            PONG => Self::Pong,
            NOSTR_CARRIER => Self::NostrCarrier,
            VOICE_FRAME => Self::VoiceFrame,
            ANNOUNCE_V2 => Self::AnnounceV2,
            SONAR_ANNOUNCE => Self::SonarAnnounce,
            _ => return None,
        })
    }

    /// The raw wire byte.
    pub fn as_u8(self) -> u8 {
        use msg_type::*;
        match self {
            Self::Announce => ANNOUNCE,
            Self::Message => MESSAGE,
            Self::Leave => LEAVE,
            Self::CourierEnvelope => COURIER_ENVELOPE,
            Self::NoiseHandshake => NOISE_HANDSHAKE,
            Self::NoiseEncrypted => NOISE_ENCRYPTED,
            Self::Fragment => FRAGMENT,
            Self::RequestSync => REQUEST_SYNC,
            Self::FileTransfer => FILE_TRANSFER,
            Self::BoardPost => BOARD_POST,
            Self::PrekeyBundle => PREKEY_BUNDLE,
            Self::GroupMessage => GROUP_MESSAGE,
            Self::Ping => PING,
            Self::Pong => PONG,
            Self::NostrCarrier => NOSTR_CARRIER,
            Self::VoiceFrame => VOICE_FRAME,
            Self::AnnounceV2 => ANNOUNCE_V2,
            Self::SonarAnnounce => SONAR_ANNOUNCE,
        }
    }
}

/// First byte of a decrypted `NOISE_ENCRYPTED` plaintext.
pub mod noise_payload {
    /// `PrivateMessagePacket` TLV follows.
    pub const PRIVATE_MESSAGE: u8 = 0x01;
    /// UTF-8 message id that was read.
    pub const READ_RECEIPT: u8 = 0x02;
    /// UTF-8 message id that was delivered to the application.
    pub const DELIVERED: u8 = 0x03;
    /// Creator-signed private group state (invite).
    pub const GROUP_INVITE: u8 = 0x06;
    /// Creator-signed private group state (key rotation / roster).
    pub const GROUP_KEY_UPDATE: u8 = 0x07;
    /// One live voice-burst packet.
    pub const VOICE_FRAME: u8 = 0x08;
    /// Prerelease iOS alias for [`PRIVATE_FILE`]: accepted on decode, never
    /// emitted.
    pub const PRERELEASE_PRIVATE_FILE: u8 = 0x09;
    /// QR verification challenge.
    pub const VERIFY_CHALLENGE: u8 = 0x10;
    /// QR verification response.
    pub const VERIFY_RESPONSE: u8 = 0x11;
    /// Batch of transitive-verification vouches.
    pub const VOUCH: u8 = 0x12;
    /// A complete [`crate::FilePacket`] encrypted inside the session (the
    /// value Android deployed first; iOS followed).
    pub const PRIVATE_FILE: u8 = 0x20;
    /// [`crate::AuthenticatedPeerState`]: capabilities + Ed25519 key proven
    /// by the surrounding Noise session.
    pub const AUTHENTICATED_PEER_STATE: u8 = 0x21;
}

/// Typed view of [`noise_payload`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[allow(missing_docs)]
pub enum NoisePayloadType {
    PrivateMessage,
    ReadReceipt,
    Delivered,
    GroupInvite,
    GroupKeyUpdate,
    VoiceFrame,
    VerifyChallenge,
    VerifyResponse,
    Vouch,
    PrivateFile,
    AuthenticatedPeerState,
}

impl NoisePayloadType {
    /// Decode a type byte. `0x09` canonicalises to [`Self::PrivateFile`]
    /// (`NoisePayloadType.decoded(rawValue:)` on iOS, `fromValue` on Android).
    pub fn decode(raw: u8) -> Option<Self> {
        use noise_payload::*;
        Some(match raw {
            PRIVATE_MESSAGE => Self::PrivateMessage,
            READ_RECEIPT => Self::ReadReceipt,
            DELIVERED => Self::Delivered,
            GROUP_INVITE => Self::GroupInvite,
            GROUP_KEY_UPDATE => Self::GroupKeyUpdate,
            VOICE_FRAME => Self::VoiceFrame,
            VERIFY_CHALLENGE => Self::VerifyChallenge,
            VERIFY_RESPONSE => Self::VerifyResponse,
            VOUCH => Self::Vouch,
            PRIVATE_FILE | PRERELEASE_PRIVATE_FILE => Self::PrivateFile,
            AUTHENTICATED_PEER_STATE => Self::AuthenticatedPeerState,
            _ => return None,
        })
    }

    /// The byte to emit. Never the prerelease alias.
    pub fn as_u8(self) -> u8 {
        use noise_payload::*;
        match self {
            Self::PrivateMessage => PRIVATE_MESSAGE,
            Self::ReadReceipt => READ_RECEIPT,
            Self::Delivered => DELIVERED,
            Self::GroupInvite => GROUP_INVITE,
            Self::GroupKeyUpdate => GROUP_KEY_UPDATE,
            Self::VoiceFrame => VOICE_FRAME,
            Self::VerifyChallenge => VERIFY_CHALLENGE,
            Self::VerifyResponse => VERIFY_RESPONSE,
            Self::Vouch => VOUCH,
            Self::PrivateFile => PRIVATE_FILE,
            Self::AuthenticatedPeerState => AUTHENTICATED_PEER_STATE,
        }
    }
}

/// Header flag bits (byte 11 of every packet).
pub mod flags {
    /// An 8-byte recipient id follows the sender id.
    pub const HAS_RECIPIENT: u8 = 0x01;
    /// A 64-byte Ed25519 signature trails the payload.
    pub const HAS_SIGNATURE: u8 = 0x02;
    /// Payload is `[original size][raw DEFLATE]`.
    pub const IS_COMPRESSED: u8 = 0x04;
    /// v2 only: a `count || hops` source route precedes the payload.
    pub const HAS_ROUTE: u8 = 0x08;
    /// Mutable "relayed by source route" marker; excluded from signatures.
    pub const IS_RSR: u8 = 0x10;
}

/// Payload ceilings, enforced on decode before any allocation. These are the
/// iOS `PacketPayloadLimits` values (the stricter of the two clients; Android
/// uses one 10 MiB frame cap). A conforming sender never exceeds them, so
/// decoding with the stricter set loses nothing and bounds memory against
/// hostile peers.
pub mod limits {
    use super::msg_type::*;

    /// Largest `original_size / compressed_size` a compressed payload may
    /// declare (DEFLATE's theoretical maximum is 1032:1).
    pub const MAX_DEFLATE_RATIO: usize = 1032;
    /// File content ceiling (`FileTransferLimits.maxPayloadBytes`).
    pub const MAX_FILE_CONTENT_BYTES: usize = 1024 * 1024;
    /// Ceiling for a framed file: content + maximal metadata TLVs + envelope
    /// (`FileTransferLimits.maxFramedFileBytes`).
    pub const MAX_FRAMED_FILE_BYTES: usize =
        MAX_FILE_CONTENT_BYTES + 18 + 2 * (u16::MAX as usize) + 16 + 8 + 8 + 64;
    const FRAGMENT_BYTES: usize = 1_280;
    const CONTROL_BYTES: usize = 4 * 1024;
    const REQUEST_SYNC_BYTES: usize = 8 * 1024;
    const ENVELOPE_BYTES: usize = 64 * 1024;
    const TWICE_V1_FRAME_BYTES: usize = 128 * 1024;

    /// Maximum decoded payload for a packet type. Unknown types (including
    /// Sonar's `0x53`) get the generic 128 KiB message ceiling.
    pub fn max_payload_bytes(packet_type: u8) -> usize {
        match packet_type {
            FILE_TRANSFER | NOISE_ENCRYPTED => MAX_FRAMED_FILE_BYTES,
            MESSAGE | GROUP_MESSAGE => TWICE_V1_FRAME_BYTES,
            COURIER_ENVELOPE | NOSTR_CARRIER => ENVELOPE_BYTES,
            REQUEST_SYNC => REQUEST_SYNC_BYTES,
            FRAGMENT => FRAGMENT_BYTES,
            ANNOUNCE | ANNOUNCE_V2 | LEAVE | BOARD_POST | PREKEY_BUNDLE | VOICE_FRAME
            | NOISE_HANDSHAKE | PING | PONG => CONTROL_BYTES,
            _ => TWICE_V1_FRAME_BYTES,
        }
    }
}
