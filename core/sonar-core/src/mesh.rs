//! bitchat BLE mesh wire format — the byte-for-byte compatible port of the
//! Swift reference (`bitchat/Protocols/BinaryProtocol.swift`,
//! `bitchat/Protocols/Packets.swift`, `bitchat/Models/MessagePadding.swift`).
//!
//! This is the M3 milestone foundation: the pure-bytes layer that lets the
//! Android app interoperate with the iOS bitchat/Sonar mesh. It contains NO
//! BLE I/O and NO crypto orchestration — just packet framing, PKCS#7 padding,
//! and the identity-announce TLV. Noise XX orchestration, fragmentation, and
//! signing build on top of this in later modules.
//!
//! Scope of this layer: protocol **v1** (14-byte header), uncompressed, no
//! source-route. That covers the two-phone interop path (announces + small
//! DMs never trip the >256-byte compression threshold). v2/route/compression
//! are additive and decode-reject for now (documented).

/// bitchat packet types (`MessageType`, BitchatProtocol.swift). Only the ones
/// the mesh foundation needs are named; others pass through as raw `u8`.
pub mod msg_type {
    pub const ANNOUNCE: u8 = 0x01;
    pub const MESSAGE: u8 = 0x02;
    pub const LEAVE: u8 = 0x03;
    pub const NOISE_HANDSHAKE: u8 = 0x10;
    pub const NOISE_ENCRYPTED: u8 = 0x11;
    pub const FRAGMENT: u8 = 0x20;
}

const V1_HEADER_SIZE: usize = 14;
const SENDER_ID_SIZE: usize = 8;
const RECIPIENT_ID_SIZE: usize = 8;
const SIGNATURE_SIZE: usize = 64;

mod flags {
    pub const HAS_RECIPIENT: u8 = 0x01;
    pub const HAS_SIGNATURE: u8 = 0x02;
    pub const IS_COMPRESSED: u8 = 0x04;
}

/// A decoded bitchat packet (v1). `sender_id`/`recipient_id` are the 8-byte
/// truncated peer IDs; broadcast recipient = `0xFF * 8`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Packet {
    pub version: u8,
    pub type_: u8,
    pub ttl: u8,
    pub timestamp: u64,
    pub sender_id: [u8; 8],
    pub recipient_id: Option<[u8; 8]>,
    pub payload: Vec<u8>,
    pub signature: Option<[u8; 64]>,
}

/// Broadcast recipient sentinel (`0xFF` × 8).
pub const BROADCAST_RECIPIENT: [u8; 8] = [0xFF; 8];

impl Packet {
    /// Build a v1 packet (the version Android sends).
    pub fn new(type_: u8, ttl: u8, timestamp: u64, sender_id: [u8; 8]) -> Self {
        Packet {
            version: 1,
            type_,
            ttl,
            timestamp,
            sender_id,
            recipient_id: None,
            payload: Vec::new(),
            signature: None,
        }
    }

    /// Encode to the wire format, PKCS#7-padded to the optimal block size
    /// exactly as `BinaryProtocol.encode(padding: true)`.
    pub fn encode(&self) -> Option<Vec<u8>> {
        let raw = self.encode_unpadded()?;
        let target = optimal_block_size(raw.len());
        Some(pad(raw, target))
    }

    /// Encode without the trailing PKCS#7 padding (the signed/inner form).
    pub fn encode_unpadded(&self) -> Option<Vec<u8>> {
        if self.version != 1 {
            return None; // v2/route/compression not emitted by this layer
        }
        if self.payload.len() > u16::MAX as usize {
            return None;
        }
        let mut out = Vec::with_capacity(V1_HEADER_SIZE + SENDER_ID_SIZE + self.payload.len());
        out.push(self.version);
        out.push(self.type_);
        out.push(self.ttl);
        out.extend_from_slice(&self.timestamp.to_be_bytes());

        let mut flags = 0u8;
        if self.recipient_id.is_some() {
            flags |= flags::HAS_RECIPIENT;
        }
        if self.signature.is_some() {
            flags |= flags::HAS_SIGNATURE;
        }
        out.push(flags);

        out.extend_from_slice(&(self.payload.len() as u16).to_be_bytes());
        out.extend_from_slice(&self.sender_id);
        if let Some(rid) = self.recipient_id {
            out.extend_from_slice(&rid);
        }
        out.extend_from_slice(&self.payload);
        if let Some(sig) = self.signature {
            out.extend_from_slice(&sig);
        }
        Some(out)
    }

