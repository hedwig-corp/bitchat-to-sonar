//! Private chat message TLV (`PrivateMessagePacket`) and the Noise plaintext
//! framing around it.
//!
//! The reference TLV is `0x00 messageID` and `0x01 content`, each with a
//! **one-byte** length, and both reference decoders **reject** any type they
//! do not know. That has two consequences this module makes explicit:
//!
//! * a stock peer can never receive more than 255 bytes of content in one
//!   message ([`PrivateMessage::fits_legacy`], [`split_for_legacy`]);
//! * Sonar's extensions — two-byte-length variants (`0x02`/`0x03`) and a
//!   reply-to parent id (`0x04`/`0x05`) — may only be sent to a peer known to
//!   understand them (one that announced itself as Sonar). Sending them to a
//!   stock client silently loses the whole message.
//!
//! The decoder here is tolerant: unknown one-byte-length TLVs are skipped.

use crate::types::noise_payload;
use crate::{Error, Result};

const T_MESSAGE_ID: u8 = 0x00;
const T_CONTENT: u8 = 0x01;
const T_MESSAGE_ID_LONG: u8 = 0x02;
const T_CONTENT_LONG: u8 = 0x03;
const T_REPLY_TO: u8 = 0x04;
const T_REPLY_TO_LONG: u8 = 0x05;

/// Largest field a stock bitchat client can decode.
pub const LEGACY_MAX_FIELD_BYTES: usize = 255;

/// A private message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrivateMessage {
    /// Sender-chosen id (UUID string in the reference clients).
    pub message_id: String,
    /// UTF-8 body.
    pub content: String,
    /// Sonar extension: id of the message this replies to.
    pub reply_to: Option<String>,
}

impl PrivateMessage {
    /// A message without a reply parent.
    pub fn new(message_id: impl Into<String>, content: impl Into<String>) -> Self {
        PrivateMessage {
            message_id: message_id.into(),
            content: content.into(),
            reply_to: None,
        }
    }

    /// Can a stock bitchat client decode this message? (Both fields ≤255
    /// bytes; a reply parent is simply not representable.)
    pub fn fits_legacy(&self) -> bool {
        self.message_id.len() <= LEGACY_MAX_FIELD_BYTES
            && self.content.len() <= LEGACY_MAX_FIELD_BYTES
            && self.reply_to.as_deref().is_none_or(str::is_empty)
    }

    /// The reference encoding: `0x00 id` + `0x01 content`, one-byte lengths.
    /// Errors when a field exceeds 255 bytes; a `reply_to` is dropped (a stock
    /// peer could not read it anyway) — check [`Self::fits_legacy`] first if
    /// that loss matters.
    pub fn encode_legacy(&self) -> Result<Vec<u8>> {
        let id = self.message_id.as_bytes();
        let content = self.content.as_bytes();
        if id.len() > LEGACY_MAX_FIELD_BYTES || content.len() > LEGACY_MAX_FIELD_BYTES {
            return Err(Error::Encode("field over 255 bytes in a legacy private message"));
        }
        let mut out = Vec::with_capacity(4 + id.len() + content.len());
        out.push(T_MESSAGE_ID);
        out.push(id.len() as u8);
        out.extend_from_slice(id);
        out.push(T_CONTENT);
        out.push(content.len() as u8);
        out.extend_from_slice(content);
        Ok(out)
    }

    /// Sonar's extended encoding: short TLVs when they fit (byte-identical to
    /// legacy), two-byte-length variants above 255 bytes, plus the reply
    /// parent. Only for peers that advertised Sonar.
    pub fn encode_extended(&self) -> Result<Vec<u8>> {
        let id = self.message_id.as_bytes();
        let content = self.content.as_bytes();
        let mut out = Vec::with_capacity(8 + id.len() + content.len());
        push_field(&mut out, T_MESSAGE_ID, T_MESSAGE_ID_LONG, id)?;
        push_field(&mut out, T_CONTENT, T_CONTENT_LONG, content)?;
        if let Some(reply) = self.reply_to.as_deref().filter(|s| !s.is_empty()) {
            push_field(&mut out, T_REPLY_TO, T_REPLY_TO_LONG, reply.as_bytes())?;
        }
        Ok(out)
    }

