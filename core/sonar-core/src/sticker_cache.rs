//! Content-addressed on-disk cache for verified sticker image bytes (SHA256).
//!
//! Survives app restarts and complements the UI-layer in-memory LRU.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex, MutexGuard};
use std::time::SystemTime;

use sonar_stickers::{sha256_hex, validate_sha256_hex, PackAddress, StickerPack};

use crate::Result;

pub(crate) const STICKER_CACHE_DIR_SUFFIX: &str = ".sonar-stickers";
pub(crate) const MAX_STICKER_CACHE_BYTES: usize = 5 * 1024 * 1024;
const MAX_STICKER_CACHE_TOTAL_BYTES: u64 = 100 * 1024 * 1024;
const VALIDATED_PACKS_DIR: &str = "validated-packs";
const INSTALLED_PACKS_FILE: &str = "installed-packs.json";
const FAILED_WIPE_TOMBSTONE_SUFFIX: &str = ".wipe-incomplete";
const FAILED_WIPE_QUARANTINE_SUFFIX: &str = ".wipe-quarantine";
const MAX_VALIDATED_PACK_BYTES: u64 = 512 * 1024;
const MAX_VALIDATED_PACK_CACHE_BYTES: u64 = 10 * 1024 * 1024;
const MAX_INSTALLED_PACKS_BYTES: u64 = 64 * 1024;
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
    /// Roots whose durable wipe tombstone could not yet be cleared. This also
    /// covers the current process if persisting the tombstone itself failed.
    failed_wipes: HashSet<PathBuf>,
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
    active: bool,
}

impl StickerCache {
    pub(crate) fn disabled() -> Self {
        Self {
            root: None,
            generation: 0,
            active: false,
        }
    }

    pub(crate) fn for_db(db_path: &Path) -> Result<Self> {
        let root = sticker_cache_dir_for_db(db_path);
        let mut state = lock_cache()?;
        if state.failed_wipes.contains(&root)
            || failed_wipe_tombstone_exists(&root)?
            || failed_wipe_quarantine_path(&root).exists()
        {
            state.failed_wipes.insert(root.clone());
            if let Err(error) = retry_failed_wipe(&root) {
                tracing::warn!(
                    %error,
                    cache_dir = %root.display(),
                    "sticker cache disabled until an incomplete wipe can be retried"
                );
                let generation = *state.generations.entry(root.clone()).or_default();
                return Ok(Self {
                    root: Some(root),
                    generation,
                    active: false,
                });
            }
            state.failed_wipes.remove(&root);
        }
        let generation = *state.generations.entry(root.clone()).or_default();
        Ok(Self {
            root: Some(root),
            generation,
            active: true,
        })
    }

    fn is_current(&self, state: &StickerCacheState, root: &Path) -> bool {
        state.generations.get(root).copied().unwrap_or_default() == self.generation
    }

    /// Whether this handle still belongs to the live node generation. Detached
    /// prefetch loops use this to stop scheduling work promptly after an
    /// identity wipe instead of relying only on write rejection at completion.
    pub(crate) fn session_is_current(&self) -> Result<bool> {
        let Some(root) = self.root.as_deref() else {
            return Ok(true);
        };
        let state = lock_cache()?;
        Ok(self.is_current(&state, root))
    }

