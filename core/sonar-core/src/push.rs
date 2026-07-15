//! MIP-05 push notification support.
//!
//! Three concerns:
//! 1. **Registration**: encrypt a device push token to the transponder's public
//!    key and cache it locally (done on app start).
//! 2. **Token sharing**: publish the encrypted token as a NIP-44 DM to each group
//!    member so they can cache it for sender-side notification.
//! 3. **Sender notification**: after every send, gift-wrap a kind-446 containing
//!    each recipient's cached encrypted token and publish to the transponder.
//!
//! Peers may register multiple devices (e.g. iPhone + Mac under the same nsec).
//! The local cache therefore stores a small map of `device_id → token` per
//! member pubkey and sender-side notify fans out to every cached device.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use nostr::prelude::*;
use nostr::secp256k1;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

const HKDF_SALT: &[u8] = b"mip05-v1";
const HKDF_INFO: &[u8] = b"mip05-token-encryption";
const TOKEN_PLAINTEXT_SIZE: usize = 1024;
const PLATFORM_APNS: u8 = 0x01;
const PLATFORM_FCM: u8 = 0x02;
pub(crate) const PUSH_TOKEN_CACHE_FILE_SUFFIX: &str = ".sonar-push-tokens.json";
/// v1 = one token per member. v2 = multiple devices per member.
const PUSH_TOKEN_CACHE_VERSION: u32 = 2;
const PUSH_TOKEN_CACHE_VERSION_V1: u32 = 1;
/// Cap devices kept per member so token rotation / churn cannot grow forever.
pub(crate) const MAX_DEVICES_PER_MEMBER: usize = 4;
const LEGACY_DEVICE_ID: &str = "legacy";
pub(crate) const KIND_NOTIFICATION_REQUEST: u16 = 446;
pub(crate) const KIND_PUSH_TOKEN_SHARE: u16 = 447;
/// Maximum accepted length of an encrypted_token (base64) in a kind-447 share.
/// Push-token blobs are tiny; anything larger is rejected to bound cache memory.
pub(crate) const MAX_ENCRYPTED_TOKEN_B64_LEN: usize = 8192;
/// Hard cap on the number of cached per-member push tokens. Group membership is
/// bounded, so this is a defense-in-depth ceiling against a flood of shares.
pub(crate) const MAX_PUSH_TOKEN_CACHE_ENTRIES: usize = 256;

/// Whether an incoming push-token share should be cached, given the
/// encrypted_token length and the current cache size. Pure so it can be
/// unit-tested independently of engine / group state.
pub(crate) fn should_cache_push_token(
    encrypted_token_len: usize,
    cache_len: usize,
    already_cached: bool,
) -> bool {
    encrypted_token_len <= MAX_ENCRYPTED_TOKEN_B64_LEN
        && (already_cached || cache_len < MAX_PUSH_TOKEN_CACHE_ENTRIES)
}

pub(crate) fn platform_byte(platform: &str) -> crate::Result<u8> {
    match platform {
        "apns" => Ok(PLATFORM_APNS),
        "fcm" => Ok(PLATFORM_FCM),
        _ => Err(crate::Error::InvalidInput(format!(
            "unknown platform: {platform} (expected \"apns\" or \"fcm\")"
        ))),
    }
}

/// Stable-enough device key derived from the provider token bytes.
///
/// Token rotation yields a new id (old entry ages out via the per-member cap).
/// Callers that want a install-stable id can pass an explicit `device_id` in the
/// share payload instead.
pub(crate) fn device_id_from_token(platform: u8, token: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update([platform]);
    hasher.update(token);
    hex_encode(&hasher.finalize()[..16])
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn now_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
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

/// Locally cached push token info for one device of a group member.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct CachedPushToken {
    pub device_id: String,
    pub encrypted_token_b64: String,
    pub server_pubkey: PublicKey,
    #[serde(default)]
    pub updated_at: u64,
}

/// This device's own push registration, stored after `register_push_token`
/// so we can share it with group members.
#[derive(Clone, Debug)]
pub(crate) struct OwnPushRegistration {
    pub device_id: String,
    pub encrypted_token_b64: String,
    pub server_pubkey: PublicKey,
}