    /// Decode a wire packet, transparently removing PKCS#7 padding (mirrors
    /// `BinaryProtocol.decode`: try as-is, else unpad and retry).
    pub fn decode(data: &[u8]) -> Option<Packet> {
        if let Some(p) = decode_core(data) {
            return Some(p);
        }
        let unpadded = unpad(data);
        if unpadded.len() == data.len() {
            return None; // nothing was stripped → already tried
        }
        decode_core(&unpadded)
    }
}

fn decode_core(raw: &[u8]) -> Option<Packet> {
    if raw.len() < V1_HEADER_SIZE + SENDER_ID_SIZE {
        return None;
    }
    let mut o = 0usize;
    let version = raw[o];
    o += 1;
    if version != 1 {
        return None; // only v1 supported in this layer
    }
    let type_ = raw[o];
    o += 1;
    let ttl = raw[o];
    o += 1;
    let mut timestamp = 0u64;
    for _ in 0..8 {
        timestamp = (timestamp << 8) | raw[o] as u64;
        o += 1;
    }
    let flags = raw[o];
    o += 1;
    let has_recipient = flags & flags::HAS_RECIPIENT != 0;
    let has_signature = flags & flags::HAS_SIGNATURE != 0;
    let is_compressed = flags & flags::IS_COMPRESSED != 0;
    if is_compressed {
        return None; // compression not handled in this foundation layer
    }
    let payload_len = ((raw[o] as usize) << 8) | raw[o + 1] as usize;
    o += 2;

    let mut sender_id = [0u8; 8];
    sender_id.copy_from_slice(&raw[o..o + SENDER_ID_SIZE]);
    o += SENDER_ID_SIZE;

    let recipient_id = if has_recipient {
        if raw.len() < o + RECIPIENT_ID_SIZE {
            return None;
        }
        let mut rid = [0u8; 8];
        rid.copy_from_slice(&raw[o..o + RECIPIENT_ID_SIZE]);
        o += RECIPIENT_ID_SIZE;
        Some(rid)
    } else {
        None
    };

    if raw.len() < o + payload_len {
        return None;
    }
    let payload = raw[o..o + payload_len].to_vec();
    o += payload_len;

    let signature = if has_signature {
        if raw.len() < o + SIGNATURE_SIZE {
            return None;
        }
        let mut sig = [0u8; 64];
        sig.copy_from_slice(&raw[o..o + SIGNATURE_SIZE]);
        o += SIGNATURE_SIZE;
        Some(sig)
    } else {
        None
    };

    let _ = o;
    Some(Packet {
        version,
        type_,
        ttl,
        timestamp,
        sender_id,
        recipient_id,
        payload,
        signature,
    })
}

// ── PKCS#7 padding (MessagePadding.swift), byte-for-byte ──

const BLOCK_SIZES: [usize; 4] = [256, 512, 1024, 2048];

/// Smallest block that fits `data_size + 16` (AES-GCM tag allowance); else the
/// size itself (large packets are fragmented, not padded).
pub fn optimal_block_size(data_size: usize) -> usize {
    let total = data_size + 16;
    for &b in &BLOCK_SIZES {
        if total <= b {
            return b;
        }
    }
    data_size
}

/// PKCS#7-style pad to `target`: only when the gap is 1..=255 (single-byte
/// marker) and `data < target`; otherwise return unchanged (== Swift).
pub fn pad(data: Vec<u8>, target: usize) -> Vec<u8> {
    if data.len() >= target {
        return data;
    }
    let needed = target - data.len();
    if needed == 0 || needed > 255 {
        return data;
    }
    let mut out = data;
    out.extend(std::iter::repeat(needed as u8).take(needed));
    out
}

/// Remove PKCS#7 padding if the trailing bytes form a valid run; else return
/// the data unchanged (== Swift `unpad`).
pub fn unpad(data: &[u8]) -> Vec<u8> {
    if data.is_empty() {
        return data.to_vec();
    }
    let last = *data.last().unwrap();
    let pad_len = last as usize;
    if pad_len == 0 || pad_len > data.len() {
        return data.to_vec();
    }
    let start = data.len() - pad_len;
    if data[start..].iter().any(|&b| b != last) {
        return data.to_vec();
    }
    data[..start].to_vec()
}