    /// Read verified bytes from disk if present and SHA256 matches.
    pub(crate) fn read(&self, expected_sha256: &str) -> Result<Option<Vec<u8>>> {
        if !self.active {
            return Ok(None);
        }
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

    /// Persist the latest locally validated definition for a pack. Transcript
    /// cache hits are authorized against this metadata before any image bytes
    /// are returned, matching Signal's local-database source-of-truth model.
    pub(crate) fn remember_validated_pack(&self, pack: &StickerPack) -> Result<bool> {
        if !self.active {
            return Ok(true);
        }
        let Some(root) = self.root.as_deref() else {
            return Ok(true);
        };
        let state = lock_cache()?;
        if !self.is_current(&state, root) {
            return Ok(false);
        }
        write_validated_pack(root, pack)?;
        Ok(true)
    }

    /// Read the latest locally validated definition for a pack. Foreground
    /// picker/transcript paths paint from this before any relay refresh so a
    /// warm disk cache never waits on network; refresh still updates the file
    /// in the background via the shared pack-fetch gate.
    pub(crate) fn read_validated_pack(&self, coordinate: &str) -> Result<Option<StickerPack>> {
        if !self.active {
            return Ok(None);
        }
        let Some(root) = self.root.as_deref() else {
            return Ok(None);
        };
        let state = lock_cache()?;
        if !self.is_current(&state, root) {
            return Ok(None);
        }
        read_validated_pack(root, coordinate)
    }

    /// Persist the last-known installed pack list (kind 10031) so the sticker
    /// picker can paint across process restarts without waiting on relays.
    pub(crate) fn remember_installed_packs(&self, packs: &[PackAddress]) -> Result<bool> {
        if !self.active {
            return Ok(true);
        }
        let Some(root) = self.root.as_deref() else {
            return Ok(true);
        };
        let state = lock_cache()?;
        if !self.is_current(&state, root) {
            return Ok(false);
        }
        write_installed_packs(root, packs)?;
        Ok(true)
    }

    /// Read the last-known installed pack list. `None` means never cached;
    /// `Some([])` means the user had an empty installed set when last synced.
    pub(crate) fn read_installed_packs(&self) -> Result<Option<Vec<PackAddress>>> {
        if !self.active {
            return Ok(None);
        }
        let Some(root) = self.root.as_deref() else {
            return Ok(None);
        };
        let state = lock_cache()?;
        if !self.is_current(&state, root) {
            return Ok(None);
        }
        read_installed_packs(root)
    }

    /// Return verified image bytes only when the latest locally validated pack
    /// still contains the exact coordinate + shortcode + plaintext hash.
    pub(crate) fn read_validated_image(
        &self,
        pack_coordinate: &str,
        shortcode: &str,
        expected_sha256: &str,
    ) -> Result<Option<Vec<u8>>> {
        if !self.active {
            return Ok(None);
        }
        let Some(root) = self.root.as_deref() else {
            return Ok(None);
        };
        let state = lock_cache()?;
        if !self.is_current(&state, root) {
            return Ok(None);
        }
        if !validated_pack_contains(root, pack_coordinate, shortcode, expected_sha256)? {
            return Ok(None);
        }
        read_sticker_cache(root, expected_sha256)
    }

    fn write_with_budget(
        &self,
        expected_sha256: &str,
        bytes: &[u8],
        total_budget: u64,
    ) -> Result<bool> {
        if !self.active {
            return Ok(true);
        }
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
    state.failed_wipes.insert(dir.clone());

    let tombstone = failed_wipe_tombstone_path(&dir);
    if let Err(tombstone_error) = persist_failed_wipe_tombstone(&tombstone) {
        // If the filesystem cannot create/sync the durable tombstone (for
        // example ENOSPC), atomically move the cache out of the live path.
        // The quarantine directory itself is then the durable fail-closed
        // marker seen by `for_db` after restart.
        let quarantine = failed_wipe_quarantine_path(&dir);
        match fs::rename(&dir, &quarantine) {
            Ok(()) => {
                fs::remove_dir_all(&quarantine).map_err(|error| {
                    crate::Error::Storage(format!(
                        "remove quarantined sticker cache {} after tombstone failure ({tombstone_error}): {error}",
                        quarantine.display()
                    ))
                })?;
                remove_failed_wipe_tombstone(&tombstone)?;
                state.failed_wipes.remove(&dir);
                return Ok(());
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                match fs::remove_dir_all(&quarantine) {
                    Ok(()) => {}
                    Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                    Err(error) => {
                        return Err(crate::Error::Storage(format!(
                            "remove quarantined sticker cache {} after tombstone failure ({tombstone_error}): {error}",
                            quarantine.display()
                        )))
                    }
                }
                remove_failed_wipe_tombstone(&tombstone)?;
                state.failed_wipes.remove(&dir);
                return Ok(());
            }
            Err(error) => {
                return Err(crate::Error::Storage(format!(
                    "persist sticker cache wipe tombstone ({tombstone_error}) and quarantine {}: {error}",
                    dir.display()
                )))
            }
        }
    }
    match fs::remove_dir_all(&dir) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => {
            return Err(crate::Error::Storage(format!(
                "remove sticker cache {}: {e}",
                dir.display()
            )))
        }
    }
    let quarantine = failed_wipe_quarantine_path(&dir);
    match fs::remove_dir_all(&quarantine) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => {
            return Err(crate::Error::Storage(format!(
                "remove quarantined sticker cache {}: {e}",
                quarantine.display()
            )))
        }
    }
    remove_failed_wipe_tombstone(&tombstone)?;
    state.failed_wipes.remove(&dir);
    Ok(())
}

