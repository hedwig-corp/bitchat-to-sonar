//! The outer binary frame (`BinaryProtocol` / `BitchatPacket`).
//!
//! ```text
//! Header (14 bytes v1, 16 bytes v2), all multi-byte fields big-endian:
//! +---------+------+-----+-----------+-------+------------------------+
//! | Version | Type | TTL | Timestamp | Flags | PayloadLength          |
//! | 1       | 1    | 1   | 8 (ms)    | 1     | 2 (v1) / 4 (v2)        |
//! +---------+------+-----+-----------+-------+------------------------+
//! | SenderID 8 | RecipientID 8* | Route: count(1) + 8×n *(v2) |
//! | [OriginalSize 2/4 *compressed] Payload | Signature 64* |
//! * present when the matching flag bit is set
//! ```
//!
//! `PayloadLength` counts the payload bytes **plus** the original-size field
//! when compressed, and never the route. A decoder tries the frame as-is and
//! then with PKCS#7 padding stripped, so padded and unpadded frames are both
//! valid on every implementation.

use sha2::{Digest, Sha256};

use crate::compression;
use crate::padding;
use crate::types::{flags, limits, msg_type};
use crate::{Error, Result};

const V1_HEADER_SIZE: usize = 14;
const V2_HEADER_SIZE: usize = 16;
/// Width of the fixed sender id field.
pub const SENDER_ID_SIZE: usize = 8;
/// Width of the optional recipient id field.
pub const RECIPIENT_ID_SIZE: usize = 8;
/// Width of the optional Ed25519 signature.
pub const SIGNATURE_SIZE: usize = 64;
/// Broadcast recipient sentinel (`0xFF` × 8).
pub const BROADCAST_RECIPIENT: [u8; 8] = [0xFF; 8];

/// The payload bytes exactly as they arrived, kept beside the decoded
/// payload so a re-encode (relay TTL decrement, signature verification)
/// reproduces the originator's bytes instead of running our own DEFLATE
/// encoder over the payload. `payload_sha256` ties the bytes to the payload
/// they decode to: change the payload and the encoder compresses afresh.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WirePayload {
    /// Compressed stream when `compressed`, else the raw payload.
    pub bytes: Vec<u8>,
    /// Whether `bytes` is a DEFLATE stream.
    pub compressed: bool,
    /// SHA-256 of the decoded payload these bytes belong to.
    pub payload_sha256: [u8; 32],
}

impl WirePayload {
    fn for_payload(bytes: Vec<u8>, compressed: bool, payload: &[u8]) -> Self {
        WirePayload {
            bytes,
            compressed,
            payload_sha256: Sha256::digest(payload).into(),
        }
    }

    fn matches(&self, payload: &[u8]) -> bool {
        self.payload_sha256 == <[u8; 32]>::from(Sha256::digest(payload))
    }
}

/// Which frames get PKCS#7 padding on the way out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaddingPolicy {
    /// Pad every frame to its bucket (what Sonar did historically; also the
    /// shape the signature preimage uses).
    Always,
    /// Pad only Noise handshake and transport frames, like the reference
    /// clients today (`BLEOutboundPacketPolicy.padsBLEFrame`). Announces and
    /// public messages travel at natural length, saving most of the airtime
    /// of the most frequent packets.
    NoiseOnly,
    /// Never pad.
    Never,
}

impl PaddingPolicy {
    /// Does this policy pad a frame of `packet_type`?
    pub fn pads(self, packet_type: u8) -> bool {
        match self {
            PaddingPolicy::Always => true,
            PaddingPolicy::Never => false,
            PaddingPolicy::NoiseOnly => {
                matches!(packet_type, msg_type::NOISE_HANDSHAKE | msg_type::NOISE_ENCRYPTED)
            }
        }
    }
}

