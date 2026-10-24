//! Sonar discovery announce — payload of packet type `0x53`
//! (`SonarAnnouncePacket` on iOS, `SonarAnnounce` on Compose; spec in
//! `docs/SONAR-DISCOVERY.md`).
//!
//! Signed with the same Ed25519 key as the bitchat announce; verified against
//! the signing key learned from that announce. TLVs use a one-byte length
//! except `0x05` (BOLT12 offer), which uses a two-byte big-endian length
//! because offers exceed 255 bytes. Stock bitchat ignores the whole packet.

use crate::{Error, Result};

/// Only payload version this implementation understands.
pub const VERSION: u8 = 1;
/// Largest `0x53` payload whose signed v1 packet fits one 512-byte BLE
/// attribute (512 − 14 header − 8 sender − 64 signature). Android 13+ throws on
/// a larger notify/write and the app crash-loops.
pub const MAX_MESH_PAYLOAD_BYTES: usize = 426;

/// Capability bits (TLV 0x04).
pub mod capability {
    /// Accepts Marmot (MLS over Nostr) DMs — White Noise interop.
    pub const MARMOT_DM: u8 = 0b0000_0001;
    /// Speaks the ⚡PAY convention.
    pub const PAYMENTS: u8 = 0b0000_0010;
    /// Supports Sonar voice/video calls.
    pub const CALLS: u8 = 0b0000_0100;
}

const TLV_VERSION: u8 = 0x01;
const TLV_NPUB: u8 = 0x02;
const TLV_BIP353: u8 = 0x03;
const TLV_CAPABILITIES: u8 = 0x04;
const TLV_BOLT12_OFFER: u8 = 0x05;

/// Decoded Sonar announce.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SonarAnnounce {
    /// Payload version (1).
    pub version: u8,
    /// 32-byte x-only Nostr public key.
    pub npub: [u8; 32],
    /// Optional BIP-353 address (`user@domain`).
    pub bip353: Option<String>,
    /// Capability bitfield (see [`capability`]).
    pub capabilities: u8,
    /// Optional BOLT12 offer (Compose only; iOS never sends it).
    pub bolt12_offer: Option<String>,
}

impl SonarAnnounce {
    /// Minimal announce for an npub.
    pub fn new(npub: [u8; 32], capabilities: u8) -> Self {
        SonarAnnounce { version: VERSION, npub, bip353: None, capabilities, bolt12_offer: None }
    }

    /// Encode the TLV payload: version, npub, bip353?, capabilities, offer?.
    pub fn encode(&self) -> Result<Vec<u8>> {
        let mut out = Vec::with_capacity(48);
        out.extend_from_slice(&[TLV_VERSION, 1, self.version]);
        out.push(TLV_NPUB);
        out.push(32);
        out.extend_from_slice(&self.npub);
        if let Some(b) = self.bip353.as_deref().filter(|s| !s.is_empty()) {
            if b.len() > 255 {
                return Err(Error::Encode("bip353 over 255 bytes"));
            }
            out.push(TLV_BIP353);
            out.push(b.len() as u8);
            out.extend_from_slice(b.as_bytes());
        }
        out.extend_from_slice(&[TLV_CAPABILITIES, 1, self.capabilities]);
        if let Some(o) = self.bolt12_offer.as_deref().filter(|s| !s.is_empty()) {
            let len = u16::try_from(o.len()).map_err(|_| Error::Encode("offer over 65535 bytes"))?;
            out.push(TLV_BOLT12_OFFER);
            out.extend_from_slice(&len.to_be_bytes());
            out.extend_from_slice(o.as_bytes());
        }
        Ok(out)
    }

    /// This announce as it may go on the mesh: drops the offer when the
    /// payload would not fit one BLE attribute. Payers read the offer from
    /// the Nostr descriptor instead.
    pub fn for_mesh(&self) -> Result<SonarAnnounce> {
        if self.bolt12_offer.is_some() && self.encode()?.len() > MAX_MESH_PAYLOAD_BYTES {
            let mut c = self.clone();
            c.bolt12_offer = None;
            return Ok(c);
        }
        Ok(self.clone())
    }