/// JSON payload sent inside NIP-44 DMs (kind 447) to share encrypted push
/// tokens with group members.
#[derive(Serialize, Deserialize)]
pub(crate) struct PushTokenSharePayload {
    pub encrypted_token: String,
    pub server_pubkey: String,
    /// Stable device key. Older clients omit this; receivers treat the share as
    /// a single legacy device for that member.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
}

/// Per-member device map. Key = device_id.
pub(crate) type MemberPushTokens = HashMap<String, CachedPushToken>;

/// In-memory cache of group member push tokens. Outer key = member pubkey hex.
pub(crate) type PushTokenCache = Arc<Mutex<HashMap<String, MemberPushTokens>>>;

/// Upsert one device token for a member, dropping the legacy placeholder when a
/// real device id arrives, and capping the number of devices kept.
pub(crate) fn upsert_member_device_token(
    cache: &mut HashMap<String, MemberPushTokens>,
    member_pubkey_hex: &str,
    token: CachedPushToken,
) {
    let devices = cache.entry(member_pubkey_hex.to_string()).or_default();
    if token.device_id != LEGACY_DEVICE_ID {
        devices.remove(LEGACY_DEVICE_ID);
    }
    devices.insert(token.device_id.clone(), token);
    if devices.len() <= MAX_DEVICES_PER_MEMBER {
        return;
    }
    let mut ranked: Vec<(u64, String)> = devices
        .values()
        .map(|t| (t.updated_at, t.device_id.clone()))
        .collect();
    ranked.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    let drop_count = devices.len() - MAX_DEVICES_PER_MEMBER;
    for (_, device_id) in ranked.into_iter().take(drop_count) {
        devices.remove(&device_id);
    }
}

pub(crate) fn load_push_token_cache(path: Option<&Path>) -> PushTokenCache {
    let cache = path
        .and_then(|path| fs::read(path).ok())
        .and_then(|bytes| serde_json::from_slice::<PushTokenCacheDisk>(&bytes).ok())
        .and_then(|disk| disk.into_cache().ok())
        .unwrap_or_default();
    Arc::new(Mutex::new(cache))
}

