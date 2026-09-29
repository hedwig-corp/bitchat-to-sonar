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
/// Durable record of which members already hold our current push token.
pub(crate) const PUSH_SHARE_LEDGER_FILE_SUFFIX: &str = ".sonar-push-shared.json";
const PUSH_SHARE_LEDGER_VERSION: u32 = 1;
/// Most token shares one pass sends. Every sync and wake ends with a pass, so
/// a large account reaches everyone within a few passes instead of one burst
/// of one gift-wrapped event per member (No Performance Regression Rule).
pub(crate) const PUSH_TOKEN_SHARE_BATCH: usize = 16;
/// Re-send an unchanged token to a member after this long, so a member who
/// lost our token (reinstall without telling us) recovers within a week.
pub(crate) const PUSH_TOKEN_RESHARE_SECS: u64 = 7 * 24 * 60 * 60;
const PUSH_TOKEN_CACHE_VERSION: u32 = 1;
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
    /// [`push_token_fingerprint`] of the plaintext registration. The encrypted
    /// token is re-randomized on every registration, so it cannot say whether
    /// the token changed; this can.
    pub fingerprint: String,
}

/// Stable id of a push registration: SHA-256 over platform, device token and
/// push server key. Equal fingerprints mean members already holding our token
/// need nothing new.
pub(crate) fn push_token_fingerprint(platform: u8, token: &[u8], server: &PublicKey) -> String {
    use sha2::Digest;
    let mut hasher = Sha256::new();
    hasher.update([platform]);
    hasher.update((token.len() as u64).to_be_bytes());
    hasher.update(token);
    hasher.update(server.to_bytes());
    hex::encode(hasher.finalize())
}

/// Who already holds our current push token, and since when. Shares are sent
/// once per member per token (plus a weekly refresh), never on every sync.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct PushShareLedger {
    version: u32,
    /// Fingerprint the `shared_at` entries were sent with.
    token_fingerprint: String,
    /// Member pubkey hex → unix seconds of the last successful share.
    shared_at: HashMap<String, u64>,
}

impl PushShareLedger {
    /// Members (in the given recency order, duplicates ignored) that should
    /// receive `fingerprint` now: never shared, shared a different token, or
    /// last shared at least [`PUSH_TOKEN_RESHARE_SECS`] ago. At most `batch`.
    pub(crate) fn due(
        &self,
        fingerprint: &str,
        members_by_recency: &[String],
        now_secs: u64,
        batch: usize,
    ) -> (Vec<String>, usize) {
        let same_token = self.token_fingerprint == fingerprint;
        let mut seen = std::collections::HashSet::new();
        let mut due = Vec::new();
        let mut total = 0usize;
        for member in members_by_recency {
            if !seen.insert(member.as_str()) {
                continue;
            }
            let fresh = same_token
                && self
                    .shared_at
                    .get(member)
                    .is_some_and(|at| now_secs < at.saturating_add(PUSH_TOKEN_RESHARE_SECS));
            if fresh {
                continue;
            }
            total += 1;
            if due.len() < batch {
                due.push(member.clone());
            }
        }
        (due, total)
    }

    /// Record a successful share of `fingerprint` to `member`. A new token
    /// starts a new ledger: nobody holds it yet.
    pub(crate) fn record(&mut self, fingerprint: &str, member: &str, now_secs: u64) {
        if self.token_fingerprint != fingerprint {
            self.token_fingerprint = fingerprint.to_string();
            self.shared_at.clear();
        }
        self.version = PUSH_SHARE_LEDGER_VERSION;
        self.shared_at.insert(member.to_string(), now_secs);
    }

    /// Forget `member`: they sent us a new token of their own (a reinstall or
    /// rotation), so they probably lost ours. The next pass shares it again.
    pub(crate) fn forget(&mut self, member: &str) -> bool {
        self.shared_at.remove(member).is_some()
    }
}

pub(crate) fn push_share_ledger_path_for_db(db_path: &Path) -> PathBuf {
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar");
    db_path.with_file_name(format!("{file_name}{PUSH_SHARE_LEDGER_FILE_SUFFIX}"))
}

/// A missing or unreadable ledger is an empty one: the only cost is one more
/// share per member, bounded by [`PUSH_TOKEN_SHARE_BATCH`] per pass.
pub(crate) fn load_push_share_ledger(path: Option<&Path>) -> PushShareLedger {
    path.and_then(|path| fs::read(path).ok())
        .and_then(|bytes| serde_json::from_slice::<PushShareLedger>(&bytes).ok())
        .filter(|ledger| ledger.version == PUSH_SHARE_LEDGER_VERSION)
        .unwrap_or_default()
}

