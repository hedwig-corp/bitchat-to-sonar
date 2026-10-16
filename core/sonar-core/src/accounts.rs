//! Account registry: several Marmot accounts per install, exactly one active.
//!
//! Layout (decided 2026-10-15, see `docs/plans/2026-10-15-multi-account-switcher.md`):
//!
//! ```text
//! <data_dir>/accounts.json                 registry (this module)
//! <data_dir>/marmot.sqlite                 the legacy single-account store, registered in place
//! <data_dir>/accounts/<pubkey_hex>/marmot.sqlite   every account added later
//! ```
//!
//! The core owns the registry file and the directory convention only. Secrets
//! (nsec, SQLCipher key) stay in the host keychain/keystore, named per account
//! through [`secret_key_name`]: the legacy account keeps the unsuffixed names
//! it has always had, so registering it never moves or rewrites a secret
//! (Account Key Durability Rule, invariant 1).
//!
//! Every store sidecar in this crate is derived from the `marmot.sqlite` path,
//! so a per-account directory isolates the index, outbox, push-token cache,
//! backup policy and restore staging without any further change.
//!
//! Failure shape: a registry file that exists but does not parse is an
//! [`Error::Storage`], never an empty registry. Hosts fall back to the legacy
//! single-account path for that launch and surface the error; they must not
//! mint a key or a store because of it (invariant 2).

use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex, MutexGuard};

use nostr::prelude::*;
use serde::{Deserialize, Serialize};

use crate::client::SonarClient;
use crate::{Error, Result};

/// Hard cap on registered accounts. Each one is a full Marmot store plus a
/// conversation index on disk, and the NSE/push path may open each of them
/// in turn, so the fan-out must stay small.
pub const MAX_ACCOUNTS: usize = 5;

/// Registry file name inside the data dir.
pub const REGISTRY_FILE_NAME: &str = "accounts.json";

/// Subdirectory of the data dir holding every non-legacy account.
pub const ACCOUNTS_SUBDIR: &str = "accounts";

/// Store file name inside an account directory (same as the legacy store).
pub const DB_FILE_NAME: &str = "marmot.sqlite";

/// On-disk registry format version.
const REGISTRY_VERSION: u32 = 1;

/// Every mutator runs its whole load → modify → save under this, so two
/// in-process callers can never lose each other's write. Cross-process
/// readers (the iOS NSE) only load; the atomic rename below keeps them
/// consistent.
static MUTATION_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

fn mutation_guard() -> MutexGuard<'static, ()> {
    MUTATION_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Distinguishes temp files written in the same process and second.
static SAVE_SEQ: AtomicU64 = AtomicU64::new(0);

/// One registered account.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountEntry {
    /// 64-char lowercase hex x-only public key. Primary key of the registry.
    pub pubkey_hex: String,
    /// `npub1...` form, derived from `pubkey_hex` on insert.
    pub npub: String,
    /// User-chosen label for the switcher. `None` renders the profile name.
    #[serde(default)]
    pub label: Option<String>,
    /// Store directory relative to the data dir. `""` is the legacy store
    /// that lives directly in the data dir; later accounts use
    /// `accounts/<pubkey_hex>`. Required on disk: a missing value must not
    /// silently reinterpret a row as the legacy namespace.
    pub store_dir: String,
    /// Suffix hosts append to their secret names. `""` keeps the legacy
    /// unsuffixed names; later accounts use their `pubkey_hex`. Required.
    pub secret_tag: String,
    /// Unix seconds.
    #[serde(default)]
    pub added_at: u64,
    /// Unix seconds of the last time this account was made active.
    #[serde(default)]
    pub last_active_at: u64,
}

impl AccountEntry {
    /// Absolute path of this account's `marmot.sqlite`.
    pub fn db_path(&self, data_dir: &Path) -> PathBuf {
        store_dir_path(data_dir, &self.store_dir).join(DB_FILE_NAME)
    }

    /// Whether this is the legacy in-place store.
    pub fn is_legacy(&self) -> bool {
        self.store_dir.is_empty()
    }
}

/// The registry file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountRegistry {
    pub version: u32,
    /// `pubkey_hex` of the active account, if any.
    #[serde(default)]
    pub active: Option<String>,
    /// Required on disk: `{"version":1}` must read as corrupt, not as a
    /// fresh install the legacy store may be registered over.
    pub accounts: Vec<AccountEntry>,
}

impl Default for AccountRegistry {
    fn default() -> Self {
        Self {
            version: REGISTRY_VERSION,
            active: None,
            accounts: Vec::new(),
        }
    }
}