fn failed_wipe_quarantine_path(root: &Path) -> PathBuf {
    let file_name = root
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("marmot.sqlite.sonar-stickers");
    root.with_file_name(format!("{file_name}{FAILED_WIPE_QUARANTINE_SUFFIX}"))
}

fn retry_failed_wipe(root: &Path) -> Result<()> {
    for path in [root.to_path_buf(), failed_wipe_quarantine_path(root)] {
        match fs::remove_dir_all(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(crate::Error::Storage(format!(
                    "retry sticker cache wipe {}: {error}",
                    path.display()
                )))
            }
        }
    }
    remove_failed_wipe_tombstone(&failed_wipe_tombstone_path(root))
}

fn failed_wipe_tombstone_path(root: &Path) -> PathBuf {
    let file_name = root
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("marmot.sqlite.sonar-stickers");
    root.with_file_name(format!("{file_name}{FAILED_WIPE_TOMBSTONE_SUFFIX}"))
}

fn failed_wipe_tombstone_exists(root: &Path) -> Result<bool> {
    let path = failed_wipe_tombstone_path(root);
    match fs::metadata(&path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(crate::Error::Storage(format!(
            "inspect sticker cache wipe tombstone {}: {error}",
            path.display()
        ))),
    }
}

fn persist_failed_wipe_tombstone(path: &Path) -> Result<()> {
    let mut file = fs::File::create(path).map_err(|error| {
        crate::Error::Storage(format!(
            "create sticker cache wipe tombstone {}: {error}",
            path.display()
        ))
    })?;
    file.write_all(b"sticker cache wipe incomplete\n")
        .and_then(|()| file.sync_all())
        .map_err(|error| {
            crate::Error::Storage(format!(
                "persist sticker cache wipe tombstone {}: {error}",
                path.display()
            ))
        })
}

fn remove_failed_wipe_tombstone(path: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(crate::Error::Storage(format!(
                "inspect sticker cache wipe tombstone {}: {error}",
                path.display()
            )))
        }
    };
    let result = if metadata.file_type().is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    };
    match result {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(crate::Error::Storage(format!(
            "remove sticker cache wipe tombstone {}: {error}",
            path.display()
        ))),
    }
}

#[cfg(not(windows))]
fn atomic_replace_file(from: &Path, to: &Path) -> io::Result<()> {
    fs::rename(from, to)
}

