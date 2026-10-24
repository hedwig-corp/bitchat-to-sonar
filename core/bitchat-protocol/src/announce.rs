//! The identity announce (`AnnouncementPacket` / `IdentityAnnouncement`),
//! payload of a `0x01` packet.
//!
//! One-byte type, one-byte length, value. Required: nickname (0x01), Noise
//! static public key (0x02), Ed25519 signing key (0x03). Optional: direct
//! neighbours (0x04, ≤10 × 8 bytes), capabilities (0x05, minimal little-endian
//! bitfield), bridge geohash (0x06, ≤12 bytes). Unknown TLVs are skipped on
//! decode and, like upstream Android, preserved so a re-encode does not erase
//! a newer client's extension; they are re-emitted after the known fields.

use crate::{Error, Result};

const TLV_NICKNAME: u8 = 0x01;
const TLV_NOISE_PUBKEY: u8 = 0x02;
const TLV_SIGNING_PUBKEY: u8 = 0x03;
const TLV_DIRECT_NEIGHBORS: u8 = 0x04;
const TLV_CAPABILITIES: u8 = 0x05;
const TLV_BRIDGE_GEOHASH: u8 = 0x06;
const MAX_NEIGHBORS: usize = 10;
const MAX_GEOHASH_BYTES: usize = 12;

/// Feature bits advertised in announce TLV 0x05 and proven in
/// [`crate::AuthenticatedPeerState`]. Wire form: the minimal little-endian
/// byte string (at least one byte). Unknown bits are kept on decode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct PeerCapabilities(pub u64);

impl PeerCapabilities {
    /// No capabilities.
    pub const NONE: Self = Self(0);
    /// Forward-secret async first contact (courier prekeys).
    pub const PREKEYS: Self = Self(1 << 0);
    /// Wi-Fi Aware bulk transfer.
    pub const WIFI_BULK: Self = Self(1 << 1);
    /// Mesh↔Nostr gateway.
    pub const GATEWAY: Self = Self(1 << 2);
    /// Private groups.
    pub const GROUPS: Self = Self(1 << 3);
    /// Geohash bulletin board.
    pub const BOARD: Self = Self(1 << 4);
    /// Transitive verification vouches.
    pub const VOUCH: Self = Self(1 << 5);
    /// `/ping`, `/trace`.
    pub const MESH_DIAGNOSTICS: Self = Self(1 << 6);
    /// Bridges a rendezvous geohash cell.
    pub const BRIDGE: Self = Self(1 << 7);
    /// Receives private media as Noise payload `0x20`.
    pub const PRIVATE_MEDIA: Self = Self(1 << 8);
    /// Sends delivery receipts for private media.
    pub const PRIVATE_MEDIA_RECEIPTS: Self = Self(1 << 9);
    /// Reserved by iOS; decode but never advertise.
    pub const NON_DESTRUCTIVE_NOISE_REPLACEMENT: Self = Self(1 << 10);

    /// Does this set include every bit of `other`?
    pub fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// Union.
    pub fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    /// Minimal little-endian encoding (always at least one byte).
    pub fn encoded(self) -> Vec<u8> {
        let mut v = self.0;
        let mut out = Vec::with_capacity(2);
        loop {
            out.push(v as u8);
            v >>= 8;
            if v == 0 {
                break;
            }
        }
        out
    }

    /// Decode the low 64 bits; extension bytes beyond 8 are ignored.
    pub fn decode(bytes: &[u8]) -> Self {
        let mut v = 0u64;
        for (i, &b) in bytes.iter().take(8).enumerate() {
            v |= (b as u64) << (8 * i);
        }
        Self(v)
    }

    /// Is `bytes` the minimal encoding of the value it decodes to?
    pub fn is_canonical(bytes: &[u8]) -> bool {
        !bytes.is_empty() && bytes.len() <= 8 && Self::decode(bytes).encoded() == bytes
    }
}

/// A TLV this build does not understand, preserved for re-encoding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnknownTlv {
    /// Type byte.
    pub type_: u8,
    /// Value (≤255 bytes).
    pub value: Vec<u8>,
}

/// Decoded announce payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Announce {
    /// UTF-8 nickname, ≤255 bytes.
    pub nickname: String,
    /// 32-byte Noise static (X25519) public key.
    pub noise_public_key: Vec<u8>,
    /// 32-byte Ed25519 signing public key.
    pub signing_public_key: Vec<u8>,
    /// Up to 10 direct-neighbour peer ids.
    pub direct_neighbors: Option<Vec<[u8; 8]>>,
    /// Advertised feature bits; `None` when the sender predates TLV 0x05.
    pub capabilities: Option<PeerCapabilities>,
    /// Coarse rendezvous cell when bridging.
    pub bridge_geohash: Option<String>,
    /// Extensions this build does not understand.
    pub unknown_tlvs: Vec<UnknownTlv>,
}