/// Outcome of [`remove_account`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemovedAccount {
    pub removed: AccountEntry,
    /// The account that is active after the removal.
    pub new_active: AccountEntry,
}

/// Path of the registry file for `data_dir`.
pub fn registry_path(data_dir: &Path) -> PathBuf {
    data_dir.join(REGISTRY_FILE_NAME)
}

/// Resolve a relative `store_dir` against the data dir. `""` is the data dir.
pub fn store_dir_path(data_dir: &Path, store_dir: &str) -> PathBuf {
    if store_dir.is_empty() {
        data_dir.to_path_buf()
    } else {
        data_dir.join(store_dir)
    }
}

/// Store directory (relative) of a non-legacy account.
pub fn account_store_dir(pubkey_hex: &str) -> String {
    format!("{ACCOUNTS_SUBDIR}/{pubkey_hex}")
}

/// Pick a `(store_dir, secret_tag)` pair no existing row owns. Both are
/// opaque handles named after the key at add time; after
/// [`replace_pubkey`] a row can keep handles named after a key that is
/// later added again, so the plain names may be taken — then `-2`, `-3`…
fn free_slot(reg: &AccountRegistry, pubkey_hex: &str) -> (String, String) {
    let taken = |dir: &str, tag: &str| {
        reg.accounts
            .iter()
            .any(|a| a.store_dir == dir || a.secret_tag == tag)
    };
    let (dir, tag) = (account_store_dir(pubkey_hex), pubkey_hex.to_string());
    if !taken(&dir, &tag) {
        return (dir, tag);
    }
    for n in 2.. {
        let (dir, tag) = (
            format!("{ACCOUNTS_SUBDIR}/{pubkey_hex}-{n}"),
            format!("{pubkey_hex}-{n}"),
        );
        if !taken(&dir, &tag) {
            return (dir, tag);
        }
    }
    unreachable!("a free slot suffix always exists")
}

/// Host secret name for `base` under `secret_tag`: `base` for the legacy tag,
/// `base.<tag>` otherwise. Kept here so every host spells it the same way
/// and the NSE agrees with the app.
pub fn secret_key_name(base: &str, secret_tag: &str) -> String {
    if secret_tag.is_empty() {
        base.to_string()
    } else {
        format!("{base}.{secret_tag}")
    }
}