pub(crate) fn save_push_token_cache(
    path: Option<&Path>,
    cache: &HashMap<String, MemberPushTokens>,
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
    replace_push_token_cache(&tmp, path)?;
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

fn replace_push_token_cache(tmp: &Path, path: &Path) -> crate::Result<()> {
    #[cfg(windows)]
    {
        match fs::remove_file(path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return Err(crate::Error::Storage(format!(
                    "remove existing push token cache {}: {e}",
                    path.display()
                )));
            }
        }
    }

    fs::rename(tmp, path).map_err(|e| {
        crate::Error::Storage(format!("replace push token cache {}: {e}", path.display()))
    })
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct PushTokenCacheDisk {
    version: u32,
    entries: Vec<PushTokenCacheEntry>,
}

impl PushTokenCacheDisk {
    fn from_cache(cache: &HashMap<String, MemberPushTokens>) -> Self {
        let mut entries: Vec<_> = cache
            .iter()
            .flat_map(|(member_pubkey_hex, devices)| {
                devices.values().map(|token| PushTokenCacheEntry {
                    member_pubkey_hex: member_pubkey_hex.clone(),
                    device_id: token.device_id.clone(),
                    encrypted_token: token.encrypted_token_b64.clone(),
                    server_pubkey_hex: token.server_pubkey.to_hex(),
                    updated_at: token.updated_at,
                })
            })
            .collect();
        entries.sort_by(|a, b| {
            a.member_pubkey_hex
                .cmp(&b.member_pubkey_hex)
                .then_with(|| a.device_id.cmp(&b.device_id))
        });
        Self {
            version: PUSH_TOKEN_CACHE_VERSION,
            entries,
        }
    }

    fn into_cache(self) -> Result<HashMap<String, MemberPushTokens>, ()> {
        match self.version {
            PUSH_TOKEN_CACHE_VERSION | PUSH_TOKEN_CACHE_VERSION_V1 => {}
            _ => return Err(()),
        }
        let mut cache: HashMap<String, MemberPushTokens> = HashMap::new();
        for entry in self.entries {
            let server_pubkey = PublicKey::parse(&entry.server_pubkey_hex).map_err(|_| ())?;
            let device_id = if entry.device_id.is_empty() {
                // v1 rows have no device_id field (serde default "").
                LEGACY_DEVICE_ID.to_string()
            } else {
                entry.device_id
            };
            let token = CachedPushToken {
                device_id: device_id.clone(),
                encrypted_token_b64: entry.encrypted_token,
                server_pubkey,
                updated_at: entry.updated_at,
            };
            upsert_member_device_token(&mut cache, &entry.member_pubkey_hex, token);
        }
        Ok(cache)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct PushTokenCacheEntry {
    member_pubkey_hex: String,
    encrypted_token: String,
    server_pubkey_hex: String,
    #[serde(default)]
    device_id: String,
    #[serde(default)]
    updated_at: u64,
}

pub(crate) fn resolve_share_device_id(payload_device_id: Option<String>) -> String {
    match payload_device_id {
        Some(id) if !id.is_empty() => id,
        _ => LEGACY_DEVICE_ID.to_string(),
    }
}

pub(crate) fn cached_token_from_share(
    device_id: String,
    encrypted_token_b64: String,
    server_pubkey: PublicKey,
) -> CachedPushToken {
    CachedPushToken {
        device_id,
        encrypted_token_b64,
        server_pubkey,
        updated_at: now_unix_secs(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn should_cache_push_token_enforces_bounds() {
        // Healthy inputs are cached (new entry).
        assert!(should_cache_push_token(0, 0, false));
        assert!(should_cache_push_token(
            MAX_ENCRYPTED_TOKEN_B64_LEN,
            MAX_PUSH_TOKEN_CACHE_ENTRIES - 1,
            false
        ));
        // Oversized encrypted token is rejected, even for an in-place update.
        assert!(!should_cache_push_token(MAX_ENCRYPTED_TOKEN_B64_LEN + 1, 0, false));
        assert!(!should_cache_push_token(MAX_ENCRYPTED_TOKEN_B64_LEN + 1, 0, true));
        // A new entry at / over the cap is rejected (no unbounded growth).
        assert!(!should_cache_push_token(1, MAX_PUSH_TOKEN_CACHE_ENTRIES, false));
        assert!(!should_cache_push_token(1, MAX_PUSH_TOKEN_CACHE_ENTRIES + 1, false));
        // An in-place update for an already-cached member is allowed even at the
        // cap (a full cache must never pin a stale / rotated token).
        assert!(should_cache_push_token(1, MAX_PUSH_TOKEN_CACHE_ENTRIES, true));
        assert!(should_cache_push_token(1, MAX_PUSH_TOKEN_CACHE_ENTRIES + 1, true));
    }

    #[test]
    fn push_token_cache_survives_reload() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("marmot.sqlite.sonar-push-tokens.json");
        let member = Keys::generate().public_key().to_hex();
        let server = Keys::generate().public_key();
        let mut cache = HashMap::new();
        upsert_member_device_token(
            &mut cache,
            &member,
            CachedPushToken {
                device_id: "iphone".into(),
                encrypted_token_b64: "encrypted-token".to_string(),
                server_pubkey: server,
                updated_at: 10,
            },
        );

        save_push_token_cache(Some(&path), &cache).expect("cache saves");
        let loaded = load_push_token_cache(Some(&path));
        let loaded = loaded.lock().unwrap();
        let devices = loaded.get(&member).expect("member tokens reload");
        let entry = devices.get("iphone").expect("device reloads");

        assert_eq!(entry.encrypted_token_b64, "encrypted-token");
        assert_eq!(entry.server_pubkey, server);
    }

    #[test]
    fn push_token_cache_keeps_multiple_devices() {
        let member = Keys::generate().public_key().to_hex();
        let server = Keys::generate().public_key();
        let mut cache = HashMap::new();
        upsert_member_device_token(
            &mut cache,
            &member,
            CachedPushToken {
                device_id: "iphone".into(),
                encrypted_token_b64: "token-phone".into(),
                server_pubkey: server,
                updated_at: 1,
            },
        );
        upsert_member_device_token(
            &mut cache,
            &member,
            CachedPushToken {
                device_id: "mac".into(),
                encrypted_token_b64: "token-mac".into(),
                server_pubkey: server,
                updated_at: 2,
            },
        );

        let devices = cache.get(&member).expect("member");
        assert_eq!(devices.len(), 2);
        assert_eq!(
            devices.get("iphone").unwrap().encrypted_token_b64,
            "token-phone"
        );
        assert_eq!(devices.get("mac").unwrap().encrypted_token_b64, "token-mac");
    }

    #[test]
    fn push_token_cache_caps_devices_and_drops_oldest() {
        let member = Keys::generate().public_key().to_hex();
        let server = Keys::generate().public_key();
        let mut cache = HashMap::new();
        for i in 0..(MAX_DEVICES_PER_MEMBER + 2) {
            upsert_member_device_token(
                &mut cache,
                &member,
                CachedPushToken {
                    device_id: format!("device-{i}"),
                    encrypted_token_b64: format!("token-{i}"),
                    server_pubkey: server,
                    updated_at: i as u64,
                },
            );
        }
        let devices = cache.get(&member).expect("member");
        assert_eq!(devices.len(), MAX_DEVICES_PER_MEMBER);
        assert!(!devices.contains_key("device-0"));
        assert!(!devices.contains_key("device-1"));
        assert!(devices.contains_key(&format!("device-{}", MAX_DEVICES_PER_MEMBER + 1)));
    }

    #[test]
    fn real_device_id_replaces_legacy_placeholder() {
        let member = Keys::generate().public_key().to_hex();
        let server = Keys::generate().public_key();
        let mut cache = HashMap::new();
        upsert_member_device_token(
            &mut cache,
            &member,
            CachedPushToken {
                device_id: LEGACY_DEVICE_ID.into(),
                encrypted_token_b64: "old".into(),
                server_pubkey: server,
                updated_at: 1,
            },
        );
        upsert_member_device_token(
            &mut cache,
            &member,
            CachedPushToken {
                device_id: "mac".into(),
                encrypted_token_b64: "new".into(),
                server_pubkey: server,
                updated_at: 2,
            },
        );
        let devices = cache.get(&member).expect("member");
        assert_eq!(devices.len(), 1);
        assert!(devices.contains_key("mac"));
    }

    #[test]
    fn push_token_cache_loads_v1_single_token_rows() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("marmot.sqlite.sonar-push-tokens.json");
        let member = Keys::generate().public_key().to_hex();
        let server = Keys::generate().public_key();
        let v1 = serde_json::json!({
            "version": 1,
            "entries": [{
                "member_pubkey_hex": member,
                "encrypted_token": "legacy-token",
                "server_pubkey_hex": server.to_hex(),
            }]
        });
        fs::write(&path, serde_json::to_vec(&v1).unwrap()).unwrap();

        let loaded = load_push_token_cache(Some(&path));
        let loaded = loaded.lock().unwrap();
        let devices = loaded.get(&member).expect("member");
        assert_eq!(devices.len(), 1);
        let entry = devices.get(LEGACY_DEVICE_ID).expect("legacy device");
        assert_eq!(entry.encrypted_token_b64, "legacy-token");
    }

    #[test]
    fn push_token_cache_replaces_existing_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("marmot.sqlite.sonar-push-tokens.json");
        let member = Keys::generate().public_key().to_hex();
        let server = Keys::generate().public_key();
        let mut cache = HashMap::new();

        upsert_member_device_token(
            &mut cache,
            &member,
            CachedPushToken {
                device_id: "iphone".into(),
                encrypted_token_b64: "first-token".to_string(),
                server_pubkey: server,
                updated_at: 1,
            },
        );
        save_push_token_cache(Some(&path), &cache).expect("initial cache saves");

        upsert_member_device_token(
            &mut cache,
            &member,
            CachedPushToken {
                device_id: "iphone".into(),
                encrypted_token_b64: "updated-token".to_string(),
                server_pubkey: server,
                updated_at: 2,
            },
        );
        save_push_token_cache(Some(&path), &cache).expect("existing cache is replaced");

        let loaded = load_push_token_cache(Some(&path));
        let loaded = loaded.lock().unwrap();
        let entry = loaded
            .get(&member)
            .and_then(|d| d.get("iphone"))
            .expect("member token reloads");

        assert_eq!(entry.encrypted_token_b64, "updated-token");
        assert_eq!(entry.server_pubkey, server);
    }

    #[test]
    fn device_id_from_token_is_stable_for_same_input() {
        let a = device_id_from_token(PLATFORM_APNS, b"token-bytes");
        let b = device_id_from_token(PLATFORM_APNS, b"token-bytes");
        let c = device_id_from_token(PLATFORM_APNS, b"other-token");
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert_eq!(a.len(), 32);
    }
}
