//! Signal-style encrypted account backup (Marmot DB + SQLCipher key) on Blossom.
//!
//! The live SQLCipher `db_key` stays host-owned and random. This module only
//! wraps that key + DB bytes with a domain-separated key derived from the
//! account nsec so delete→reinstall→paste nsec can restore Marmot history.
//!
//! Blossom sees ciphertext only (`application/vnd.sonar.account-backup-v1`).

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use ::hkdf::Hkdf;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use nostr::hashes::sha256::Hash as Sha256Hash;
use nostr::hashes::Hash;
use nostr::prelude::*;
use nostr_blossom::prelude::*;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::conversation_index::index_db_path_for_db;
use crate::{Error, Result};

const MAGIC: &[u8; 8] = b"SONARBAK";
const FORMAT_VERSION: u32 = 1;
const HKDF_SALT: &[u8] = b"sonar-backup";
const HKDF_INFO: &[u8] = b"sonar-account-backup-v1";
const NONCE_LEN: usize = 12;
/// Distinct MIME so the BUD-03 listing can pick account backups among media.
pub const ACCOUNT_BACKUP_MIME: &str = "application/vnd.sonar.account-backup-v1";
/// Same fallback host as media uploads — referenced, not copied. The previous
/// hand-copied duplicate silently drifted when #360 moved media to Hedwig
/// Blossom, leaving account backups (recovery data) on a third-party public
/// host while media went to our own.
use crate::client::DEFAULT_BLOSSOM_SERVER;

/// Hosts that older builds uploaded account backups to, tried on restore after
/// the current default yields nothing.
///
/// Media does not need this — a message carries the blob's absolute URL, so
/// `fetch_media` reaches any prior host directly. A backup has no stored URL:
/// restore finds it by LISTING one host, so moving the default would otherwise
/// orphan every backup already sitting on the old one.
const LEGACY_BACKUP_BLOSSOM_SERVERS: &[&str] = &["https://nostr.download"];
/// Soft ceiling for a downloaded backup (DB + index). Far above typical chats;
/// guards memory against a malicious Blossom response.
const MAX_BACKUP_BYTES: usize = 200 * 1024 * 1024;
/// Buffer hint for a backup download. Deliberately small and independent of
/// anything the server says — see `download_blob_capped_to`.
const INITIAL_DOWNLOAD_CAPACITY: usize = 1024 * 1024;
/// Prefix for dry-run scratch dirs, so a leftover can be recognised and reaped.
const PREVIEW_SCRATCH_PREFIX: &str = ".sonar-backup-preview-";
/// Sidecar next to the Marmot DB: `{db_filename}.sonar-backup-policy.json`.
const BACKUP_POLICY_SUFFIX: &str = ".sonar-backup-policy.json";
/// Default opportunistic debounce after a dirty mark (30 minutes).
pub const DEFAULT_OPPORTUNISTIC_DEBOUNCE_SECS: u64 = 30 * 60;
/// Default daily floor when the account is quiet (24 hours).
pub const DEFAULT_DAILY_INTERVAL_SECS: u64 = 24 * 60 * 60;
const MAX_POLICY_ERROR_CHARS: usize = 240;

/// Core-owned auto-backup policy (Approach B). Hosts only execute when due.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BackupPolicy {
    /// On-by-default for new installs (missing sidecar ⇒ default).
    pub enabled: bool,
    /// Set when local transcript/index changes; cleared on successful upload
    /// only when no newer dirty mark arrived after the seal attempt.
    pub dirty: bool,
    /// Wall time of the latest dirty mark (bumped on every mark, even if already dirty).
    #[serde(default)]
    pub last_dirty_at: Option<u64>,
    /// Monotonic dirty counter — bumped on every mark so same-second remakes
    /// during upload are not cleared by [`record_backup_success`].
    #[serde(default)]
    pub dirty_seq: u64,
    /// `dirty_seq` snapshotted by [`record_backup_attempt`]; success clears dirty
    /// only when `dirty_seq` still equals this value.
    #[serde(default)]
    pub attempt_dirty_seq: Option<u64>,
    pub last_success_at: Option<u64>,
    pub last_attempt_at: Option<u64>,
    pub last_error: Option<String>,
    pub opportunistic_debounce_secs: u64,
    pub daily_interval_secs: u64,
    /// Sealed size of the last successful upload, for the Settings stats strip.
    /// `None` until one succeeds — hosts must render "—", never a guess.
    #[serde(default)]
    pub last_size_bytes: Option<u64>,
    /// Messages covered by that upload, read from the conversation index at
    /// success time rather than recounted later (the DB moves on).
    #[serde(default)]
    pub last_message_count: Option<u64>,
}

/// The three cadences the Settings UI offers, mapped onto policy fields.
///
/// `Manual` is `enabled = false`: the executors already refuse to run when the
/// policy is disabled, so "manual only" needs no separate flag — one source of
/// truth for "will something upload without me asking".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackupFrequency {
    Manual,
    Daily,
    Weekly,
}

impl BackupFrequency {
    pub fn interval_secs(self) -> u64 {
        match self {
            // Kept at the daily floor so flipping Manual -> Daily later does not
            // inherit a stale week-long interval.
            BackupFrequency::Manual | BackupFrequency::Daily => DEFAULT_DAILY_INTERVAL_SECS,
            BackupFrequency::Weekly => 7 * DEFAULT_DAILY_INTERVAL_SECS,
        }
    }

    pub fn from_policy(policy: &BackupPolicy) -> Self {
        if !policy.enabled {
            return BackupFrequency::Manual;
        }
        if policy.daily_interval_secs > DEFAULT_DAILY_INTERVAL_SECS {
            BackupFrequency::Weekly
        } else {
            BackupFrequency::Daily
        }
    }
}

impl Default for BackupPolicy {
    fn default() -> Self {
        Self {
            enabled: true,
            dirty: false,
            last_dirty_at: None,
            dirty_seq: 0,
            attempt_dirty_seq: None,
            last_success_at: None,
            last_attempt_at: None,
            last_error: None,
            opportunistic_debounce_secs: DEFAULT_OPPORTUNISTIC_DEBOUNCE_SECS,
            daily_interval_secs: DEFAULT_DAILY_INTERVAL_SECS,
            last_size_bytes: None,
            last_message_count: None,
        }
    }
}

/// Serializes policy RMW and holds an in-process cache so the message hot path
/// can skip disk reads/writes once `dirty` is already set (and at most one
/// remake bump while a seal/upload is in flight).
static POLICY_STATE: LazyLock<Mutex<HashMap<String, BackupPolicy>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn policy_cache_key(db_path: &Path) -> String {
    backup_policy_path_for_db(db_path)
        .to_string_lossy()
        .into_owned()
}

fn with_policy_state<R>(f: impl FnOnce(&mut HashMap<String, BackupPolicy>) -> R) -> R {
    let mut guard = POLICY_STATE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    f(&mut guard)
}

fn cached_policy(map: &mut HashMap<String, BackupPolicy>, db_path: &Path) -> BackupPolicy {
    let key = policy_cache_key(db_path);
    if let Some(p) = map.get(&key) {
        return p.clone();
    }
    let p = load_backup_policy_from_disk(db_path);
    map.insert(key, p.clone());
    p
}

fn store_policy(
    map: &mut HashMap<String, BackupPolicy>,
    db_path: &Path,
    policy: &BackupPolicy,
) -> Result<()> {
    save_backup_policy_to_disk(db_path, policy)?;
    map.insert(policy_cache_key(db_path), policy.clone());
    Ok(())
}

/// Path of the durable policy sidecar for `db_path`.
pub fn backup_policy_path_for_db(db_path: &Path) -> PathBuf {
    let name = db_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("marmot.sqlite");
    db_path.with_file_name(format!("{name}{BACKUP_POLICY_SUFFIX}"))
}

/// Load policy (cache-aware). Missing file ⇒ on-by-default. Corrupt file ⇒
/// fail closed (`enabled: false`) and persist that so opt-out survives.
pub fn load_backup_policy(db_path: &Path) -> BackupPolicy {
    with_policy_state(|map| cached_policy(map, db_path))
}

fn load_backup_policy_from_disk(db_path: &Path) -> BackupPolicy {
    let path = backup_policy_path_for_db(db_path);
    let Ok(bytes) = fs::read(&path) else {
        return BackupPolicy::default();
    };
    match serde_json::from_slice::<BackupPolicy>(&bytes) {
        Ok(mut p) => {
            if p.opportunistic_debounce_secs == 0 {
                p.opportunistic_debounce_secs = DEFAULT_OPPORTUNISTIC_DEBOUNCE_SECS;
            }
            if p.daily_interval_secs == 0 {
                p.daily_interval_secs = DEFAULT_DAILY_INTERVAL_SECS;
            }
            // Stale in-flight marker from a crashed process — clear so the
            // hot path does not fsync on every message after restart.
            p.attempt_dirty_seq = None;
            p
        }
        Err(e) => {
            tracing::warn!(
                %e,
                path = %path.display(),
                "backup policy corrupt; fail-closed (disabled)"
            );
            let mut p = BackupPolicy::default();
            p.enabled = false;
            p.last_error = Some("backup policy corrupt".into());
            let _ = save_backup_policy_to_disk(db_path, &p);
            p
        }
    }
}

/// Persist policy atomically (unique tmp + fsync + rename) and refresh cache.
pub fn save_backup_policy(db_path: &Path, policy: &BackupPolicy) -> Result<()> {
    with_policy_state(|map| store_policy(map, db_path, policy))
}

fn save_backup_policy_to_disk(db_path: &Path, policy: &BackupPolicy) -> Result<()> {
    let path = backup_policy_path_for_db(db_path);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| {
            Error::InvalidInput(format!("backup policy mkdir {}: {e}", parent.display()))
        })?;
    }
    let bytes = serde_json::to_vec_pretty(policy)
        .map_err(|e| Error::InvalidInput(format!("backup policy encode: {e}")))?;
    let tmp = path.with_file_name(format!(
        "{}.{}.{}.tmp",
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("sonar-backup-policy.json"),
        std::process::id(),
        now_unix_secs()
    ));
    {
        let mut f = File::create(&tmp).map_err(|e| {
            Error::InvalidInput(format!("backup policy create {}: {e}", tmp.display()))
        })?;
        f.write_all(&bytes).map_err(|e| {
            Error::InvalidInput(format!("backup policy write {}: {e}", tmp.display()))
        })?;
        f.sync_all().map_err(|e| {
            Error::InvalidInput(format!("backup policy fsync {}: {e}", tmp.display()))
        })?;
    }
    fs::rename(&tmp, &path).map_err(|e| {
        Error::InvalidInput(format!("backup policy rename {}: {e}", path.display()))
    })?;
    if let Some(parent) = path.parent() {
        if let Ok(dir) = File::open(parent) {
            let _ = dir.sync_all();
        }
    }
    Ok(())
}

/// Mark the account dirty so an opportunistic backup becomes due after debounce.
///
/// Hot path: once dirty and not in flight, update only the in-memory cache
/// (no disk I/O). During an in-flight attempt, bump `dirty_seq` at most once
/// so [`record_backup_success`] keeps coverage for post-seal messages.
pub fn mark_backup_dirty(db_path: &Path) {
    with_policy_state(|map| {
        let mut policy = cached_policy(map, db_path);
        let in_flight = policy.attempt_dirty_seq.is_some();
        if policy.dirty && !in_flight {
            return;
        }
        if policy.dirty && in_flight {
            if let Some(attempt_seq) = policy.attempt_dirty_seq {
                if policy.dirty_seq > attempt_seq {
                    // Already remade once for this attempt — memory only.
                    return;
                }
            }
        }
        let now = now_unix_secs();
        policy.dirty = true;
        policy.last_dirty_at = Some(now);
        policy.dirty_seq = policy.dirty_seq.saturating_add(1);
        if let Err(e) = store_policy(map, db_path, &policy) {
            tracing::warn!(%e, "mark_backup_dirty failed");
        }
    });
}