// ── Identity announce TLV (Packets.swift `AnnouncementPacket`) ──

const TLV_NICKNAME: u8 = 0x01;
const TLV_NOISE_PUBKEY: u8 = 0x02;
const TLV_SIGNING_PUBKEY: u8 = 0x03;
const TLV_DIRECT_NEIGHBORS: u8 = 0x04;

/// The identity announce a peer broadcasts so others learn its nickname + keys.
/// `noise_public_key` is the 32-byte Noise static key; `signing_public_key` is
/// the 32-byte Ed25519 key the announce is signed with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Announce {
    pub nickname: String,
    pub noise_public_key: Vec<u8>,
    pub signing_public_key: Vec<u8>,
    pub direct_neighbors: Option<Vec<[u8; 8]>>,
}

impl Announce {
    /// Encode to the TLV payload (the bytes that go into a `0x01` packet and
    /// that the Ed25519 announce signature covers). Returns None on oversize.
    pub fn encode(&self) -> Option<Vec<u8>> {
        let nick = self.nickname.as_bytes();
        if nick.len() > 255 || self.noise_public_key.len() > 255 || self.signing_public_key.len() > 255 {
            return None;
        }
        let mut out = Vec::new();
        out.push(TLV_NICKNAME);
        out.push(nick.len() as u8);
        out.extend_from_slice(nick);

        out.push(TLV_NOISE_PUBKEY);
        out.push(self.noise_public_key.len() as u8);
        out.extend_from_slice(&self.noise_public_key);

        out.push(TLV_SIGNING_PUBKEY);
        out.push(self.signing_public_key.len() as u8);
        out.extend_from_slice(&self.signing_public_key);

        if let Some(neighbors) = &self.direct_neighbors {
            if !neighbors.is_empty() {
                // Swift caps at 10 neighbors and requires a multiple of 8 bytes.
                let take = neighbors.len().min(10);
                let bytes: Vec<u8> = neighbors[..take].iter().flatten().copied().collect();
                if !bytes.is_empty() && bytes.len() % 8 == 0 && bytes.len() <= 255 {
                    out.push(TLV_DIRECT_NEIGHBORS);
                    out.push(bytes.len() as u8);
                    out.extend_from_slice(&bytes);
                }
            }
        }
        Some(out)
    }

    /// Decode from a TLV payload. Tolerant of unknown TLV types (forward-compat,
    /// == Swift). Requires nickname + both keys to be present.
    pub fn decode(data: &[u8]) -> Option<Announce> {
        let mut o = 0usize;
        let mut nickname: Option<String> = None;
        let mut noise_public_key: Option<Vec<u8>> = None;
        let mut signing_public_key: Option<Vec<u8>> = None;
        let mut direct_neighbors: Option<Vec<[u8; 8]>> = None;

        while o + 2 <= data.len() {
            let t = data[o];
            o += 1;
            let len = data[o] as usize;
            o += 1;
            if o + len > data.len() {
                return None;
            }
            let value = &data[o..o + len];
            o += len;
            match t {
                TLV_NICKNAME => nickname = String::from_utf8(value.to_vec()).ok(),
                TLV_NOISE_PUBKEY => noise_public_key = Some(value.to_vec()),
                TLV_SIGNING_PUBKEY => signing_public_key = Some(value.to_vec()),
                TLV_DIRECT_NEIGHBORS => {
                    if len > 0 && len % 8 == 0 {
                        let mut ns = Vec::with_capacity(len / 8);
                        for chunk in value.chunks_exact(8) {
                            let mut id = [0u8; 8];
                            id.copy_from_slice(chunk);
                            ns.push(id);
                        }
                        direct_neighbors = Some(ns);
                    }
                }
                _ => {} // unknown TLV: skip
            }
        }
        Some(Announce {
            nickname: nickname?,
            noise_public_key: noise_public_key?,
            signing_public_key: signing_public_key?,
            direct_neighbors,
        })
    }
}

/// Derive the short bitchat peer ID from a Noise static public key:
/// `SHA256(noise_pubkey)` → first 8 bytes → 16 lowercase hex chars
/// (== `BLEService` peerID derivation).
pub fn peer_id_from_noise_key(noise_public_key: &[u8]) -> String {
    use nostr::hashes::{sha256, Hash};
    let digest = sha256::Hash::hash(noise_public_key);
    digest.as_byte_array()[..8]
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect()
}

