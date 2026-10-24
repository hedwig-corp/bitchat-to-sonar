//! Ed25519 packet signatures.
//!
//! The signed bytes are the packet in canonical form — **TTL = 0, no
//! signature, RSR flag clear, PKCS#7-padded** — exactly
//! `BitchatPacket.toBinaryDataForSigning()`. TTL is zeroed because relays
//! decrement it; RSR is cleared because relays set it. Everything else,
//! including the compressed payload bytes, is covered.
//!
//! A verifier rebuilds that preimage from the **received** payload bytes
//! ([`crate::WirePayload`]), never by compressing the payload again: DEFLATE
//! output is encoder-specific, so re-compression on a different platform
//! rejects valid packets (upstream Android fixed this in #863; upstream iOS
//! still re-encodes and therefore cannot verify a compressed payload produced
//! by a different encoder — see `SPEC.md`).

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};

use crate::packet::Packet;
use crate::{Error, Result};

/// The Ed25519 identity a device signs its mesh packets with — distinct from
/// its Noise static key. The host persists the 32-byte seed.
pub struct MeshSigner {
    key: SigningKey,
}

impl std::fmt::Debug for MeshSigner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MeshSigner")
            .field("public_key", &hex::encode(self.public_key()))
            .finish()
    }
}

impl MeshSigner {
    /// A fresh signer from the OS CSPRNG; fails loudly if it is unavailable.
    pub fn generate() -> Result<Self> {
        let mut seed = [0u8; 32];
        getrandom::getrandom(&mut seed).map_err(|_| Error::Rng)?;
        Ok(Self::from_seed(&seed))
    }

    /// Reconstruct from a persisted seed.
    pub fn from_seed(seed: &[u8; 32]) -> Self {
        MeshSigner {
            key: SigningKey::from_bytes(seed),
        }
    }

    /// The seed to persist.
    pub fn seed(&self) -> [u8; 32] {
        self.key.to_bytes()
    }

    /// The 32-byte public key carried in the announce TLV.
    pub fn public_key(&self) -> [u8; 32] {
        self.key.verifying_key().to_bytes()
    }

    /// Sign arbitrary bytes.
    pub fn sign(&self, msg: &[u8]) -> [u8; 64] {
        self.key.sign(msg).to_bytes()
    }
}

/// The canonical bytes a packet signature covers.
pub fn signing_preimage(packet: &Packet) -> Result<Vec<u8>> {
    let mut canon = packet.clone();
    canon.ttl = 0;
    canon.signature = None;
    canon.is_rsr = false;
    canon.encode()
}

/// Sign `packet` in place with `signer`.
pub fn sign_packet(packet: &mut Packet, signer: &MeshSigner) -> Result<()> {
    let preimage = signing_preimage(packet)?;
    packet.signature = Some(signer.sign(&preimage));
    Ok(())
}

/// Verify a packet's signature against a 32-byte Ed25519 public key. False
/// when unsigned, unencodable, malformed or invalid.
pub fn verify_packet(packet: &Packet, signing_public_key: &[u8]) -> bool {
    let Some(sig) = packet.signature else {
        return false;
    };
    let Ok(preimage) = signing_preimage(packet) else {
        return false;
    };
    ed25519_verify(signing_public_key, &preimage, &sig)
}

/// Raw Ed25519 verify. Non-strict (cofactorless) like CryptoKit's
/// `isValidSignature` and the JVM implementation upstream Android uses.
pub fn ed25519_verify(public_key: &[u8], msg: &[u8], signature: &[u8]) -> bool {
    let Ok(pk) = <[u8; 32]>::try_from(public_key) else {
        return false;
    };
    let Ok(sig) = <[u8; 64]>::try_from(signature) else {
        return false;
    };
    let Ok(vk) = VerifyingKey::from_bytes(&pk) else {
        return false;
    };
    vk.verify(msg, &Signature::from_bytes(&sig)).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::msg_type;

    fn signer() -> MeshSigner {
        MeshSigner::from_seed(&[7u8; 32])
    }

    #[test]
    fn sign_verify_roundtrip_and_ttl_rsr_mutation_survive() {
        let mut p = Packet::new(msg_type::MESSAGE, 7, 1234, [1; 8]).with_payload(b"hello".to_vec());
        sign_packet(&mut p, &signer()).unwrap();
        assert!(verify_packet(&p, &signer().public_key()));
        let mut relayed = Packet::decode(&p.encode().unwrap()).unwrap();
        relayed.ttl = 3;
        relayed.is_rsr = true;
        assert!(verify_packet(&relayed, &signer().public_key()));
        relayed.payload[0] ^= 1;
        assert!(!verify_packet(&relayed, &signer().public_key()));
        assert!(!verify_packet(&p, &MeshSigner::from_seed(&[8u8; 32]).public_key()));
        p.signature = None;
        assert!(!verify_packet(&p, &signer().public_key()));
    }

    #[test]
    fn compressed_payload_verifies_from_wire_bytes_not_a_recompression() {
        let text = b"compress-me".repeat(40);
        let mut p = Packet::new(msg_type::MESSAGE, 7, 1234, [1; 8]).with_payload(text);
        sign_packet(&mut p, &signer()).unwrap();
        let wire = p.encode().unwrap();
        let mut d = Packet::decode(&wire).unwrap();
        assert!(d.wire_payload.as_ref().unwrap().compressed);
        assert!(verify_packet(&d, &signer().public_key()));
        // Simulate a foreign encoder: swap the wire bytes for a different but
        // valid deflate stream of the same payload. The signature was made
        // over the ORIGINAL stream, so verification must now fail — which is
        // exactly why verifiers must keep the received bytes.
        let other = {
            let mut e = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::best());
            std::io::Write::write_all(&mut e, &d.payload).unwrap();
            e.finish().unwrap()
        };
        if other != d.wire_payload.as_ref().unwrap().bytes {
            d.wire_payload.as_mut().unwrap().bytes = other;
            assert!(!verify_packet(&d, &signer().public_key()));
        }
    }

    #[test]
    fn seed_roundtrip_and_malformed_inputs() {
        let s = signer();
        assert_eq!(MeshSigner::from_seed(&s.seed()).public_key(), s.public_key());
        assert!(!ed25519_verify(&[0u8; 31], b"x", &[0u8; 64]));
        assert!(!ed25519_verify(&s.public_key(), b"x", &[0u8; 63]));
        assert!(!ed25519_verify(&s.public_key(), b"x", &[0u8; 64]));
        assert!(MeshSigner::generate().is_ok());
    }
}
