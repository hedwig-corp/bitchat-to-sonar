//! Content-addressed on-disk cache for verified sticker image bytes (SHA256).
//!
//! Survives app restarts and complements the UI-layer in-memory LRU.

use std::fs;
use std::path::{Path, PathBuf};

use sonar_stickers::{sha256_hex, validate_sha256_hex};

use crate::Result;

pub(crate) const STICKER_CACHE_DIR_SUFFIX: &str = ".sonar-stickers";
const MAX_STICKER_CACHE_BYTES: usize = 5 * 1024 * 1024;

/// Directory next to the Marmot DB: `marmot.sqlite.sonar-stickers/`.
pub fn sticker_cache_dir_for_db(db_path: &Path) -> PathBuf {
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("marmot.sqlite");
    db_path.with_file_name(format!("{file_name}{STICKER_CACHE_DIR_SUFFIX}"))
}

pub(crate) fn wipe_sticker_cache_for_db(db_path: &Path) -> Result<()> {
    let dir = sticker_cache_dir_for_db(db_path);
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

/// Read verified bytes from disk if present and SHA256 matches.
pub fn read_sticker_cache(root: Option<&Path>, expected_sha256: &str) -> Result<Option<Vec<u8>>> {
    let Some(root) = root else {
        return Ok(None);
    };
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

/// Persist verified sticker bytes (atomic write). No-op when `root` is None.
pub fn write_sticker_cache(root: Option<&Path>, expected_sha256: &str, bytes: &[u8]) -> Result<()> {
    let Some(root) = root else {
        return Ok(());
    };
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
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, bytes).map_err(|e| {
        crate::Error::Storage(format!("write sticker cache tmp {}: {e}", tmp.display()))
    })?;
    fs::rename(&tmp, &path).map_err(|e| {
        crate::Error::Storage(format!("commit sticker cache {}: {e}", path.display()))
    })?;
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
        let bytes = b"png-bytes";
        let sha = sha256_hex(bytes);
        write_sticker_cache(Some(&cache_root), &sha, bytes).unwrap();
        let hit = read_sticker_cache(Some(&cache_root), &sha)
            .unwrap()
            .unwrap();
        assert_eq!(hit, bytes);
        wipe_sticker_cache_for_db(&db).unwrap();
        assert!(!cache_root.exists());
    }
}
