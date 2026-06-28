//! MIP-05 push notification support.
//!
//! Three concerns:
//! 1. **Registration**: encrypt a device push token to the transponder's public
//!    key and cache it locally (done on app start).
//! 2. **Token sharing**: publish the encrypted token as a NIP-44 DM to each group
//!    member so they can cache it for sender-side notification.
//! 3. **Sender notification**: after every send, gift-wrap a kind-446 containing
//!    each recipient's cached encrypted token and publish to the transponder.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use nostr::prelude::*;
use nostr::secp256k1;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

const HKDF_SALT: &[u8] = b"mip05-v1";
const HKDF_INFO: &[u8] = b"mip05-token-encryption";
const TOKEN_PLAINTEXT_SIZE: usize = 1024;
const PLATFORM_APNS: u8 = 0x01;
const PLATFORM_FCM: u8 = 0x02;
pub(crate) const KIND_NOTIFICATION_REQUEST: u16 = 446;
pub(crate) const KIND_PUSH_TOKEN_SHARE: u16 = 447;

pub(crate) fn platform_byte(platform: &str) -> crate::Result<u8> {
    match platform {
        "apns" => Ok(PLATFORM_APNS),
        "fcm" => Ok(PLATFORM_FCM),
        _ => Err(crate::Error::InvalidInput(format!(
            "unknown platform: {platform} (expected \"apns\" or \"fcm\")"
        ))),
    }
}

pub(crate) fn encrypt_token(
    platform: u8,
    token: &[u8],
    server_pubkey: &PublicKey,
) -> crate::Result<Vec<u8>> {
    if token.is_empty() || token.len() > TOKEN_PLAINTEXT_SIZE - 3 {
        return Err(crate::Error::InvalidInput(format!(
            "token length {} out of range 1..={}",
            token.len(),
            TOKEN_PLAINTEXT_SIZE - 3
        )));
    }

    let mut plaintext = vec![0u8; TOKEN_PLAINTEXT_SIZE];
    plaintext[0] = platform;
    plaintext[1..3].copy_from_slice(&(token.len() as u16).to_be_bytes());
    plaintext[3..3 + token.len()].copy_from_slice(token);
    getrandom::getrandom(&mut plaintext[3 + token.len()..])?;

    let ephemeral = Keys::generate();
    let ephemeral_secret = ephemeral.secret_key();
    let ephemeral_xonly = ephemeral.public_key().to_bytes();

    let xonly = secp256k1::XOnlyPublicKey::from_slice(&server_pubkey.to_bytes())
        .map_err(|e| crate::Error::InvalidInput(format!("bad server pubkey: {e}")))?;
    let full_pk = secp256k1::PublicKey::from_x_only_public_key(xonly, secp256k1::Parity::Even);
    let eph_sk = secp256k1::SecretKey::from_slice(&ephemeral_secret.to_secret_bytes())
        .map_err(|e| crate::Error::InvalidInput(format!("ephemeral sk: {e}")))?;
    let shared_point = secp256k1::ecdh::shared_secret_point(&full_pk, &eph_sk);
    let shared_x = &shared_point[..32];

    let hkdf = ::hkdf::Hkdf::<Sha256>::new(Some(HKDF_SALT), shared_x);
    let mut key = [0u8; 32];
    hkdf.expand(HKDF_INFO, &mut key)
        .map_err(|e| crate::Error::InvalidInput(format!("hkdf expand: {e}")))?;

    let mut nonce_bytes = [0u8; 12];
    getrandom::getrandom(&mut nonce_bytes)?;
    let nonce = Nonce::from_slice(&nonce_bytes);

    let cipher = ChaCha20Poly1305::new_from_slice(&key)
        .map_err(|e| crate::Error::InvalidInput(format!("cipher init: {e}")))?;
    let ciphertext = cipher
        .encrypt(nonce, plaintext.as_ref())
        .map_err(|e| crate::Error::InvalidInput(format!("encrypt: {e}")))?;

    let mut out = Vec::with_capacity(32 + 12 + ciphertext.len());
    out.extend_from_slice(&ephemeral_xonly);
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

pub(crate) fn encode_notification_request(
    platform: u8,
    token: &[u8],
    server_pubkey: &PublicKey,
) -> crate::Result<(String, PublicKey)> {
    let blob = encrypt_token(platform, token, server_pubkey)?;
    let content = BASE64.encode(&blob);
    Ok((content, *server_pubkey))
}

/// Locally cached push token info for a specific group member.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct CachedPushToken {
    pub encrypted_token_b64: String,
    pub server_pubkey: PublicKey,
}

/// This device's own push registration, stored after `register_push_token`
/// so we can share it with group members.
#[derive(Clone, Debug)]
pub(crate) struct OwnPushRegistration {
    pub encrypted_token_b64: String,
    pub server_pubkey: PublicKey,
}

/// JSON payload sent inside NIP-44 DMs (kind 447) to share encrypted push
/// tokens with group members.
#[derive(Serialize, Deserialize)]
pub(crate) struct PushTokenSharePayload {
    pub encrypted_token: String,
    pub server_pubkey: String,
}

/// In-memory cache of group member push tokens.  Key = member pubkey hex.
pub(crate) type PushTokenCache = Arc<Mutex<HashMap<String, CachedPushToken>>>;

pub(crate) fn new_push_token_cache() -> PushTokenCache {
    Arc::new(Mutex::new(HashMap::new()))
}
