//! Durable local outbox metadata for Signal-style sends.
//!
//! Message bodies stay in MDK's encrypted SQLCipher store. This sidecar stores
//! only the already-encrypted relay event plus delivery metadata so a local
//! pending message can survive restart and be retried when relays attach.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use nostr::{Event, JsonUtil};
use serde::{Deserialize, Serialize};

use crate::marmot::DeliveryState;
use crate::{Error, Result};

pub(crate) const OUTBOX_STATE_FILE_SUFFIX: &str = ".sonar-outbox.json";
const OUTBOX_STATE_VERSION: u32 = 1;
const OUTBOX_RETRY_ATTEMPT_LIMIT: u32 = 20;

#[derive(Clone, Debug, Deserialize, Serialize)]
struct OutboxStateDisk {
    version: u32,
    entries: Vec<OutboxEntry>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub(crate) struct OutboxEntry {
    pub group_id_hex: String,
    pub message_id_hex: String,
    pub wrapper_event_id_hex: String,
    pub event_json: String,
    pub created_at_secs: u64,
    pub updated_at_secs: u64,
    pub attempts: u32,
    pub state: DeliveryState,
    pub last_error: Option<String>,
}

#[derive(Debug)]
pub(crate) struct OutboxState {
    path: Option<PathBuf>,
    entries: HashMap<String, OutboxEntry>,
    dirty: bool,
}

impl OutboxState {
    pub fn load(path: Option<PathBuf>) -> Self {
        let disk = path
            .as_ref()
            .and_then(|path| fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice::<OutboxStateDisk>(&bytes).ok())
            .filter(|state| state.version == OUTBOX_STATE_VERSION);

        let entries = disk
            .map(|state| {
                state
                    .entries
                    .into_iter()
                    .map(|entry| (entry.message_id_hex.clone(), entry))
                    .collect()
            })
            .unwrap_or_default();

        Self {
            path,
            entries,
            dirty: false,
        }
    }

    pub fn status_for_message(&self, message_id_hex: &str) -> Option<DeliveryState> {
        self.entries
            .get(message_id_hex)
            .map(|entry| entry.state.clone())
    }

    pub fn mark_pending(
        &mut self,
        group_id_hex: String,
        message_id_hex: String,
        wrapper_event_id_hex: String,
        event_json: String,
        now_secs: u64,
    ) -> Result<()> {
        let entry = OutboxEntry {
            group_id_hex,
            message_id_hex: message_id_hex.clone(),
            wrapper_event_id_hex,
            event_json,
            created_at_secs: now_secs,
            updated_at_secs: now_secs,
            attempts: 0,
            state: DeliveryState::Pending,
            last_error: None,
        };
        self.entries.insert(message_id_hex, entry);
        self.dirty = true;
        self.save_if_dirty()
    }

    pub fn mark_sent_by_message_id(&mut self, message_id_hex: &str, _now_secs: u64) -> Result<()> {
        if self.entries.remove(message_id_hex).is_some() {
            self.dirty = true;
        }
        self.save_if_dirty()
    }

    pub fn reload_from_disk(&mut self) {
        let path = self.path.clone();
        let reloaded = Self::load(path);
        self.entries = reloaded.entries;
        self.dirty = false;
    }

    pub fn mark_failed_by_message_id(
        &mut self,
        message_id_hex: &str,
        error: String,
        now_secs: u64,
    ) -> Result<()> {
        if let Some(entry) = self.entries.get_mut(message_id_hex) {
            entry.state = DeliveryState::Failed;
            entry.updated_at_secs = now_secs;
            entry.attempts = entry.attempts.saturating_add(1);
            entry.last_error = Some(error);
            self.dirty = true;
        }
        self.save_if_dirty()
    }

    pub fn retryable_events(&mut self, now_secs: u64) -> Result<Vec<(String, Event)>> {
        let mut out = Vec::new();
        for entry in self.entries.values_mut() {
            if !matches!(entry.state, DeliveryState::Pending | DeliveryState::Failed) {
                continue;
            }
            if entry.attempts >= OUTBOX_RETRY_ATTEMPT_LIMIT {
                continue;
            }
            let event = Event::from_json(&entry.event_json)
                .map_err(|e| Error::Storage(format!("outbox event decode: {e}")))?;
            entry.state = DeliveryState::Pending;
            entry.updated_at_secs = now_secs;
            entry.last_error = None;
            self.dirty = true;
            out.push((entry.message_id_hex.clone(), event));
        }
        self.save_if_dirty()?;
        Ok(out)
    }

    fn save_if_dirty(&mut self) -> Result<()> {
        if !self.dirty {
            return Ok(());
        }
        let Some(path) = self.path.as_ref() else {
            self.dirty = false;
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| {
                Error::Storage(format!("create outbox-state dir {}: {e}", parent.display()))
            })?;
        }
        let mut entries: Vec<_> = self.entries.values().cloned().collect();
        entries.sort_by_key(|entry| (entry.created_at_secs, entry.message_id_hex.clone()));
        let disk = OutboxStateDisk {
            version: OUTBOX_STATE_VERSION,
            entries,
        };
        let bytes = serde_json::to_vec(&disk)?;
        let tmp = outbox_state_tmp_path(path);
        fs::write(&tmp, bytes)
            .map_err(|e| Error::Storage(format!("write outbox state {}: {e}", tmp.display())))?;
        fs::rename(&tmp, path)
            .map_err(|e| Error::Storage(format!("replace outbox state {}: {e}", path.display())))?;
        self.dirty = false;
        Ok(())
    }
}

pub(crate) fn outbox_state_path_for_db(db_path: &Path) -> PathBuf {
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-outbox.json");
    db_path.with_file_name(format!("{file_name}{OUTBOX_STATE_FILE_SUFFIX}"))
}

fn outbox_state_tmp_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-outbox.json");
    path.with_file_name(format!("{file_name}.tmp"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mark_sent_compacts_retry_payload() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("outbox.json");
        let mut outbox = OutboxState::load(Some(path.clone()));

        outbox
            .mark_pending(
                "group".into(),
                "message".into(),
                "wrapper".into(),
                "{}".into(),
                1,
            )
            .expect("mark pending");
        outbox
            .mark_sent_by_message_id("message", 2)
            .expect("mark sent");

        let reloaded = OutboxState::load(Some(path));
        assert_eq!(reloaded.status_for_message("message"), None);
    }

    #[test]
    fn reload_from_disk_picks_up_pending_entries() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("outbox.json");
        let mut stale = OutboxState::load(Some(path.clone()));
        let mut writer = OutboxState::load(Some(path));

        writer
            .mark_pending(
                "group".into(),
                "message".into(),
                "wrapper".into(),
                "{}".into(),
                1,
            )
            .expect("mark pending");
        assert_eq!(stale.status_for_message("message"), None);

        stale.reload_from_disk();
        assert_eq!(
            stale.status_for_message("message"),
            Some(DeliveryState::Pending)
        );
    }
}
