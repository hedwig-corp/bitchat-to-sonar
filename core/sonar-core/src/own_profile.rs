//! Own kind-0 profile cache sidecar.
//!
//! Kind-0 is replaceable: whoever publishes last wins the whole event. Our
//! publish path fetch-and-merges the current relay profile so a Sonar publish
//! never wipes fields it does not manage (picture, about, banner, lud16,
//! custom keys). But `fetch_metadata` returning "no event" is ambiguous — a
//! genuinely fresh key looks exactly like a flaky network that missed the
//! relay holding the profile. Publishing from scratch in the second case
//! replaces a rich profile with a bare one on every relay.
//!
//! This sidecar persists the last own kind-0 we fetched or published, derived
//! from the chat DB path like every other sidecar
//! (`sonar.db` → `sonar.db.sonar-profile.json`). When a publish-time fetch
//! comes back empty, the cache is the merge floor, so the republished event
//! can never carry fewer fields than the richest profile this device has
//! seen. When the fetch succeeds, the relay copy stays authoritative — the
//! cache never resurrects a field the user deleted through another client.

use std::fs;
use std::path::{Path, PathBuf};

use nostr::Metadata;
use serde::{Deserialize, Serialize};

use crate::{Error, Result};

pub(crate) const OWN_PROFILE_FILE_SUFFIX: &str = ".sonar-profile.json";
const OWN_PROFILE_VERSION: u32 = 1;

/// Sidecar path for the own-profile cache, derived from the chat DB path
/// like every other sidecar (`sonar.db` → `sonar.db.sonar-profile.json`).
pub(crate) fn own_profile_path_for_db(db_path: &Path) -> PathBuf {
    let name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar.db");
    db_path.with_file_name(format!("{name}{OWN_PROFILE_FILE_SUFFIX}"))
}

#[derive(Serialize, Deserialize)]
struct OwnProfileDisk {
    version: u32,
    /// The kind-0 content of the last profile we fetched or published.
    metadata: Metadata,
}

/// Load the cached own profile. Missing/corrupt files read as "no cache" —
/// the cache is an optimization over the relay copy, so corruption must never
/// take the publish path down.
pub(crate) fn load_own_profile(path: &Path) -> Option<Metadata> {
    let bytes = fs::read(path).ok()?;
    let disk: OwnProfileDisk = serde_json::from_slice(&bytes).ok()?;
    Some(disk.metadata)
}

/// Persist the own profile atomically (tmp + rename), matching the other
/// sidecars so a crash mid-write can't leave a truncated file.
pub(crate) fn store_own_profile(path: &Path, metadata: &Metadata) -> Result<()> {
    let disk = OwnProfileDisk {
        version: OWN_PROFILE_VERSION,
        metadata: metadata.clone(),
    };
    let bytes = serde_json::to_vec(&disk)
        .map_err(|e| Error::InvalidInput(format!("own profile serialize: {e}")))?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, bytes)
        .map_err(|e| Error::InvalidInput(format!("own profile write {}: {e}", tmp.display())))?;
    fs::rename(&tmp, path)
        .map_err(|e| Error::InvalidInput(format!("own profile rename {}: {e}", path.display())))?;
    Ok(())
}

/// Remove the sidecar (account wipe). Missing file is fine.
pub(crate) fn wipe_own_profile_for_db(db_path: &Path) -> Result<()> {
    let path = own_profile_path_for_db(db_path);
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(Error::InvalidInput(format!(
            "own profile wipe {}: {e}",
            path.display()
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sidecar_round_trip_and_wipe() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("sonar.db");
        let path = own_profile_path_for_db(&db);
        assert!(load_own_profile(&path).is_none());

        let metadata = Metadata::new()
            .name("vincenzo")
            .about("bitcoin dev")
            .picture(nostr::Url::parse("https://example.com/pic.png").unwrap());
        store_own_profile(&path, &metadata).unwrap();
        assert_eq!(load_own_profile(&path), Some(metadata));

        wipe_own_profile_for_db(&db).unwrap();
        wipe_own_profile_for_db(&db).unwrap(); // idempotent
        assert!(load_own_profile(&path).is_none());
    }

    #[test]
    fn corrupt_sidecar_reads_as_no_cache() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("sonar.db");
        let path = own_profile_path_for_db(&db);
        fs::write(&path, b"not json").unwrap();
        assert!(load_own_profile(&path).is_none());
    }
}