    /// Encode for a peer: extended when `peer_is_sonar`, else legacy.
    pub fn encode_for(&self, peer_is_sonar: bool) -> Result<Vec<u8>> {
        if peer_is_sonar {
            self.encode_extended()
        } else {
            self.encode_legacy()
        }
    }

    /// Decode either encoding. Unknown types are assumed to carry a one-byte
    /// length and are skipped; a future long-length type must be added here.
    pub fn decode(data: &[u8]) -> Result<PrivateMessage> {
        let mut o = 0usize;
        let mut message_id = None;
        let mut content = None;
        let mut reply_to = None;
        // A trailing lone type byte is ignored, like the reference decoders
        // (`while offset + 2 <= count`).
        while o + 2 <= data.len() {
            let t = data[o];
            o += 1;
            let is_long = matches!(t, T_MESSAGE_ID_LONG | T_CONTENT_LONG | T_REPLY_TO_LONG);
            let len = if is_long {
                if o + 2 > data.len() {
                    return Err(Error::Decode("truncated long TLV length"));
                }
                let l = u16::from_be_bytes([data[o], data[o + 1]]) as usize;
                o += 2;
                l
            } else {
                if o + 1 > data.len() {
                    return Err(Error::Decode("truncated TLV length"));
                }
                let l = data[o] as usize;
                o += 1;
                l
            };
            if o + len > data.len() {
                return Err(Error::Decode("TLV length overruns the payload"));
            }
            let value = &data[o..o + len];
            o += len;
            match t {
                T_MESSAGE_ID | T_MESSAGE_ID_LONG => {
                    message_id = String::from_utf8(value.to_vec()).ok()
                }
                T_CONTENT | T_CONTENT_LONG => content = String::from_utf8(value.to_vec()).ok(),
                T_REPLY_TO | T_REPLY_TO_LONG => {
                    reply_to = String::from_utf8(value.to_vec()).ok().filter(|s| !s.is_empty())
                }
                _ => {}
            }
        }
        Ok(PrivateMessage {
            message_id: message_id.ok_or(Error::Decode("private message without id"))?,
            content: content.ok_or(Error::Decode("private message without content"))?,
            reply_to,
        })
    }
}

fn push_field(out: &mut Vec<u8>, short: u8, long: u8, value: &[u8]) -> Result<()> {
    if value.len() <= LEGACY_MAX_FIELD_BYTES {
        out.push(short);
        out.push(value.len() as u8);
    } else {
        let len = u16::try_from(value.len()).map_err(|_| Error::Encode("field over 65535 bytes"))?;
        out.push(long);
        out.extend_from_slice(&len.to_be_bytes());
    }
    out.extend_from_slice(value);
    Ok(())
}

/// Split UTF-8 `content` into pieces of at most `max_bytes` bytes on character
/// boundaries, for delivery to a stock client one legacy message at a time.
pub fn split_for_legacy(content: &str, max_bytes: usize) -> Vec<String> {
    let max_bytes = max_bytes.max(4); // room for any single UTF-8 scalar
    let mut pieces = Vec::new();
    let mut start = 0usize;
    while start < content.len() {
        let mut end = (start + max_bytes).min(content.len());
        while !content.is_char_boundary(end) {
            end -= 1;
        }
        pieces.push(content[start..end].to_string());
        start = end;
    }
    if pieces.is_empty() {
        pieces.push(String::new());
    }
    pieces
}

/// `[0x01][PrivateMessagePacket]` — the plaintext to Noise-encrypt.
pub fn encode_private_message_plaintext(msg: &PrivateMessage, peer_is_sonar: bool) -> Result<Vec<u8>> {
    let mut out = vec![noise_payload::PRIVATE_MESSAGE];
    out.extend(msg.encode_for(peer_is_sonar)?);
    Ok(out)
}

/// `[0x03][message id UTF-8]` — delivery acknowledgement plaintext.
pub fn encode_delivered_plaintext(message_id: &str) -> Result<Vec<u8>> {
    typed(noise_payload::DELIVERED, message_id)
}

/// `[0x02][message id UTF-8]` — read receipt plaintext.
pub fn encode_read_receipt_plaintext(message_id: &str) -> Result<Vec<u8>> {
    typed(noise_payload::READ_RECEIPT, message_id)
}