impl Announce {
    /// The minimal announce: nickname and the two keys.
    pub fn new(nickname: impl Into<String>, noise_public_key: Vec<u8>, signing_public_key: Vec<u8>) -> Self {
        Announce {
            nickname: nickname.into(),
            noise_public_key,
            signing_public_key,
            direct_neighbors: None,
            capabilities: None,
            bridge_geohash: None,
            unknown_tlvs: Vec::new(),
        }
    }

    /// Builder: advertise capabilities.
    pub fn with_capabilities(mut self, caps: PeerCapabilities) -> Self {
        self.capabilities = Some(caps);
        self
    }

    /// Encode the TLV payload (byte-identical to `AnnouncementPacket.encode`).
    pub fn encode(&self) -> Result<Vec<u8>> {
        let nick = self.nickname.as_bytes();
        if nick.len() > 255 {
            return Err(Error::Encode("nickname over 255 bytes"));
        }
        if self.noise_public_key.len() > 255 || self.signing_public_key.len() > 255 {
            return Err(Error::Encode("key over 255 bytes"));
        }
        let mut out = Vec::with_capacity(6 + nick.len() + 64 + 32);
        push_tlv(&mut out, TLV_NICKNAME, nick);
        push_tlv(&mut out, TLV_NOISE_PUBKEY, &self.noise_public_key);
        push_tlv(&mut out, TLV_SIGNING_PUBKEY, &self.signing_public_key);
        if let Some(neighbors) = &self.direct_neighbors {
            if !neighbors.is_empty() {
                let bytes: Vec<u8> = neighbors
                    .iter()
                    .take(MAX_NEIGHBORS)
                    .flatten()
                    .copied()
                    .collect();
                push_tlv(&mut out, TLV_DIRECT_NEIGHBORS, &bytes);
            }
        }
        if let Some(caps) = self.capabilities {
            push_tlv(&mut out, TLV_CAPABILITIES, &caps.encoded());
        }
        if let Some(cell) = &self.bridge_geohash {
            let b = cell.as_bytes();
            if !b.is_empty() && b.len() <= MAX_GEOHASH_BYTES {
                push_tlv(&mut out, TLV_BRIDGE_GEOHASH, b);
            }
        }
        for u in &self.unknown_tlvs {
            if u.value.len() > 255 {
                return Err(Error::Encode("unknown TLV over 255 bytes"));
            }
            push_tlv(&mut out, u.type_, &u.value);
        }
        Ok(out)
    }

    /// Decode; tolerant of unknown TLVs, strict on lengths, requires the
    /// nickname and both keys.
    pub fn decode(data: &[u8]) -> Result<Announce> {
        let mut nickname = None;
        let mut noise_public_key = None;
        let mut signing_public_key = None;
        let mut direct_neighbors = None;
        let mut capabilities = None;
        let mut bridge_geohash = None;
        let mut unknown_tlvs = Vec::new();
        for (t, value) in tlv_iter(data)? {
            match t {
                TLV_NICKNAME => nickname = String::from_utf8(value.to_vec()).ok(),
                TLV_NOISE_PUBKEY => noise_public_key = Some(value.to_vec()),
                TLV_SIGNING_PUBKEY => signing_public_key = Some(value.to_vec()),
                TLV_DIRECT_NEIGHBORS => {
                    if !value.is_empty() && value.len() % 8 == 0 {
                        direct_neighbors = Some(
                            value
                                .chunks_exact(8)
                                .map(|c| {
                                    let mut id = [0u8; 8];
                                    id.copy_from_slice(c);
                                    id
                                })
                                .collect(),
                        );
                    }
                }
                TLV_CAPABILITIES => capabilities = Some(PeerCapabilities::decode(value)),
                TLV_BRIDGE_GEOHASH => {
                    if value.len() <= MAX_GEOHASH_BYTES {
                        bridge_geohash = String::from_utf8(value.to_vec()).ok();
                    }
                }
                other => unknown_tlvs.push(UnknownTlv {
                    type_: other,
                    value: value.to_vec(),
                }),
            }
        }
        Ok(Announce {
            nickname: nickname.ok_or(Error::Decode("announce without nickname"))?,
            noise_public_key: noise_public_key.ok_or(Error::Decode("announce without noise key"))?,
            signing_public_key: signing_public_key
                .ok_or(Error::Decode("announce without signing key"))?,
            direct_neighbors,
            capabilities,
            bridge_geohash,
            unknown_tlvs,
        })
    }
}

/// Append a one-byte-length TLV. Caller guarantees `value.len() <= 255`.
pub(crate) fn push_tlv(out: &mut Vec<u8>, t: u8, value: &[u8]) {
    out.push(t);
    out.push(value.len() as u8);
    out.extend_from_slice(value);
}