/// Normalise a public key given as 64-char hex or `npub1...` to lowercase
/// hex, and return its `npub` form too.
pub fn normalize_pubkey(input: &str) -> Result<(String, String)> {
    let trimmed = input.trim();
    let pk = PublicKey::parse(trimmed)
        .map_err(|e| Error::InvalidInput(format!("account pubkey: {e}")))?;
    let npub = pk
        .to_bech32()
        .map_err(|e| Error::InvalidInput(format!("account npub: {e}")))?;
    Ok((pk.to_hex(), npub))
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl AccountRegistry {
    /// Load the registry. A missing file is an empty registry; a file that
    /// exists but does not parse is an error (fail closed, see module doc).
    pub fn load(data_dir: &Path) -> Result<Self> {
        let path = registry_path(data_dir);
        let bytes = match fs::read(&path) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(e) => {
                return Err(Error::Storage(format!(
                    "account registry read {}: {e}",
                    path.display()
                )))
            }
        };
        let mut reg: Self = serde_json::from_slice(&bytes).map_err(|e| {
            Error::Storage(format!(
                "account registry corrupt at {}: {e}",
                path.display()
            ))
        })?;
        if reg.version == 0 || reg.version > REGISTRY_VERSION {
            return Err(Error::Storage(format!(
                "account registry version {} unsupported (this build reads {REGISTRY_VERSION})",
                reg.version
            )));
        }
        reg.version = REGISTRY_VERSION;
        reg.validate()?;
        // An active pointer at an entry that is gone is treated as "none":
        // hosts then pick the most recently active entry. Never an error, so
        // a half-written removal cannot lock the user out.
        if let Some(active) = &reg.active {
            if !reg.accounts.iter().any(|a| &a.pubkey_hex == active) {
                reg.active = None;
            }
        }
        Ok(reg)
    }

    /// Invariants a parseable file can still break: one row per key, one
    /// owner per store directory and per secret tag, directories that stay
    /// inside `accounts/`, the cap. Any of these makes the file an error — a
    /// removal would otherwise wipe a path another row (or `..`) points at.
    fn validate(&self) -> Result<()> {
        let bad = |why: String| Error::Storage(format!("account registry invalid: {why}"));
        if self.accounts.len() > MAX_ACCOUNTS {
            return Err(bad(format!(
                "{} accounts, cap is {MAX_ACCOUNTS}",
                self.accounts.len()
            )));
        }
        let mut keys = std::collections::HashSet::new();
        let mut dirs = std::collections::HashSet::new();
        let mut tags = std::collections::HashSet::new();
        for a in &self.accounts {
            if a.pubkey_hex.len() != 64 || !a.pubkey_hex.chars().all(|c| c.is_ascii_hexdigit()) {
                return Err(bad(format!("malformed pubkey {:?}", a.pubkey_hex)));
            }
            if !keys.insert(a.pubkey_hex.as_str()) {
                return Err(bad(format!("duplicate pubkey {}", a.pubkey_hex)));
            }
            if !dirs.insert(a.store_dir.as_str()) {
                return Err(bad(format!("store dir {:?} owned twice", a.store_dir)));
            }
            if !tags.insert(a.secret_tag.as_str()) {
                return Err(bad(format!("secret tag {:?} owned twice", a.secret_tag)));
            }
            if !a.store_dir.is_empty() {
                // Exactly `accounts/<slot>`: one non-empty slot of hex and
                // `-`, no trailing slash, no nesting. The container itself
                // (`accounts/`) or a nested path would make a removal
                // delete other accounts' stores.
                let slot = a.store_dir.strip_prefix(&format!("{ACCOUNTS_SUBDIR}/"));
                let canonical = slot.is_some_and(|slot| {
                    !slot.is_empty() && slot.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
                });
                if !canonical {
                    return Err(bad(format!(
                        "store dir {:?} is not accounts/<slot>",
                        a.store_dir
                    )));
                }
            }
        }
        Ok(())
    }

    /// Persist atomically: unique tmp + fsync + rename + parent fsync, the
    /// same shape as the backup-policy sidecar.
    pub fn save(&self, data_dir: &Path) -> Result<()> {
        self.validate()?;
        let path = registry_path(data_dir);
        fs::create_dir_all(data_dir).map_err(|e| {
            Error::Storage(format!(
                "account registry mkdir {}: {e}",
                data_dir.display()
            ))
        })?;
        let bytes = serde_json::to_vec_pretty(self)
            .map_err(|e| Error::Storage(format!("account registry encode: {e}")))?;
        let tmp = path.with_file_name(format!(
            "{REGISTRY_FILE_NAME}.{}.{}.{}.tmp",
            std::process::id(),
            now_secs(),
            SAVE_SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        {
            let mut f = File::create(&tmp).map_err(|e| {
                Error::Storage(format!("account registry create {}: {e}", tmp.display()))
            })?;
            f.write_all(&bytes).map_err(|e| {
                Error::Storage(format!("account registry write {}: {e}", tmp.display()))
            })?;
            f.sync_all().map_err(|e| {
                Error::Storage(format!("account registry fsync {}: {e}", tmp.display()))
            })?;
        }
        fs::rename(&tmp, &path).map_err(|e| {
            Error::Storage(format!("account registry rename {}: {e}", path.display()))
        })?;
        // The rename is only durable once the directory entry is: a crash
        // before that can resurrect the previous registry after a reported
        // success, which is exactly the registry/keychain drift this file
        // exists to prevent.
        // On Windows a directory handle needs FILE_FLAG_BACKUP_SEMANTICS and
        // FlushFileBuffers on it is best effort: NTFS journals the rename's
        // metadata, but a power loss right after a reported success can still
        // surface the previous registry. No Sonar build ships on Windows; the
        // attempt is made and a refusal is logged rather than failing every
        // registry write on a platform this cannot be verified on.
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
            let flushed = fs::OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
                .open(data_dir)
                .and_then(|dir| dir.sync_all());
            if let Err(e) = flushed {
                tracing::warn!(
                    "account registry: directory flush unavailable on Windows ({}): {e}",
                    data_dir.display()
                );
            }
        }
        #[cfg(not(windows))]
        {
            let dir = File::open(data_dir).map_err(|e| {
                Error::Storage(format!(
                    "account registry open dir {}: {e}",
                    data_dir.display()
                ))
            })?;
            dir.sync_all().map_err(|e| {
                Error::Storage(format!(
                    "account registry fsync dir {}: {e}",
                    data_dir.display()
                ))
            })?;
        }
        Ok(())
    }

    /// The active entry, or the most recently active one when the pointer is
    /// unset, or `None` for an empty registry.
    pub fn active(&self) -> Option<&AccountEntry> {
        if let Some(active) = &self.active {
            if let Some(e) = self.accounts.iter().find(|a| &a.pubkey_hex == active) {
                return Some(e);
            }
        }
        self.accounts.iter().max_by_key(|a| a.last_active_at)
    }

    /// Entry by hex pubkey.
    pub fn get(&self, pubkey_hex: &str) -> Option<&AccountEntry> {
        self.accounts.iter().find(|a| a.pubkey_hex == pubkey_hex)
    }

    fn get_mut(&mut self, pubkey_hex: &str) -> Option<&mut AccountEntry> {
        self.accounts
            .iter_mut()
            .find(|a| a.pubkey_hex == pubkey_hex)
    }

    /// Whether the legacy slot (store dir `""`, secret tag `""`) is taken.
    pub fn legacy_entry(&self) -> Option<&AccountEntry> {
        self.accounts.iter().find(|a| a.is_legacy())
    }
}

/// Register the pre-registry single-account store in place as `pubkey`.
///
/// Idempotent: calling it again for the same key returns the existing entry
/// untouched. Refuses when the legacy slot already belongs to a different
/// key, because two accounts can never share the unsuffixed secret names.
/// Makes the entry active when nothing is active yet.
pub fn register_legacy(data_dir: &Path, pubkey: &str) -> Result<AccountEntry> {
    let (pubkey_hex, npub) = normalize_pubkey(pubkey)?;
    let _guard = mutation_guard();
    let mut reg = AccountRegistry::load(data_dir)?;
    if let Some(existing) = reg.get(&pubkey_hex) {
        return Ok(existing.clone());
    }
    if let Some(legacy) = reg.legacy_entry() {
        return Err(Error::Storage(format!(
            "legacy store already registered to {}; refusing to re-register it to {npub}",
            legacy.npub
        )));
    }
    if reg.accounts.len() >= MAX_ACCOUNTS {
        return Err(Error::InvalidInput(format!(
            "account limit reached ({MAX_ACCOUNTS})"
        )));
    }
    let now = now_secs();
    let entry = AccountEntry {
        pubkey_hex: pubkey_hex.clone(),
        npub,
        label: None,
        store_dir: String::new(),
        secret_tag: String::new(),
        added_at: now,
        last_active_at: now,
    };
    reg.accounts.push(entry.clone());
    if reg.active.is_none() {
        reg.active = Some(pubkey_hex);
    }
    reg.save(data_dir)?;
    Ok(entry)
}

/// Add a new account under `accounts/<hex>/`, creating the directory.
///
/// An already-registered key returns its existing entry unchanged: hosts
/// treat "add the key I already have" as a switch, never as a replacement
/// (R-023). Does not change the active account.
pub fn add_account(data_dir: &Path, pubkey: &str, label: Option<&str>) -> Result<AccountEntry> {
    let (pubkey_hex, npub) = normalize_pubkey(pubkey)?;
    let _guard = mutation_guard();
    let mut reg = AccountRegistry::load(data_dir)?;
    if let Some(existing) = reg.get(&pubkey_hex) {
        return Ok(existing.clone());
    }
    if reg.accounts.len() >= MAX_ACCOUNTS {
        return Err(Error::InvalidInput(format!(
            "account limit reached ({MAX_ACCOUNTS})"
        )));
    }
    let (store_dir, secret_tag) = free_slot(&reg, &pubkey_hex);
    let dir = store_dir_path(data_dir, &store_dir);
    fs::create_dir_all(&dir)
        .map_err(|e| Error::Storage(format!("account dir mkdir {}: {e}", dir.display())))?;
    let now = now_secs();
    let entry = AccountEntry {
        pubkey_hex,
        npub,
        label: label
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty()),
        store_dir,
        secret_tag,
        added_at: now,
        last_active_at: 0,
    };
    reg.accounts.push(entry.clone());
    reg.save(data_dir)?;
    Ok(entry)
}