pub fn set_backup_enabled(db_path: &Path, enabled: bool) -> Result<()> {
    with_policy_state(|map| {
        let mut policy = cached_policy(map, db_path);
        policy.enabled = enabled;
        store_policy(map, db_path, &policy)
    })
}

/// Persist the on-by-default policy only when the sidecar is missing. Never
/// overwrites an existing (including fail-closed corrupt) file.
pub fn ensure_backup_policy_default(db_path: &Path) -> Result<()> {
    with_policy_state(|map| {
        let path = backup_policy_path_for_db(db_path);
        if path.exists() {
            let _ = cached_policy(map, db_path);
            return Ok(());
        }
        store_policy(map, db_path, &BackupPolicy::default())
    })
}

/// Whether a host should run a backup now (enabled + opportunistic or daily floor).
pub fn backup_is_due(policy: &BackupPolicy, now_secs: u64) -> bool {
    if !policy.enabled {
        return false;
    }
    let last_ok = policy.last_success_at.unwrap_or(0);
    let last_attempt = policy.last_attempt_at.unwrap_or(0);
    // Don't thrash: wait at least debounce since last attempt even on failure.
    if last_attempt > 0
        && now_secs.saturating_sub(last_attempt) < policy.opportunistic_debounce_secs
    {
        return false;
    }
    if policy.dirty
        && now_secs.saturating_sub(last_ok.max(last_attempt)) >= policy.opportunistic_debounce_secs
    {
        return true;
    }
    // Daily floor even when quiet (not dirty): keep a recent archive for reinstall.
    if now_secs.saturating_sub(last_ok) >= policy.daily_interval_secs {
        return true;
    }
    false
}

pub fn backup_is_due_now(db_path: &Path) -> bool {
    backup_is_due(&load_backup_policy(db_path), now_unix_secs())
}

/// Stamp `last_attempt_at` before seal/upload so overlapping host executors see
/// `backup_is_due == false` during the in-flight window (debounce). Snapshots
/// `dirty_seq` so success can detect remakes that arrived after seal started.
pub fn record_backup_attempt(db_path: &Path) -> Result<()> {
    with_policy_state(|map| {
        let now = now_unix_secs();
        let mut policy = cached_policy(map, db_path);
        policy.last_attempt_at = Some(now);
        policy.attempt_dirty_seq = Some(policy.dirty_seq);
        store_policy(map, db_path, &policy)
    })
}

pub fn record_backup_success(
    db_path: &Path,
    size_bytes: Option<u64>,
    db_key_hex: Option<&str>,
) -> Result<()> {
    // Count at success time, not on read: the Settings strip describes what the
    // uploaded blob contains, and the live index moves on the moment a message
    // arrives. Best-effort — a missing count renders as "—", never as zero.
    // The key comes from the caller: hosts hold it in Keychain/Keystore, and a
    // persisted copy on disk is exactly what SQLCipher exists to prevent.
    let message_count = db_key_hex.and_then(|key| count_indexed_messages(db_path, key));
    // Heal installs that ran the withdrawn `remember_index_key`: that sidecar
    // was the raw key in plaintext beside the DB it unlocks.
    let _ = fs::remove_file(index_key_path_for_db(db_path));
    with_policy_state(|map| {
        let now = now_unix_secs();
        let mut policy = cached_policy(map, db_path);
        // Messages that arrived after seal started must keep dirty=true so the
        // next opportunistic backup still covers them.
        if policy.attempt_dirty_seq == Some(policy.dirty_seq) {
            policy.dirty = false;
        }
        policy.last_success_at = Some(now);
        policy.last_attempt_at = Some(now);
        policy.last_error = None;
        policy.attempt_dirty_seq = None;
        if size_bytes.is_some() {
            policy.last_size_bytes = size_bytes;
        }
        if message_count.is_some() {
            policy.last_message_count = message_count;
        }
        store_policy(map, db_path, &policy)
    })
}

/// Total messages across every conversation in the local index.
fn count_indexed_messages(db_path: &Path, db_key_hex: &str) -> Option<u64> {
    let key: [u8; 32] = hex::decode(db_key_hex).ok()?.try_into().ok()?;
    let index = crate::conversation_index::ConversationIndex::open(
        &crate::conversation_index::index_db_path_for_db(db_path),
        key,
    )
    .ok()?;
    let summaries = index.summaries_ordered().ok()?;
    Some(summaries.iter().map(|s| s.message_count).sum())
}

/// Wipe hook: remove a plaintext key sidecar left by builds that briefly wrote
/// one. The Account Key Durability Rule requires wipe to clear every location
/// that can hold key material.
pub fn wipe_index_key_sidecar_for_db(db_path: &Path) {
    let _ = fs::remove_file(index_key_path_for_db(db_path));
}

/// Path of the WITHDRAWN plaintext key sidecar. Kept only so record-success and
/// wipe can delete a copy left by builds that briefly wrote it — persisting the
/// SQLCipher key beside the DB defeats the encryption it belongs to.
fn index_key_path_for_db(db_path: &Path) -> PathBuf {
    let name = db_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "marmot.sqlite".to_string());
    db_path.with_file_name(format!("{name}.sonar-index-key"))
}

/// On-disk footprint of this account: the encrypted DB, its index, every
/// sidecar, staged media and the sticker cache. Logs are excluded — they are
/// diagnostics, not the user's data, and showing them would inflate the number
/// the Settings row promises is "your chats".
pub fn account_storage_bytes(db_path: &Path) -> u64 {
    let Some(dir) = db_path.parent() else {
        return file_len(db_path);
    };
    dir_size_excluding(dir, &["logs"])
}

fn file_len(path: &Path) -> u64 {
    fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

fn dir_size_excluding(dir: &Path, skip: &[&str]) -> u64 {
    let Ok(entries) = fs::read_dir(dir) else {
        return 0;
    };
    let mut total = 0u64;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if skip.iter().any(|s| *s == name) {
            continue;
        }
        match entry.file_type() {
            Ok(t) if t.is_dir() => {
                total = total.saturating_add(dir_size_excluding(&entry.path(), skip))
            }
            Ok(t) if t.is_file() => {
                total = total.saturating_add(entry.metadata().map(|m| m.len()).unwrap_or(0))
            }
            _ => {}
        }
    }
    total
}

/// Apply a Settings cadence choice to the policy.
pub fn set_backup_frequency(db_path: &Path, frequency: BackupFrequency) -> Result<()> {
    with_policy_state(|map| {
        let mut policy = cached_policy(map, db_path);
        policy.enabled = frequency != BackupFrequency::Manual;
        policy.daily_interval_secs = frequency.interval_secs();
        store_policy(map, db_path, &policy)
    })
}

pub fn record_backup_failure(db_path: &Path, err: &str) -> Result<()> {
    with_policy_state(|map| {
        let now = now_unix_secs();
        let mut policy = cached_policy(map, db_path);
        policy.last_attempt_at = Some(now);
        let truncated: String = err.chars().take(MAX_POLICY_ERROR_CHARS).collect();
        policy.last_error = Some(truncated);
        // End in-flight window so the message hot path stops bumping dirty_seq.
        // Keep dirty so opportunistic retry remains due after debounce.
        policy.attempt_dirty_seq = None;
        store_policy(map, db_path, &policy)
    })
}

fn now_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Best-effort wipe of the policy sidecar (panic wipe / account reset).
pub fn wipe_backup_policy_for_db(db_path: &Path) {
    // An erase must also drop any in-flight restore. Leaving staging plus its
    // intent marker behind would let the next boot's reconcile promote the
    // backup over the account the user just erased.
    abort_staged_account_restore(db_path);
    with_policy_state(|map| {
        map.remove(&policy_cache_key(db_path));
    });
    let path = backup_policy_path_for_db(db_path);
    if let Err(e) = fs::remove_file(&path) {
        if e.kind() != std::io::ErrorKind::NotFound {
            tracing::warn!(%e, path = %path.display(), "wipe backup policy failed");
        }
    }
}

/// Plaintext package before AEAD wrap.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountBackupPackage {
    pub db_key_hex: String,
    pub db_bytes: Vec<u8>,
    pub index_bytes: Option<Vec<u8>>,
}

/// Result of uploading a sealed backup to Blossom.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountBackupUpload {
    pub url: String,
    pub sha256_hex: String,
    pub size: u64,
}

fn secret_bytes(keys: &Keys) -> [u8; 32] {
    keys.secret_key().to_secret_bytes()
}

fn derive_wrapping_key(nsec_secret: &[u8; 32]) -> Result<[u8; 32]> {
    let hkdf = Hkdf::<Sha256>::new(Some(HKDF_SALT), nsec_secret);
    let mut key = [0u8; 32];
    hkdf.expand(HKDF_INFO, &mut key)
        .map_err(|e| Error::InvalidInput(format!("backup hkdf: {e}")))?;
    Ok(key)
}

fn encode_plaintext(package: &AccountBackupPackage) -> Result<Vec<u8>> {
    if package.db_key_hex.len() != 64 || hex::decode(&package.db_key_hex).is_err() {
        return Err(Error::InvalidInput(
            "db_key_hex must be 64 hex chars".into(),
        ));
    }
    if package.db_bytes.is_empty() {
        return Err(Error::InvalidInput("db_bytes is empty".into()));
    }
    let key_bytes = package.db_key_hex.as_bytes();
    let index = package.index_bytes.as_deref().unwrap_or(&[]);
    let mut out = Vec::with_capacity(
        8 + 4 + 4 + key_bytes.len() + 8 + package.db_bytes.len() + 8 + index.len(),
    );
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
    out.extend_from_slice(&(key_bytes.len() as u32).to_le_bytes());
    out.extend_from_slice(key_bytes);
    out.extend_from_slice(&(package.db_bytes.len() as u64).to_le_bytes());
    out.extend_from_slice(&package.db_bytes);
    out.extend_from_slice(&(index.len() as u64).to_le_bytes());
    out.extend_from_slice(index);
    Ok(out)
}

fn decode_plaintext(bytes: &[u8]) -> Result<AccountBackupPackage> {
    if bytes.len() < 8 + 4 + 4 + 64 + 8 + 1 + 8 {
        return Err(Error::InvalidInput("backup plaintext too short".into()));
    }
    if &bytes[0..8] != MAGIC {
        return Err(Error::InvalidInput("bad backup magic".into()));
    }
    let version = u32::from_le_bytes(bytes[8..12].try_into().unwrap());
    if version != FORMAT_VERSION {
        return Err(Error::InvalidInput(format!(
            "unsupported backup version {version}"
        )));
    }
    let mut off = 12;
    let key_len = u32::from_le_bytes(bytes[off..off + 4].try_into().unwrap()) as usize;
    off += 4;
    if key_len != 64 || off + key_len > bytes.len() {
        return Err(Error::InvalidInput("bad db_key length in backup".into()));
    }
    let db_key_hex = std::str::from_utf8(&bytes[off..off + key_len])
        .map_err(|e| Error::InvalidInput(format!("db_key utf8: {e}")))?
        .to_string();
    validate_db_key_hex(&db_key_hex)?;
    off += key_len;
    if off + 8 > bytes.len() {
        return Err(Error::InvalidInput("truncated backup db length".into()));
    }
    let db_len = u64::from_le_bytes(bytes[off..off + 8].try_into().unwrap()) as usize;
    off += 8;
    if db_len == 0 || off + db_len > bytes.len() {
        return Err(Error::InvalidInput("bad db payload in backup".into()));
    }
    let db_bytes = bytes[off..off + db_len].to_vec();
    off += db_len;
    if off + 8 > bytes.len() {
        return Err(Error::InvalidInput("truncated backup index length".into()));
    }
    let index_len = u64::from_le_bytes(bytes[off..off + 8].try_into().unwrap()) as usize;
    off += 8;
    if off + index_len != bytes.len() {
        return Err(Error::InvalidInput("backup trailing bytes mismatch".into()));
    }
    let index_bytes = if index_len == 0 {
        None
    } else {
        Some(bytes[off..].to_vec())
    };
    Ok(AccountBackupPackage {
        db_key_hex,
        db_bytes,
        index_bytes,
    })
}

