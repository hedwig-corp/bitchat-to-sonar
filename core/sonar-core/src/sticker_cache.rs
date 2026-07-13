//! Content-addressed on-disk cache for verified sticker image bytes (SHA256).
//!
//! Survives app restarts and complements the UI-layer in-memory LRU.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex, MutexGuard};
use std::time::SystemTime;

use sonar_stickers::{sha256_hex, validate_sha256_hex};

use crate::Result;

pub(crate) const STICKER_CACHE_DIR_SUFFIX: &str = ".sonar-stickers";
const MAX_STICKER_CACHE_BYTES: usize = 5 * 1024 * 1024;
const MAX_STICKER_CACHE_TOTAL_BYTES: u64 = 100 * 1024 * 1024;
/// Bound install prefetch to the leading window that can fit even when every
/// sticker is at the per-object maximum. This keeps picker-order stickers warm
/// instead of downloading the whole pack and evicting its first entries.
pub(crate) const STICKER_CACHE_PREFETCH_IMAGE_LIMIT: usize =
    MAX_STICKER_CACHE_TOTAL_BYTES as usize / MAX_STICKER_CACHE_BYTES;

#[derive(Default)]
struct StickerCacheState {
    /// Incremented before every wipe. A cache handle captures the generation at
    /// node creation, so an old async fetch cannot recreate files after panic
    /// wipe (or write into a freshly-created session for the same DB path).
    generations: HashMap<PathBuf, u64>,
}

// Serializes cache reads, writes, eviction, and wipe within the process. The
// cache is best-effort, but readers must never observe a half-finished
// replacement and wipe must not race an in-flight write.
static STICKER_CACHE_STATE: LazyLock<Mutex<StickerCacheState>> =
    LazyLock::new(|| Mutex::new(StickerCacheState::default()));

fn lock_cache() -> Result<MutexGuard<'static, StickerCacheState>> {
    STICKER_CACHE_STATE
        .lock()
        .map_err(|_| crate::Error::Storage("sticker cache lock poisoned".into()))
}

/// Directory next to the Marmot DB: `marmot.sqlite.sonar-stickers/`.
pub fn sticker_cache_dir_for_db(db_path: &Path) -> PathBuf {
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("marmot.sqlite");
    db_path.with_file_name(format!("{file_name}{STICKER_CACHE_DIR_SUFFIX}"))
}

/// One node/session's view of the persistent sticker cache.
///
/// The captured generation makes cache writes revocable: once the DB path is
/// wiped, retained host references and detached prefetch tasks become read-only
/// misses and their later writes are ignored.
#[derive(Clone, Debug)]
pub(crate) struct StickerCache {
    root: Option<PathBuf>,
    generation: u64,
}

impl StickerCache {
    pub(crate) fn disabled() -> Self {
        Self {
            root: None,
            generation: 0,
        }
    }

    pub(crate) fn for_db(db_path: &Path) -> Result<Self> {
        let root = sticker_cache_dir_for_db(db_path);
        let mut state = lock_cache()?;
        let generation = *state.generations.entry(root.clone()).or_default();
        Ok(Self {
            root: Some(root),
            generation,
        })
    }

    fn is_current(&self, state: &StickerCacheState, root: &Path) -> bool {
        state.generations.get(root).copied().unwrap_or_default() == self.generation
    }

    /// Read verified bytes from disk if present and SHA256 matches.
    pub(crate) fn read(&self, expected_sha256: &str) -> Result<Option<Vec<u8>>> {
        let Some(root) = self.root.as_deref() else {
            return Ok(None);
        };
        let state = lock_cache()?;
        if !self.is_current(&state, root) {
            return Ok(None);
        }
        read_sticker_cache(root, expected_sha256)
    }

    /// Persist verified sticker bytes atomically. A write from a node invalidated
    /// by panic wipe is intentionally a no-op.
    pub(crate) fn write(&self, expected_sha256: &str, bytes: &[u8]) -> Result<bool> {
        self.write_with_budget(expected_sha256, bytes, MAX_STICKER_CACHE_TOTAL_BYTES)
    }

    fn write_with_budget(
        &self,
        expected_sha256: &str,
        bytes: &[u8],
        total_budget: u64,
    ) -> Result<bool> {
        let Some(root) = self.root.as_deref() else {
            return Ok(true);
        };
        let state = lock_cache()?;
        if !self.is_current(&state, root) {
            return Ok(false);
        }
        write_sticker_cache_with_budget(root, expected_sha256, bytes, total_budget)?;
        Ok(true)
    }
}

