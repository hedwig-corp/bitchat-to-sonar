//! The 8-byte mesh peer id.
//!
//! `peerID = SHA-256(noiseStaticPublicKey)[0..8]`, rendered as 16 lowercase
//! hex characters. This is not a convention but the binding that makes sender
//! ids unforgeable: announce preflight and handshake completion both require
//! the id derived from the key to equal the id on the wire.

use sha2::{Digest, Sha256};

/// Derive the 8 raw id bytes from a Noise static public key.
pub fn peer_id_bytes(noise_public_key: &[u8]) -> [u8; 8] {
    let digest = Sha256::digest(noise_public_key);
    let mut id = [0u8; 8];
    id.copy_from_slice(&digest[..8]);
    id
}

/// Derive the 16-hex-char peer id string from a Noise static public key.
pub fn peer_id_from_noise_key(noise_public_key: &[u8]) -> String {
    hex::encode(peer_id_bytes(noise_public_key))
}

/// Parse a 16-hex-char peer id (case-insensitive) into its 8 bytes.
pub fn parse_peer_id(hex_id: &str) -> Option<[u8; 8]> {
    if hex_id.len() != 16 {
        return None;
    }
    let bytes = hex::decode(hex_id).ok()?;
    let mut id = [0u8; 8];
    id.copy_from_slice(&bytes);
    Some(id)
}

/// Does `claimed` (hex) equal the id derived from `noise_public_key`?
pub fn matches_claimed_peer_id(claimed: &str, noise_public_key: &[u8]) -> bool {
    parse_peer_id(claimed).is_some_and(|c| c == peer_id_bytes(noise_public_key))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn id_is_sha256_prefix_in_lowercase_hex() {
        let key = [0x01u8; 32];
        let id = peer_id_from_noise_key(&key);
        assert_eq!(id.len(), 16);
        assert_eq!(id, hex::encode(&Sha256::digest(key)[..8]));
        assert!(matches_claimed_peer_id(&id, &key));
        assert!(matches_claimed_peer_id(&id.to_uppercase(), &key));
        assert!(!matches_claimed_peer_id(&id, &[0x02u8; 32]));
        assert!(parse_peer_id("abc").is_none());
    }
}