    /// Decode. Skips unknown TLVs; rejects an unknown version, a missing or
    /// non-32-byte npub, a missing capabilities TLV, or an overrun.
    pub fn decode(data: &[u8]) -> Result<SonarAnnounce> {
        let mut version = None;
        let mut npub = None;
        let mut bip353 = None;
        let mut capabilities = None;
        let mut offer = None;
        let mut o = 0usize;
        while o + 2 <= data.len() {
            let t = data[o];
            let (len, start) = if t == TLV_BOLT12_OFFER {
                if o + 3 > data.len() {
                    return Err(Error::Decode("truncated offer TLV"));
                }
                (u16::from_be_bytes([data[o + 1], data[o + 2]]) as usize, o + 3)
            } else {
                (data[o + 1] as usize, o + 2)
            };
            if start + len > data.len() {
                return Err(Error::Decode("TLV length overruns the payload"));
            }
            let value = &data[start..start + len];
            o = start + len;
            match t {
                TLV_VERSION => {
                    if len != 1 {
                        return Err(Error::Decode("malformed version TLV"));
                    }
                    version = Some(value[0]);
                }
                TLV_NPUB => {
                    if len != 32 {
                        return Err(Error::Decode("npub must be 32 bytes"));
                    }
                    let mut k = [0u8; 32];
                    k.copy_from_slice(value);
                    npub = Some(k);
                }
                TLV_BIP353 => bip353 = String::from_utf8(value.to_vec()).ok().filter(|s| !s.is_empty()),
                TLV_CAPABILITIES => {
                    if len != 1 {
                        return Err(Error::Decode("malformed capabilities TLV"));
                    }
                    capabilities = Some(value[0]);
                }
                TLV_BOLT12_OFFER => offer = String::from_utf8(value.to_vec()).ok().filter(|s| !s.is_empty()),
                _ => {}
            }
        }
        let version = version.ok_or(Error::Decode("sonar announce without version"))?;
        if version != VERSION {
            return Err(Error::Decode("unsupported sonar announce version"));
        }
        Ok(SonarAnnounce {
            version,
            npub: npub.ok_or(Error::Decode("sonar announce without npub"))?,
            bip353,
            capabilities: capabilities.ok_or(Error::Decode("sonar announce without capabilities"))?,
            bolt12_offer: offer,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_and_roundtrip() {
        let mut a = SonarAnnounce::new([0x42; 32], capability::MARMOT_DM | capability::PAYMENTS);
        let b = a.encode().unwrap();
        assert_eq!(&b[..5], &[0x01, 1, 1, 0x02, 32]);
        assert_eq!(&b[37..], &[0x04, 1, 0x03]);
        assert_eq!(SonarAnnounce::decode(&b).unwrap(), a);
        a.bip353 = Some("alice@example.com".into());
        a.bolt12_offer = Some("lno1".repeat(110)); // 440 bytes
        let b = a.encode().unwrap();
        assert_eq!(SonarAnnounce::decode(&b).unwrap(), a);
        let m = a.for_mesh().unwrap();
        assert!(m.bolt12_offer.is_none());
        assert!(m.encode().unwrap().len() <= MAX_MESH_PAYLOAD_BYTES);
        let mut small = a.clone();
        small.bolt12_offer = Some("lno1short".into());
        assert_eq!(small.for_mesh().unwrap(), small);
    }

    #[test]
    fn decode_rules() {
        let b = SonarAnnounce::new([1; 32], 0).encode().unwrap();
        let mut with_unknown = b.clone();
        with_unknown.extend_from_slice(&[0x7f, 2, 1, 2]);
        assert!(SonarAnnounce::decode(&with_unknown).is_ok());
        let mut v2 = b.clone();
        v2[2] = 2;
        assert!(SonarAnnounce::decode(&v2).is_err());
        assert!(SonarAnnounce::decode(&b[..b.len() - 3]).is_err()); // no caps
        let mut short_npub = vec![0x01, 1, 1, 0x02, 31];
        short_npub.extend_from_slice(&[0u8; 31]);
        short_npub.extend_from_slice(&[0x04, 1, 0]);
        assert!(SonarAnnounce::decode(&short_npub).is_err());
        let mut overrun = b.clone();
        overrun[4] = 40;
        assert!(SonarAnnounce::decode(&overrun).is_err());
    }
}