/// A decoded (or to-be-encoded) mesh packet.
///
/// Equality ignores [`Self::wire_payload`]: two packets with the same fields
/// are the same packet whether or not one of them remembers its wire bytes.
#[derive(Debug, Clone)]
pub struct Packet {
    /// Protocol version: 1 (u16 payload length) or 2 (u32 length, routes).
    pub version: u8,
    /// Packet type byte (see [`crate::msg_type`]).
    pub type_: u8,
    /// Hop budget; decremented by relays, excluded from signatures.
    pub ttl: u8,
    /// Sender wall clock in Unix milliseconds.
    pub timestamp: u64,
    /// 8-byte sender peer id.
    pub sender_id: [u8; 8],
    /// 8-byte recipient peer id; `None` for undirected broadcasts.
    pub recipient_id: Option<[u8; 8]>,
    /// v2 source route (intermediate hops), encoded only for version ≥ 2.
    pub route: Option<Vec<[u8; 8]>>,
    /// Application payload (decompressed).
    pub payload: Vec<u8>,
    /// 64-byte Ed25519 signature over [`crate::signing::signing_preimage`].
    pub signature: Option<[u8; 64]>,
    /// "Relayed via source route" marker; mutable, excluded from signatures.
    pub is_rsr: bool,
    /// Payload bytes as received; `None` for a locally built packet.
    pub wire_payload: Option<WirePayload>,
}

impl PartialEq for Packet {
    fn eq(&self, o: &Self) -> bool {
        self.version == o.version
            && self.type_ == o.type_
            && self.ttl == o.ttl
            && self.timestamp == o.timestamp
            && self.sender_id == o.sender_id
            && self.recipient_id == o.recipient_id
            && self.route == o.route
            && self.payload == o.payload
            && self.signature == o.signature
            && self.is_rsr == o.is_rsr
    }
}
impl Eq for Packet {}

impl Packet {
    /// A v1 packet with no recipient, payload or signature.
    pub fn new(type_: u8, ttl: u8, timestamp: u64, sender_id: [u8; 8]) -> Self {
        Packet {
            version: 1,
            type_,
            ttl,
            timestamp,
            sender_id,
            recipient_id: None,
            route: None,
            payload: Vec::new(),
            signature: None,
            is_rsr: false,
            wire_payload: None,
        }
    }

    /// A v2 packet (u32 payload length; may carry a source route).
    pub fn new_v2(type_: u8, ttl: u8, timestamp: u64, sender_id: [u8; 8]) -> Self {
        let mut p = Self::new(type_, ttl, timestamp, sender_id);
        p.version = 2;
        p
    }

    /// Builder: set the recipient.
    pub fn to(mut self, recipient: [u8; 8]) -> Self {
        self.recipient_id = Some(recipient);
        self
    }

    /// Builder: set the payload (drops any remembered wire bytes).
    pub fn with_payload(mut self, payload: Vec<u8>) -> Self {
        self.payload = payload;
        self.wire_payload = None;
        self
    }

    /// Encode padded to the optimal PKCS#7 bucket (`encode(padding: true)`),
    /// the form the signature preimage is computed over.
    pub fn encode(&self) -> Result<Vec<u8>> {
        self.encode_with(PaddingPolicy::Always)
    }

    /// Encode with no padding (`encode(padding: false)`).
    pub fn encode_unpadded(&self) -> Result<Vec<u8>> {
        self.encode_with(PaddingPolicy::Never)
    }

    /// Encode for the radio under a padding policy.
    pub fn encode_with(&self, padding: PaddingPolicy) -> Result<Vec<u8>> {
        let raw = self.encode_core()?;
        if padding.pads(self.type_) {
            let target = padding::optimal_block_size(raw.len());
            Ok(padding::pad(raw, target))
        } else {
            Ok(raw)
        }
    }

