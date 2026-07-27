//! Signal-style encrypted account backup (Marmot DB + SQLCipher key) on Blossom.
//!
//! The live SQLCipher `db_key` stays host-owned and random. This module only
//! wraps that key + DB bytes with a domain-separated key derived from the
//! account nsec so delete→reinstall→paste nsec can restore Marmot history.
//!
//! Blossom sees ciphertext only (`application/vnd.sonar.account-backup-v1`).

use std::fs;
use std::path::Path;

use ::hkdf::Hkdf;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use nostr::hashes::sha256::Hash as Sha256Hash;
use nostr::hashes::Hash;
use nostr::prelude::*;
use nostr_blossom::prelude::*;
use rusqlite::Connection;
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
/// Same fallback host as media uploads (`client::DEFAULT_BLOSSOM_SERVER`).
/// Duplicated here to avoid a client ↔ account_backup import cycle.
const DEFAULT_BLOSSOM_SERVER: &str = "https://nostr.download";
/// Soft ceiling for a downloaded backup (DB + index). Far above typical chats;
/// guards memory against a malicious Blossom response.
const MAX_BACKUP_BYTES: usize = 200 * 1024 * 1024;

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

/// BUD-03 `GET /list/<pubkey>` with a signed kind-24242 authorization.
///
/// Hand-rolled rather than `BlossomClient::list_blobs` — see [`backup_list_url`]
/// for why that path cannot reach the endpoint. The auth event mirrors what the
/// crate builds for every other verb, so servers see nothing unusual.
async fn list_account_backup_blobs(keys: &Keys, base: &Url) -> Result<Vec<BlobDescriptor>> {
    let url = backup_list_url(base, &keys.public_key())?;
    let authorization = BlossomAuthorization::new(
        "Blossom list authorization".to_string(),
        Timestamp::now() + std::time::Duration::from_secs(300),
        BlossomAuthorizationVerb::List,
        BlossomAuthorizationScope::ServerUrl(base.clone()),
    );
    let auth_event = EventBuilder::blossom_auth(authorization)
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

/// List this pubkey's blobs and download the newest account-backup MIME.
pub async fn download_latest_sealed_backup(keys: &Keys, server_url: &str) -> Result<Vec<u8>> {
    let base = blossom_base(server_url)?;
    download_latest_sealed_backup_at(keys, &base).await
}

/// Same, against an already-validated base. Split out so tests can drive the
/// real list → download → verify path against a loopback mock without
/// loosening the https requirement in [`blossom_base`].
async fn download_latest_sealed_backup_at(keys: &Keys, base: &Url) -> Result<Vec<u8>> {
    let client = BlossomClient::new(base.clone());
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

/// High-level: read local DB, seal with nsec, upload to Blossom.
pub async fn backup_account_files(
    keys: &Keys,
    db_path: &Path,
    db_key_hex: &str,
    server_url: &str,
) -> Result<AccountBackupUpload> {
    let package = read_account_backup_package(db_path, db_key_hex)?;
    let sealed = seal_account_backup(&secret_bytes(keys), &package)?;
    upload_sealed_backup(keys, server_url, sealed).await
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
        let base = spawn_mock_blossom_list(keys.public_key(), sealed.clone());
        let got = download_latest_sealed_backup_at(&keys, &base)
            .await
            .expect("restore must find the uploaded backup");
        assert_eq!(got, sealed);
    }

    /// A server with no account backup for this pubkey must surface the typed
    /// missing error, not a transport error — that is the difference between
    /// "chats start empty" and "restore failed" in the host UI.
    #[tokio::test]
    async fn empty_list_is_a_missing_backup_not_a_failure() {
        let keys = Keys::generate();
        let base = spawn_mock_blossom_list(Keys::generate().public_key(), b"other".to_vec());
        let err = download_latest_sealed_backup_at(&keys, &base)
            .await
            .expect_err("no backup for this pubkey");
        assert!(
            matches!(err, Error::AccountBackupMissing),
            "expected AccountBackupMissing, got {err:?}",
        );
        assert!(is_missing_backup_error(&err));
    }

    /// Minimal BUD-01/03 server: `GET /list/<owner>` lists one account-backup
    /// descriptor, `GET /<sha>` serves it, everything else 404s — including the
    /// `/<pubkey>` route the upstream client's URL join would hit.
    fn spawn_mock_blossom_list(owner: PublicKey, blob: Vec<u8>) -> Url {
        use sha2::Digest;
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock blossom");
        let port = listener.local_addr().unwrap().port();
        let base = format!("http://127.0.0.1:{port}");
        let base_for_thread = base.clone();
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
        Url::parse(&base).expect("mock base url")
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
}