// ── Ed25519 mesh signing identity + announce sign/verify ──
//
// The announce is Ed25519-signed (`NoiseEncryptionService.signData`). The signed
// bytes are the packet in canonical form — **ttl=0, signature=nil, isRSR=false,
// PKCS#7-padded** — produced by `BitchatPacket.toBinaryDataForSigning()` (which
// calls `BinaryProtocol.encode(padding: true)`). ed25519-dalek is RFC 8032, so
// it interoperates with Apple's `Curve25519.Signing` on iOS. Non-strict `verify`
// matches CryptoKit's `isValidSignature`.

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};

/// The Ed25519 keypair the device signs its mesh announce with — distinct from
/// the Noise static key and the Nostr key. The host persists the 32-byte seed.
pub struct MeshSigner {
    key: SigningKey,
}

impl MeshSigner {
    /// Generate a fresh signer from the OS CSPRNG.
    pub fn generate() -> Self {
        let mut seed = [0u8; 32];
        getrandom::getrandom(&mut seed).expect("OS RNG available");
        MeshSigner {
            key: SigningKey::from_bytes(&seed),
        }
    }

    /// Reconstruct from a persisted 32-byte seed.
    pub fn from_seed(seed: &[u8; 32]) -> Self {
        MeshSigner {
            key: SigningKey::from_bytes(seed),
        }
    }

    /// The 32-byte seed to persist (host-side Keychain/Keystore).
    pub fn seed(&self) -> [u8; 32] {
        self.key.to_bytes()
    }

    /// The 32-byte Ed25519 public key that goes in the announce TLV.
    pub fn public_key(&self) -> [u8; 32] {
        self.key.verifying_key().to_bytes()
    }

    fn sign(&self, msg: &[u8]) -> [u8; 64] {
        self.key.sign(msg).to_bytes()
    }
}

/// Canonical signing bytes for a packet: ttl forced to 0, signature stripped,
/// then the normal padded encode (== `toBinaryDataForSigning`).
fn signing_bytes(packet: &Packet) -> Option<Vec<u8>> {
    let mut canon = packet.clone();
    canon.ttl = 0;
    canon.signature = None;
    canon.encode()
}

/// Sign `packet` in place (sets `packet.signature`) with the mesh signer.
/// Returns false if the packet can't be encoded for signing.
pub fn sign_packet(packet: &mut Packet, signer: &MeshSigner) -> bool {
    match signing_bytes(packet) {
        Some(bytes) => {
            packet.signature = Some(signer.sign(&bytes));
            true
        }
        None => false,
    }
}

/// Verify a received packet's signature against an Ed25519 signing public key
/// (== `verifyPacketSignature`). False if unsigned, malformed, or invalid.
pub fn verify_packet(packet: &Packet, signing_public_key: &[u8]) -> bool {
    let sig = match packet.signature {
        Some(s) => s,
        None => return false,
    };
    let bytes = match signing_bytes(packet) {
        Some(b) => b,
        None => return false,
    };
    ed25519_verify(signing_public_key, &bytes, &sig)
}

/// Raw Ed25519 verify (non-strict, to match Apple CryptoKit).
pub fn ed25519_verify(public_key: &[u8], msg: &[u8], signature: &[u8]) -> bool {
    let pk: [u8; 32] = match public_key.try_into() {
        Ok(p) => p,
        Err(_) => return false,
    };
    let sig: [u8; 64] = match signature.try_into() {
        Ok(s) => s,
        Err(_) => return false,
    };
    let vk = match VerifyingKey::from_bytes(&pk) {
        Ok(v) => v,
        Err(_) => return false,
    };
    vk.verify(msg, &Signature::from_bytes(&sig)).is_ok()
}

// ── Noise-over-mesh framing (0x10 handshake / 0x11 encrypted) ──
//
// Handshake (m1/m2/m3): raw Noise message bytes are the payload of a 0x10
// packet, directed (recipientID = peer). Application messages: the Noise
// ciphertext is the payload of a 0x11 packet, directed. The decrypted inner
// plaintext is `[NoisePayloadType byte][TLV]` — for a private message,
// `[0x01][PrivateMessagePacket TLV]` (== NoiseEncryptionService).