/// AEAD-seal a package with a key derived from the account secret.
pub fn seal_account_backup(
    nsec_secret: &[u8; 32],
    package: &AccountBackupPackage,
) -> Result<Vec<u8>> {
    let key = derive_wrapping_key(nsec_secret)?;
    let plaintext = encode_plaintext(package)?;
    let mut nonce_bytes = [0u8; NONCE_LEN];
    getrandom::getrandom(&mut nonce_bytes)
        .map_err(|e| Error::InvalidInput(format!("nonce: {e}")))?;
    let cipher = ChaCha20Poly1305::new_from_slice(&key)
        .map_err(|e| Error::InvalidInput(format!("cipher key: {e}")))?;
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, plaintext.as_ref())
        .map_err(|e| Error::InvalidInput(format!("encrypt backup: {e}")))?;
    let mut out = Vec::with_capacity(NONCE_LEN + ciphertext.len());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

/// Open a sealed backup with the account secret.
pub fn open_account_backup(nsec_secret: &[u8; 32], sealed: &[u8]) -> Result<AccountBackupPackage> {
    if sealed.len() <= NONCE_LEN {
        return Err(Error::InvalidInput("sealed backup too short".into()));
    }
    let key = derive_wrapping_key(nsec_secret)?;
    let (nonce_bytes, ciphertext) = sealed.split_at(NONCE_LEN);
    let cipher = ChaCha20Poly1305::new_from_slice(&key)
        .map_err(|e| Error::InvalidInput(format!("cipher key: {e}")))?;
    let nonce = Nonce::from_slice(nonce_bytes);
    let plaintext = cipher
        .decrypt(nonce, ciphertext)
        .map_err(|_| Error::InvalidInput("backup decrypt failed (wrong nsec or corrupt)".into()))?;
    decode_plaintext(&plaintext)
}

fn validate_db_key_hex(db_key_hex: &str) -> Result<()> {
    if db_key_hex.len() != 64
        || hex::decode(db_key_hex)
            .map(|b| b.len() != 32)
            .unwrap_or(true)
    {
        return Err(Error::InvalidInput(
            "db_key_hex must be 64 hex chars (32 bytes)".into(),
        ));
    }
    Ok(())
}

/// Open SQLCipher DB with `db_key_hex` and TRUNCATE-checkpoint WAL into the
/// main file so a subsequent raw `fs::read` captures recent commits.
fn checkpoint_sqlcipher_file(path: &Path, db_key_hex: &str) -> Result<()> {
    if !path.is_file() {
        return Ok(());
    }
    // Wrong SQLCipher keys often "succeed" as an empty DB — require user tables
    // before sealing so we never backup garbage under a bad key.
    verify_sqlcipher_opens(path, db_key_hex)?;
    let conn = Connection::open(path)
        .map_err(|e| Error::Storage(format!("backup checkpoint open {}: {e}", path.display())))?;
    conn.execute_batch(&format!("PRAGMA key = \"x'{db_key_hex}'\";"))
        .map_err(|e| Error::Storage(format!("backup checkpoint key: {e}")))?;
    // Inspect the busy column — execute_batch success does not mean TRUNCATE
    // finished if another connection still holds the WAL.
    let busy: i64 = conn
        .query_row("PRAGMA wal_checkpoint(TRUNCATE);", [], |row| row.get(0))
        .map_err(|e| Error::Storage(format!("backup wal_checkpoint: {e}")))?;
    if busy != 0 {
        return Err(Error::Storage(format!(
            "backup wal_checkpoint busy={busy} — close live SonarNode before backup"
        )));
    }
    Ok(())
}

/// Read Marmot DB (+ optional conversation index) from disk into a package.
/// Checkpoints WAL first so the sealed bytes include recent commits.
pub fn read_account_backup_package(
    db_path: &Path,
    db_key_hex: &str,
) -> Result<AccountBackupPackage> {
    validate_db_key_hex(db_key_hex)?;
    checkpoint_sqlcipher_file(db_path, db_key_hex)?;
    let index_path = index_db_path_for_db(db_path);
    checkpoint_sqlcipher_file(&index_path, db_key_hex)?;
    let db_bytes = fs::read(db_path).map_err(|e| Error::Storage(format!("read db: {e}")))?;
    if db_bytes.is_empty() {
        return Err(Error::InvalidInput("db_bytes is empty".into()));
    }
    let index_bytes = if index_path.is_file() {
        Some(fs::read(&index_path).map_err(|e| Error::Storage(format!("read index: {e}")))?)
    } else {
        None
    };
    Ok(AccountBackupPackage {
        db_key_hex: db_key_hex.to_string(),
        db_bytes,
        index_bytes,
    })
}

/// Suffix appended to the live DB path while a restore is staged (key not
/// persisted yet). Host must [`commit_staged_account_restore`] or
/// [`abort_staged_account_restore`].
const RESTORE_STAGING_SUFFIX: &str = ".sonar-restore-staging";
const RESTORE_INTENT_SUFFIX: &str = ".sonar-restore-intent";

fn staging_db_path(db_path: &Path) -> std::path::PathBuf {
    let mut staged = db_path.as_os_str().to_owned();
    staged.push(RESTORE_STAGING_SUFFIX);
    std::path::PathBuf::from(staged)
}

/// Marker proving a restore was actually asked for, written next to the staging
/// DB and cleared by both commit and abort.
///
/// Boot reconcile promotes staged bytes over the live account. Presence of a
/// staging file alone is not proof of intent: a staging DB left by an
/// interrupted restore of *this same account* opens under the live key, so
/// without this marker reconcile would silently roll the database back to the
/// backup and drop everything received since.
fn restore_intent_path(db_path: &Path) -> std::path::PathBuf {
    let mut p = db_path.as_os_str().to_owned();
    p.push(RESTORE_INTENT_SUFFIX);
    std::path::PathBuf::from(p)
}

fn mark_restore_intent(db_path: &Path) -> Result<()> {
    let path = restore_intent_path(db_path);
    let mut f = File::create(&path)
        .map_err(|e| Error::Storage(format!("restore intent create {}: {e}", path.display())))?;
    f.write_all(b"1")
        .map_err(|e| Error::Storage(format!("restore intent write: {e}")))?;
    f.sync_all()
        .map_err(|e| Error::Storage(format!("restore intent fsync: {e}")))?;
    Ok(())
}

fn clear_restore_intent(db_path: &Path) {
    let _ = fs::remove_file(restore_intent_path(db_path));
}

fn remove_db_tree(db_path: &Path) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut p = db_path.as_os_str().to_owned();
        p.push(suffix);
        let _ = fs::remove_file(Path::new(&p));
    }
    let index_path = index_db_path_for_db(db_path);
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut p = index_path.as_os_str().to_owned();
        p.push(suffix);
        let _ = fs::remove_file(Path::new(&p));
    }
}

/// Write a restored package to disk. Parent dirs must exist. Caller must not
/// hold a live `SonarNode` on `db_path`.
pub fn write_account_backup_package(db_path: &Path, package: &AccountBackupPackage) -> Result<()> {
    validate_db_key_hex(&package.db_key_hex)?;
    if package.db_bytes.is_empty() {
        return Err(Error::InvalidInput("db_bytes is empty".into()));
    }
    if let Some(parent) = db_path.parent() {
        fs::create_dir_all(parent).map_err(|e| Error::Storage(format!("mkdir: {e}")))?;
    }
    // Remove prior sidecars so a partial restore cannot mix WAL from another key.
    remove_db_tree(db_path);
    fs::write(db_path, &package.db_bytes).map_err(|e| Error::Storage(format!("write db: {e}")))?;
    if let Some(index) = &package.index_bytes {
        let index_path = index_db_path_for_db(db_path);
        fs::write(&index_path, index).map_err(|e| Error::Storage(format!("write index: {e}")))?;
    }
    Ok(())
}

fn sync_file(path: &Path) -> Result<()> {
    let f = fs::File::open(path)
        .map_err(|e| Error::Storage(format!("fsync open {}: {e}", path.display())))?;
    f.sync_all()
        .map_err(|e| Error::Storage(format!("fsync {}: {e}", path.display())))?;
    Ok(())
}

fn remove_wal_sidecars(db_path: &Path) {
    for suffix in ["-wal", "-shm", "-journal"] {
        let mut p = db_path.as_os_str().to_owned();
        p.push(suffix);
        let _ = fs::remove_file(Path::new(&p));
    }
}

/// True when a restore staging DB still exists beside `db_path`.
pub fn account_restore_staging_present(db_path: &Path) -> bool {
    staging_db_path(db_path).is_file()
}

/// Promote staged restore files to the live `db_path` (after host persisted key).
///
/// Crash-safer than delete-then-rename: fsync staged bytes, drop live WAL/shm,
/// then `rename(staged → live)` which atomically replaces on the same filesystem.
///
/// Idempotent: if staging is already gone, returns `Ok(())` so hosts can retry
/// after a partial commit without treating success as failure.
///
/// After the main DB rename succeeds, conversation-index promotion is
/// best-effort. Failing the whole commit there would push hosts to clear
/// `db_key` and permanently orphan the already-live restored ciphertext.
pub fn commit_staged_account_restore(db_path: &Path) -> Result<()> {
    let staged = staging_db_path(db_path);
    if !staged.is_file() {
        // Already promoted (or never staged). Finish any leftover staged index.
        promote_staged_index_best_effort(db_path);
        clear_restore_intent(db_path);
        return Ok(());
    }
    sync_file(&staged)?;
    let staged_index = index_db_path_for_db(&staged);
    if staged_index.is_file() {
        sync_file(&staged_index)?;
    }
    remove_wal_sidecars(db_path);
    fs::rename(&staged, db_path).map_err(|e| Error::Storage(format!("commit db rename: {e}")))?;
    promote_staged_index_best_effort(db_path);
    // Drop leftover staging DB sidecars (index may remain if rename failed).
    for suffix in ["-wal", "-shm", "-journal"] {
        let mut p = staging_db_path(db_path).as_os_str().to_owned();
        p.push(suffix);
        let _ = fs::remove_file(Path::new(&p));
    }
    // Last: the restore is done, so the intent must not survive to the next
    // boot. Clearing it before the rename would let a crash mid-commit look
    // like an unrequested staging file and get aborted.
    clear_restore_intent(db_path);
    Ok(())
}

fn promote_staged_index_best_effort(db_path: &Path) {
    let staged_index = index_db_path_for_db(&staging_db_path(db_path));
    if !staged_index.is_file() {
        return;
    }
    let live_index = index_db_path_for_db(db_path);
    remove_wal_sidecars(&live_index);
    let _ = fs::remove_file(&live_index);
    if let Err(e) = fs::rename(&staged_index, &live_index) {
        // Main DB is already live — leave staged index for a later reconcile.
        tracing::warn!(
            error = %e,
            "account restore: index rename failed; main DB committed, staged index kept"
        );
        return;
    }
    for suffix in ["-wal", "-shm", "-journal"] {
        let mut p = staged_index.as_os_str().to_owned();
        p.push(suffix);
        let _ = fs::remove_file(Path::new(&p));
    }
}