    fn encode_core(&self) -> Result<Vec<u8>> {
        if self.version != 1 && self.version != 2 {
            return Err(Error::Encode("unsupported protocol version"));
        }
        let v2 = self.version == 2;
        let length_field = if v2 { 4 } else { 2 };

        // Payload: reuse the originator's bytes when we still hold them and the
        // payload is unchanged; otherwise decide compression like the clients.
        let max_original = if v2 { u32::MAX as usize } else { u16::MAX as usize };
        let reused = self.wire_payload.as_ref().filter(|w| w.matches(&self.payload));
        let (wire_bytes, compressed): (std::borrow::Cow<'_, [u8]>, bool) = match reused {
            Some(w) => (std::borrow::Cow::Borrowed(&w.bytes[..]), w.compressed),
            None => {
                let fresh = if self.payload.len() <= max_original
                    && compression::should_compress(&self.payload)
                {
                    compression::compress(&self.payload)
                } else {
                    None
                };
                match fresh {
                    Some(c) => (std::borrow::Cow::Owned(c), true),
                    None => (std::borrow::Cow::Borrowed(&self.payload[..]), false),
                }
            }
        };
        let wire_bytes: &[u8] = &wire_bytes;
        let original_size_field = if compressed { length_field } else { 0 };
        let payload_field_len = wire_bytes.len() + original_size_field;
        if !v2 && (payload_field_len > u16::MAX as usize || self.payload.len() > u16::MAX as usize)
        {
            return Err(Error::Encode("payload exceeds the v1 u16 length field"));
        }
        if payload_field_len > u32::MAX as usize {
            return Err(Error::Encode("payload exceeds the v2 u32 length field"));
        }

        let route: &[[u8; 8]] = if v2 { self.route.as_deref().unwrap_or(&[]) } else { &[] };
        if route.len() > u8::MAX as usize {
            return Err(Error::Encode("route has more than 255 hops"));
        }
        let has_route = !route.is_empty();

        let header = if v2 { V2_HEADER_SIZE } else { V1_HEADER_SIZE };
        let mut out = Vec::with_capacity(
            header
                + SENDER_ID_SIZE
                + RECIPIENT_ID_SIZE
                + if has_route { 1 + route.len() * 8 } else { 0 }
                + payload_field_len
                + SIGNATURE_SIZE,
        );
        out.push(self.version);
        out.push(self.type_);
        out.push(self.ttl);
        out.extend_from_slice(&self.timestamp.to_be_bytes());

        let mut f = 0u8;
        if self.recipient_id.is_some() {
            f |= flags::HAS_RECIPIENT;
        }
        if self.signature.is_some() {
            f |= flags::HAS_SIGNATURE;
        }
        if compressed {
            f |= flags::IS_COMPRESSED;
        }
        if has_route {
            f |= flags::HAS_ROUTE;
        }
        if self.is_rsr {
            f |= flags::IS_RSR;
        }
        out.push(f);

        if v2 {
            out.extend_from_slice(&(payload_field_len as u32).to_be_bytes());
        } else {
            out.extend_from_slice(&(payload_field_len as u16).to_be_bytes());
        }
        out.extend_from_slice(&self.sender_id);
        if let Some(r) = &self.recipient_id {
            out.extend_from_slice(r);
        }
        if has_route {
            out.push(route.len() as u8);
            for hop in route {
                out.extend_from_slice(hop);
            }
        }
        if compressed {
            if v2 {
                out.extend_from_slice(&(self.payload.len() as u32).to_be_bytes());
            } else {
                out.extend_from_slice(&(self.payload.len() as u16).to_be_bytes());
            }
        }
        out.extend_from_slice(wire_bytes);
        if let Some(sig) = &self.signature {
            out.extend_from_slice(sig);
        }
        Ok(out)
    }

    /// Decode a frame, padded or not. Enforces the per-type payload ceilings
    /// and the DEFLATE ratio bound before allocating for the payload.
    pub fn decode(data: &[u8]) -> Result<Packet> {
        match decode_core(data) {
            Ok(p) => Ok(p),
            Err(e) => {
                let unpadded = padding::unpad(data);
                if unpadded.len() == data.len() {
                    return Err(e);
                }
                decode_core(&unpadded)
            }
        }
    }
}

struct Reader<'a> {
    buf: &'a [u8],
    o: usize,
}

impl<'a> Reader<'a> {
    fn u8(&mut self) -> Result<u8> {
        let b = *self.buf.get(self.o).ok_or(Error::Decode("truncated"))?;
        self.o += 1;
        Ok(b)
    }
    fn u16(&mut self) -> Result<u16> {
        Ok(((self.u8()? as u16) << 8) | self.u8()? as u16)
    }
    fn u32(&mut self) -> Result<u32> {
        Ok(((self.u16()? as u32) << 16) | self.u16()? as u32)
    }
    fn u64(&mut self) -> Result<u64> {
        Ok(((self.u32()? as u64) << 32) | self.u32()? as u64)
    }
    fn bytes(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self.o.checked_add(n).ok_or(Error::Decode("length overflow"))?;
        let s = self.buf.get(self.o..end).ok_or(Error::Decode("truncated"))?;
        self.o = end;
        Ok(s)
    }
    fn array<const N: usize>(&mut self) -> Result<[u8; N]> {
        let mut a = [0u8; N];
        a.copy_from_slice(self.bytes(N)?);
        Ok(a)
    }
}