fn typed(t: u8, message_id: &str) -> Result<Vec<u8>> {
    if message_id.is_empty() {
        return Err(Error::Encode("empty message id"));
    }
    let mut out = Vec::with_capacity(1 + message_id.len());
    out.push(t);
    out.extend_from_slice(message_id.as_bytes());
    Ok(out)
}

/// Split a decrypted Noise plaintext into its type byte and body.
pub fn split_noise_plaintext(plain: &[u8]) -> Option<(u8, &[u8])> {
    plain.split_first().map(|(t, rest)| (*t, rest))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_and_extended_agree_on_short_fields() {
        let m = PrivateMessage::new("m1", "hi");
        let legacy = m.encode_legacy().unwrap();
        assert_eq!(legacy, vec![0x00, 2, b'm', b'1', 0x01, 2, b'h', b'i']);
        assert_eq!(m.encode_extended().unwrap(), legacy);
        assert_eq!(PrivateMessage::decode(&legacy).unwrap(), m);
        assert!(m.fits_legacy());
    }

    #[test]
    fn long_content_uses_two_byte_length_only_in_extended() {
        let m = PrivateMessage::new("id", "a".repeat(300));
        assert!(!m.fits_legacy());
        assert!(m.encode_legacy().is_err());
        let e = m.encode_extended().unwrap();
        assert_eq!(e[4], T_CONTENT_LONG);
        assert_eq!(&e[5..7], &[0x01, 0x2c]);
        assert_eq!(PrivateMessage::decode(&e).unwrap(), m);
        let exact = PrivateMessage::new("id", "a".repeat(255));
        assert!(exact.fits_legacy());
        assert_eq!(exact.encode_legacy().unwrap(), exact.encode_extended().unwrap());
    }

    #[test]
    fn reply_to_is_extended_only_and_dropped_by_legacy() {
        let mut m = PrivateMessage::new("m1", "hi");
        m.reply_to = Some("parent".into());
        assert!(!m.fits_legacy());
        let legacy = m.encode_legacy().unwrap();
        assert_eq!(PrivateMessage::decode(&legacy).unwrap().reply_to, None);
        let ext = m.encode_extended().unwrap();
        assert_eq!(ext[8], T_REPLY_TO);
        assert_eq!(PrivateMessage::decode(&ext).unwrap(), m);
        m.reply_to = Some(String::new());
        assert!(m.fits_legacy());
        assert_eq!(m.encode_extended().unwrap(), legacy);
    }

    #[test]
    fn decoder_skips_unknown_and_rejects_overrun() {
        let mut b = PrivateMessage::new("m1", "hi").encode_legacy().unwrap();
        b.extend_from_slice(&[0x7f, 2, 0xaa, 0xbb]);
        assert_eq!(PrivateMessage::decode(&b).unwrap(), PrivateMessage::new("m1", "hi"));
        b.extend_from_slice(&[0x7e, 9]);
        assert!(PrivateMessage::decode(&b).is_err());
        let mut lone = PrivateMessage::new("m1", "hi").encode_legacy().unwrap();
        lone.push(0x7e);
        assert!(PrivateMessage::decode(&lone).is_ok(), "trailing lone byte ignored like upstream");
        assert!(PrivateMessage::decode(&[0x00, 1, b'x']).is_err()); // no content
    }

    #[test]
    fn plaintext_framing_and_split() {
        let p = encode_private_message_plaintext(&PrivateMessage::new("m", "x"), false).unwrap();
        assert_eq!(p[0], noise_payload::PRIVATE_MESSAGE);
        assert_eq!(encode_delivered_plaintext("m1").unwrap(), vec![0x03, b'm', b'1']);
        assert_eq!(encode_read_receipt_plaintext("m1").unwrap(), vec![0x02, b'm', b'1']);
        assert!(encode_delivered_plaintext("").is_err());
        assert_eq!(split_noise_plaintext(&[0x03, 1]), Some((0x03, &[1u8][..])));
        assert_eq!(split_noise_plaintext(&[]), None);
        let pieces = split_for_legacy(&"é".repeat(300), 255);
        assert!(pieces.iter().all(|p| p.len() <= 255));
        assert_eq!(pieces.concat(), "é".repeat(300));
        assert_eq!(split_for_legacy("", 255), vec![String::new()]);
    }
}