/// Discard staged restore files (key persist failed or user aborted).
///
/// Only call this when [`account_restore_staging_present`] is still true. If
/// the main DB was already promoted, clearing the host `db_key` instead of
/// aborting staging is what orphans chats.
pub fn abort_staged_account_restore(db_path: &Path) {
    remove_db_tree(&staging_db_path(db_path));
    clear_restore_intent(db_path);
}

fn verify_sqlcipher_opens(path: &Path, db_key_hex: &str) -> Result<()> {
    validate_db_key_hex(db_key_hex)?;
    let conn = Connection::open(path)
        .map_err(|e| Error::Storage(format!("verify open {}: {e}", path.display())))?;
    conn.execute_batch(&format!("PRAGMA key = \"x'{db_key_hex}'\";"))
        .map_err(|e| Error::Storage(format!("verify key: {e}")))?;
    // Wrong SQLCipher keys often "succeed" as an empty DB — require user tables.
    let table_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
            [],
            |row| row.get(0),
        )
        .map_err(|e| Error::Storage(format!("verify schema: {e}")))?;
    if table_count <= 0 {
        return Err(Error::Storage(
            "staged restore DB empty or wrong key".into(),
        ));
    }
    Ok(())
}

/// Boot-time recovery: if `*.sonar-restore-staging` remains and `db_key_hex`
/// opens it, commit. Otherwise abort the orphaned staging so connect cannot
/// leave ciphertext stranded beside a minted key.
///
/// Returns `true` when a commit ran.
pub fn reconcile_staged_account_restore(db_path: &Path, db_key_hex: &str) -> Result<bool> {
    let staged = staging_db_path(db_path);
    if !staged.is_file() {
        // Crash after DB rename / before index rename — finish the index only.
        promote_staged_index_best_effort(db_path);
        clear_restore_intent(db_path);
        return Ok(false);
    }
    // Staging without intent is debris, not a restore. Promoting it would
    // overwrite the live account with older bytes — and when the backup came
    // from this same install the key check cannot tell the two apart, because
    // the staged DB opens under the live key. Discard instead: the live
    // database is always the safer of the two to keep.
    if !restore_intent_path(db_path).is_file() {
        tracing::warn!(
            db = %db_path.display(),
            "restore staging without intent marker; discarding rather than promoting"
        );
        abort_staged_account_restore(db_path);
        return Ok(false);
    }
    match verify_sqlcipher_opens(&staged, db_key_hex) {
        Ok(()) => {
            commit_staged_account_restore(db_path)?;
            Ok(true)
        }
        Err(_) => {
            abort_staged_account_restore(db_path);
            Ok(false)
        }
    }
}

fn blossom_base(server_url: &str) -> Result<Url> {
    let server = if server_url.is_empty() {
        DEFAULT_BLOSSOM_SERVER
    } else {
        server_url
    };
    let url =
        Url::parse(server).map_err(|e| Error::Blossom(format!("bad server url {server}: {e}")))?;
    if url.scheme() != "https" {
        return Err(Error::Blossom(format!(
            "blossom server must be https (got {})",
            url.scheme()
        )));
    }
    Ok(url)
}

/// Upload a sealed backup blob (BUD-02) authenticated as `keys`.
pub async fn upload_sealed_backup(
    keys: &Keys,
    server_url: &str,
    sealed: Vec<u8>,
) -> Result<AccountBackupUpload> {
    if sealed.is_empty() {
        return Err(Error::InvalidInput("empty sealed backup".into()));
    }
    if sealed.len() > MAX_BACKUP_BYTES {
        return Err(Error::InvalidInput(format!(
            "backup too large ({} > {MAX_BACKUP_BYTES})",
            sealed.len()
        )));
    }
    let base = blossom_base(server_url)?;
    let descriptor = BlossomClient::new(base)
        .upload_blob(
            sealed,
            Some(ACCOUNT_BACKUP_MIME.to_string()),
            None,
            Some(keys),
        )
        .await
        .map_err(|e| Error::Blossom(e.to_string()))?;
    Ok(AccountBackupUpload {
        url: descriptor.url.to_string(),
        sha256_hex: descriptor.sha256.to_string(),
        size: descriptor.size as u64,
    })
}

/// BUD-03 list endpoint for `pubkey`: `{base}/list/{pubkey_hex}`.
///
/// Built segment-wise on purpose. `nostr-blossom` (0.44.0 and 0.45.0-alpha.6)
/// does `base.join("list")?.join(&pubkey.to_hex())?`, and `Url::join` is RFC
/// 3986 relative resolution: joining a bare segment onto a path that does not
/// end in `/` REPLACES the last segment. So upstream requests `{base}/{pubkey}`
/// — the BUD-01 blob-fetch route — which 404s for a pubkey, and every account
/// backup restore fails with a transport error instead of finding the blob.
fn backup_list_url(base: &Url, pubkey: &PublicKey) -> Result<Url> {
    let mut url = base.clone();
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| Error::Blossom(format!("blossom base cannot be a base: {base}")))?;
        // A base with a trailing slash parses as a final empty segment, which
        // would otherwise render as `//list/`.
        segments.pop_if_empty();
        segments.push("list");
        segments.push(&pubkey.to_hex());
    }
    Ok(url)
}

/// Server scope for a BUD-01 authorization, without the trailing slash.
///
/// `Url::parse("https://nostr.download")` normalizes to `https://nostr.download/`,
/// and servers compare this tag as a plain string: nostr.download answers
/// `401` with `x-reason: Server not in authorization token scope` for the
/// slashed form and `200` for the bare one. BUD-01's own examples are bare, so
/// trim rather than hope the server is lenient.
fn blossom_server_scope(base: &Url) -> String {
    base.as_str().trim_end_matches('/').to_string()
}

/// BUD-03 `GET /list/<pubkey>` with a signed kind-24242 authorization.
///
/// Hand-rolled rather than `BlossomClient::list_blobs` — see [`backup_list_url`]
/// for why that path cannot reach the endpoint, and [`blossom_server_scope`] for
/// why the crate's `ServerUrl` scope is rejected once it does.
async fn list_account_backup_blobs(keys: &Keys, base: &Url) -> Result<Vec<BlobDescriptor>> {
    let url = backup_list_url(base, &keys.public_key())?;
    let expiration = Timestamp::now() + std::time::Duration::from_secs(300);
    let auth_event = EventBuilder::new(Kind::BlossomAuth, "Blossom list authorization")
        .tags([
            Tag::parse(["server", &blossom_server_scope(base)])
                .map_err(|e| Error::Blossom(format!("blossom server tag: {e}")))?,
            Tag::expiration(expiration),
            Tag::hashtag("list"),
        ])
        .sign(keys)
        .await
        .map_err(|e| Error::Blossom(format!("blossom list auth: {e}")))?;
    let header = {
        use base64::Engine as _;
        format!(
            "Nostr {}",
            base64::engine::general_purpose::STANDARD.encode(auth_event.as_json())
        )
    };
    let response = reqwest::Client::new()
        .get(url)
        .header(reqwest::header::AUTHORIZATION, header)
        .send()
        .await
        .map_err(|e| Error::Blossom(format!("blossom list: {e}")))?;
    let status = response.status();
    if !status.is_success() {
        return Err(Error::Blossom(format!("blossom list http {status}")));
    }
    response
        .json::<Vec<BlobDescriptor>>()
        .await
        .map_err(|e| Error::Blossom(format!("blossom list decode: {e}")))
}

/// BUD-01 blob endpoint for `sha256`: `{base}/{sha256}`.
///
/// Segment-wise for the same reason as [`backup_list_url`]: `Url::join` would
/// drop the last path segment of a based-under-a-path server.
fn backup_blob_url(base: &Url, sha256: &Sha256Hash) -> Result<Url> {
    let mut url = base.clone();
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| Error::Blossom(format!("blossom base cannot be a base: {base}")))?;
        segments.pop_if_empty();
        segments.push(&sha256.to_string());
    }
    Ok(url)
}

/// How much to reserve up front for a backup download.
///
/// `Content-Length` is the server's claim about a body it has not sent yet, so
/// it must never size the allocation. Bounding the hint by `MAX_BACKUP_BYTES`
/// is not enough: a hostile host can advertise 200 MiB and then send nothing,
/// and the phone is out of memory before the first byte arrives. Reserve a
/// small fixed amount instead and let the `Vec` grow — growth is amortized, and
/// the streaming check in `download_blob_capped_to` is the real bound.
fn download_buffer_capacity(content_length: Option<u64>) -> usize {
    content_length.unwrap_or(0).min(INITIAL_DOWNLOAD_CAPACITY as u64) as usize
}

/// Download a blob, refusing to buffer more than `MAX_BACKUP_BYTES`.
///
/// `BlossomClient::get_blob` calls `Response::bytes()`, which buffers the whole
/// body before any size check can run. The advertised `size` in the list
/// response is the server's own claim, so a hostile or compromised host can
/// advertise a small blob and then stream gigabytes — turning a restore into an
/// OOM kill on a phone. Cap the read itself and abort mid-stream instead.
async fn download_blob_capped(keys: &Keys, base: &Url, sha256: Sha256Hash) -> Result<Vec<u8>> {
    download_blob_capped_to(keys, base, sha256, MAX_BACKUP_BYTES).await
}

/// Same, with an injectable ceiling so tests can prove the mid-stream abort
/// without moving 200 MiB.
async fn download_blob_capped_to(
    keys: &Keys,
    base: &Url,
    sha256: Sha256Hash,
    limit: usize,
) -> Result<Vec<u8>> {
    let url = backup_blob_url(base, &sha256)?;
    let expiration = Timestamp::now() + std::time::Duration::from_secs(300);
    let auth_event = EventBuilder::new(Kind::BlossomAuth, "Blossom get authorization")
        .tags([
            Tag::parse(["server", &blossom_server_scope(base)])
                .map_err(|e| Error::Blossom(format!("blossom server tag: {e}")))?,
            Tag::expiration(expiration),
            Tag::hashtag("get"),
            Tag::parse(["x", &sha256.to_string()])
                .map_err(|e| Error::Blossom(format!("blossom x tag: {e}")))?,
        ])
        .sign(keys)
        .await
        .map_err(|e| Error::Blossom(format!("blossom get auth: {e}")))?;
    let header = {
        use base64::Engine as _;
        format!(
            "Nostr {}",
            base64::engine::general_purpose::STANDARD.encode(auth_event.as_json())
        )
    };
    let mut response = reqwest::Client::new()
        .get(url)
        .header(reqwest::header::AUTHORIZATION, header)
        .send()
        .await
        .map_err(|e| Error::Blossom(format!("blossom get: {e}")))?;
    let status = response.status();
    if !status.is_success() {
        return Err(Error::Blossom(format!("blossom get http {status}")));
    }
    let mut body = Vec::with_capacity(download_buffer_capacity(response.content_length()));
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|e| Error::Blossom(format!("blossom get body: {e}")))?
    {
        if body.len().saturating_add(chunk.len()) > limit {
            return Err(Error::Blossom(
                "downloaded backup exceeds size cap".to_string(),
            ));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// Hosts to search on restore: the caller's server, or — when it defaulted —
/// the current default followed by [`LEGACY_BACKUP_BLOSSOM_SERVERS`].
///
/// An explicit server is honoured verbatim: a caller pointing at their own
/// Blossom does not want us reaching out to a public one behind their back.
fn backup_search_hosts(server_url: &str) -> Result<Vec<Url>> {
    let base = blossom_base(server_url)?;
    if !server_url.is_empty() {
        return Ok(vec![base]);
    }
    let mut hosts = vec![base];
    for legacy in LEGACY_BACKUP_BLOSSOM_SERVERS {
        let legacy = blossom_base(legacy)?;
        if !hosts.contains(&legacy) {
            hosts.push(legacy);
        }
    }
    Ok(hosts)
}

/// One conversation as it exists inside a sealed backup.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupPreviewConversation {
    pub name: String,
    pub latest_content: String,
    pub message_count: u64,
}

/// What a restore *would* bring back. Produced without touching the live store.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountBackupPreview {
    pub conversations: Vec<BackupPreviewConversation>,
    pub total_messages: u64,
    pub size_bytes: u64,
    /// When the blob was uploaded, per the Blossom descriptor.
    pub uploaded_at_secs: u64,
}

