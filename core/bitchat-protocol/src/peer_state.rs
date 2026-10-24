//! `AuthenticatedPeerStatePacket` — Noise payload `0x21`.
//!
//! State that is authoritative only because it arrives inside an established
//! Noise session: the public announce's self-signature cannot prove possession
//! of the Noise key it carries, this can. Emitted after every completed or
//! rekeyed handshake. Wire: `[version=0x01][type][len][value]...` with TLV
//! `0x01` = canonical minimal little-endian capabilities (1–8 bytes) and
//! `0x02` = 32-byte Ed25519 signing key. Duplicates, non-canonical
//! capabilities, bad lengths, missing fields and unknown versions are
//! rejected; unknown TLVs are skipped.

use crate::announce::{push_tlv, PeerCapabilities};
use crate::{Error, Result};

const VERSION: u8 = 0x01;
const TLV_CAPABILITIES: u8 = 0x01;
const TLV_SIGNING_KEY: u8 = 0x02;

/// Capabilities and signing key bound to the current Noise session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthenticatedPeerState {
    /// Proven feature bits.
    pub capabilities: PeerCapabilities,
    /// The Ed25519 key this peer signs announces and public messages with.
    pub signing_public_key: [u8; 32],
}

impl AuthenticatedPeerState {
    /// Encode (without the leading Noise payload type byte).
    pub fn encode(&self) -> Result<Vec<u8>> {
        let caps = self.capabilities.encoded();
        if caps.is_empty() || caps.len() > 8 {
            return Err(Error::Encode("capabilities encoding out of range"));
        }
        let mut out = Vec::with_capacity(1 + 2 + caps.len() + 2 + 32);
        out.push(VERSION);
        push_tlv(&mut out, TLV_CAPABILITIES, &caps);
        push_tlv(&mut out, TLV_SIGNING_KEY, &self.signing_public_key);
        Ok(out)
    }

    /// Decode (input starts at the version byte).
    pub fn decode(data: &[u8]) -> Result<Self> {
        if data.first() != Some(&VERSION) {
            return Err(Error::Decode("unknown peer-state version"));
        }
        let mut caps = None;
        let mut key = None;
        let mut o = 1usize;
        while o < data.len() {
            if o + 2 > data.len() {
                return Err(Error::Decode("truncated TLV header"));
            }
            let t = data[o];
            let len = data[o + 1] as usize;
            o += 2;
            if o + len > data.len() {
                return Err(Error::Decode("TLV length overruns the payload"));
            }
            let value = &data[o..o + len];
            o += len;
            match t {
                TLV_CAPABILITIES => {
                    if caps.is_some() || !PeerCapabilities::is_canonical(value) {
                        return Err(Error::Decode("duplicate or non-canonical capabilities"));
                    }
                    caps = Some(PeerCapabilities::decode(value));
                }
                TLV_SIGNING_KEY => {
                    if key.is_some() || value.len() != 32 {
                        return Err(Error::Decode("duplicate or malformed signing key"));
                    }
                    let mut k = [0u8; 32];
                    k.copy_from_slice(value);
                    key = Some(k);
                }
                _ => {}
            }
        }
        Ok(AuthenticatedPeerState {
            capabilities: caps.ok_or(Error::Decode("peer state without capabilities"))?,
            signing_public_key: key.ok_or(Error::Decode("peer state without signing key"))?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_strictness() {
        let s = AuthenticatedPeerState {
            capabilities: PeerCapabilities::PRIVATE_MEDIA,
            signing_public_key: [7u8; 32],
        };
        let b = s.encode().unwrap();
        assert_eq!(&b[..5], &[0x01, 0x01, 0x02, 0x00, 0x01]);
        assert_eq!(b[5], 0x02);
        assert_eq!(b[6], 32);
        assert_eq!(AuthenticatedPeerState::decode(&b).unwrap(), s);
        // Unknown TLV is skipped.
        let mut with_unknown = b.clone();
        with_unknown.extend_from_slice(&[0x7f, 1, 0xaa]);
        assert_eq!(AuthenticatedPeerState::decode(&with_unknown).unwrap(), s);
        // Version 2 rejected.
        let mut v2 = b.clone();
        v2[0] = 2;
        assert!(AuthenticatedPeerState::decode(&v2).is_err());
        // Non-canonical capabilities (0x100 as three bytes) rejected.
        let mut nc = vec![0x01, 0x01, 0x03, 0x00, 0x01, 0x00];
        push_tlv(&mut nc, 0x02, &[7u8; 32]);
        assert!(AuthenticatedPeerState::decode(&nc).is_err());
        // Duplicate key rejected; missing capabilities rejected.
        let mut dup = b.clone();
        dup.extend_from_slice(&b[5..]);
        assert!(AuthenticatedPeerState::decode(&dup).is_err());
        assert!(AuthenticatedPeerState::decode(&b[..5].iter().copied().chain([]).collect::<Vec<_>>()).is_err());
        assert!(AuthenticatedPeerState::decode(&[]).is_err());
    }
}
