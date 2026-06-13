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