/// Dry run: read a backup and report what restoring it would recover.
///
/// Deliberately never calls the staging/commit path. It decrypts in memory and
/// opens only the conversation *index* from a scratch copy, so a preview can
/// never disturb the live SQLCipher store, leave staged files behind, or race
/// the node — the failure mode of a "preview" that mutates state is losing the
/// chats the user was trying to inspect.
///
/// `db_path` is not read or written — only its directory is used to place the
/// scratch copy. It must be the live DB path so the scratch lands in
/// app-private storage: the process temp dir is **not** usable on Android,
/// where `TMPDIR` is unset for app processes and `/tmp` is `shell`-owned and
/// unwritable, so `env::temp_dir()` fails the dry run outright.
pub async fn preview_account_backup(
    keys: &Keys,
    db_path: &Path,
    server_url: &str,
) -> Result<AccountBackupPreview> {
    preview_account_backup_from(keys, db_path, &backup_search_hosts(server_url)?).await
}

/// Scratch dir for the dry run, always inside `db_path`'s own directory.
///
/// Returns a [`TempDir`] so the decrypted index is removed on every exit path,
/// including errors and panics.
fn preview_scratch_dir(db_path: &Path) -> Result<tempfile::TempDir> {
    let parent = db_path.parent().unwrap_or(Path::new("."));
    fs::create_dir_all(parent)
        .map_err(|e| Error::Storage(format!("backup preview scratch parent: {e}")))?;
    reap_stale_preview_scratch(parent);
    tempfile::Builder::new()
        .prefix(PREVIEW_SCRATCH_PREFIX)
        .tempdir_in(parent)
        .map_err(|e| Error::Storage(format!("backup preview scratch dir: {e}")))
}

/// Remove scratch dirs a previous preview could not clean up itself.
///
/// [`tempfile::TempDir`] reaps on drop, which covers errors and panics but not
/// the process being killed mid-preview — and the account dir is exactly where
/// a leftover is most expensive, because `account_storage_bytes` counts it and
/// one accumulates per kill.
fn reap_stale_preview_scratch(parent: &Path) {
    let Ok(entries) = fs::read_dir(parent) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !name.starts_with(PREVIEW_SCRATCH_PREFIX) {
            continue;
        }
        if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
}

/// Same, against already-validated hosts. Split out so tests can drive the real
/// download -> decrypt -> read path against a loopback mock without loosening
/// the https requirement in [`blossom_base`].
async fn preview_account_backup_from(
    keys: &Keys,
    db_path: &Path,
    hosts: &[Url],
) -> Result<AccountBackupPreview> {
    let (sealed, uploaded_at_secs) = download_latest_sealed_backup_with_meta(keys, hosts).await?;
    let package = open_account_backup(&secret_bytes(keys), &sealed)?;
    let size_bytes = sealed.len() as u64;
    let Some(index_bytes) = package.index_bytes.as_ref() else {
        // A backup with no index still restores; there is just nothing to list.
        return Ok(AccountBackupPreview {
            conversations: Vec::new(),
            total_messages: 0,
            size_bytes,
            uploaded_at_secs,
        });
    };

    let scratch = preview_scratch_dir(db_path)?;
    let index_path = scratch.path().join("preview-index.db");
    fs::write(&index_path, index_bytes)
        .map_err(|e| Error::Storage(format!("backup preview index write: {e}")))?;
    let key: [u8; 32] = hex::decode(&package.db_key_hex)
        .ok()
        .and_then(|b| b.try_into().ok())
        .ok_or_else(|| Error::InvalidInput("backup db key malformed".into()))?;

    let summaries = crate::conversation_index::ConversationIndex::open(&index_path, key)
        .and_then(|idx| idx.summaries_ordered())
        .unwrap_or_default();
    let conversations: Vec<_> = summaries
        .into_iter()
        .map(|s| BackupPreviewConversation {
            name: s.name,
            // Control lines (⚡TRILL / ⚡PAY / ☎CALL) are transcript-hidden;
            // leaking them here was caught on device — the dry run rendered a
            // raw "⚡TRILL|1|…" as a chat's preview. Blank anything that is not
            // a plain message and let hosts render name/count only.
            latest_content: match crate::notification::classify_content(&s.latest_content) {
                crate::notification::NotificationKind::Message => s.latest_content,
                _ => String::new(),
            },
            message_count: s.message_count,
        })
        .collect();
    let total_messages = conversations.iter().map(|c| c.message_count).sum();
    // `scratch` drops here: the decrypted index never outlives the call.
    Ok(AccountBackupPreview {
        conversations,
        total_messages,
        size_bytes,
        uploaded_at_secs,
    })
}

/// Newest account backup plus its upload timestamp, searching each host in turn.
async fn download_latest_sealed_backup_with_meta(
    keys: &Keys,
    bases: &[Url],
) -> Result<(Vec<u8>, u64)> {
    let mut last_missing = Error::AccountBackupMissing;
    for base in bases {
        let mut blobs = match list_account_backup_blobs(keys, base).await {
            Ok(b) => b,
            Err(e) => return Err(e),
        };
        blobs.retain(|b| b.mime_type.as_deref() == Some(ACCOUNT_BACKUP_MIME));
        if blobs.is_empty() {
            last_missing = Error::AccountBackupMissing;
            continue;
        }
        blobs.sort_by_key(|b| b.uploaded);
        let latest = blobs.pop().expect("non-empty after retain");
        let uploaded = latest.uploaded.as_secs();
        let data = download_latest_sealed_backup_at(keys, base).await?;
        return Ok((data, uploaded));
    }
    Err(last_missing)
}

/// List this pubkey's blobs and download the newest account-backup MIME.
pub async fn download_latest_sealed_backup(keys: &Keys, server_url: &str) -> Result<Vec<u8>> {
    download_latest_sealed_backup_from(keys, &backup_search_hosts(server_url)?).await
}

/// Try each host in order. Only a genuinely absent backup advances to the next
/// one — a transport or decode failure is reported as-is rather than being
/// retried elsewhere and surfacing as the misleading "no backup" outcome.
async fn download_latest_sealed_backup_from(keys: &Keys, bases: &[Url]) -> Result<Vec<u8>> {
    let mut last_missing = Error::AccountBackupMissing;
    for base in bases {
        match download_latest_sealed_backup_at(keys, base).await {
            Ok(data) => return Ok(data),
            Err(e) if is_missing_backup_error(&e) => last_missing = e,
            Err(e) => return Err(e),
        }
    }
    Err(last_missing)
}

/// Same, against an already-validated base. Split out so tests can drive the
/// real list → download → verify path against a loopback mock without
/// loosening the https requirement in [`blossom_base`].
async fn download_latest_sealed_backup_at(keys: &Keys, base: &Url) -> Result<Vec<u8>> {
    let mut blobs = list_account_backup_blobs(keys, base).await?;
    blobs.retain(|b| b.mime_type.as_deref() == Some(ACCOUNT_BACKUP_MIME));
    if blobs.is_empty() {
        return Err(Error::AccountBackupMissing);
    }
    blobs.sort_by_key(|b| b.uploaded);
    let latest = blobs.pop().expect("non-empty after retain");
    if latest.size as usize > MAX_BACKUP_BYTES {
        return Err(Error::Blossom(format!(
            "backup blob too large ({})",
            latest.size
        )));
    }
    let data = download_blob_capped(keys, base, latest.sha256).await?;
    let hash = Sha256Hash::hash(&data);
    if hash != latest.sha256 {
        return Err(Error::Blossom("backup sha256 mismatch".into()));
    }
    Ok(data)
}

/// Checkpoint + read + AEAD seal. Requires **no** live `SonarNode` on `db_path`.
/// Hosts should reopen the node before calling [`upload_sealed_backup`] so chat
/// is not blocked on the Blossom RTT.
///
/// Stamps `last_attempt_at` up front so concurrent host executors see
/// `backup_is_due == false` for the debounce window.
pub fn seal_account_backup_files(keys: &Keys, db_path: &Path, db_key_hex: &str) -> Result<Vec<u8>> {
    record_backup_attempt(db_path)?;
    let sealed = (|| {
        let package = read_account_backup_package(db_path, db_key_hex)?;
        seal_account_backup(&secret_bytes(keys), &package)
    })();
    if let Err(ref e) = sealed {
        let _ = record_backup_failure(db_path, &e.to_string());
    }
    sealed
}

/// High-level convenience: seal then upload (holds exclusive DB access for the
/// whole call). Prefer host-side seal → reconnect → [`upload_sealed_backup`].
pub async fn backup_account_files(
    keys: &Keys,
    db_path: &Path,
    db_key_hex: &str,
    server_url: &str,
) -> Result<AccountBackupUpload> {
    let sealed = seal_account_backup_files(keys, db_path, db_key_hex)?;
    let sealed_len = sealed.len() as u64;
    match upload_sealed_backup(keys, server_url, sealed).await {
        Ok(uploaded) => {
            let _ = record_backup_success(db_path, Some(sealed_len), Some(db_key_hex));
            Ok(uploaded)
        }
        Err(e) => {
            let _ = record_backup_failure(db_path, &e.to_string());
            Err(e)
        }
    }
}

/// Download + decrypt only (no disk write). Host must persist `db_key_hex`
/// durably, then call [`write_account_backup_package`].
pub async fn fetch_account_backup_package(
    keys: &Keys,
    server_url: &str,
) -> Result<AccountBackupPackage> {
    let sealed = download_latest_sealed_backup(keys, server_url).await?;
    let package = open_account_backup(&secret_bytes(keys), &sealed)?;
    validate_db_key_hex(&package.db_key_hex)?;
    Ok(package)
}

/// Download + decrypt + stage files beside `db_path`. Returns `db_key_hex`.
/// Host must persist the key, then [`commit_staged_account_restore`]. On any
/// persist failure call [`abort_staged_account_restore`] so connect never opens
/// restored ciphertext with a freshly minted key.
pub async fn restore_account_files(
    keys: &Keys,
    db_path: &Path,
    server_url: &str,
) -> Result<String> {
    let package = fetch_account_backup_package(keys, server_url).await?;
    let staged = staging_db_path(db_path);
    // Replace any leftover staging from a prior interrupted restore.
    abort_staged_account_restore(db_path);
    write_account_backup_package(&staged, &package)?;
    sync_file(&staged)?;
    let staged_index = index_db_path_for_db(&staged);
    if staged_index.is_file() {
        sync_file(&staged_index)?;
    }
    // Refuse to hand hosts a key for corrupt / wrong-key empty SQLCipher bytes.
    verify_sqlcipher_opens(&staged, &package.db_key_hex)?;
    // Only now, with verified staged bytes on disk, record that a restore was
    // genuinely requested. Boot reconcile promotes staging only against this
    // marker; written last so a crash mid-staging leaves debris that reconcile
    // discards instead of promoting over the live account.
    mark_restore_intent(db_path)?;
    Ok(package.db_key_hex)
}