/// Make `pubkey` the active account and stamp `last_active_at`.
pub fn set_active(data_dir: &Path, pubkey: &str) -> Result<AccountEntry> {
    let (pubkey_hex, _) = normalize_pubkey(pubkey)?;
    let _guard = mutation_guard();
    let mut reg = AccountRegistry::load(data_dir)?;
    let now = now_secs();
    let entry = reg
        .get_mut(&pubkey_hex)
        .ok_or_else(|| Error::InvalidInput(format!("account not registered: {pubkey_hex}")))?;
    entry.last_active_at = now;
    let entry = entry.clone();
    reg.active = Some(pubkey_hex);
    reg.save(data_dir)?;
    Ok(entry)
}

/// Set or clear the switcher label.
pub fn set_label(data_dir: &Path, pubkey: &str, label: Option<&str>) -> Result<AccountEntry> {
    let (pubkey_hex, _) = normalize_pubkey(pubkey)?;
    let _guard = mutation_guard();
    let mut reg = AccountRegistry::load(data_dir)?;
    let entry = reg
        .get_mut(&pubkey_hex)
        .ok_or_else(|| Error::InvalidInput(format!("account not registered: {pubkey_hex}")))?;
    entry.label = label
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty());
    let entry = entry.clone();
    reg.save(data_dir)?;
    Ok(entry)
}

