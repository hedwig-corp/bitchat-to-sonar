//! bitchat's NIP-17 embedding: a private message carried over Nostr as the
//! rumor content `bitchat1:<base64url, no padding, of a 0x11 packet whose
//! payload is the PLAINTEXT [0x01][PrivateMessagePacket]>` (iOS
//! `NostrEmbeddedBitChat.encodePMForNostr`). The gift wrap provides the
//! transport encryption; the embedded packet is never Noise-encrypted.

use base64::Engine;

use crate::packet::Packet;
use crate::private_message::{encode_private_message_plaintext, split_noise_plaintext, PrivateMessage};
use crate::types::{msg_type, noise_payload};
use crate::{Error, Result};

/// Content prefix.
pub const PREFIX: &str = "bitchat1:";
const MAX_EMBEDDED_PACKET_BYTES: usize = 2 * 1024 * 1024;

/// A private message recovered from a `bitchat1:` rumor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbeddedPrivateMessage {
    /// Sender peer id from the packet header.
    pub sender_id: [u8; 8],
    /// Recipient peer id from the packet header.
    pub recipient_id: Option<[u8; 8]>,
    /// The message.
    pub message: PrivateMessage,
    /// Packet timestamp (ms).
    pub timestamp: u64,
}

/// Encode a rumor content string. `extended` selects Sonar's TLV extensions
/// (only for a Sonar recipient).
pub fn encode_content(
    sender_id: [u8; 8],
    recipient_id: Option<[u8; 8]>,
    timestamp: u64,
    msg: &PrivateMessage,
    extended: bool,
) -> Result<String> {
    let mut packet = Packet::new(msg_type::NOISE_ENCRYPTED, 7, timestamp, sender_id);
    packet.recipient_id = recipient_id;
    packet.payload = encode_private_message_plaintext(msg, extended)?;
    let raw = packet.encode()?;
    Ok(format!("{PREFIX}{}", base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(raw)))
}

/// Decode a rumor content string; `Err` for non-bitchat or malformed content.
pub fn decode_content(content: &str) -> Result<EmbeddedPrivateMessage> {
    let encoded = content.strip_prefix(PREFIX).ok_or(Error::Decode("not a bitchat1 rumor"))?;
    let max_encoded = MAX_EMBEDDED_PACKET_BYTES.div_ceil(3) * 4;
    if encoded.len() > max_encoded {
        return Err(Error::Decode("embedded packet too large"));
    }
    let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| Error::Decode("invalid base64url"))?;
    if raw.len() > MAX_EMBEDDED_PACKET_BYTES {
        return Err(Error::Decode("embedded packet too large"));
    }
    let packet = Packet::decode(&raw)?;
    if packet.type_ != msg_type::NOISE_ENCRYPTED {
        return Err(Error::Decode("embedded packet is not type 0x11"));
    }
    let (t, rest) = split_noise_plaintext(&packet.payload).ok_or(Error::Decode("empty payload"))?;
    if t != noise_payload::PRIVATE_MESSAGE {
        return Err(Error::Decode("embedded payload is not a private message"));
    }
    Ok(EmbeddedPrivateMessage {
        sender_id: packet.sender_id,
        recipient_id: packet.recipient_id,
        message: PrivateMessage::decode(rest)?,
        timestamp: packet.timestamp,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_rejections() {
        let m = PrivateMessage::new("m1", "hello");
        let c = encode_content([1; 8], Some([2; 8]), 1234, &m, false).unwrap();
        assert!(c.starts_with(PREFIX));
        let d = decode_content(&c).unwrap();
        assert_eq!(d.message, m);
        assert_eq!(d.sender_id, [1; 8]);
        assert_eq!(d.recipient_id, Some([2; 8]));
        assert_eq!(d.timestamp, 1234);
        assert!(decode_content("hello").is_err());
        assert!(decode_content("bitchat1:!!!").is_err());
        let other = Packet::new(msg_type::MESSAGE, 7, 1, [1; 8]).with_payload(vec![1, 2]).encode().unwrap();
        let c2 = format!("{PREFIX}{}", base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(other));
        assert!(decode_content(&c2).is_err());
    }
}