#[cfg(windows)]
fn atomic_replace_file(from: &Path, to: &Path) -> io::Result<()> {
    use std::iter;
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let from = from
        .as_os_str()
        .encode_wide()
        .chain(iter::once(0))
        .collect::<Vec<_>>();
    let to = to
        .as_os_str()
        .encode_wide()
        .chain(iter::once(0))
        .collect::<Vec<_>>();
    let result = unsafe {
        MoveFileExW(
            from.as_ptr(),
            to.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn cache_file_path(root: &Path, sha256_hex_lower: &str) -> PathBuf {
    let prefix = &sha256_hex_lower[0..2];
    root.join(prefix).join(sha256_hex_lower)
}

fn validated_pack_file_path(root: &Path, coordinate: &str) -> PathBuf {
    root.join(VALIDATED_PACKS_DIR)
        .join(format!("{}.json", sha256_hex(coordinate.as_bytes())))
}

fn installed_packs_file_path(root: &Path) -> PathBuf {
    root.join(INSTALLED_PACKS_FILE)
}

fn write_installed_packs(root: &Path, packs: &[PackAddress]) -> Result<()> {
    let coordinates: Vec<String> = packs.iter().map(|pack| pack.coordinate()).collect();
    let bytes = serde_json::to_vec(&coordinates)
        .map_err(|e| crate::Error::Storage(format!("encode installed packs cache: {e}")))?;
    if bytes.len() as u64 > MAX_INSTALLED_PACKS_BYTES {
        return Err(crate::Error::Storage(format!(
            "installed packs metadata exceeds {MAX_INSTALLED_PACKS_BYTES} byte cache cap"
        )));
    }
    fs::create_dir_all(root).map_err(|e| {
        crate::Error::Storage(format!(
            "create sticker cache dir {}: {e}",
            root.display()
        ))
    })?;
    let path = installed_packs_file_path(root);
    let tmp = path.with_extension(format!("{}.tmp", std::process::id()));
    if let Err(error) = fs::write(&tmp, bytes) {
        let _ = fs::remove_file(&tmp);
        return Err(crate::Error::Storage(format!(
            "write installed packs cache tmp {}: {error}",
            tmp.display()
        )));
    }
    if let Err(error) = atomic_replace_file(&tmp, &path) {
        let _ = fs::remove_file(&tmp);
        return Err(crate::Error::Storage(format!(
            "commit installed packs cache {}: {error}",
            path.display()
        )));
    }
    Ok(())
}

fn read_installed_packs(root: &Path) -> Result<Option<Vec<PackAddress>>> {
    let path = installed_packs_file_path(root);
    let metadata = match fs::metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(crate::Error::Storage(format!(
                "inspect installed packs cache {}: {error}",
                path.display()
            )))
        }
    };
    if metadata.len() > MAX_INSTALLED_PACKS_BYTES {
        let _ = fs::remove_file(&path);
        return Ok(None);
    }
    let bytes = fs::read(&path).map_err(|error| {
        crate::Error::Storage(format!(
            "read installed packs cache {}: {error}",
            path.display()
        ))
    })?;
    let coordinates: Vec<String> = match serde_json::from_slice(&bytes) {
        Ok(coordinates) => coordinates,
        Err(_) => {
            let _ = fs::remove_file(&path);
            return Ok(None);
        }
    };
    let mut packs = Vec::with_capacity(coordinates.len());
    for coordinate in coordinates {
        match PackAddress::parse(&coordinate) {
            Ok(address) => packs.push(address),
            Err(_) => {
                let _ = fs::remove_file(&path);
                return Ok(None);
            }
        }
    }
    Ok(Some(packs))
}

fn write_validated_pack(root: &Path, pack: &StickerPack) -> Result<()> {
    pack.validate().map_err(|e| {
        crate::Error::InvalidInput(format!("invalid sticker pack cache entry: {e}"))
    })?;
    let coordinate = pack.address.coordinate();
    let bytes = serde_json::to_vec(pack)
        .map_err(|e| crate::Error::Storage(format!("encode sticker pack cache: {e}")))?;
    if bytes.len() as u64 > MAX_VALIDATED_PACK_BYTES {
        return Err(crate::Error::Storage(format!(
            "sticker pack metadata exceeds {MAX_VALIDATED_PACK_BYTES} byte cache cap"
        )));
    }
    let path = validated_pack_file_path(root, &coordinate);
    let parent = path
        .parent()
        .ok_or_else(|| crate::Error::Storage("invalid sticker pack cache path".into()))?;
    fs::create_dir_all(parent).map_err(|e| {
        crate::Error::Storage(format!(
            "create sticker pack cache dir {}: {e}",
            parent.display()
        ))
    })?;
    let tmp = path.with_extension(format!("{}.tmp", std::process::id()));
    if let Err(error) = fs::write(&tmp, bytes) {
        let _ = fs::remove_file(&tmp);
        return Err(crate::Error::Storage(format!(
            "write sticker pack cache tmp {}: {error}",
            tmp.display()
        )));
    }
    if let Err(error) = atomic_replace_file(&tmp, &path) {
        let _ = fs::remove_file(&tmp);
        return Err(crate::Error::Storage(format!(
            "commit sticker pack cache {}: {error}",
            path.display()
        )));
    }
    enforce_cache_budget(parent, MAX_VALIDATED_PACK_CACHE_BYTES, &path)
}

fn read_validated_pack(root: &Path, coordinate: &str) -> Result<Option<StickerPack>> {
    let address = PackAddress::parse(coordinate)
        .map_err(|e| crate::Error::InvalidInput(format!("invalid sticker pack coordinate: {e}")))?;
    let coordinate = address.coordinate();
    let path = validated_pack_file_path(root, &coordinate);
    let metadata = match fs::metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(crate::Error::Storage(format!(
                "inspect sticker pack cache {}: {error}",
                path.display()
            )))
        }
    };
    if metadata.len() > MAX_VALIDATED_PACK_BYTES {
        let _ = fs::remove_file(&path);
        return Ok(None);
    }
    let bytes = fs::read(&path).map_err(|error| {
        crate::Error::Storage(format!(
            "read sticker pack cache {}: {error}",
            path.display()
        ))
    })?;
    let pack: StickerPack = match serde_json::from_slice(&bytes) {
        Ok(pack) => pack,
        Err(_) => {
            let _ = fs::remove_file(&path);
            return Ok(None);
        }
    };
    if pack.address != address || pack.validate().is_err() {
        let _ = fs::remove_file(&path);
        return Ok(None);
    }
    Ok(Some(pack))
}