fn decode_core(raw: &[u8]) -> Result<Packet> {
    if raw.len() < V1_HEADER_SIZE + SENDER_ID_SIZE {
        return Err(Error::Decode("shorter than a v1 header"));
    }
    let mut r = Reader { buf: raw, o: 0 };
    let version = r.u8()?;
    if version != 1 && version != 2 {
        return Err(Error::Decode("unsupported protocol version"));
    }
    let v2 = version == 2;
    let header = if v2 { V2_HEADER_SIZE } else { V1_HEADER_SIZE };
    if raw.len() < header + SENDER_ID_SIZE {
        return Err(Error::Decode("shorter than the header"));
    }
    let type_ = r.u8()?;
    let ttl = r.u8()?;
    let timestamp = r.u64()?;
    let f = r.u8()?;
    let has_recipient = f & flags::HAS_RECIPIENT != 0;
    let has_signature = f & flags::HAS_SIGNATURE != 0;
    let is_compressed = f & flags::IS_COMPRESSED != 0;
    let has_route = v2 && f & flags::HAS_ROUTE != 0;
    let is_rsr = f & flags::IS_RSR != 0;
    let length_field = if v2 { 4 } else { 2 };
    let payload_len = if v2 { r.u32()? as usize } else { r.u16()? as usize };

    let sender_id = r.array::<8>()?;
    let recipient_id = if has_recipient { Some(r.array::<8>()?) } else { None };
    let route = if has_route {
        let count = r.u8()? as usize;
        let mut hops = Vec::with_capacity(count);
        for _ in 0..count {
            hops.push(r.array::<8>()?);
        }
        if hops.is_empty() {
            None
        } else {
            Some(hops)
        }
    } else {
        None
    };

    let cap = limits::max_payload_bytes(type_);
    let (payload, wire_payload) = if is_compressed {
        if payload_len < length_field {
            return Err(Error::Decode("compressed payload shorter than its size field"));
        }
        let original = if v2 { r.u32()? as usize } else { r.u16()? as usize };
        if original == 0 || original > cap {
            return Err(Error::Decode("declared original size outside the type ceiling"));
        }
        let compressed_len = payload_len - length_field;
        if compressed_len == 0 {
            return Err(Error::Decode("compressed payload has no deflate bytes"));
        }
        if original > compressed_len.saturating_mul(limits::MAX_DEFLATE_RATIO) {
            return Err(Error::Decode("impossible compression ratio"));
        }
        let compressed = r.bytes(compressed_len)?;
        let payload = compression::decompress(compressed, original)
            .ok_or(Error::Decode("invalid deflate stream"))?;
        let wire = WirePayload::for_payload(compressed.to_vec(), true, &payload);
        (payload, wire)
    } else {
        if payload_len > cap {
            return Err(Error::Decode("payload exceeds the type ceiling"));
        }
        let bytes = r.bytes(payload_len)?.to_vec();
        let wire = WirePayload::for_payload(bytes.clone(), false, &bytes);
        (bytes, wire)
    };

    let signature = if has_signature { Some(r.array::<64>()?) } else { None };

    Ok(Packet {
        version,
        type_,
        ttl,
        timestamp,
        sender_id,
        recipient_id,
        route,
        payload,
        signature,
        is_rsr,
        wire_payload: Some(wire_payload),
    })
}

/// Wrap a raw Noise handshake message in a directed `0x10` packet.
pub fn handshake_packet(
    sender: [u8; 8],
    recipient: [u8; 8],
    ttl: u8,
    timestamp: u64,
    noise_msg: Vec<u8>,
) -> Packet {
    Packet::new(msg_type::NOISE_HANDSHAKE, ttl, timestamp, sender)
        .to(recipient)
        .with_payload(noise_msg)
}

