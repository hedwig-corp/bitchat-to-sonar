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
/// Distinct MIME so `list_blobs` can pick account backups among media.
pub const ACCOUNT_BACKUP_MIME: &str = "application/vnd.sonar.account-backup-v1";
/// Same fallback host as media uploads (`client::DEFAULT_BLOSSOM_SERVER`).
/// Duplicated here to avoid a client ↔ account_backup import cycle.
const DEFAULT_BLOSSOM_SERVER: &str = "https://nostr.download";
/// Soft ceiling for a downloaded backup (DB + index). Far above typical chats;
/// guards memory against a malicious Blossom response.
const MAX_BACKUP_BYTES: usize = 200 * 1024 * 1024;
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
    fs::rename(&tmp, &path)
        .map_err(|e| Error::InvalidInput(format!("backup policy rename {}: {e}", path.display())))?;
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
    if last_attempt > 0 && now_secs.saturating_sub(last_attempt) < policy.opportunistic_debounce_secs
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

pub fn record_backup_success(db_path: &Path) -> Result<()> {
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
pub fn seal_account_backup(nsec_secret: &[u8; 32], package: &AccountBackupPackage) -> Result<Vec<u8>> {
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
    if db_key_hex.len() != 64 || hex::decode(db_key_hex).map(|b| b.len() != 32).unwrap_or(true) {
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
pub fn read_account_backup_package(db_path: &Path, db_key_hex: &str) -> Result<AccountBackupPackage> {
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

fn staging_db_path(db_path: &Path) -> std::path::PathBuf {
    let mut staged = db_path.as_os_str().to_owned();
    staged.push(RESTORE_STAGING_SUFFIX);
    std::path::PathBuf::from(staged)
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

/// List this pubkey's blobs and download the newest account-backup MIME.
pub async fn download_latest_sealed_backup(keys: &Keys, server_url: &str) -> Result<Vec<u8>> {
    let base = blossom_base(server_url)?;
    let client = BlossomClient::new(base);
    let pubkey = keys.public_key();
    let mut blobs = client
        .list_blobs(&pubkey, None, None, None, Some(keys))
        .await
        .map_err(|e| Error::Blossom(e.to_string()))?;
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
    let data = client
        .get_blob(latest.sha256, None, None, Some(keys))
        .await
        .map_err(|e| Error::Blossom(e.to_string()))?;
    if data.len() > MAX_BACKUP_BYTES {
        return Err(Error::Blossom("downloaded backup exceeds size cap".into()));
    }
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
pub fn seal_account_backup_files(
    keys: &Keys,
    db_path: &Path,
    db_key_hex: &str,
) -> Result<Vec<u8>> {
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
    match upload_sealed_backup(keys, server_url, sealed).await {
        Ok(uploaded) => {
            let _ = record_backup_success(db_path);
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
        assert!(reconcile_staged_account_restore(&db_path, &key_hex).unwrap());
        assert!(db_path.is_file());
        assert!(!staged.is_file());
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
        assert!(!reconcile_staged_account_restore(&db_path, &wrong).unwrap());
        assert!(!staged.is_file());
        assert!(!db_path.is_file());
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
            conn.execute_batch("PRAGMA journal_mode = WAL; CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (42);")
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
        let reloaded = serde_json::from_slice::<BackupPolicy>(&std::fs::read(&path).unwrap()).unwrap();
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
        record_backup_success(&db_path).unwrap();
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
        record_backup_success(&db_path).unwrap();
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