/// Iterate one-byte-type / one-byte-length TLVs. A trailing single byte is
/// ignored (the clients loop `while offset + 2 <= count`); a length that
/// overruns the buffer is an error.
pub(crate) fn tlv_iter(data: &[u8]) -> Result<Vec<(u8, &[u8])>> {
    let mut out = Vec::new();
    let mut o = 0usize;
    while o + 2 <= data.len() {
        let t = data[o];
        let len = data[o + 1] as usize;
        o += 2;
        if o + len > data.len() {
            return Err(Error::Decode("TLV length overruns the payload"));
        }
        out.push((t, &data[o..o + len]));
        o += len;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_with_every_optional_field_and_unknown_tlv() {
        let mut a = Announce::new("carol", vec![5u8; 32], vec![6u8; 32]);
        a.direct_neighbors = Some(vec![[1; 8], [2; 8]]);
        a.capabilities = Some(PeerCapabilities(0x301));
        a.bridge_geohash = Some("u4pruyd".into());
        a.unknown_tlvs.push(UnknownTlv { type_: 0x7f, value: b"abc".to_vec() });
        let b = a.encode().unwrap();
        // nickname(2+5) noise(2+32) signing(2+32) neighbors(2+16) caps(2+2) geo(2+7) unk(2+3)
        assert_eq!(b.len(), 7 + 34 + 34 + 18 + 4 + 9 + 5);
        assert_eq!(&b[0..7], &[0x01, 5, b'c', b'a', b'r', b'o', b'l']);
        let caps_at = 7 + 34 + 34 + 18;
        assert_eq!(&b[caps_at..caps_at + 4], &[0x05, 2, 0x01, 0x03]);
        assert_eq!(Announce::decode(&b).unwrap(), a);
    }

    #[test]
    fn unknown_tlv_in_the_middle_is_kept_and_reemitted_last() {
        let a = Announce::new("alice", vec![1u8; 32], vec![2u8; 32]).with_capabilities(PeerCapabilities::PRIVATE_MEDIA);
        let mut b = a.encode().unwrap();
        // Insert 7f 03 61 62 63 before the capabilities TLV.
        let caps_at = b.len() - 4;
        let mut with_unknown = b[..caps_at].to_vec();
        with_unknown.extend_from_slice(&[0x7f, 3, b'a', b'b', b'c']);
        with_unknown.extend_from_slice(&b[caps_at..]);
        let d = Announce::decode(&with_unknown).unwrap();
        assert_eq!(d.unknown_tlvs, vec![UnknownTlv { type_: 0x7f, value: b"abc".to_vec() }]);
        b.extend_from_slice(&[0x7f, 3, b'a', b'b', b'c']);
        assert_eq!(d.encode().unwrap(), b, "re-encode appends unknown TLVs after known ones");
    }

    #[test]
    fn decode_rejects_missing_keys_and_overrun() {
        let a = Announce::new("x", vec![1u8; 32], vec![2u8; 32]);
        let b = a.encode().unwrap();
        assert!(Announce::decode(&b[..b.len() - 34]).is_err()); // no signing key
        let mut bad = b.clone();
        bad[1] = 200; // nickname length overruns
        assert!(Announce::decode(&bad).is_err());
        assert!(Announce::new("x".repeat(256), vec![], vec![]).encode().is_err());
        assert!(Announce::new("x".repeat(255), vec![], vec![]).encode().is_ok());
    }

    #[test]
    fn capabilities_encoding_is_minimal_little_endian() {
        assert_eq!(PeerCapabilities(0).encoded(), vec![0]);
        assert_eq!(PeerCapabilities(1).encoded(), vec![1]);
        assert_eq!(PeerCapabilities(0x100).encoded(), vec![0, 1]);
        assert_eq!(PeerCapabilities(0x301).encoded(), vec![1, 3]);
        assert_eq!(PeerCapabilities(0x10000).encoded(), vec![0, 0, 1]);
        assert_eq!(PeerCapabilities(u64::MAX).encoded(), vec![0xff; 8]);
        assert_eq!(PeerCapabilities::decode(&[]), PeerCapabilities(0));
        assert_eq!(PeerCapabilities::decode(&[0xff; 9]), PeerCapabilities(u64::MAX));
        assert!(PeerCapabilities::is_canonical(&[0, 1]));
        assert!(!PeerCapabilities::is_canonical(&[0, 1, 0]));
        assert!(!PeerCapabilities::is_canonical(&[]));
        assert!(PeerCapabilities(0x300).contains(PeerCapabilities::PRIVATE_MEDIA));
        assert!(!PeerCapabilities(0x200).contains(PeerCapabilities::PRIVATE_MEDIA));
    }
}
