use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{MigrateError, Result};

pub const JOURNAL_FILE: &str = "cashu.migration.v1.json";
pub const JOURNAL_TMP_FILE: &str = "cashu.migration.v1.json.tmp";
pub const JOURNAL_LOCK_FILE: &str = "cashu.migration.v1.lock";
const JOURNAL_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MigrationAttemptState {
    AwaitingConsent,
    Sending,
    PaymentUnknown,
    SourcePending,
    SourcePaid,
    MintPaid,
    Settled,
    SourceFailed,
    ExpiredUnsent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MigrationAttempt {
    pub settlement_id: String,
    pub invoice: String,
    pub payment_hash: String,
    pub amount_sats: u64,
    pub source_fee_sats: Option<u64>,
    pub expires_at_secs: Option<u64>,
    pub source_payment_id: Option<String>,
    pub state: MigrationAttemptState,
}

#[derive(Debug, Serialize, Deserialize)]
struct JournalDocument {
    version: u32,
    account_fingerprint: String,
    mint_fingerprint: String,
    attempt: Option<MigrationAttempt>,
}

/// Crash-safe, account-and-mint-bound migration journal.
///
/// Every read-modify-write sequence must run under [`MigrationJournal::with_lock`].
/// The sidecar lock file is intentionally durable so wipe guards can identify
/// it; the in-process mutex is the exclusive lock used by the embedded engine.
pub struct MigrationJournal {
    working_dir: PathBuf,
    account_fingerprint: String,
    mint_fingerprint: String,
    lock: Mutex<()>,
}

impl MigrationJournal {
    pub fn new(
        working_dir: impl Into<PathBuf>,
        account_id: impl AsRef<[u8]>,
        mint_id: impl AsRef<[u8]>,
    ) -> Result<Self> {
        let working_dir = working_dir.into();
        fs::create_dir_all(&working_dir).map_err(|e| MigrateError::Journal(e.to_string()))?;
        let lock_path = working_dir.join(JOURNAL_LOCK_FILE);
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(&lock_path)
            .and_then(|f| f.sync_all())
            .map_err(|e| MigrateError::Journal(format!("create {}: {e}", lock_path.display())))?;
        let journal = Self {
            working_dir,
            account_fingerprint: fingerprint(account_id.as_ref()),
            mint_fingerprint: fingerprint(mint_id.as_ref()),
            lock: Mutex::new(()),
        };
        // Validate existing bytes immediately. A corrupt or misbound journal
        // must fail construction, not become an apparently empty migration.
        journal.with_lock(|journal| journal.load_unlocked().map(|_| ()))?;
        Ok(journal)
    }

    pub fn with_lock<T>(&self, f: impl FnOnce(&Self) -> Result<T>) -> Result<T> {
        let _guard = self
            .lock
            .lock()
            .map_err(|_| MigrateError::Journal("migration journal lock poisoned".into()))?;
        let lock_path = self.working_dir.join(JOURNAL_LOCK_FILE);
        let lock_file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&lock_path)
            .map_err(|e| {
                MigrateError::Journal(format!("open {}: {e}", lock_path.display()))
            })?;
        #[cfg(unix)]
        {
            use std::os::unix::io::AsRawFd;
            let rc = unsafe {
                libc::flock(lock_file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB)
            };
            if rc != 0 {
                return Err(MigrateError::Journal(
                    "another migration holds the journal lock".into(),
                ));
            }
        }
        let result = f(self);
        #[cfg(unix)]
        {
            use std::os::unix::io::AsRawFd;
            let _ = unsafe { libc::flock(lock_file.as_raw_fd(), libc::LOCK_UN) };
        }
        let _ = lock_file;
        result
    }

    pub fn load(&self) -> Result<Option<MigrationAttempt>> {
        self.with_lock(|journal| journal.load_unlocked())
    }

    pub fn store(&self, attempt: Option<&MigrationAttempt>) -> Result<()> {
        self.with_lock(|journal| journal.store_unlocked(attempt))
    }

    pub(crate) fn load_unlocked(&self) -> Result<Option<MigrationAttempt>> {
        let path = self.path();
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => {
                return Err(MigrateError::Journal(format!(
                    "read {}: {e}",
                    path.display()
                )))
            }
        };
        let document: JournalDocument = serde_json::from_slice(&bytes)
            .map_err(|e| MigrateError::Journal(format!("corrupt {}: {e}", path.display())))?;
        if document.version != JOURNAL_VERSION {
            return Err(MigrateError::Journal(format!(
                "unsupported migration journal version {}",
                document.version
            )));
        }
        if document.account_fingerprint != self.account_fingerprint {
            return Err(MigrateError::Journal(
                "migration journal belongs to a different account".into(),
            ));
        }
        if document.mint_fingerprint != self.mint_fingerprint {
            return Err(MigrateError::Journal(
                "migration journal belongs to a different mint".into(),
            ));
        }
        Ok(document.attempt)
    }

    pub(crate) fn store_unlocked(&self, attempt: Option<&MigrationAttempt>) -> Result<()> {
        let document = JournalDocument {
            version: JOURNAL_VERSION,
            account_fingerprint: self.account_fingerprint.clone(),
            mint_fingerprint: self.mint_fingerprint.clone(),
            attempt: attempt.cloned(),
        };
        let bytes = serde_json::to_vec_pretty(&document)
            .map_err(|e| MigrateError::Journal(format!("encode journal: {e}")))?;
        atomic_write(&self.working_dir, &self.path(), &self.tmp_path(), &bytes)
    }

    fn path(&self) -> PathBuf {
        self.working_dir.join(JOURNAL_FILE)
    }

    fn tmp_path(&self) -> PathBuf {
        self.working_dir.join(JOURNAL_TMP_FILE)
    }
}

fn fingerprint(value: &[u8]) -> String {
    hex::encode(Sha256::digest(value))
}

fn atomic_write(parent: &Path, path: &Path, tmp: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(tmp)
        .map_err(|e| MigrateError::Journal(format!("open {}: {e}", tmp.display())))?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|e| MigrateError::Journal(format!("write {}: {e}", tmp.display())))?;
    fs::rename(tmp, path)
        .map_err(|e| MigrateError::Journal(format!("rename {}: {e}", path.display())))?;
    OpenOptions::new()
        .read(true)
        .open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|e| MigrateError::Journal(format!("sync {}: {e}", parent.display())))
}
