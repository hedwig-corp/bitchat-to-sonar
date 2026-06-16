//! Geohash public channels over Nostr (kind-20000 ephemeral events tagged
//! with `g`=geohash), wire-compatible with the bitchat/Sonar iOS app.
//!
//! Each message is signed with a per-(device, geohash) ephemeral key derived
//! from the identity secret, so the user has a stable pseudonymous identity
//! within a channel without exposing their main key. Messages carry the
//! display nickname in an `n` tag.

use nostr::hashes::{sha256, Hash};
use nostr::prelude::*;

use crate::Result;

/// Derive the stable per-geohash ephemeral signing key for this identity.
/// Deterministic: the same device uses the same key in a given geohash across
/// sessions (so "mine" detection and continuity work), but it is unlinkable to
/// the main identity key.
pub fn derive_geohash_keys(identity_secret: &[u8; 32], geohash: &str) -> Result<Keys> {
    let mut data = Vec::with_capacity(17 + 32 + geohash.len());
    data.extend_from_slice(b"sonar-geohash-v1:");
    data.extend_from_slice(identity_secret);
    data.extend_from_slice(geohash.as_bytes());
    let hash = sha256::Hash::hash(&data);
    let sk = SecretKey::from_slice(hash.as_byte_array())?;
    Ok(Keys::new(sk))
}

/// Decode a geohash to the centre (latitude, longitude) of its cell — matches
/// bitchat's `Geohash.decodeCenter`, used to route a channel to the relays
/// nearest its location. Returns `None` on an invalid character.
pub fn decode_center(geohash: &str) -> Option<(f64, f64)> {
    const BASE32: &[u8] = b"0123456789bcdefghjkmnpqrstuvwxyz";
    let (mut lat0, mut lat1) = (-90.0_f64, 90.0_f64);
    let (mut lon0, mut lon1) = (-180.0_f64, 180.0_f64);
    let mut is_lon = true; // the first bit of a geohash refines longitude
    for ch in geohash.bytes() {
        let val = BASE32.iter().position(|&b| b == ch.to_ascii_lowercase())?;
        for i in (0..5).rev() {
            let bit = (val >> i) & 1;
            if is_lon {
                let mid = (lon0 + lon1) / 2.0;
                if bit == 1 {
                    lon0 = mid
                } else {
                    lon1 = mid
                }
            } else {
                let mid = (lat0 + lat1) / 2.0;
                if bit == 1 {
                    lat0 = mid
                } else {
                    lat1 = mid
                }
            }
            is_lon = !is_lon;
        }
    }
    Some(((lat0 + lat1) / 2.0, (lon0 + lon1) / 2.0))
}

/// A decrypted (well, plaintext — geohash channels are public) channel message.
#[derive(Debug, Clone)]
pub struct GeoMessage {
    pub id: String,
    pub sender_pubkey: String,
    pub nickname: String,
    pub content: String,
    pub created_at: u64,
    pub mine: bool,
}
