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
use std::fs;
use std::path::{Path, PathBuf};
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
pub(crate) const PUSH_TOKEN_CACHE_FILE_SUFFIX: &str = ".sonar-push-tokens.json";
const PUSH_TOKEN_CACHE_VERSION: u32 = 1;
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

pub(crate) fn load_push_token_cache(path: Option<&Path>) -> PushTokenCache {
    let cache = path
        .and_then(|path| fs::read(path).ok())
        .and_then(|bytes| serde_json::from_slice::<PushTokenCacheDisk>(&bytes).ok())
        .filter(|disk| disk.version == PUSH_TOKEN_CACHE_VERSION)
        .map(PushTokenCacheDisk::into_cache)
        .unwrap_or_default();
    Arc::new(Mutex::new(cache))
}

pub(crate) fn save_push_token_cache(
    path: Option<&Path>,
    cache: &HashMap<String, CachedPushToken>,
) -> crate::Result<()> {
    let Some(path) = path else {
        return Ok(());
    };
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| {
            crate::Error::Storage(format!(
                "create push-token-cache dir {}: {e}",
                parent.display()
            ))
        })?;
    }
    let disk = PushTokenCacheDisk::from_cache(cache);
    let bytes = serde_json::to_vec(&disk)?;
    let tmp = push_token_cache_tmp_path(path);
    fs::write(&tmp, bytes).map_err(|e| {
        crate::Error::Storage(format!("write push token cache {}: {e}", tmp.display()))
    })?;
    fs::rename(&tmp, path).map_err(|e| {
        crate::Error::Storage(format!("replace push token cache {}: {e}", path.display()))
    })?;
    Ok(())
}

pub(crate) fn push_token_cache_path_for_db(db_path: &Path) -> PathBuf {
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-push-tokens.json");
    db_path.with_file_name(format!("{file_name}{PUSH_TOKEN_CACHE_FILE_SUFFIX}"))
}

pub(crate) fn wipe_push_token_cache_for_db(db_path: &Path) -> crate::Result<()> {
    let path = push_token_cache_path_for_db(db_path);
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(crate::Error::Storage(format!(
            "remove push token cache {}: {e}",
            path.display()
        ))),
    }
}

fn push_token_cache_tmp_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-push-tokens.json");
    path.with_file_name(format!("{file_name}.tmp"))
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct PushTokenCacheDisk {
    version: u32,
    entries: Vec<PushTokenCacheEntry>,
}

impl PushTokenCacheDisk {
    fn from_cache(cache: &HashMap<String, CachedPushToken>) -> Self {
        let mut entries: Vec<_> = cache
            .iter()
            .map(|(member_pubkey_hex, token)| PushTokenCacheEntry {
                member_pubkey_hex: member_pubkey_hex.clone(),
                encrypted_token: token.encrypted_token_b64.clone(),
                server_pubkey_hex: token.server_pubkey.to_hex(),
            })
            .collect();
        entries.sort_by(|a, b| a.member_pubkey_hex.cmp(&b.member_pubkey_hex));
        Self {
            version: PUSH_TOKEN_CACHE_VERSION,
            entries,
        }
    }

    fn into_cache(self) -> HashMap<String, CachedPushToken> {
        self.entries
            .into_iter()
            .filter_map(|entry| {
                let server_pubkey = PublicKey::parse(&entry.server_pubkey_hex).ok()?;
                Some((
                    entry.member_pubkey_hex,
                    CachedPushToken {
                        encrypted_token_b64: entry.encrypted_token,
                        server_pubkey,
                    },
                ))
            })
            .collect()
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct PushTokenCacheEntry {
    member_pubkey_hex: String,
    encrypted_token: String,
    server_pubkey_hex: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_token_cache_survives_reload() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("marmot.sqlite.sonar-push-tokens.json");
        let member = Keys::generate().public_key().to_hex();
        let server = Keys::generate().public_key();
        let mut cache = HashMap::new();
        cache.insert(
            member.clone(),
            CachedPushToken {
                encrypted_token_b64: "encrypted-token".to_string(),
                server_pubkey: server,
            },
        );

        save_push_token_cache(Some(&path), &cache).expect("cache saves");
        let loaded = load_push_token_cache(Some(&path));
        let loaded = loaded.lock().unwrap();
        let entry = loaded.get(&member).expect("member token reloads");

        assert_eq!(entry.encrypted_token_b64, "encrypted-token");
        assert_eq!(entry.server_pubkey, server);
    }
}