/// True when a Blossom / network error means "no backup to restore" (soft).
pub fn is_missing_backup_error(err: &Error) -> bool {
    matches!(err, Error::AccountBackupMissing)
        || matches!(err, Error::Blossom(msg) if msg.contains("no account backup found"))
}

/// Stable FFI / host marker embedded in [`SonarFfiError::InvalidInput`].
pub const ACCOUNT_BACKUP_MISSING_MARKER: &str = "account_backup_missing";

/// Host helper: classify an FFI/`localizedDescription` string as missing backup.
pub fn message_indicates_missing_backup(message: &str) -> bool {
    message.contains(ACCOUNT_BACKUP_MISSING_MARKER) || message.contains("no account backup found")
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    /// The whole point of [`backup_list_url`]: `Url::join` would drop `list`.
    #[test]
    fn list_url_keeps_the_list_segment() {
        let keys = Keys::generate();
        let pubkey = keys.public_key();
        for base in ["https://nostr.download", "https://nostr.download/"] {
            let base = Url::parse(base).unwrap();
            let built = backup_list_url(&base, &pubkey).unwrap();
            assert_eq!(
                built.as_str(),
                format!("https://nostr.download/list/{}", pubkey.to_hex()),
                "base {base} must resolve to the BUD-03 list route",
            );
            // Pin the upstream behaviour this function exists to avoid, so a
            // future `Url::join` rewrite of the helper fails loudly here.
            let upstream = base.join("list").unwrap().join(&pubkey.to_hex()).unwrap();
            assert_ne!(
                upstream, built,
                "join-based construction must not be mistaken for correct",
            );
        }
    }

    /// End-to-end over a loopback Blossom that answers BUD-03 `/list/<pubkey>`
    /// and 404s the BUD-01 `/<pubkey>` blob route, exactly like nostr.download.
    /// Before the [`backup_list_url`] fix this failed with `blossom list http
    /// 404` — which `is_missing_account_backup_error` does NOT classify as
    /// missing, so hosts reported "chat backup restore failed" and no restore
    /// could ever succeed.
    #[tokio::test]
    async fn download_finds_the_backup_through_the_list_route() {
        let keys = Keys::generate();
        let sealed = b"sealed-account-backup-bytes".to_vec();
        let (base, _seen) = spawn_mock_blossom_list(keys.public_key(), sealed.clone());
        let got = download_latest_sealed_backup_at(&keys, &base)
            .await
            .expect("restore must find the uploaded backup");
        assert_eq!(got, sealed);
    }

    /// The authorization a real server actually accepts.
    ///
    /// nostr.download rejects a `server` scope carrying `Url`'s normalized
    /// trailing slash with `401 / x-reason: Server not in authorization token
    /// scope`, which reached users as "chat backup restore failed" even after
    /// the list route was correct. Verified against the live server with a
    /// throwaway key: bare scope 200, slashed scope 401.
    #[tokio::test]
    async fn list_request_sends_an_accepted_authorization() {
        use base64::Engine as _;

        let keys = Keys::generate();
        let (base, seen) = spawn_mock_blossom_list(keys.public_key(), b"blob".to_vec());
        let _ = download_latest_sealed_backup_at(&keys, &base).await;

        let header = seen
            .lock()
            .unwrap()
            .clone()
            .expect("list must send Authorization");
        let encoded = header
            .strip_prefix("Nostr ")
            .expect("BUD-01 header is `Nostr <base64>`");
        let json = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .expect("base64 auth payload");
        let event = Event::from_json(String::from_utf8(json).expect("utf8 auth event"))
            .expect("auth event parses");

        assert_eq!(event.kind, Kind::BlossomAuth, "BUD-01 uses kind 24242");
        assert!(event.verify().is_ok(), "auth event must be signed");
        assert_eq!(event.pubkey, keys.public_key());

        let tag = |name: &str| {
            event
                .tags
                .iter()
                .find(|t| t.as_slice().first().map(String::as_str) == Some(name))
                .map(|t| t.as_slice()[1].clone())
        };
        assert_eq!(tag("t").as_deref(), Some("list"), "verb tag");
        let server = tag("server").expect("server scope tag");
        assert!(
            !server.ends_with('/'),
            "a trailing slash is rejected as out-of-scope: {server}",
        );
        assert_eq!(server, base.as_str().trim_end_matches('/'));
        let expiration: u64 = tag("expiration")
            .expect("expiration tag")
            .parse()
            .expect("numeric expiration");
        assert!(
            expiration > Timestamp::now().as_u64(),
            "expired authorizations are refused",
        );
    }

    /// Moving the default host must not orphan a backup already uploaded to the
    /// old one: unlike media, a backup carries no stored URL, so restore can
    /// only find it by listing.
    #[tokio::test]
    async fn restore_falls_back_to_a_legacy_host() {
        let keys = Keys::generate();
        let sealed = b"backup-on-the-old-host".to_vec();
        let (current, _a) = spawn_mock_blossom_list(Keys::generate().public_key(), b"x".to_vec());
        let (legacy, _b) = spawn_mock_blossom_list(keys.public_key(), sealed.clone());
        let got = download_latest_sealed_backup_from(&keys, &[current, legacy])
            .await
            .expect("must search the legacy host too");
        assert_eq!(got, sealed);
    }

    /// A real error on the first host must not be retried onto the next and
    /// end up reported as "no backup" — that is how a transient outage would
    /// tell a user their chats are gone.
    #[tokio::test]
    async fn a_transport_error_does_not_become_a_missing_backup() {
        let keys = Keys::generate();
        let dead = Url::parse("http://127.0.0.1:1/").expect("closed port");
        let (legacy, _b) = spawn_mock_blossom_list(keys.public_key(), b"sealed".to_vec());
        let err = download_latest_sealed_backup_from(&keys, &[dead, legacy])
            .await
            .expect_err("the first host failed for real");
        assert!(
            !is_missing_backup_error(&err),
            "a transport failure must stay a failure, got {err:?}",
        );
    }

    #[test]
    fn default_search_hosts_start_at_the_media_host_then_legacy() {
        let hosts = backup_search_hosts("").unwrap();
        assert_eq!(
            hosts.first().map(Url::as_str),
            Some(format!("{DEFAULT_BLOSSOM_SERVER}/").as_str()),
            "backups must target the same host as media",
        );
        assert!(
            hosts.len() > 1 && hosts.iter().any(|h| h.as_str().contains("nostr.download")),
            "the previous default must stay searchable: {hosts:?}",
        );
        // An explicit server is honoured alone, no public-host fallback.
        let explicit = backup_search_hosts("https://blossom.example").unwrap();
        assert_eq!(explicit.len(), 1);
    }

    /// Manual is `enabled = false` — the executors already refuse to run a
    /// disabled policy, so "manual only" needs no second flag to fall out of
    /// sync with. Round-trips through the sidecar.
    #[test]
    fn frequency_round_trips_through_the_policy() {
        let dir = tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        for (freq, enabled) in [
            (BackupFrequency::Weekly, true),
            (BackupFrequency::Manual, false),
            (BackupFrequency::Daily, true),
        ] {
            set_backup_frequency(&db, freq).unwrap();
            let policy = load_backup_policy(&db);
            assert_eq!(policy.enabled, enabled, "{freq:?} enabled");
            assert_eq!(
                BackupFrequency::from_policy(&policy),
                freq,
                "{freq:?} round trip"
            );
        }
    }

    /// Manual must never be "due": it is the opt-out.
    #[test]
    fn manual_frequency_is_never_due() {
        let dir = tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        set_backup_frequency(&db, BackupFrequency::Manual).unwrap();
        mark_backup_dirty(&db);
        assert!(!backup_is_due_now(&db), "manual-only must not auto-upload");
    }

    /// The SQLCipher key must never be persisted beside the DB it unlocks. A
    /// briefly-shipped sidecar did exactly that; record-success now deletes any
    /// copy it finds and never writes one.
    #[test]
    fn success_never_leaves_a_key_sidecar_and_heals_a_legacy_one() {
        let dir = tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let sidecar = dir.path().join("marmot.sqlite.sonar-index-key");
        fs::write(&sidecar, "55".repeat(32)).unwrap();

        record_backup_success(&db, Some(1), Some(&"55".repeat(32))).unwrap();

        assert!(
            !sidecar.exists(),
            "legacy plaintext key sidecar must be deleted"
        );
        let leftovers: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| n.contains("index-key"))
            .collect();
        assert!(
            leftovers.is_empty(),
            "no key material on disk: {leftovers:?}"
        );
    }

    /// The Settings strip reports the uploaded blob, so a failed upload must not
    /// overwrite the last known-good size with nothing.
    #[test]
    fn success_records_size_and_failure_keeps_it() {
        let dir = tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        record_backup_success(&db, Some(282_748), None).unwrap();
        assert_eq!(load_backup_policy(&db).last_size_bytes, Some(282_748));

        record_backup_failure(&db, "network down").unwrap();
        let after = load_backup_policy(&db);
        assert_eq!(
            after.last_size_bytes,
            Some(282_748),
            "a failure must not erase the last good size",
        );
        assert_eq!(after.last_error.as_deref(), Some("network down"));

        // A success with no size reported leaves the previous one intact.
        record_backup_success(&db, None, None).unwrap();
        assert_eq!(load_backup_policy(&db).last_size_bytes, Some(282_748));
    }

    /// Storage counts the user's data and excludes logs — otherwise the number
    /// grows with diagnostics the row does not claim to measure.
    #[test]
    fn storage_counts_account_data_and_skips_logs() {
        let dir = tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        fs::write(&db, vec![7u8; 4096]).unwrap();
        fs::write(
            db.with_file_name("marmot.sqlite.sonar-index.db"),
            vec![1u8; 2048],
        )
        .unwrap();
        let media = dir.path().join("media");
        fs::create_dir_all(&media).unwrap();
        fs::write(media.join("blob.bin"), vec![2u8; 1024]).unwrap();
        let logs = dir.path().join("logs");
        fs::create_dir_all(&logs).unwrap();
        fs::write(logs.join("sonar-app.log"), vec![3u8; 500_000]).unwrap();

        let total = account_storage_bytes(&db);
        assert_eq!(total, 4096 + 2048 + 1024, "logs must be excluded: {total}");
    }

    #[test]
    fn server_scope_drops_url_normalized_trailing_slash() {
        for raw in ["https://nostr.download", "https://nostr.download/"] {
            let base = Url::parse(raw).unwrap();
            assert_eq!(blossom_server_scope(&base), "https://nostr.download");
        }
    }

    /// A server with no account backup for this pubkey must surface the typed
    /// missing error, not a transport error — that is the difference between
    /// "chats start empty" and "restore failed" in the host UI.
    #[tokio::test]
    async fn empty_list_is_a_missing_backup_not_a_failure() {
        let keys = Keys::generate();
        let (base, _seen) =
            spawn_mock_blossom_list(Keys::generate().public_key(), b"other".to_vec());
        let err = download_latest_sealed_backup_at(&keys, &base)
            .await
            .expect_err("no backup for this pubkey");
        assert!(
            matches!(err, Error::AccountBackupMissing),
            "expected AccountBackupMissing, got {err:?}",
        );
        assert!(is_missing_backup_error(&err));
    }

    /// `Authorization` header a mock saw on its list route. Per-server, not
    /// global: these tests run in parallel and each spawns its own mock.
    type SeenAuthorization = std::sync::Arc<std::sync::Mutex<Option<String>>>;

    /// Minimal BUD-01/03 server: `GET /list/<owner>` lists one account-backup
    /// descriptor, `GET /<sha>` serves it, everything else 404s — including the
    /// `/<pubkey>` route the upstream client's URL join would hit.
    fn spawn_mock_blossom_list(owner: PublicKey, blob: Vec<u8>) -> (Url, SeenAuthorization) {
        use sha2::Digest;
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock blossom");
        let port = listener.local_addr().unwrap().port();
        let base = format!("http://127.0.0.1:{port}");
        let base_for_thread = base.clone();
        let seen: SeenAuthorization = Default::default();
        let seen_for_thread = seen.clone();
        std::thread::spawn(move || {
            let sha = hex::encode(sha2::Sha256::digest(&blob));
            let list_path = format!("/list/{}", owner.to_hex());
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut buf = [0u8; 8192];
                let Ok(n) = stream.read(&mut buf) else {
                    continue;
                };
                let head = String::from_utf8_lossy(&buf[..n]).to_string();
                let path = head
                    .lines()
                    .next()
                    .unwrap_or("")
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or("")
                    .to_string();
                if path.starts_with("/list/") {
                    let authorization = head.lines().find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("authorization")
                            .then(|| value.trim().to_string())
                    });
                    *seen_for_thread.lock().unwrap() = authorization;
                }
                if path == list_path {
                    let json = format!(
                        "[{{\"url\":\"{base_for_thread}/{sha}\",\"sha256\":\"{sha}\",\
                         \"size\":{},\"type\":\"{ACCOUNT_BACKUP_MIME}\",\"uploaded\":7}}]",
                        blob.len()
                    );
                    let _ = stream.write_all(
                        format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\
                             Content-Length: {}\r\nConnection: close\r\n\r\n{json}",
                            json.len()
                        )
                        .as_bytes(),
                    );
                } else if path.trim_start_matches('/') == sha {
                    let _ = stream.write_all(
                        format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\
                             Content-Length: {}\r\nConnection: close\r\n\r\n",
                            blob.len()
                        )
                        .as_bytes(),
                    );
                    let _ = stream.write_all(&blob);
                } else if path.starts_with("/list/") {
                    // Another pubkey's listing: valid request, nothing stored.
                    let _ = stream.write_all(
                        b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\
                          Content-Length: 2\r\nConnection: close\r\n\r\n[]",
                    );
                } else {
                    let _ = stream.write_all(
                        b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    );
                }
                let _ = stream.flush();
            }
        });
        (Url::parse(&base).expect("mock base url"), seen)
    }

    /// A base with a path prefix (some servers mount Blossom under a subpath)
    /// must keep that prefix rather than have it replaced.
    #[test]
    fn list_url_preserves_a_base_path_prefix() {
        let keys = Keys::generate();
        let base = Url::parse("https://example.test/blossom/").unwrap();
        let built = backup_list_url(&base, &keys.public_key()).unwrap();
        assert_eq!(
            built.as_str(),
            format!(
                "https://example.test/blossom/list/{}",
                keys.public_key().to_hex()
            ),
        );
    }

    #[test]
    fn seal_open_roundtrip() {
        let keys = Keys::generate();
        let package = AccountBackupPackage {
            db_key_hex: "ab".repeat(32),
            db_bytes: b"fake-sqlcipher-bytes".to_vec(),
            index_bytes: Some(b"index".to_vec()),
        };
        let sealed = seal_account_backup(&secret_bytes(&keys), &package).unwrap();
        let opened = open_account_backup(&secret_bytes(&keys), &sealed).unwrap();
        assert_eq!(opened, package);
    }

    #[test]
    fn wrong_nsec_fails_decrypt() {
        let a = Keys::generate();
        let b = Keys::generate();
        let package = AccountBackupPackage {
            db_key_hex: "cd".repeat(32),
            db_bytes: vec![1, 2, 3, 4],
            index_bytes: None,
        };
        let sealed = seal_account_backup(&secret_bytes(&a), &package).unwrap();
        assert!(open_account_backup(&secret_bytes(&b), &sealed).is_err());
    }

    #[test]
    fn write_read_package_files() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        let package = AccountBackupPackage {
            db_key_hex: "ef".repeat(32),
            db_bytes: b"db-body".to_vec(),
            index_bytes: Some(b"idx-body".to_vec()),
        };
        write_account_backup_package(&db_path, &package).unwrap();
        // Checkpoint needs a real SQLCipher DB; skip read_account for fake bytes.
        let raw = std::fs::read(&db_path).unwrap();
        assert_eq!(raw, package.db_bytes);
        let index_path = index_db_path_for_db(&db_path);
        assert_eq!(std::fs::read(&index_path).unwrap(), b"idx-body");
    }

    #[test]
    fn staged_restore_commit_roundtrip() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        let package = AccountBackupPackage {
            db_key_hex: "aa".repeat(32),
            db_bytes: b"staged-db".to_vec(),
            index_bytes: Some(b"staged-idx".to_vec()),
        };
        write_account_backup_package(&staging_db_path(&db_path), &package).unwrap();
        assert!(!db_path.exists());
        commit_staged_account_restore(&db_path).unwrap();
        assert_eq!(std::fs::read(&db_path).unwrap(), b"staged-db");
        assert_eq!(
            std::fs::read(index_db_path_for_db(&db_path)).unwrap(),
            b"staged-idx"
        );
        assert!(!staging_db_path(&db_path).exists());
        // Idempotent retry must not clear the already-live DB.
        commit_staged_account_restore(&db_path).unwrap();
        assert_eq!(std::fs::read(&db_path).unwrap(), b"staged-db");
    }

    #[test]
    fn commit_promotes_leftover_staged_index_after_db_live() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        std::fs::write(&db_path, b"already-live").unwrap();
        let staged_index = index_db_path_for_db(&staging_db_path(&db_path));
        if let Some(parent) = staged_index.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(&staged_index, b"late-idx").unwrap();
        commit_staged_account_restore(&db_path).unwrap();
        assert_eq!(std::fs::read(&db_path).unwrap(), b"already-live");
        assert_eq!(
            std::fs::read(index_db_path_for_db(&db_path)).unwrap(),
            b"late-idx"
        );
        assert!(!staged_index.exists());
    }

    #[test]
    fn reconcile_commits_valid_staging() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        let key_hex = "22".repeat(32);
        let staged = staging_db_path(&db_path);
        {
            let conn = Connection::open(&staged).unwrap();
            conn.execute_batch(&format!("PRAGMA key = \"x'{key_hex}'\";"))
                .unwrap();
            conn.execute_batch("CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (7);")
                .unwrap();
        }
        mark_restore_intent(&db_path).unwrap();
        assert!(reconcile_staged_account_restore(&db_path, &key_hex).unwrap());
        assert!(db_path.is_file());
        assert!(!staged.is_file());
        assert!(
            !restore_intent_path(&db_path).exists(),
            "a committed restore must not re-arm reconcile on the next boot"
        );
    }

    /// Staging that nobody asked for must never be promoted. The dangerous
    /// shape is a backup taken by *this* install: the staged DB opens under the
    /// live key, so the key check cannot reject it, and promoting would roll
    /// the account back to the backup and drop every message since.
    #[test]
    fn reconcile_discards_staging_with_no_intent_marker() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        let key_hex = "55".repeat(32);
        // Live account, same key as the leftover staging.
        {
            let conn = Connection::open(&db_path).unwrap();
            conn.execute_batch(&format!("PRAGMA key = \"x'{key_hex}'\";"))
                .unwrap();
            conn.execute_batch("CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (99);")
                .unwrap();
        }
        let live_before = std::fs::read(&db_path).unwrap();
        let staged = staging_db_path(&db_path);
        {
            let conn = Connection::open(&staged).unwrap();
            conn.execute_batch(&format!("PRAGMA key = \"x'{key_hex}'\";"))
                .unwrap();
            conn.execute_batch("CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (1);")
                .unwrap();
        }
        // No mark_restore_intent: this staging is debris, not a restore.
        assert!(!reconcile_staged_account_restore(&db_path, &key_hex).unwrap());
        assert!(!staged.is_file(), "debris staging must be cleaned up");
        assert_eq!(
            std::fs::read(&db_path).unwrap(),
            live_before,
            "the live account must survive byte-identical"
        );
    }

    #[test]
    fn reconcile_aborts_wrong_key_staging() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        let key_hex = "33".repeat(32);
        let wrong = "44".repeat(32);
        let staged = staging_db_path(&db_path);
        {
            let conn = Connection::open(&staged).unwrap();
            conn.execute_batch(&format!("PRAGMA key = \"x'{key_hex}'\";"))
                .unwrap();
            conn.execute_batch("CREATE TABLE t (v INTEGER);").unwrap();
        }
        mark_restore_intent(&db_path).unwrap();
        assert!(!reconcile_staged_account_restore(&db_path, &wrong).unwrap());
        assert!(!staged.is_file());
        assert!(!db_path.is_file());
        assert!(!restore_intent_path(&db_path).exists());
    }

    #[test]
    fn checkpoint_then_read_real_sqlcipher() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        let key_hex = "11".repeat(32);
        {
            let conn = Connection::open(&db_path).unwrap();
            conn.execute_batch(&format!("PRAGMA key = \"x'{key_hex}'\";"))
                .unwrap();
            conn.execute_batch(
                "PRAGMA journal_mode = WAL; CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (42);",
            )
            .unwrap();
        }
        let package = read_account_backup_package(&db_path, &key_hex).unwrap();
        assert_eq!(package.db_key_hex, key_hex);
        assert!(!package.db_bytes.is_empty());
        // Round-trip write to a new path and verify SELECT still works.
        let restored = dir.path().join("restored.sqlite");
        write_account_backup_package(&restored, &package).unwrap();
        let conn = Connection::open(&restored).unwrap();
        conn.execute_batch(&format!("PRAGMA key = \"x'{key_hex}'\";"))
            .unwrap();
        let v: i64 = conn.query_row("SELECT v FROM t", [], |r| r.get(0)).unwrap();
        assert_eq!(v, 42);
    }

    #[test]
    fn policy_defaults_enabled_and_due_without_success() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        let policy = load_backup_policy(&db_path);
        assert!(policy.enabled);
        assert!(!policy.dirty);
        // Never backed up ⇒ daily floor makes it due immediately.
        assert!(backup_is_due(&policy, 1_700_000_000));
    }

    #[test]
    fn policy_corrupt_fails_closed() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        let path = backup_policy_path_for_db(&db_path);
        std::fs::write(&path, b"{not-json").unwrap();
        let policy = load_backup_policy(&db_path);
        assert!(!policy.enabled);
        assert!(!backup_is_due(&policy, 1_700_000_000));
        // Fail-closed must be persisted so a later load / onboarding helper
        // cannot silently re-enable from a missing-file default.
        let reloaded =
            serde_json::from_slice::<BackupPolicy>(&std::fs::read(&path).unwrap()).unwrap();
        assert!(!reloaded.enabled);
    }

    #[test]
    fn ensure_backup_policy_default_does_not_overwrite() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        set_backup_enabled(&db_path, false).unwrap();
        ensure_backup_policy_default(&db_path).unwrap();
        assert!(!load_backup_policy(&db_path).enabled);
    }

    #[test]
    fn mark_backup_dirty_hot_path_skips_rewrite_when_already_dirty() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        mark_backup_dirty(&db_path);
        let seq = load_backup_policy(&db_path).dirty_seq;
        mark_backup_dirty(&db_path);
        mark_backup_dirty(&db_path);
        assert_eq!(load_backup_policy(&db_path).dirty_seq, seq);
    }

    #[test]
    fn policy_dirty_respects_debounce() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        mark_backup_dirty(&db_path);
        let mut policy = load_backup_policy(&db_path);
        assert!(policy.dirty);
        policy.last_attempt_at = Some(1_000);
        policy.last_success_at = Some(1_000);
        assert!(!backup_is_due(&policy, 1_000 + 60)); // within debounce
        assert!(backup_is_due(
            &policy,
            1_000 + DEFAULT_OPPORTUNISTIC_DEBOUNCE_SECS
        ));
    }

    #[test]
    fn policy_disabled_never_due() {
        let mut policy = BackupPolicy::default();
        policy.enabled = false;
        policy.dirty = true;
        assert!(!backup_is_due(&policy, 1_700_000_000));
    }

    #[test]
    fn policy_success_clears_dirty_and_error() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        mark_backup_dirty(&db_path);
        record_backup_attempt(&db_path).unwrap();
        record_backup_failure(&db_path, "blossom down").unwrap();
        // Retry after failure still covers the same dirty_seq.
        record_backup_attempt(&db_path).unwrap();
        record_backup_success(&db_path, None, None).unwrap();
        let policy = load_backup_policy(&db_path);
        assert!(!policy.dirty);
        assert!(policy.last_error.is_none());
        assert!(policy.last_success_at.is_some());
        // Quiet + recent success ⇒ not due until daily floor.
        assert!(!backup_is_due(
            &policy,
            policy.last_success_at.unwrap() + 60
        ));
    }

    #[test]
    fn policy_success_keeps_dirty_when_remarked_after_attempt() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        mark_backup_dirty(&db_path);
        record_backup_attempt(&db_path).unwrap();
        // Message arrives while seal/upload is in flight.
        mark_backup_dirty(&db_path);
        record_backup_success(&db_path, None, None).unwrap();
        let policy = load_backup_policy(&db_path);
        assert!(policy.dirty, "post-seal dirty mark must survive success");
        assert!(policy.last_success_at.is_some());
    }

    #[test]
    fn policy_sidecar_roundtrips_with_fsync() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        let mut policy = BackupPolicy::default();
        policy.enabled = false;
        policy.dirty = true;
        policy.dirty_seq = 7;
        save_backup_policy(&db_path, &policy).unwrap();
        let loaded = load_backup_policy(&db_path);
        assert!(!loaded.enabled);
        assert!(loaded.dirty);
        assert_eq!(loaded.dirty_seq, 7);
    }

    /// Build a real account (SQLCipher DB + conversation index with summaries)
    /// and seal it, returning the sealed blob and the account dir.
    fn sealed_account_with_chats(keys: &Keys) -> (tempfile::TempDir, PathBuf, Vec<u8>) {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        let key_hex = "55".repeat(32);
        {
            let conn = Connection::open(&db_path).unwrap();
            conn.execute_batch(&format!("PRAGMA key = \"x'{key_hex}'\";"))
                .unwrap();
            conn.execute_batch("CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (9);")
                .unwrap();
        }
        let key: [u8; 32] = hex::decode(&key_hex).unwrap().try_into().unwrap();
        {
            let index = crate::conversation_index::ConversationIndex::open(
                &crate::conversation_index::index_db_path_for_db(&db_path),
                key,
            )
            .unwrap();
            index
                .upsert_summary(
                    "aa11",
                    "Lake crew",
                    "bringing the speaker",
                    "maya",
                    100,
                    false,
                    true,
                )
                .unwrap();
            index
                .upsert_summary(
                    "bb22",
                    "Maya",
                    "find me by the coffee table",
                    "maya",
                    200,
                    false,
                    true,
                )
                .unwrap();
            index
                .upsert_summary("bb22", "Maya", "on my way", "maya", 300, true, true)
                .unwrap();
        }
        let sealed = seal_account_backup_files(keys, &db_path, &key_hex).unwrap();
        (dir, db_path, sealed)
    }

    /// Snapshot every file in the account dir so a test can prove nothing moved.
    fn account_fingerprint(dir: &Path) -> Vec<(String, Vec<u8>)> {
        let mut out = Vec::new();
        if let Ok(entries) = fs::read_dir(dir) {
            for e in entries.flatten() {
                if e.file_type().map(|t| t.is_file()).unwrap_or(false) {
                    let name = e.file_name().to_string_lossy().to_string();
                    let bytes = fs::read(e.path()).unwrap_or_default();
                    out.push((name, bytes));
                }
            }
        }
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out
    }

    /// The dry run reports what a restore would recover.
    #[tokio::test]
    async fn preview_lists_the_chats_inside_the_backup() {
        let keys = Keys::generate();
        let (_dir, db, sealed) = sealed_account_with_chats(&keys);
        let (base, _seen) = spawn_mock_blossom_list(keys.public_key(), sealed.clone());

        let preview = preview_account_backup_from(&keys, &db, &[base])
            .await
            .unwrap();

        assert_eq!(preview.size_bytes, sealed.len() as u64);
        assert_eq!(
            preview.conversations.len(),
            2,
            "{:?}",
            preview.conversations
        );
        let maya = preview
            .conversations
            .iter()
            .find(|c| c.name == "Maya")
            .expect("Maya listed");
        assert_eq!(maya.message_count, 2, "counts come from the sealed index");
        assert_eq!(maya.latest_content, "on my way");
        assert_eq!(preview.total_messages, 3);
        assert_eq!(preview.uploaded_at_secs, 7, "descriptor timestamp");
    }

    /// The whole promise of a dry run: it changes nothing. If this regresses,
    /// a user previewing a backup could lose the chats they opened it to check.
    #[tokio::test]
    async fn preview_leaves_the_live_account_byte_identical() {
        let keys = Keys::generate();
        let (dir, db, sealed) = sealed_account_with_chats(&keys);
        let (base, _seen) = spawn_mock_blossom_list(keys.public_key(), sealed);

        let before = account_fingerprint(dir.path());
        assert!(!before.is_empty(), "fixture must have written files");

        preview_account_backup_from(&keys, &db, &[base])
            .await
            .unwrap();

        // The scratch dir now lives *inside* the account dir (it cannot live in
        // the process temp dir — see `preview_scratch_dir`), so assert it was
        // reaped: a leaked dir means a decrypted index outlived the call.
        let leftover_dirs: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .flatten()
            .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        assert!(
            leftover_dirs.is_empty(),
            "preview left scratch dirs behind: {leftover_dirs:?}"
        );

        let after = account_fingerprint(dir.path());
        assert_eq!(
            before.iter().map(|(n, _)| n).collect::<Vec<_>>(),
            after.iter().map(|(n, _)| n).collect::<Vec<_>>(),
            "a preview must not add or remove files (staging left behind?)",
        );
        for ((name, a), (_, b)) in before.iter().zip(after.iter()) {
            assert_eq!(a, b, "preview modified {name}");
        }
    }

    /// A server's `Content-Length` must never drive the allocation. Bounding
    /// the hint by `MAX_BACKUP_BYTES` looks safe and is not: a hostile host can
    /// advertise 200 MiB, send nothing, and the phone is out of memory before
    /// the first byte — on the restore path, which the user only reaches after
    /// they have already wiped.
    #[test]
    fn a_lying_content_length_cannot_size_the_download_buffer() {
        assert_eq!(download_buffer_capacity(None), 0);
        assert_eq!(download_buffer_capacity(Some(4096)), 4096, "honest small body");
        assert_eq!(
            download_buffer_capacity(Some(MAX_BACKUP_BYTES as u64)),
            INITIAL_DOWNLOAD_CAPACITY,
            "a body claiming the whole cap must not reserve the whole cap"
        );
        assert_eq!(
            download_buffer_capacity(Some(u64::MAX)),
            INITIAL_DOWNLOAD_CAPACITY,
            "an absurd claim must clamp, not overflow"
        );
        assert!(
            INITIAL_DOWNLOAD_CAPACITY < MAX_BACKUP_BYTES,
            "the hint must stay well under the hard cap"
        );
    }

    /// A restore must not be able to OOM the app. The advertised blob size is
    /// the server's own claim, so the ceiling has to bind the body itself:
    /// stop reading mid-stream rather than buffering whatever arrives.
    #[tokio::test]
    async fn download_refuses_a_body_over_the_cap() {
        use sha2::Digest;
        let keys = Keys::generate();
        let blob = vec![7u8; 4096];
        let sha = Sha256Hash::from_slice(&sha2::Sha256::digest(&blob)).unwrap();
        let (base, _seen) = spawn_mock_blossom_list(keys.public_key(), blob.clone());

        let err = download_blob_capped_to(&keys, &base, sha, 1024)
            .await
            .expect_err("4096 bytes must not pass a 1024 byte ceiling");
        assert!(
            err.to_string().contains("exceeds size cap"),
            "got {err:?}"
        );

        // Same blob, ample ceiling: the cap must not break honest restores.
        let ok = download_blob_capped_to(&keys, &base, sha, 8192)
            .await
            .expect("under the ceiling");
        assert_eq!(ok, blob);
    }

    /// No backup on the server is a typed miss, not a transport failure — hosts
    /// key their copy off that distinction.
    #[tokio::test]
    async fn preview_without_a_backup_reports_missing() {
        let keys = Keys::generate();
        let (base, _seen) =
            spawn_mock_blossom_list(Keys::generate().public_key(), b"someone else".to_vec());
        let dir = tempdir().unwrap();
        let err = preview_account_backup_from(&keys, &dir.path().join("marmot.sqlite"), &[base])
            .await
            .expect_err("nothing stored for this pubkey");
        assert!(is_missing_backup_error(&err), "got {err:?}");
    }

    /// Regression pin for the Android dry run. `tempfile::tempdir()` resolves
    /// `env::temp_dir()`, which on Android is `/tmp` (unset `TMPDIR`) — a
    /// `shell`-owned dir the app UID cannot write, so the preview failed on
    /// every device. The scratch must live beside the DB, in app-private
    /// storage, and must never depend on the process temp dir.
    #[test]
    fn preview_scratch_lives_beside_the_database() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("nested").join("marmot.sqlite");

        let scratch = preview_scratch_dir(&db_path).unwrap();
        let path = scratch.path().to_path_buf();

        assert!(
            path.starts_with(db_path.parent().unwrap()),
            "scratch {} escaped the account dir",
            path.display()
        );
        assert!(path.is_dir(), "scratch dir was not created (parent unmade?)");
        drop(scratch);
        assert!(!path.exists(), "scratch dir must be reaped on drop");
    }

    /// `TempDir` reaps on drop, which does not cover the process being killed
    /// mid-preview. A leftover sits in the account dir forever and is counted
    /// by `account_storage_bytes`, so one accumulates per kill.
    #[test]
    fn a_preview_reaps_scratch_left_by_a_killed_process() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        // Debris from a previous run that never got to drop its TempDir.
        let orphan = dir.path().join(format!("{PREVIEW_SCRATCH_PREFIX}dead"));
        fs::create_dir_all(&orphan).unwrap();
        fs::write(orphan.join("preview-index.db"), b"leftover").unwrap();
        // A real store file beside it must survive the sweep.
        fs::write(&db_path, b"live").unwrap();

        let scratch = preview_scratch_dir(&db_path).unwrap();

        assert!(!orphan.exists(), "stale scratch must be reaped");
        assert!(db_path.is_file(), "the sweep must not touch the account");
        assert!(scratch.path().is_dir(), "the fresh scratch still exists");
    }

    #[test]
    fn seal_account_backup_files_roundtrip_open() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        let key_hex = "55".repeat(32);
        {
            let conn = Connection::open(&db_path).unwrap();
            conn.execute_batch(&format!("PRAGMA key = \"x'{key_hex}'\";"))
                .unwrap();
            conn.execute_batch("CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (9);")
                .unwrap();
        }
        let keys = Keys::generate();
        let sealed = seal_account_backup_files(&keys, &db_path, &key_hex).unwrap();
        let opened = open_account_backup(&secret_bytes(&keys), &sealed).unwrap();
        assert_eq!(opened.db_key_hex, key_hex);
        assert!(!opened.db_bytes.is_empty());
    }
}