fn validated_pack_contains(
    root: &Path,
    pack_coordinate: &str,
    shortcode: &str,
    expected_sha256: &str,
) -> Result<bool> {
    let address = PackAddress::parse(pack_coordinate)
        .map_err(|e| crate::Error::InvalidInput(format!("invalid sticker pack coordinate: {e}")))?;
    let expected = expected_sha256.to_ascii_lowercase();
    validate_sha256_hex(&expected).map_err(|e| crate::Error::InvalidInput(e.to_string()))?;
    let coordinate = address.coordinate();
    let path = validated_pack_file_path(root, &coordinate);
    let metadata = match fs::metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => {
            return Err(crate::Error::Storage(format!(
                "inspect sticker pack cache {}: {error}",
                path.display()
            )))
        }
    };
    if metadata.len() > MAX_VALIDATED_PACK_BYTES {
        let _ = fs::remove_file(&path);
        return Ok(false);
    }
    let Some(pack) = read_validated_pack(root, &coordinate)? else {
        return Ok(false);
    };
    Ok(pack.stickers.iter().any(|sticker| {
        sticker.shortcode == shortcode && sticker.sha256.eq_ignore_ascii_case(&expected)
    }))
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
    if let Err(error) = atomic_replace_file(&tmp, &path) {
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
            if child.file_name().to_str() == Some(VALIDATED_PACKS_DIR) {
                continue;
            }
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
    use sonar_stickers::Sticker;
    use tempfile::tempdir;

    fn pack_with_sticker(shortcode: &str, bytes: &[u8]) -> StickerPack {
        let sha = sha256_hex(bytes);
        let address = PackAddress::new("11".repeat(32), "pack").unwrap();
        let sticker = Sticker::new(
            shortcode,
            format!("https://example.com/{sha}"),
            sha,
            "image/png",
            Some(128),
            Some(128),
            None,
            None,
        )
        .unwrap();
        StickerPack::new(address, "Pack", None, None, vec![sticker], None).unwrap()
    }

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
    fn failed_wipe_tombstone_blocks_cache_until_cleanup_succeeds() {
        let dir = tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let cache_root = sticker_cache_dir_for_db(&db);
        let tombstone = failed_wipe_tombstone_path(&cache_root);
        let stale = StickerCache::for_db(&db).unwrap();

        // A plain file at the cache-directory path makes remove_dir_all fail on
        // every supported host without relying on permissions or test hooks.
        fs::write(&cache_root, b"not-a-directory").unwrap();
        assert!(wipe_sticker_cache_for_db(&db).is_err());
        assert!(tombstone.is_file());
        assert!(stale.read(&sha256_hex(b"old")).unwrap().is_none());
        assert!(!StickerCache::for_db(&db).unwrap().active);

        // Simulate a process restart: the durable tombstone remains sufficient
        // even after the in-memory failed-wipe record is gone.
        lock_cache().unwrap().failed_wipes.remove(&cache_root);
        assert!(!StickerCache::for_db(&db).unwrap().active);

        fs::remove_file(&cache_root).unwrap();
        wipe_sticker_cache_for_db(&db).unwrap();
        assert!(!tombstone.exists());

        let fresh = StickerCache::for_db(&db).unwrap();
        let bytes = b"new-session";
        assert!(fresh.write(&sha256_hex(bytes), bytes).unwrap());
        assert_eq!(
            fresh.read(&sha256_hex(bytes)).unwrap().as_deref(),
            Some(bytes.as_slice())
        );
    }

    #[test]
    fn startup_retries_a_recoverable_incomplete_wipe() {
        let dir = tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let cache_root = sticker_cache_dir_for_db(&db);
        let tombstone = failed_wipe_tombstone_path(&cache_root);
        fs::create_dir_all(&cache_root).unwrap();
        fs::write(cache_root.join("stale"), b"old account bytes").unwrap();
        persist_failed_wipe_tombstone(&tombstone).unwrap();
        lock_cache().unwrap().failed_wipes.remove(&cache_root);

        let fresh = StickerCache::for_db(&db).unwrap();

        assert!(fresh.root.is_some());
        assert!(!cache_root.exists());
        assert!(!tombstone.exists());
    }

    #[test]
    fn tombstone_create_failure_still_removes_existing_quarantine() {
        let dir = tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let cache_root = sticker_cache_dir_for_db(&db);
        let quarantine = failed_wipe_quarantine_path(&cache_root);
        let tombstone = failed_wipe_tombstone_path(&cache_root);

        fs::create_dir_all(&quarantine).unwrap();
        fs::write(quarantine.join("old-account"), b"stale").unwrap();
        // File::create must fail, exercising the quarantine fallback with no
        // live root and a pre-existing quarantine from an interrupted wipe.
        fs::create_dir_all(&tombstone).unwrap();

        wipe_sticker_cache_for_db(&db).unwrap();

        assert!(!cache_root.exists());
        assert!(!quarantine.exists());
        assert!(!tombstone.exists());
        let fresh = StickerCache::for_db(&db).unwrap();
        let bytes = b"fresh-session";
        assert!(fresh.write(&sha256_hex(bytes), bytes).unwrap());
    }

    #[test]
    fn installed_packs_round_trip_distinguishes_missing_from_empty() {
        let dir = tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let cache = StickerCache::for_db(&db).unwrap();
        assert!(cache.read_installed_packs().unwrap().is_none());

        assert!(cache.remember_installed_packs(&[]).unwrap());
        assert_eq!(
            cache.read_installed_packs().unwrap().as_deref(),
            Some([].as_slice())
        );

        let pack = PackAddress::new(
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "sonar-cats-v1",
        )
        .unwrap();
        assert!(cache.remember_installed_packs(&[pack.clone()]).unwrap());
        assert_eq!(
            cache.read_installed_packs().unwrap().as_deref(),
            Some([pack].as_slice())
        );
    }

    #[test]
    fn cached_image_requires_current_validated_pack_reference() {
        let dir = tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        let cache = StickerCache::for_db(&db).unwrap();
        let bytes = b"first-sticker";
        let sha = sha256_hex(bytes);
        let pack = pack_with_sticker("wave", bytes);
        let coordinate = pack.address.coordinate();

        assert!(cache.write(&sha, bytes).unwrap());
        assert!(cache
            .read_validated_image(&coordinate, "wave", &sha)
            .unwrap()
            .is_none());

        assert!(cache.remember_validated_pack(&pack).unwrap());
        assert_eq!(
            cache
                .read_validated_image(&coordinate, "wave", &sha)
                .unwrap()
                .as_deref(),
            Some(bytes.as_slice())
        );
        assert!(cache
            .read_validated_image(&coordinate, "other", &sha)
            .unwrap()
            .is_none());

        let replacement = b"replacement-sticker";
        let replacement_sha = sha256_hex(replacement);
        assert!(cache.write(&replacement_sha, replacement).unwrap());
        assert!(cache
            .remember_validated_pack(&pack_with_sticker("new", replacement))
            .unwrap());
        assert!(cache
            .read_validated_image(&coordinate, "wave", &sha)
            .unwrap()
            .is_none());
        assert_eq!(
            cache
                .read_validated_image(&coordinate, "new", &replacement_sha)
                .unwrap()
                .as_deref(),
            Some(replacement.as_slice())
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