/// An nsec restore replaced the key behind `old` with `new` in place (the
/// store was wiped and refilled under the same directory and the same secret
/// names). Point the registry row at the new key. An empty registry (a
/// pre-registry install) is a no-op; a registry that has rows but not `old`
/// is an error — the host's idea of the active account has drifted from the
/// file, and the restore must not proceed under the wrong row. `new`
/// already registered elsewhere is an error too. `store_dir` and
/// `secret_tag` stay as they were: both are opaque handles ([`free_slot`]
/// steps around them when that key is added again).
pub fn replace_pubkey(data_dir: &Path, old: &str, new: &str) -> Result<Option<AccountEntry>> {
    let (old_hex, _) = normalize_pubkey(old)?;
    let (new_hex, new_npub) = normalize_pubkey(new)?;
    let _guard = mutation_guard();
    let mut reg = AccountRegistry::load(data_dir)?;
    if reg.accounts.is_empty() {
        return Ok(None);
    }
    if reg.get(&old_hex).is_none() {
        return Err(Error::Storage(format!(
            "account registry drift: no row for {old_hex}; refusing to repoint"
        )));
    }
    if old_hex != new_hex && reg.get(&new_hex).is_some() {
        return Err(Error::InvalidInput(format!(
            "account already registered: {new_npub}"
        )));
    }
    let entry = reg.get_mut(&old_hex).expect("checked above");
    entry.pubkey_hex = new_hex.clone();
    entry.npub = new_npub;
    let entry = entry.clone();
    if reg.active.as_deref() == Some(old_hex.as_str()) {
        reg.active = Some(new_hex);
    }
    reg.save(data_dir)?;
    Ok(Some(entry))
}