pub(crate) fn wipe_sticker_cache_for_db(db_path: &Path) -> Result<()> {
    let dir = sticker_cache_dir_for_db(db_path);
    let mut state = lock_cache()?;
    let generation = state.generations.entry(dir.clone()).or_default();
    *generation = generation.wrapping_add(1);
    match fs::remove_dir_all(&dir) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(crate::Error::Storage(format!(
            "remove sticker cache {}: {e}",
            dir.display()
        ))),
    }
}

fn cache_file_path(root: &Path, sha256_hex_lower: &str) -> PathBuf {
    let prefix = &sha256_hex_lower[0..2];
    root.join(prefix).join(sha256_hex_lower)
}

fn read_sticker_cache(root: &Path, expected_sha256: &str) -> Result<Option<Vec<u8>>> {
    let expected = expected_sha256.to_ascii_lowercase();
    validate_sha256_hex(&expected).map_err(|e| crate::Error::InvalidInput(e.to_string()))?;
    let path = cache_file_path(root, &expected);
    if !path.is_file() {
        return Ok(None);
    }
    let bytes = fs::read(&path).map_err(|e| {
        crate::Error::Storage(format!("read sticker cache {}: {e}", path.display()))
    })?;
    if bytes.len() > MAX_STICKER_CACHE_BYTES {
        let _ = fs::remove_file(&path);
        return Ok(None);
    }
    let actual = sha256_hex(&bytes);
    if actual != expected {
        let _ = fs::remove_file(&path);
        return Ok(None);
    }
    Ok(Some(bytes))
}

fn write_sticker_cache_with_budget(
    root: &Path,
    expected_sha256: &str,
    bytes: &[u8],
    total_budget: u64,
) -> Result<()> {
    let expected = expected_sha256.to_ascii_lowercase();
    validate_sha256_hex(&expected).map_err(|e| crate::Error::InvalidInput(e.to_string()))?;
    if bytes.len() > MAX_STICKER_CACHE_BYTES {
        return Err(crate::Error::Http(format!(
            "sticker too large for cache: {} bytes (cap {MAX_STICKER_CACHE_BYTES})",
            bytes.len()
        )));
    }
    if sha256_hex(bytes) != expected {
        return Err(crate::Error::InvalidInput(
            "sticker cache write: sha256 mismatch".into(),
        ));
    }
    fs::create_dir_all(root).map_err(|e| {
        crate::Error::Storage(format!("create sticker cache dir {}: {e}", root.display()))
    })?;
    let path = cache_file_path(root, &expected);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| {
            crate::Error::Storage(format!(
                "create sticker cache shard {}: {e}",
                parent.display()
            ))
        })?;
    }
    let tmp = path.with_extension(format!("{}.tmp", std::process::id()));
    if let Err(error) = fs::write(&tmp, bytes) {
        let _ = fs::remove_file(&tmp);
        return Err(crate::Error::Storage(format!(
            "write sticker cache tmp {}: {error}",
            tmp.display()
        )));
    }
    if let Err(error) = fs::rename(&tmp, &path) {
        let _ = fs::remove_file(&tmp);
        return Err(crate::Error::Storage(format!(
            "commit sticker cache {}: {error}",
            path.display()
        )));
    }
    enforce_cache_budget(root, total_budget, &path)?;
    Ok(())
}

#[derive(Debug)]
struct CacheEntry {
    path: PathBuf,
    len: u64,
    modified: SystemTime,
}

fn collect_cache_entries(dir: &Path, entries: &mut Vec<CacheEntry>) -> Result<()> {
    let children = match fs::read_dir(dir) {
        Ok(children) => children,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(crate::Error::Storage(format!(
                "scan sticker cache {}: {error}",
                dir.display()
            )))
        }
    };
    for child in children {
        let child = child.map_err(|error| {
            crate::Error::Storage(format!("scan sticker cache {}: {error}", dir.display()))
        })?;
        let file_type = child.file_type().map_err(|error| {
            crate::Error::Storage(format!(
                "inspect sticker cache entry {}: {error}",
                child.path().display()
            ))
        })?;
        if file_type.is_dir() {
            collect_cache_entries(&child.path(), entries)?;
        } else if file_type.is_file() {
            let metadata = child.metadata().map_err(|error| {
                crate::Error::Storage(format!(
                    "inspect sticker cache file {}: {error}",
                    child.path().display()
                ))
            })?;
            entries.push(CacheEntry {
                path: child.path(),
                len: metadata.len(),
                modified: metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH),
            });
        }
    }
    Ok(())
}