pub(crate) fn save_push_share_ledger(path: Option<&Path>, ledger: &PushShareLedger) -> crate::Result<()> {
    let Some(path) = path else {
        return Ok(());
    };
    let bytes = serde_json::to_vec(ledger)?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, bytes).map_err(|e| {
        crate::Error::Storage(format!("write push share ledger {}: {e}", tmp.display()))
    })?;
    fs::rename(&tmp, path).map_err(|e| {
        crate::Error::Storage(format!("replace push share ledger {}: {e}", path.display()))
    })?;
    Ok(())
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
    match fs::remove_file(push_share_ledger_path_for_db(db_path)) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => {
            return Err(crate::Error::Storage(format!("remove push share ledger: {e}")));
        }
    }
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

    #[test]
    fn push_token_cache_replaces_existing_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("marmot.sqlite.sonar-push-tokens.json");
        let member = Keys::generate().public_key().to_hex();
        let server = Keys::generate().public_key();
        let mut cache = HashMap::new();

        cache.insert(
            member.clone(),
            CachedPushToken {
                encrypted_token_b64: "first-token".to_string(),
                server_pubkey: server,
            },
        );
        save_push_token_cache(Some(&path), &cache).expect("initial cache saves");

        cache.insert(
            member.clone(),
            CachedPushToken {
                encrypted_token_b64: "updated-token".to_string(),
                server_pubkey: server,
            },
        );
        save_push_token_cache(Some(&path), &cache).expect("existing cache is replaced");

        let loaded = load_push_token_cache(Some(&path));
        let loaded = loaded.lock().unwrap();
        let entry = loaded.get(&member).expect("member token reloads");

        assert_eq!(entry.encrypted_token_b64, "updated-token");
        assert_eq!(entry.server_pubkey, server);
    }

    fn members(ids: &[&str]) -> Vec<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn each_member_gets_a_token_once_until_it_changes() {
        let mut ledger = PushShareLedger::default();
        let all = members(&["a", "b", "a", "c"]);
        let (due, total) = ledger.due("t1", &all, 100, PUSH_TOKEN_SHARE_BATCH);
        assert_eq!(due, members(&["a", "b", "c"]), "a member in two groups is shared once");
        assert_eq!(total, 3);
        for m in &due {
            ledger.record("t1", m, 100);
        }
        assert!(ledger.due("t1", &all, 200, 16).0.is_empty(), "a second sync shares nothing");
        let (due, _) = ledger.due("t2", &all, 200, 16);
        assert_eq!(due.len(), 3, "a new token reaches everyone again");
        ledger.record("t2", "a", 200);
        assert!(!ledger.shared_at.contains_key("b"), "recording a new token resets the ledger");
    }

    #[test]
    fn a_pass_is_capped_and_the_rest_follow_on_later_passes() {
        let mut ledger = PushShareLedger::default();
        let all: Vec<String> = (0..40).map(|i| format!("m{i:02}")).collect();
        let mut passes = 0;
        loop {
            let (due, total) = ledger.due("t", &all, 100, PUSH_TOKEN_SHARE_BATCH);
            if due.is_empty() {
                break;
            }
            assert!(due.len() <= PUSH_TOKEN_SHARE_BATCH);
            assert_eq!(due[0], all[40 - total], "most recent members first");
            for m in &due {
                ledger.record("t", m, 100);
            }
            passes += 1;
        }
        assert_eq!(passes, 3);
    }

    #[test]
    fn an_unchanged_token_is_refreshed_weekly_or_when_a_member_resets() {
        let mut ledger = PushShareLedger::default();
        ledger.record("t", "a", 1_000);
        ledger.record("t", "b", 1_000);
        let week = PUSH_TOKEN_RESHARE_SECS;
        assert!(ledger.due("t", &members(&["a", "b"]), 1_000 + week - 1, 16).0.is_empty());
        assert_eq!(ledger.due("t", &members(&["a", "b"]), 1_000 + week, 16).0.len(), 2);
        assert!(ledger.forget("b"));
        assert_eq!(ledger.due("t", &members(&["a", "b"]), 2_000, 16).0, members(&["b"]));
    }

    #[test]
    fn the_ledger_survives_a_restart_and_is_wiped_with_the_cache() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let path = push_share_ledger_path_for_db(&db);
        let mut ledger = PushShareLedger::default();
        ledger.record("t", "a", 5);
        save_push_share_ledger(Some(&path), &ledger).unwrap();
        assert_eq!(load_push_share_ledger(Some(&path)), ledger);
        wipe_push_token_cache_for_db(&db).unwrap();
        assert_eq!(load_push_share_ledger(Some(&path)), PushShareLedger::default());
    }

    #[test]
    fn the_fingerprint_ignores_encryption_randomness_but_not_the_token() {
        let server = Keys::generate().public_key();
        let a = push_token_fingerprint(1, b"device-token", &server);
        assert_eq!(a, push_token_fingerprint(1, b"device-token", &server));
        assert_ne!(a, push_token_fingerprint(1, b"other-token", &server));
        assert_ne!(a, push_token_fingerprint(2, b"device-token", &server));
    }
}