/// Wrap a Noise transport ciphertext in a directed `0x11` packet.
pub fn encrypted_packet(
    sender: [u8; 8],
    recipient: [u8; 8],
    ttl: u8,
    timestamp: u64,
    ciphertext: Vec<u8>,
) -> Packet {
    Packet::new(msg_type::NOISE_ENCRYPTED, ttl, timestamp, sender)
        .to(recipient)
        .with_payload(ciphertext)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Packet {
        Packet::new(msg_type::MESSAGE, 7, 0x0102030405060708, [0, 1, 2, 3, 4, 5, 6, 7])
            .with_payload(b"hi".to_vec())
    }

    #[test]
    fn header_byte_layout_is_exact() {
        let bytes = sample().encode_unpadded().unwrap();
        assert_eq!(bytes.len(), 24);
        assert_eq!(bytes[0], 1);
        assert_eq!(bytes[1], msg_type::MESSAGE);
        assert_eq!(bytes[2], 7);
        assert_eq!(&bytes[3..11], &[1, 2, 3, 4, 5, 6, 7, 8]);
        assert_eq!(bytes[11], 0);
        assert_eq!(&bytes[12..14], &[0, 2]);
        assert_eq!(&bytes[14..22], &[0, 1, 2, 3, 4, 5, 6, 7]);
        assert_eq!(&bytes[22..], b"hi");
        let padded = sample().encode().unwrap();
        assert_eq!(padded.len(), 256);
        assert_eq!(Packet::decode(&padded).unwrap(), sample());
        assert_eq!(Packet::decode(&bytes).unwrap(), sample());
    }

    #[test]
    fn recipient_signature_and_rsr_flags() {
        let mut p = sample().to(BROADCAST_RECIPIENT);
        p.signature = Some([0x22; 64]);
        p.is_rsr = true;
        let b = p.encode_unpadded().unwrap();
        assert_eq!(b[11], flags::HAS_RECIPIENT | flags::HAS_SIGNATURE | flags::IS_RSR);
        let d = Packet::decode(&b).unwrap();
        assert_eq!(d, p);
        assert!(d.is_rsr);
        assert_eq!(d.recipient_id, Some(BROADCAST_RECIPIENT));
    }

    #[test]
    fn compressible_payload_rides_compressed_and_decodes() {
        let text = b"compress-me".repeat(30);
        let p = sample().with_payload(text.clone());
        let b = p.encode_unpadded().unwrap();
        assert_ne!(b[11] & flags::IS_COMPRESSED, 0);
        let declared = u16::from_be_bytes([b[12], b[13]]) as usize;
        assert!(declared < text.len());
        let d = Packet::decode(&b).unwrap();
        assert_eq!(d.payload, text);
        let w = d.wire_payload.as_ref().unwrap();
        assert!(w.compressed);
        // Re-encoding the decoded packet reproduces the wire bytes exactly,
        // even if this process' encoder would have produced something else.
        assert_eq!(d.encode_unpadded().unwrap(), b);
        // ...and padded form matches the originator's padded form.
        assert_eq!(d.encode().unwrap(), p.encode().unwrap());
    }

    #[test]
    fn changing_the_payload_drops_the_remembered_wire_bytes() {
        let p = sample().with_payload(b"compress-me".repeat(30));
        let mut d = Packet::decode(&p.encode().unwrap()).unwrap();
        d.payload = b"something else entirely that is also quite long and repeats repeats repeats repeats repeats".to_vec();
        let b = d.encode_unpadded().unwrap();
        assert_eq!(Packet::decode(&b).unwrap().payload, d.payload);
    }

    #[test]
    fn v1_route_is_ignored_and_v2_route_roundtrips() {
        let route = vec![[0x21; 8], [0x22; 8]];
        let mut p1 = sample();
        p1.route = Some(route.clone());
        let b1 = p1.encode_unpadded().unwrap();
        assert_eq!(b1[11] & flags::HAS_ROUTE, 0);
        assert!(Packet::decode(&b1).unwrap().route.is_none());

        let mut p2 = Packet::new_v2(msg_type::FILE_TRANSFER, 7, 1, [1; 8]).to([9; 8]);
        p2.route = Some(route.clone());
        p2.payload = vec![1, 2, 3, 4, 5];
        let b2 = p2.encode_unpadded().unwrap();
        assert_eq!(b2[11], flags::HAS_RECIPIENT | flags::HAS_ROUTE);
        assert_eq!(&b2[12..16], &[0, 0, 0, 5]);
        assert_eq!(b2[32], 2); // route count after sender + recipient
        let d = Packet::decode(&b2).unwrap();
        assert_eq!(d.route, Some(route));
        assert_eq!(d.payload, vec![1, 2, 3, 4, 5]);
    }

    #[test]
    fn length_fields_are_enforced() {
        let p = sample().with_payload(vec![7u8; 70_000]); // not compressible? byte 7 repeated → compressible
        // 70000 zero-ish bytes compress far below u16 but the ORIGINAL exceeds
        // the v1 field, so v1 must refuse while v2 encodes.
        assert!(p.encode().is_err());
        let mut p2 = p.clone();
        p2.version = 2;
        let b = p2.encode_unpadded().unwrap();
        // 0x02 message ceiling is 128 KiB, so 70000 decodes.
        assert_eq!(Packet::decode(&b).unwrap().payload.len(), 70_000);
        let unique: Vec<u8> = (0..70_000u32).map(|i| (i * 7 % 251) as u8).collect();
        let p3 = sample().with_payload(unique);
        assert!(p3.encode().is_err());
        let mut p4 = p3.clone();
        p4.version = 2;
        assert_eq!(Packet::decode(&p4.encode().unwrap()).unwrap(), p4);
    }

    #[test]
    fn decode_rejects_malformed_frames() {
        assert!(Packet::decode(&[0u8; 10]).is_err());
        let mut b = sample().encode_unpadded().unwrap();
        b[0] = 3;
        assert!(Packet::decode(&b).is_err());
        let mut b = sample().encode_unpadded().unwrap();
        b[13] = 200; // declared payload longer than the frame
        assert!(Packet::decode(&b).is_err());
        let mut b = sample().encode_unpadded().unwrap();
        b[11] |= flags::IS_COMPRESSED;
        b[13] = 1; // shorter than the size field
        assert!(Packet::decode(&b).is_err());
        // Type ceiling: a fragment over 1280 bytes.
        let frag = Packet::new(msg_type::FRAGMENT, 7, 1, [1; 8]).with_payload(
            (0..1300u32).map(|i| (i * 31 % 256) as u8).collect(),
        );
        assert!(Packet::decode(&frag.encode_unpadded().unwrap()).is_err());
        // Impossible ratio: declare a huge original for a tiny stream.
        let mut b = sample().encode_unpadded().unwrap();
        b[11] |= flags::IS_COMPRESSED;
        b[12] = 0;
        b[13] = 4; // 2-byte original + 2 bytes stream
        b.truncate(22);
        b.extend_from_slice(&[0xFF, 0xFF, 0x03, 0x00]);
        assert!(Packet::decode(&b).is_err());
    }

    #[test]
    fn padding_policy_only_pads_noise_frames() {
        let pm = sample();
        assert_eq!(pm.encode_with(PaddingPolicy::NoiseOnly).unwrap().len(), 24);
        let hs = handshake_packet([1; 8], [2; 8], 7, 1, vec![0u8; 32]);
        assert_eq!(hs.encode_with(PaddingPolicy::NoiseOnly).unwrap().len(), 256);
        let enc = encrypted_packet([1; 8], [2; 8], 7, 1, (0..300u32).map(|i| (i * 131 % 256) as u8).collect());
        assert_eq!(enc.encode_with(PaddingPolicy::NoiseOnly).unwrap().len(), 512);
        assert_eq!(enc.recipient_id, Some([2; 8]));
        assert_eq!(enc.type_, msg_type::NOISE_ENCRYPTED);
        assert_eq!(hs.type_, msg_type::NOISE_HANDSHAKE);
    }

    #[test]
    fn padded_frame_with_trailing_bytes_still_decodes() {
        let mut b = sample().encode_unpadded().unwrap();
        b.extend_from_slice(&[0u8; 200]);
        assert_eq!(Packet::decode(&b).unwrap().payload, b"hi");
    }
}