/// Inner payload-type byte inside a decrypted noiseEncrypted message.
pub mod noise_payload {
    pub const PRIVATE_MESSAGE: u8 = 0x01;
    pub const READ_RECEIPT: u8 = 0x02;
    pub const DELIVERED: u8 = 0x03;
    pub const VERIFY_CHALLENGE: u8 = 0x10;
    pub const VERIFY_RESPONSE: u8 = 0x11;
}

/// A private chat message (`PrivateMessagePacket`): messageID + content, both
/// UTF-8, carried inside a noiseEncrypted payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrivateMessage {
    pub message_id: String,
    pub content: String,
}

const PM_TLV_MESSAGE_ID: u8 = 0x00;
const PM_TLV_CONTENT: u8 = 0x01;

impl PrivateMessage {
    /// Encode the TLV (messageID 0x00, content 0x01) — order matches Swift.
    pub fn encode(&self) -> Option<Vec<u8>> {
        let id = self.message_id.as_bytes();
        let content = self.content.as_bytes();
        if id.len() > 255 || content.len() > 255 {
            return None;
        }
        let mut out = Vec::with_capacity(4 + id.len() + content.len());
        out.push(PM_TLV_MESSAGE_ID);
        out.push(id.len() as u8);
        out.extend_from_slice(id);
        out.push(PM_TLV_CONTENT);
        out.push(content.len() as u8);
        out.extend_from_slice(content);
        Some(out)
    }

    /// Decode the TLV. Swift's decoder rejects unknown TLV types here (unlike the
    /// tolerant announce decoder), so we mirror that.
    pub fn decode(data: &[u8]) -> Option<PrivateMessage> {
        let mut o = 0usize;
        let mut message_id: Option<String> = None;
        let mut content: Option<String> = None;
        while o + 2 <= data.len() {
            let t = data[o];
            o += 1;
            let len = data[o] as usize;
            o += 1;
            if o + len > data.len() {
                return None;
            }
            let value = &data[o..o + len];
            o += len;
            match t {
                PM_TLV_MESSAGE_ID => message_id = String::from_utf8(value.to_vec()).ok(),
                PM_TLV_CONTENT => content = String::from_utf8(value.to_vec()).ok(),
                _ => return None,
            }
        }
        Some(PrivateMessage {
            message_id: message_id?,
            content: content?,
        })
    }
}

/// Build the inner plaintext to Noise-encrypt for a private message:
/// `[0x01][PrivateMessagePacket TLV]`.
pub fn encode_private_message_plaintext(msg: &PrivateMessage) -> Option<Vec<u8>> {
    let mut out = vec![noise_payload::PRIVATE_MESSAGE];
    out.extend(msg.encode()?);
    Some(out)
}

/// Split a decrypted noiseEncrypted plaintext into its type byte and the rest.
pub fn split_noise_plaintext(plain: &[u8]) -> Option<(u8, &[u8])> {
    plain.split_first().map(|(t, rest)| (*t, rest))
}

/// Wrap a raw Noise handshake message in a directed 0x10 packet.
pub fn handshake_packet(sender: [u8; 8], recipient: [u8; 8], ttl: u8, timestamp: u64, noise_msg: Vec<u8>) -> Packet {
    let mut p = Packet::new(msg_type::NOISE_HANDSHAKE, ttl, timestamp, sender);
    p.recipient_id = Some(recipient);
    p.payload = noise_msg;
    p
}

/// Wrap a Noise ciphertext in a directed 0x11 packet.
pub fn encrypted_packet(sender: [u8; 8], recipient: [u8; 8], ttl: u8, timestamp: u64, ciphertext: Vec<u8>) -> Packet {
    let mut p = Packet::new(msg_type::NOISE_ENCRYPTED, ttl, timestamp, sender);
    p.recipient_id = Some(recipient);
    p.payload = ciphertext;
    p
}

// ── Fragmentation (type 0x20) ──
//
// Large packets are split: each fragment is a 0x20 packet whose payload is
// `fragmentID(8) | index(2 BE) | total(2 BE) | originalType(1) | chunk`, with
// the original packet's sender/recipient/ttl/timestamp preserved. The chunks
// reassemble (keyed by sender||fragmentID) into the original encoded packet
// bytes, which are then decoded. Not needed for sub-MTU traffic (announces +
// short DMs) — present for long messages; live-validated on device.
pub mod fragment {
    pub const HEADER_SIZE: usize = 13;