fn enforce_cache_budget(root: &Path, total_budget: u64, protected: &Path) -> Result<()> {
    let mut entries = Vec::new();
    collect_cache_entries(root, &mut entries)?;
    let mut total: u64 = entries.iter().map(|entry| entry.len).sum();
    if total <= total_budget {
        return Ok(());
    }

    // Keep the just-verified object and evict older entries first. The path is
    // the final tie-breaker so eviction remains deterministic on filesystems
    // with coarse modification timestamps.
    entries.sort_by(|left, right| {
        (left.path == protected)
            .cmp(&(right.path == protected))
            .then_with(|| left.modified.cmp(&right.modified))
            .then_with(|| left.path.cmp(&right.path))
    });
    for entry in entries {
        if total <= total_budget || entry.path == protected {
            continue;
        }
        fs::remove_file(&entry.path).map_err(|error| {
            crate::Error::Storage(format!(
                "evict sticker cache file {}: {error}",
                entry.path.display()
            ))
        })?;
        total = total.saturating_sub(entry.len);
    }
    if total > total_budget {
        return Err(crate::Error::Storage(format!(
            "sticker cache exceeds {total_budget} byte budget after eviction"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn round_trip_and_wipe() {
        let dir = tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let cache_root = sticker_cache_dir_for_db(&db);
        let cache = StickerCache::for_db(&db).unwrap();
        let bytes = b"png-bytes";
        let sha = sha256_hex(bytes);
        assert!(cache.write(&sha, bytes).unwrap());
        let hit = cache.read(&sha).unwrap().unwrap();
        assert_eq!(hit, bytes);
        wipe_sticker_cache_for_db(&db).unwrap();
        assert!(!cache_root.exists());
        assert!(cache.read(&sha).unwrap().is_none());
    }

    #[test]
    fn stale_writer_cannot_recreate_cache_after_wipe() {
        let dir = tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let cache_root = sticker_cache_dir_for_db(&db);
        let stale = StickerCache::for_db(&db).unwrap();
        let before = b"before-wipe";
        assert!(stale.write(&sha256_hex(before), before).unwrap());

        wipe_sticker_cache_for_db(&db).unwrap();
        let after = b"late-old-session-write";
        assert!(!stale.write(&sha256_hex(after), after).unwrap());
        assert!(!cache_root.exists());

        let fresh = StickerCache::for_db(&db).unwrap();
        assert!(fresh.write(&sha256_hex(after), after).unwrap());
        assert_eq!(
            fresh.read(&sha256_hex(after)).unwrap().as_deref(),
            Some(after.as_slice())
        );
    }

    #[test]
    fn evicts_oldest_entries_to_total_budget() {
        let dir = tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let cache_root = sticker_cache_dir_for_db(&db);
        let cache = StickerCache::for_db(&db).unwrap();
        for bytes in [b"aaaa".as_slice(), b"bbbb".as_slice(), b"cccc".as_slice()] {
            let sha = sha256_hex(bytes);
            assert!(cache.write_with_budget(&sha, bytes, 8).unwrap());
        }

        let mut entries = Vec::new();
        collect_cache_entries(&cache_root, &mut entries).unwrap();
        assert!(entries.iter().map(|entry| entry.len).sum::<u64>() <= 8);
        let newest = sha256_hex(b"cccc");
        assert!(cache_file_path(&cache_root, &newest).is_file());
    }

    #[test]
    fn prefetch_window_cannot_exceed_total_budget() {
        assert!(
            STICKER_CACHE_PREFETCH_IMAGE_LIMIT * MAX_STICKER_CACHE_BYTES
                <= MAX_STICKER_CACHE_TOTAL_BYTES as usize
        );
        assert!(
            (STICKER_CACHE_PREFETCH_IMAGE_LIMIT + 1) * MAX_STICKER_CACHE_BYTES
                > MAX_STICKER_CACHE_TOTAL_BYTES as usize
        );
    }
}
