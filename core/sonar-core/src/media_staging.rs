//! Durable pre-Blossom media staging.
//!
//! Attachments are written to an app-owned staging directory (and a JSON sidecar)
//! *before* the Blossom upload starts. Mid-upload disconnect/kill keeps the
//! files so send can resume after relaunch. Only after a successful upload does
//! the normal outbox publish path take over.

use std::collections::HashMap;
use std::fs;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::{Error, Result};

pub(crate) const MEDIA_STAGING_STATE_FILE_SUFFIX: &str = ".sonar-media-staging.json";
pub(crate) const MEDIA_STAGING_DIR_SUFFIX: &str = ".sonar-media-staging";
const MEDIA_STAGING_STATE_VERSION: u32 = 1;
/// Failed staged rows older than this are deleted on resume prep so abandoned
/// sends cannot grow staging forever.
const FAILED_STAGING_TTL_SECS: u64 = 7 * 24 * 60 * 60;
const MAX_STAGING_ID_LEN: usize = 128;

fn is_safe_staging_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_STAGING_ID_LEN
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn is_safe_relative_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.contains('\\')
        && Path::new(path)
            .components()
            .all(|c| matches!(c, Component::Normal(_)))
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MediaStagingStatus {
    Uploading,
    Failed,
    /// Outbox already owns publish. Never auto-resume — a crash after
    /// `mark_outbox_pending` must not create a second kind-445.
    Committed,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub(crate) struct StagedMediaItem {
    pub filename: String,
    pub mime: String,
    /// Relative path under the staging directory (`{entry_id}/{index}.bin`).
    pub relative_path: String,
    pub byte_len: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub(crate) struct StagedMediaEntry {
    pub id: String,
    pub client_pending_id: String,
    pub group_id_hex: String,
    pub caption: String,
    pub server_url: String,
    pub items: Vec<StagedMediaItem>,
    pub created_at_secs: u64,
    pub updated_at_secs: u64,
    pub state: MediaStagingStatus,
    pub last_error: Option<String>,
    pub bytes_sent: u64,
    pub total_bytes: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct MediaStagingStateDisk {
    version: u32,
    entries: Vec<StagedMediaEntry>,
}

/// In-memory plaintext held only when durable staging is disabled (in-memory
/// test sessions). Persistent sessions always load bytes from disk.
#[derive(Debug, Default)]
struct InlinePayload {
    /// entry_id → per-item plaintext
    data: HashMap<String, Vec<Vec<u8>>>,
}

#[derive(Debug)]
pub(crate) struct MediaStagingState {
    state_path: Option<PathBuf>,
    dir_path: Option<PathBuf>,
    entries: HashMap<String, StagedMediaEntry>,
    inline: InlinePayload,
    dirty: bool,
}

impl MediaStagingState {
    pub fn load(state_path: Option<PathBuf>, dir_path: Option<PathBuf>) -> Self {
        let disk = state_path
            .as_ref()
            .and_then(|path| fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice::<MediaStagingStateDisk>(&bytes).ok())
            .filter(|state| state.version == MEDIA_STAGING_STATE_VERSION);

        let entries = disk
            .map(|state| {
                state
                    .entries
                    .into_iter()
                    .filter(|entry| {
                        is_safe_staging_id(&entry.id)
                            && is_safe_staging_id(&entry.client_pending_id)
                            && entry
                                .items
                                .iter()
                                .all(|item| is_safe_relative_path(&item.relative_path))
                    })
                    .map(|entry| (entry.id.clone(), entry))
                    .collect()
            })
            .unwrap_or_default();

        Self {
            state_path,
            dir_path,
            entries,
            inline: InlinePayload::default(),
            dirty: false,
        }
    }

    pub fn get(&self, id: &str) -> Option<&StagedMediaEntry> {
        self.entries.get(id)
    }

    /// Uploading + Failed ids (manual retry / UI). Auto-resume uses [`Self::resumable_ids`].
    #[allow(dead_code)]
    pub fn pending_ids(&self) -> Vec<String> {
        let mut ids: Vec<_> = self.entries.keys().cloned().collect();
        ids.sort();
        ids
    }

    /// Entries safe to auto-resume after relaunch. Failed rows stay until the
    /// host explicitly retries — otherwise every cold start would re-upload
    /// (and potentially double-publish) abandoned sends.
    pub fn resumable_ids(&self) -> Vec<String> {
        let mut ids: Vec<_> = self
            .entries
            .iter()
            .filter(|(_, entry)| entry.state == MediaStagingStatus::Uploading)
            .map(|(id, _)| id.clone())
            .collect();
        ids.sort();
        ids
    }

    pub fn stage(
        &mut self,
        id: String,
        client_pending_id: String,
        group_id_hex: String,
        caption: String,
        server_url: String,
        items: Vec<(String, String, Vec<u8>)>,
        now_secs: u64,
    ) -> Result<()> {
        if !is_safe_staging_id(&id) || !is_safe_staging_id(&client_pending_id) {
            return Err(Error::Media(
                "staged media id must be a bounded alphanumeric token".into(),
            ));
        }
        if items.is_empty() {
            return Err(Error::Media("no media to stage".into()));
        }
        let total_bytes: u64 = items.iter().map(|(_, _, data)| data.len() as u64).sum();
        let mut staged_items = Vec::with_capacity(items.len());
        let mut inline_payload = Vec::with_capacity(items.len());

        if let Some(dir) = self.dir_path.clone() {
            let entry_dir = dir.join(&id);
            fs::create_dir_all(&entry_dir).map_err(|e| {
                Error::Storage(format!(
                    "create media staging dir {}: {e}",
                    entry_dir.display()
                ))
            })?;
            for (index, (filename, mime, data)) in items.into_iter().enumerate() {
                let relative_path = format!("{id}/{index}.bin");
                let absolute = dir.join(&relative_path);
                if let Some(parent) = absolute.parent() {
                    fs::create_dir_all(parent).map_err(|e| {
                        Error::Storage(format!(
                            "create media staging parent {}: {e}",
                            parent.display()
                        ))
                    })?;
                }
                write_private_file(&absolute, &data)?;
                staged_items.push(StagedMediaItem {
                    filename,
                    mime,
                    relative_path,
                    byte_len: data.len() as u64,
                });
            }
        } else {
            for (index, (filename, mime, data)) in items.into_iter().enumerate() {
                staged_items.push(StagedMediaItem {
                    filename,
                    mime,
                    relative_path: format!("{id}/{index}.bin"),
                    byte_len: data.len() as u64,
                });
                inline_payload.push(data);
            }
            self.inline.data.insert(id.clone(), inline_payload);
        }

        let entry = StagedMediaEntry {
            id: id.clone(),
            client_pending_id,
            group_id_hex,
            caption,
            server_url,
            items: staged_items,
            created_at_secs: now_secs,
            updated_at_secs: now_secs,
            state: MediaStagingStatus::Uploading,
            last_error: None,
            bytes_sent: 0,
            total_bytes,
        };
        self.entries.insert(id, entry);
        self.dirty = true;
        self.save_if_dirty()
    }

    pub fn update_progress(
        &mut self,
        id: &str,
        bytes_sent: u64,
        now_secs: u64,
        persist: bool,
    ) -> Result<()> {
        let Some(entry) = self.entries.get_mut(id) else {
            return Ok(());
        };
        if bytes_sent > entry.bytes_sent {
            entry.bytes_sent = bytes_sent.min(entry.total_bytes);
            entry.updated_at_secs = now_secs;
            if entry.state != MediaStagingStatus::Committed {
                entry.state = MediaStagingStatus::Uploading;
            }
            self.dirty = true;
        }
        if persist {
            self.save_if_dirty()
        } else {
            Ok(())
        }
    }

    pub fn mark_failed(&mut self, id: &str, error: String, now_secs: u64) -> Result<()> {
        let Some(entry) = self.entries.get_mut(id) else {
            return Ok(());
        };
        entry.state = MediaStagingStatus::Failed;
        entry.last_error = Some(error);
        entry.updated_at_secs = now_secs;
        self.dirty = true;
        self.save_if_dirty()
    }

    pub fn mark_uploading(&mut self, id: &str, now_secs: u64) -> Result<()> {
        let Some(entry) = self.entries.get_mut(id) else {
            return Ok(());
        };
        if entry.state == MediaStagingStatus::Committed {
            return Ok(());
        }
        entry.state = MediaStagingStatus::Uploading;
        entry.last_error = None;
        entry.updated_at_secs = now_secs;
        self.dirty = true;
        self.save_if_dirty()
    }

    /// Outbox row is durable — never auto-resume this entry again.
    pub fn mark_committed(&mut self, id: &str, now_secs: u64) -> Result<()> {
        let Some(entry) = self.entries.get_mut(id) else {
            return Ok(());
        };
        entry.state = MediaStagingStatus::Committed;
        entry.last_error = None;
        entry.updated_at_secs = now_secs;
        self.dirty = true;
        self.save_if_dirty()
    }

    pub fn remove(&mut self, id: &str) -> Result<()> {
        if !is_safe_staging_id(id) {
            return Err(Error::Media(
                "staged media id must be a bounded alphanumeric token".into(),
            ));
        }
        self.inline.data.remove(id);
        if self.entries.remove(id).is_some() {
            self.dirty = true;
        }
        if let Some(dir) = self.dir_path.as_ref() {
            let entry_dir = dir.join(id);
            let _ = fs::remove_dir_all(entry_dir);
        }
        self.save_if_dirty()
    }

    pub fn load_item_bytes(&self, entry: &StagedMediaEntry) -> Result<Vec<Vec<u8>>> {
        if !is_safe_staging_id(&entry.id) {
            return Err(Error::Media(
                "staged media id must be a bounded alphanumeric token".into(),
            ));
        }
        if let Some(inline) = self.inline.data.get(&entry.id) {
            return Ok(inline.clone());
        }
        let dir = self.dir_path.as_ref().ok_or_else(|| {
            Error::Storage("media staging has no directory and no inline payload".into())
        })?;
        let mut out = Vec::with_capacity(entry.items.len());
        for item in &entry.items {
            if !is_safe_relative_path(&item.relative_path) {
                return Err(Error::Storage(format!(
                    "unsafe staged media path: {}",
                    item.relative_path
                )));
            }
            let path = dir.join(&item.relative_path);
            let bytes = fs::read(&path).map_err(|e| {
                Error::Storage(format!("read staged media {}: {e}", path.display()))
            })?;
            if bytes.len() as u64 != item.byte_len {
                return Err(Error::Storage(format!(
                    "staged media size mismatch for {}: expected {} got {}",
                    path.display(),
                    item.byte_len,
                    bytes.len()
                )));
            }
            out.push(bytes);
        }
        Ok(out)
    }

    pub fn reload_from_disk(&mut self) {
        // In-memory sessions have no sidecar; reloading would wipe live entries
        // mid-upload and turn progress/fail updates into silent no-ops.
        let Some(state_path) = self.state_path.clone() else {
            return;
        };
        let dir_path = self.dir_path.clone();
        let reloaded = Self::load(Some(state_path), dir_path);
        self.entries = reloaded.entries;
        self.dirty = false;
    }

    /// Drop Committed rows immediately and Failed rows older than
    /// [`FAILED_STAGING_TTL_SECS`].
    pub fn purge_expired_failed(&mut self, now_secs: u64) -> Result<()> {
        let expired: Vec<String> = self
            .entries
            .iter()
            .filter(|(_, entry)| {
                entry.state == MediaStagingStatus::Committed
                    || (entry.state == MediaStagingStatus::Failed
                        && now_secs.saturating_sub(entry.updated_at_secs)
                            >= FAILED_STAGING_TTL_SECS)
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in expired {
            self.remove(&id)?;
        }
        Ok(())
    }

    fn save_if_dirty(&mut self) -> Result<()> {
        if !self.dirty {
            return Ok(());
        }
        let Some(path) = self.state_path.as_ref() else {
            self.dirty = false;
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| {
                Error::Storage(format!(
                    "create media-staging-state dir {}: {e}",
                    parent.display()
                ))
            })?;
        }
        let mut entries: Vec<_> = self.entries.values().cloned().collect();
        entries.sort_by_key(|entry| (entry.created_at_secs, entry.id.clone()));
        let disk = MediaStagingStateDisk {
            version: MEDIA_STAGING_STATE_VERSION,
            entries,
        };
        let bytes = serde_json::to_vec(&disk)?;
        let tmp = media_staging_state_tmp_path(path);
        fs::write(&tmp, &bytes).map_err(|e| {
            Error::Storage(format!("write media staging state {}: {e}", tmp.display()))
        })?;
        fs::rename(&tmp, path).map_err(|e| {
            Error::Storage(format!(
                "replace media staging state {}: {e}",
                path.display()
            ))
        })?;
        self.dirty = false;
        Ok(())
    }
}

pub(crate) fn media_staging_paths_for_db(db_path: &Path) -> (PathBuf, PathBuf) {
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar");
    let state = db_path.with_file_name(format!("{file_name}{MEDIA_STAGING_STATE_FILE_SUFFIX}"));
    let dir = db_path.with_file_name(format!("{file_name}{MEDIA_STAGING_DIR_SUFFIX}"));
    (state, dir)
}

pub(crate) fn wipe_media_staging_for_db(db_path: &Path) -> Result<()> {
    let (state, dir) = media_staging_paths_for_db(db_path);
    if state.exists() {
        fs::remove_file(&state).map_err(|e| {
            Error::Storage(format!("remove media staging state {}: {e}", state.display()))
        })?;
    }
    if dir.exists() {
        fs::remove_dir_all(&dir).map_err(|e| {
            Error::Storage(format!("remove media staging dir {}: {e}", dir.display()))
        })?;
    }
    Ok(())
}

fn media_staging_state_tmp_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-media-staging.json");
    path.with_file_name(format!("{file_name}.tmp"))
}

fn write_private_file(path: &Path, data: &[u8]) -> Result<()> {
    let mut options = fs::OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    use std::io::Write as _;
    let mut file = options
        .open(path)
        .map_err(|e| Error::Storage(format!("create staged media {}: {e}", path.display())))?;
    file.write_all(data)
        .and_then(|_| file.sync_all())
        .map_err(|e| Error::Storage(format!("write staged media {}: {e}", path.display())))?;
    Ok(())
}

pub(crate) fn new_media_staging_id() -> String {
    let mut buf = [0u8; 16];
    let _ = getrandom::getrandom(&mut buf);
    hex::encode(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stage_survives_reload_and_remove_cleans_files() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db = dir.path().join("chat.db");
        let (state_path, staging_dir) = media_staging_paths_for_db(&db);
        let mut staging = MediaStagingState::load(Some(state_path.clone()), Some(staging_dir.clone()));

        staging
            .stage(
                "pending-1".into(),
                "pending-1".into(),
                "group".into(),
                "hi".into(),
                "".into(),
                vec![("a.jpg".into(), "image/jpeg".into(), b"abc".to_vec())],
                10,
            )
            .expect("stage");

        let file = staging_dir.join("pending-1/0.bin");
        assert_eq!(fs::read(&file).expect("read staged"), b"abc");

        let reloaded = MediaStagingState::load(Some(state_path), Some(staging_dir.clone()));
        let entry = reloaded.get("pending-1").expect("entry");
        assert_eq!(entry.state, MediaStagingStatus::Uploading);
        assert_eq!(entry.total_bytes, 3);
        let bytes = reloaded.load_item_bytes(entry).expect("load");
        assert_eq!(bytes, vec![b"abc".to_vec()]);

        let mut staging = reloaded;
        staging.remove("pending-1").expect("remove");
        assert!(staging.get("pending-1").is_none());
        assert!(!file.exists());
    }

    #[test]
    fn fail_then_retry_updates_state() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db = dir.path().join("chat.db");
        let (state_path, staging_dir) = media_staging_paths_for_db(&db);
        let mut staging = MediaStagingState::load(Some(state_path), Some(staging_dir));
        staging
            .stage(
                "p".into(),
                "p".into(),
                "g".into(),
                "".into(),
                "".into(),
                vec![("a.jpg".into(), "image/jpeg".into(), b"x".to_vec())],
                1,
            )
            .expect("stage");
        staging
            .mark_failed("p", "network down".into(), 2)
            .expect("fail");
        assert_eq!(
            staging.get("p").expect("entry").state,
            MediaStagingStatus::Failed
        );
        assert!(
            staging.resumable_ids().is_empty(),
            "failed rows must not auto-resume"
        );
        assert_eq!(staging.pending_ids(), vec!["p".to_string()]);
        staging.mark_uploading("p", 3).expect("retry");
        assert_eq!(
            staging.get("p").expect("entry").state,
            MediaStagingStatus::Uploading
        );
        assert_eq!(staging.resumable_ids(), vec!["p".to_string()]);
    }

    #[test]
    fn committed_is_not_resumable_and_is_purged() {
        let mut staging = MediaStagingState::load(None, None);
        staging
            .stage(
                "c".into(),
                "c".into(),
                "g".into(),
                "".into(),
                "".into(),
                vec![("a.jpg".into(), "image/jpeg".into(), b"x".to_vec())],
                1,
            )
            .expect("stage");
        staging.mark_committed("c", 2).expect("commit");
        assert!(staging.resumable_ids().is_empty());
        staging.purge_expired_failed(2).expect("purge");
        assert!(staging.get("c").is_none());
    }

    #[test]
    fn rejects_unsafe_staging_ids() {
        let mut staging = MediaStagingState::load(None, None);
        let err = staging
            .stage(
                "../evil".into(),
                "ok".into(),
                "g".into(),
                "".into(),
                "".into(),
                vec![("a.jpg".into(), "image/jpeg".into(), b"x".to_vec())],
                1,
            )
            .expect_err("path traversal id");
        assert!(err.to_string().contains("alphanumeric"));
    }

    #[test]
    fn purge_expired_failed_keeps_fresh_rows() {
        let mut staging = MediaStagingState::load(None, None);
        staging
            .stage(
                "old".into(),
                "old".into(),
                "g".into(),
                "".into(),
                "".into(),
                vec![("a.jpg".into(), "image/jpeg".into(), b"x".to_vec())],
                1,
            )
            .expect("stage");
        staging
            .mark_failed("old", "gone".into(), 1)
            .expect("fail");
        staging
            .stage(
                "fresh".into(),
                "fresh".into(),
                "g".into(),
                "".into(),
                "".into(),
                vec![("b.jpg".into(), "image/jpeg".into(), b"y".to_vec())],
                1,
            )
            .expect("stage");
        staging
            .mark_failed("fresh", "recent".into(), 1_000_000)
            .expect("fail");
        staging
            .purge_expired_failed(1 + FAILED_STAGING_TTL_SECS)
            .expect("purge");
        assert!(staging.get("old").is_none());
        assert!(staging.get("fresh").is_some());
    }

    #[test]
    fn load_skips_unsafe_disk_entries() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db = dir.path().join("chat.db");
        let (state_path, staging_dir) = media_staging_paths_for_db(&db);
        let disk = MediaStagingStateDisk {
            version: MEDIA_STAGING_STATE_VERSION,
            entries: vec![StagedMediaEntry {
                id: "../evil".into(),
                client_pending_id: "ok".into(),
                group_id_hex: "g".into(),
                caption: String::new(),
                server_url: String::new(),
                items: vec![StagedMediaItem {
                    filename: "a.jpg".into(),
                    mime: "image/jpeg".into(),
                    relative_path: "../../etc/passwd".into(),
                    byte_len: 1,
                }],
                created_at_secs: 1,
                updated_at_secs: 1,
                state: MediaStagingStatus::Uploading,
                last_error: None,
                bytes_sent: 0,
                total_bytes: 1,
            }],
        };
        fs::write(
            &state_path,
            serde_json::to_vec(&disk).expect("serialize"),
        )
        .expect("write");
        let staging = MediaStagingState::load(Some(state_path), Some(staging_dir));
        assert!(staging.entries.is_empty());
    }

    #[test]
    fn reload_from_disk_is_noop_without_state_path() {
        let mut staging = MediaStagingState::load(None, None);
        staging
            .stage(
                "live".into(),
                "live".into(),
                "g".into(),
                "".into(),
                "".into(),
                vec![("a.jpg".into(), "image/jpeg".into(), b"x".to_vec())],
                1,
            )
            .expect("stage");
        staging.reload_from_disk();
        assert!(staging.get("live").is_some());
    }

    #[test]
    fn progress_is_monotonic() {
        let mut staging = MediaStagingState::load(None, None);
        staging
            .stage(
                "p".into(),
                "p".into(),
                "g".into(),
                "".into(),
                "".into(),
                vec![("a.jpg".into(), "image/jpeg".into(), vec![0u8; 100])],
                1,
            )
            .expect("stage");
        staging.update_progress("p", 40, 2, true).expect("p1");
        staging.update_progress("p", 20, 3, true).expect("p2 ignored");
        staging.update_progress("p", 80, 4, true).expect("p3");
        assert_eq!(staging.get("p").expect("entry").bytes_sent, 80);
    }
}