    /// A parsed fragment payload.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Fragment {
        pub fragment_id: [u8; 8],
        pub index: u16,
        pub total: u16,
        pub original_type: u8,
        pub chunk: Vec<u8>,
    }

    impl Fragment {
        /// Encode to the `0x20` packet payload (big-endian index/total).
        pub fn encode_payload(&self) -> Vec<u8> {
            let mut out = Vec::with_capacity(HEADER_SIZE + self.chunk.len());
            out.extend_from_slice(&self.fragment_id);
            out.extend_from_slice(&self.index.to_be_bytes());
            out.extend_from_slice(&self.total.to_be_bytes());
            out.push(self.original_type);
            out.extend_from_slice(&self.chunk);
            out
        }

        /// Decode a `0x20` packet payload.
        pub fn decode_payload(p: &[u8]) -> Option<Fragment> {
            if p.len() < HEADER_SIZE {
                return None;
            }
            let mut fragment_id = [0u8; 8];
            fragment_id.copy_from_slice(&p[0..8]);
            let index = u16::from_be_bytes([p[8], p[9]]);
            let total = u16::from_be_bytes([p[10], p[11]]);
            let original_type = p[12];
            Some(Fragment {
                fragment_id,
                index,
                total,
                original_type,
                chunk: p[HEADER_SIZE..].to_vec(),
            })
        }
    }

    use std::collections::HashMap;

    /// Reassembles fragments keyed by (sender, fragmentID). `add` returns the
    /// concatenated original bytes once every index 0..total has arrived.
    #[derive(Default)]
    pub struct Reassembler {
        buckets: HashMap<([u8; 8], [u8; 8]), Vec<Option<Vec<u8>>>>,
    }

    impl Reassembler {
        pub fn new() -> Self {
            Reassembler { buckets: HashMap::new() }
        }

        /// Feed one fragment (with the carrying packet's `sender`). Returns the
        /// reassembled original packet bytes when complete.
        pub fn add(&mut self, sender: [u8; 8], frag: &Fragment) -> Option<Vec<u8>> {
            if frag.total == 0 || frag.index >= frag.total {
                return None;
            }
            let key = (sender, frag.fragment_id);
            let slots = self
                .buckets
                .entry(key)
                .or_insert_with(|| vec![None; frag.total as usize]);
            if slots.len() != frag.total as usize {
                return None; // inconsistent total for this id
            }
            slots[frag.index as usize] = Some(frag.chunk.clone());
            if slots.iter().all(|s| s.is_some()) {
                let mut out = Vec::new();
                for s in slots.iter() {
                    out.extend_from_slice(s.as_ref().unwrap());
                }
                self.buckets.remove(&key);
                Some(out)
            } else {
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packet_roundtrip_broadcast_no_sig() {
        let mut p = Packet::new(msg_type::MESSAGE, 7, 0x0102030405060708, [1, 2, 3, 4, 5, 6, 7, 8]);
        p.payload = b"hello mesh".to_vec();
        let wire = p.encode().unwrap();
        let back = Packet::decode(&wire).unwrap();
        assert_eq!(back, p);
    }

    #[test]
    fn packet_roundtrip_with_recipient_and_signature() {
        let mut p = Packet::new(msg_type::NOISE_ENCRYPTED, 3, 42, [9; 8]);
        p.recipient_id = Some([0xAB; 8]);
        p.payload = vec![0u8; 200];
        p.signature = Some([0x5A; 64]);
        let wire = p.encode().unwrap();
        let back = Packet::decode(&wire).unwrap();
        assert_eq!(back, p);
        assert_eq!(back.recipient_id, Some([0xAB; 8]));
        assert_eq!(back.signature, Some([0x5A; 64]));
    }

    #[test]
    fn header_byte_layout_is_exact() {
        // Anchor the v1 header against the documented Swift layout.
        let p = Packet::new(0x02, 0x07, 0x0011223344556677, [0xAA; 8]);
        let raw = p.encode_unpadded().unwrap();
        assert_eq!(raw[0], 1, "version");
        assert_eq!(raw[1], 0x02, "type");
        assert_eq!(raw[2], 0x07, "ttl");
        assert_eq!(&raw[3..11], &[0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77], "timestamp BE");
        assert_eq!(raw[11], 0, "flags (no recipient/sig)");
        assert_eq!(&raw[12..14], &[0x00, 0x00], "payload length BE");
        assert_eq!(&raw[14..22], &[0xAA; 8], "sender id");
    }

    #[test]
    fn padding_matches_swift_rules() {
        // 50-byte data → +16 = 66 → block 256 → pad to 256.
        assert_eq!(optimal_block_size(50), 256);
        let padded = pad(vec![0u8; 50], 256);
        assert_eq!(padded.len(), 256);
        assert_eq!(*padded.last().unwrap(), (256 - 50) as u8);
        assert_eq!(unpad(&padded), vec![0u8; 50]);

        // Gap > 255 → no padding (Swift returns unchanged).
        assert_eq!(optimal_block_size(241), 512); // 241+16=257 → 512
        let not_padded = pad(vec![0u8; 241], 512); // gap 271 > 255
        assert_eq!(not_padded.len(), 241);
    }

    #[test]
    fn unpad_leaves_non_padded_data() {
        let data = vec![1, 2, 3, 9]; // last=9 but only 4 bytes → invalid run
        assert_eq!(unpad(&data), data);
    }

    #[test]
    fn announce_roundtrip_and_tolerant_decode() {
        let a = Announce {
            nickname: "softsignal".into(),
            noise_public_key: vec![0x11; 32],
            signing_public_key: vec![0x22; 32],
            direct_neighbors: Some(vec![[1; 8], [2; 8]]),
        };
        let enc = a.encode().unwrap();
        assert_eq!(Announce::decode(&enc).unwrap(), a);

        // Unknown TLV in the middle is skipped.
        let mut with_unknown = Vec::new();
        with_unknown.push(0x09u8); // unknown type
        with_unknown.push(3u8);
        with_unknown.extend_from_slice(&[1, 2, 3]);
        with_unknown.extend_from_slice(&enc);
        let back = Announce::decode(&with_unknown).unwrap();
        assert_eq!(back.nickname, "softsignal");
    }

    #[test]
    fn announce_missing_required_field_is_none() {
        // Only a nickname TLV — missing keys → None.
        let only_nick = vec![TLV_NICKNAME, 3, b'a', b'b', b'c'];
        assert!(Announce::decode(&only_nick).is_none());
    }

    #[test]
    fn peer_id_is_16_hex_chars() {
        let id = peer_id_from_noise_key(&[0u8; 32]);
        assert_eq!(id.len(), 16);
        assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
    }

    fn signed_announce_packet(signer: &MeshSigner) -> Packet {
        let announce = Announce {
            nickname: "softsignal".into(),
            noise_public_key: vec![0x11; 32],
            signing_public_key: signer.public_key().to_vec(),
            direct_neighbors: None,
        };
        let mut p = Packet::new(msg_type::ANNOUNCE, 7, 1_700_000_000_000, [0xCA; 8]);
        p.payload = announce.encode().unwrap();
        assert!(sign_packet(&mut p, signer));
        p
    }

    #[test]
    fn announce_sign_and_verify_roundtrip() {
        let signer = MeshSigner::generate();
        let p = signed_announce_packet(&signer);
        // Verifies against the signer's public key (the one in the TLV).
        assert!(verify_packet(&p, &signer.public_key()));
    }

    #[test]
    fn signature_survives_wire_roundtrip_and_ttl_change() {
        let signer = MeshSigner::generate();
        let mut p = signed_announce_packet(&signer);
        // A relay decrements ttl; the signature (ttl=0 canonical) must still verify.
        let wire = p.encode().unwrap();
        let mut received = Packet::decode(&wire).unwrap();
        received.ttl = 3; // simulate relay
        assert!(verify_packet(&received, &signer.public_key()));
        p.ttl = 1;
        assert!(verify_packet(&p, &signer.public_key()));
    }

    #[test]
    fn tampered_payload_or_wrong_key_fails() {
        let signer = MeshSigner::generate();
        let other = MeshSigner::generate();
        let mut p = signed_announce_packet(&signer);
        assert!(!verify_packet(&p, &other.public_key()), "wrong key rejected");
        p.payload[0] ^= 0xFF; // tamper
        assert!(!verify_packet(&p, &signer.public_key()), "tamper rejected");
    }

    #[test]
    fn seed_roundtrip_is_stable() {
        let signer = MeshSigner::generate();
        let seed = signer.seed();
        let restored = MeshSigner::from_seed(&seed);
        assert_eq!(signer.public_key(), restored.public_key());
        let msg = b"deterministic";
        // Ed25519 is deterministic → same signer, same signature.
        assert_eq!(signer.sign(msg), restored.sign(msg));
    }

    #[test]
    fn ed25519_verify_rejects_malformed_inputs() {
        assert!(!ed25519_verify(&[0u8; 10], b"x", &[0u8; 64]), "bad pubkey len");
        assert!(!ed25519_verify(&[0u8; 32], b"x", &[0u8; 10]), "bad sig len");
    }

    #[test]
    fn private_message_tlv_roundtrip() {
        let pm = PrivateMessage { message_id: "abc-123".into(), content: "ciao mesh".into() };
        let enc = pm.encode().unwrap();
        // First TLV is messageID (0x00), then content (0x01).
        assert_eq!(enc[0], PM_TLV_MESSAGE_ID);
        assert_eq!(PrivateMessage::decode(&enc).unwrap(), pm);
    }

    #[test]
    fn noise_private_message_plaintext_framing() {
        let pm = PrivateMessage { message_id: "id".into(), content: "hi".into() };
        let plain = encode_private_message_plaintext(&pm).unwrap();
        let (t, rest) = split_noise_plaintext(&plain).unwrap();
        assert_eq!(t, noise_payload::PRIVATE_MESSAGE);
        assert_eq!(PrivateMessage::decode(rest).unwrap(), pm);
    }

    #[test]
    fn noise_packets_are_directed_with_right_types() {
        let hs = handshake_packet([1; 8], [2; 8], 1, 0, vec![0xAB; 48]);
        assert_eq!(hs.type_, msg_type::NOISE_HANDSHAKE);
        assert_eq!(hs.recipient_id, Some([2; 8]));
        let enc = encrypted_packet([1; 8], [2; 8], 1, 0, vec![0xCD; 80]);
        assert_eq!(enc.type_, msg_type::NOISE_ENCRYPTED);
        assert_eq!(enc.recipient_id, Some([2; 8]));
        // Wire round-trips preserve everything.
        assert_eq!(Packet::decode(&hs.encode().unwrap()).unwrap(), hs);
        assert_eq!(Packet::decode(&enc.encode().unwrap()).unwrap(), enc);
    }

    #[test]
    fn fragment_payload_byte_layout_and_roundtrip() {
        let f = fragment::Fragment {
            fragment_id: [0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7],
            index: 0x0102,
            total: 0x0304,
            original_type: msg_type::NOISE_ENCRYPTED,
            chunk: vec![1, 2, 3, 4],
        };
        let p = f.encode_payload();
        assert_eq!(&p[0..8], &f.fragment_id);
        assert_eq!(&p[8..10], &[0x01, 0x02], "index BE");
        assert_eq!(&p[10..12], &[0x03, 0x04], "total BE");
        assert_eq!(p[12], msg_type::NOISE_ENCRYPTED, "original type");
        assert_eq!(fragment::Fragment::decode_payload(&p).unwrap(), f);
    }

    #[test]
    fn fragment_reassembly_completes_in_order_and_out_of_order() {
        let id = [9u8; 8];
        let sender = [7u8; 8];
        let original = b"the original encoded packet bytes".to_vec();
        // Split into 3 chunks.
        let chunks: Vec<&[u8]> = original.chunks(12).collect();
        let total = chunks.len() as u16;
        let frags: Vec<fragment::Fragment> = chunks
            .iter()
            .enumerate()
            .map(|(i, c)| fragment::Fragment {
                fragment_id: id,
                index: i as u16,
                total,
                original_type: msg_type::MESSAGE,
                chunk: c.to_vec(),
            })
            .collect();

        let mut r = fragment::Reassembler::new();
        // Feed out of order: 2, 0, 1.
        assert!(r.add(sender, &frags[2]).is_none());
        assert!(r.add(sender, &frags[0]).is_none());
        let done = r.add(sender, &frags[1]).unwrap();
        assert_eq!(done, original);
    }
}