/// Remove `pubkey`: wipe its store and sidecars, delete its `accounts/<hex>`
/// directory (never the data dir itself, which holds logs and the other
/// accounts), and drop it from the registry. Refuses to remove the last
/// account — that is a wipe, not a removal. When the removed account was
/// active, the most recently active remaining account becomes active.
///
/// Call with no live node on that store. The host clears the account's
/// secrets afterwards, using the returned entry's `secret_tag`.
pub fn remove_account(data_dir: &Path, pubkey: &str) -> Result<RemovedAccount> {
    let (pubkey_hex, _) = normalize_pubkey(pubkey)?;
    let _guard = mutation_guard();
    let mut reg = AccountRegistry::load(data_dir)?;
    let idx = reg
        .accounts
        .iter()
        .position(|a| a.pubkey_hex == pubkey_hex)
        .ok_or_else(|| Error::InvalidInput(format!("account not registered: {pubkey_hex}")))?;
    if reg.accounts.len() == 1 {
        return Err(Error::InvalidInput(
            "cannot remove the only account; use wipe instead".into(),
        ));
    }
    let removed = reg.accounts.remove(idx);
    let new_active = if reg.active.as_deref() == Some(pubkey_hex.as_str()) || reg.active.is_none() {
        let next = reg
            .accounts
            .iter()
            .max_by_key(|a| a.last_active_at)
            .cloned()
            .expect("at least one account remains");
        reg.active = Some(next.pubkey_hex.clone());
        next
    } else {
        reg.active().cloned().expect("active entry present")
    };
    // Registry first: a crash after this point leaves orphan files, never a
    // registry entry pointing at a half-wiped store.
    reg.save(data_dir)?;
    let db_path = removed.db_path(data_dir);
    SonarClient::wipe_database(&db_path)?;
    if !removed.is_legacy() {
        let dir = store_dir_path(data_dir, &removed.store_dir);
        if dir.starts_with(data_dir) && dir != data_dir {
            if let Err(e) = fs::remove_dir_all(&dir) {
                if e.kind() != std::io::ErrorKind::NotFound {
                    tracing::warn!(path = %dir.display(), %e, "account dir not fully removed");
                }
            }
        }
    }
    Ok(RemovedAccount {
        removed,
        new_active,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;

    fn hex_of(id: &Identity) -> String {
        id.public_key().to_hex()
    }

    #[test]
    fn missing_registry_is_empty_not_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let reg = AccountRegistry::load(dir.path()).unwrap();
        assert!(reg.accounts.is_empty());
        assert!(reg.active().is_none());
    }

    #[test]
    fn corrupt_registry_is_an_error_not_empty() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(registry_path(dir.path()), b"{not json").unwrap();
        let err = AccountRegistry::load(dir.path()).unwrap_err();
        assert!(matches!(err, Error::Storage(_)), "{err}");
    }

    #[test]
    fn legacy_registration_is_in_place_and_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let id = Identity::generate();
        let a = register_legacy(dir.path(), &hex_of(&id)).unwrap();
        assert!(a.is_legacy());
        assert_eq!(a.secret_tag, "");
        assert_eq!(a.db_path(dir.path()), dir.path().join(DB_FILE_NAME));
        assert_eq!(a.npub, id.npub());
        let again = register_legacy(dir.path(), &id.npub()).unwrap();
        assert_eq!(a, again);
        let reg = AccountRegistry::load(dir.path()).unwrap();
        assert_eq!(reg.accounts.len(), 1);
        assert_eq!(reg.active().unwrap().pubkey_hex, a.pubkey_hex);
    }

    #[test]
    fn legacy_slot_is_never_given_to_a_second_key() {
        let dir = tempfile::tempdir().unwrap();
        register_legacy(dir.path(), &hex_of(&Identity::generate())).unwrap();
        let err = register_legacy(dir.path(), &hex_of(&Identity::generate())).unwrap_err();
        assert!(matches!(err, Error::Storage(_)), "{err}");
    }

    #[test]
    fn added_accounts_get_their_own_dir_and_tag() {
        let dir = tempfile::tempdir().unwrap();
        let legacy = Identity::generate();
        register_legacy(dir.path(), &hex_of(&legacy)).unwrap();
        let b = Identity::generate();
        let entry = add_account(dir.path(), &hex_of(&b), Some("  work ")).unwrap();
        assert_eq!(entry.store_dir, format!("accounts/{}", hex_of(&b)));
        assert_eq!(entry.secret_tag, hex_of(&b));
        assert_eq!(entry.label.as_deref(), Some("work"));
        assert!(store_dir_path(dir.path(), &entry.store_dir).is_dir());
        // Adding does not switch.
        let reg = AccountRegistry::load(dir.path()).unwrap();
        assert_eq!(reg.active().unwrap().pubkey_hex, hex_of(&legacy));
    }

    #[test]
    fn adding_a_registered_key_returns_it_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let legacy = Identity::generate();
        let a = register_legacy(dir.path(), &hex_of(&legacy)).unwrap();
        let same = add_account(dir.path(), &legacy.npub(), Some("ignored")).unwrap();
        assert_eq!(a, same);
        assert_eq!(AccountRegistry::load(dir.path()).unwrap().accounts.len(), 1);
    }

    #[test]
    fn cap_is_enforced() {
        let dir = tempfile::tempdir().unwrap();
        for _ in 0..MAX_ACCOUNTS {
            add_account(dir.path(), &hex_of(&Identity::generate()), None).unwrap();
        }
        let err = add_account(dir.path(), &hex_of(&Identity::generate()), None).unwrap_err();
        assert!(matches!(err, Error::InvalidInput(_)), "{err}");
    }

    #[test]
    fn set_active_stamps_and_switches() {
        let dir = tempfile::tempdir().unwrap();
        let a = Identity::generate();
        let b = Identity::generate();
        register_legacy(dir.path(), &hex_of(&a)).unwrap();
        add_account(dir.path(), &hex_of(&b), None).unwrap();
        let e = set_active(dir.path(), &hex_of(&b)).unwrap();
        assert!(e.last_active_at > 0);
        let reg = AccountRegistry::load(dir.path()).unwrap();
        assert_eq!(reg.active.as_deref(), Some(hex_of(&b).as_str()));
        let err = set_active(dir.path(), &hex_of(&Identity::generate())).unwrap_err();
        assert!(matches!(err, Error::InvalidInput(_)));
    }

    #[test]
    fn remove_wipes_only_the_removed_dir_and_refuses_the_last() {
        let dir = tempfile::tempdir().unwrap();
        let a = Identity::generate();
        let b = Identity::generate();
        let legacy = register_legacy(dir.path(), &hex_of(&a)).unwrap();
        let added = add_account(dir.path(), &hex_of(&b), None).unwrap();
        fs::write(legacy.db_path(dir.path()), b"legacy").unwrap();
        fs::write(added.db_path(dir.path()), b"added").unwrap();
        set_active(dir.path(), &hex_of(&b)).unwrap();

        let out = remove_account(dir.path(), &hex_of(&b)).unwrap();
        assert_eq!(out.removed.pubkey_hex, hex_of(&b));
        assert_eq!(out.new_active.pubkey_hex, hex_of(&a));
        assert!(!store_dir_path(dir.path(), &added.store_dir).exists());
        assert!(
            legacy.db_path(dir.path()).exists(),
            "other account untouched"
        );
        let reg = AccountRegistry::load(dir.path()).unwrap();
        assert_eq!(reg.active.as_deref(), Some(hex_of(&a).as_str()));

        let err = remove_account(dir.path(), &hex_of(&a)).unwrap_err();
        assert!(matches!(err, Error::InvalidInput(_)), "{err}");
        assert!(legacy.db_path(dir.path()).exists());
    }

    #[test]
    fn removing_the_legacy_account_keeps_the_data_dir() {
        let dir = tempfile::tempdir().unwrap();
        let a = Identity::generate();
        let b = Identity::generate();
        let legacy = register_legacy(dir.path(), &hex_of(&a)).unwrap();
        add_account(dir.path(), &hex_of(&b), None).unwrap();
        fs::write(legacy.db_path(dir.path()), b"legacy").unwrap();
        fs::create_dir_all(dir.path().join("logs")).unwrap();
        let out = remove_account(dir.path(), &hex_of(&a)).unwrap();
        assert!(out.removed.is_legacy());
        assert!(!legacy.db_path(dir.path()).exists());
        assert!(dir.path().join("logs").is_dir(), "logs survive");
        assert!(registry_path(dir.path()).is_file());
    }

    #[test]
    fn dangling_active_pointer_falls_back_to_most_recent() {
        let dir = tempfile::tempdir().unwrap();
        let a = Identity::generate();
        let b = Identity::generate();
        register_legacy(dir.path(), &hex_of(&a)).unwrap();
        add_account(dir.path(), &hex_of(&b), None).unwrap();
        let mut reg = AccountRegistry::load(dir.path()).unwrap();
        reg.active = Some("ff".repeat(32));
        reg.save(dir.path()).unwrap();
        let reg = AccountRegistry::load(dir.path()).unwrap();
        assert_eq!(reg.active, None);
        assert_eq!(reg.active().unwrap().pubkey_hex, hex_of(&a));
    }

    #[test]
    fn restore_in_place_repoints_the_row_and_keeps_its_handles() {
        let dir = tempfile::tempdir().unwrap();
        let a = Identity::generate();
        let b = Identity::generate();
        let c = Identity::generate();
        register_legacy(dir.path(), &hex_of(&a)).unwrap();
        let added = add_account(dir.path(), &hex_of(&b), None).unwrap();
        set_active(dir.path(), &hex_of(&b)).unwrap();

        // Restore C's nsec over B's slot.
        let moved = replace_pubkey(dir.path(), &hex_of(&b), &hex_of(&c))
            .unwrap()
            .unwrap();
        assert_eq!(moved.pubkey_hex, hex_of(&c));
        assert_eq!(moved.npub, c.npub());
        assert_eq!(
            moved.store_dir, added.store_dir,
            "directory handle unchanged"
        );
        assert_eq!(moved.secret_tag, added.secret_tag, "secret names unchanged");
        let reg = AccountRegistry::load(dir.path()).unwrap();
        assert_eq!(reg.active.as_deref(), Some(hex_of(&c).as_str()));
        assert!(reg.get(&hex_of(&b)).is_none());

        // Unknown old key on a populated registry: drift, refused.
        let err =
            replace_pubkey(dir.path(), &hex_of(&Identity::generate()), &hex_of(&b)).unwrap_err();
        assert!(matches!(err, Error::Storage(_)), "{err}");
        // Empty registry: nothing to do (pre-registry install).
        let empty = tempfile::tempdir().unwrap();
        assert!(replace_pubkey(empty.path(), &hex_of(&a), &hex_of(&b))
            .unwrap()
            .is_none());
        // Restoring a key that already has its own row is refused.
        let err = replace_pubkey(dir.path(), &hex_of(&c), &hex_of(&a)).unwrap_err();
        assert!(matches!(err, Error::InvalidInput(_)), "{err}");
    }

    /// After C was restored over B's slot, adding B again must not reuse
    /// B's old directory and secret names: C still owns them.
    #[test]
    fn re_adding_a_replaced_key_gets_a_fresh_slot() {
        let dir = tempfile::tempdir().unwrap();
        let a = Identity::generate();
        let b = Identity::generate();
        let c = Identity::generate();
        register_legacy(dir.path(), &hex_of(&a)).unwrap();
        let b_row = add_account(dir.path(), &hex_of(&b), None).unwrap();
        replace_pubkey(dir.path(), &hex_of(&b), &hex_of(&c)).unwrap();
        let b_again = add_account(dir.path(), &hex_of(&b), None).unwrap();
        assert_ne!(b_again.store_dir, b_row.store_dir);
        assert_ne!(b_again.secret_tag, b_row.secret_tag);
        assert_eq!(b_again.store_dir, format!("accounts/{}-2", hex_of(&b)));
        assert_eq!(b_again.secret_tag, format!("{}-2", hex_of(&b)));
        assert_eq!(
            secret_key_name("nsec", &b_again.secret_tag),
            format!("nsec.{}-2", hex_of(&b))
        );
        AccountRegistry::load(dir.path()).unwrap();
    }

    #[test]
    fn a_registry_that_breaks_an_invariant_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let a = Identity::generate();
        let b = Identity::generate();
        register_legacy(dir.path(), &hex_of(&a)).unwrap();
        add_account(dir.path(), &hex_of(&b), None).unwrap();
        let path = registry_path(dir.path());
        let good = fs::read_to_string(&path).unwrap();

        // Two rows pointing at one directory (the legacy one).
        let dup = good.replace(&format!("accounts/{}", hex_of(&b)), "");
        fs::write(&path, dup).unwrap();
        assert!(matches!(
            AccountRegistry::load(dir.path()).unwrap_err(),
            Error::Storage(_)
        ));

        // A directory that escapes accounts/.
        let escape = good.replace(&format!("accounts/{}", hex_of(&b)), "accounts/../../victim");
        fs::write(&path, escape).unwrap();
        assert!(matches!(
            AccountRegistry::load(dir.path()).unwrap_err(),
            Error::Storage(_)
        ));

        fs::write(&path, good).unwrap();
        AccountRegistry::load(dir.path()).unwrap();
    }

    #[test]
    fn the_accounts_container_or_a_nested_dir_is_not_a_slot() {
        let dir = tempfile::tempdir().unwrap();
        let a = Identity::generate();
        let b = Identity::generate();
        register_legacy(dir.path(), &hex_of(&a)).unwrap();
        add_account(dir.path(), &hex_of(&b), None).unwrap();
        let path = registry_path(dir.path());
        let good = fs::read_to_string(&path).unwrap();
        let own = format!("accounts/{}", hex_of(&b));
        for bad in [
            "accounts/".to_string(),
            format!("{own}/"),
            format!("{own}/inner"),
            "accounts/../x".to_string(),
        ] {
            fs::write(&path, good.replace(&own, &bad)).unwrap();
            assert!(
                matches!(
                    AccountRegistry::load(dir.path()).unwrap_err(),
                    Error::Storage(_)
                ),
                "{bad} must be rejected"
            );
        }
        fs::write(&path, good).unwrap();
        AccountRegistry::load(dir.path()).unwrap();
    }

    #[test]
    fn a_registry_missing_its_accounts_field_is_corrupt_not_empty() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(registry_path(dir.path()), br#"{"version":1}"#).unwrap();
        assert!(matches!(
            AccountRegistry::load(dir.path()).unwrap_err(),
            Error::Storage(_)
        ));
        // A row without its ownership metadata is corrupt too.
        let a = Identity::generate();
        fs::write(
            registry_path(dir.path()),
            format!(
                r#"{{"version":1,"accounts":[{{"pubkey_hex":"{}","npub":"{}"}}]}}"#,
                hex_of(&a),
                a.npub()
            ),
        )
        .unwrap();
        assert!(matches!(
            AccountRegistry::load(dir.path()).unwrap_err(),
            Error::Storage(_)
        ));
    }

    #[test]
    fn secret_names_follow_the_tag() {
        assert_eq!(secret_key_name("marmot-nsec", ""), "marmot-nsec");
        assert_eq!(secret_key_name("marmot-nsec", "abcd"), "marmot-nsec.abcd");
        assert_eq!(secret_key_name("dbKeyHex", "abcd"), "dbKeyHex.abcd");
    }

    #[test]
    fn save_leaves_no_tmp_behind() {
        let dir = tempfile::tempdir().unwrap();
        add_account(dir.path(), &hex_of(&Identity::generate()), None).unwrap();
        let leftovers: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty());
    }
}
