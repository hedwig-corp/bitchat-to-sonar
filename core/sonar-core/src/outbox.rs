//! Durable local outbox metadata for Signal-style sends.
//!
//! Message bodies stay in MDK's encrypted SQLCipher store. This sidecar stores
//! only the already-encrypted relay event plus delivery metadata so a local
//! pending message can survive restart and be retried when relays attach.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use nostr::{Event, JsonUtil};
use serde::{Deserialize, Serialize};

use crate::marmot::DeliveryState;
use crate::{Error, Result};

pub(crate) const OUTBOX_STATE_FILE_SUFFIX: &str = ".sonar-outbox.json";
const OUTBOX_STATE_VERSION: u32 = 1;
const MAX_AUTOMATIC_RETRY_DELAY_SECS: u64 = 30;

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
        self.entries.get(message_id_hex).map(|entry| entry.state)
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

    pub fn remove_group_entries(&mut self, group_id_hex: &str) -> Result<()> {
        let before = self.entries.len();
        self.entries
            .retain(|_, entry| entry.group_id_hex != group_id_hex);
        if self.entries.len() != before {
            self.dirty = true;
        }
        self.save_if_dirty()
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

    /// Move one failed row back to pending and return its already-encrypted
    /// relay event for a user-initiated retry. Manual retry deliberately resets
    /// the automatic-attempt budget: a long outage must not permanently disable
    /// the Signal-style retry button after the transport comes back.
    pub fn retry_failed_event(
        &mut self,
        message_id_hex: &str,
        now_secs: u64,
    ) -> Result<(String, Event)> {
        let entry = self
            .entries
            .get_mut(message_id_hex)
            .ok_or_else(|| Error::InvalidInput("message is no longer available to retry".into()))?;
        if entry.state != DeliveryState::Failed {
            return Err(Error::InvalidInput("message is not failed".into()));
        }
        let event = Event::from_json(&entry.event_json)
            .map_err(|e| Error::Storage(format!("outbox event decode: {e}")))?;
        let group_id_hex = entry.group_id_hex.clone();
        entry.state = DeliveryState::Pending;
        entry.updated_at_secs = now_secs;
        entry.attempts = 0;
        entry.last_error = None;
        self.dirty = true;
        self.save_if_dirty()?;
        Ok((group_id_hex, event))
    }

    /// Returns `(message_id_hex, group_id_hex, event)` for each retryable row.
    /// `group_id_hex` is the MLS id hosts use for conversation refresh (not
    /// the Nostr `#h` / `nostr_group_id`).
    pub fn retryable_events(
        &mut self,
        now_secs: u64,
        active_group_ids: &HashSet<String>,
    ) -> Result<Vec<(String, String, Event)>> {
        let mut out = Vec::new();
        let before = self.entries.len();
        self.entries
            .retain(|_, entry| active_group_ids.contains(&entry.group_id_hex));
        if self.entries.len() != before {
            self.dirty = true;
        }
        for entry in self.entries.values_mut() {
            if !matches!(entry.state, DeliveryState::Pending | DeliveryState::Failed) {
                continue;
            }
            // A wall-clock correction must not strand a durable send behind a
            // timestamp that is now days or months in the future. Rebase it
            // onto the current clock and preserve only the bounded backoff.
            if entry.updated_at_secs > now_secs {
                entry.updated_at_secs = now_secs;
                self.dirty = true;
            }
            let retry_at = entry
                .updated_at_secs
                .saturating_add(automatic_retry_delay_secs(entry.attempts));
            if entry.attempts > 0 && now_secs < retry_at {
                continue;
            }
            let event = Event::from_json(&entry.event_json)
                .map_err(|e| Error::Storage(format!("outbox event decode: {e}")))?;
            entry.state = DeliveryState::Pending;
            entry.updated_at_secs = now_secs;
            entry.last_error = None;
            self.dirty = true;
            out.push((
                entry.message_id_hex.clone(),
                entry.group_id_hex.clone(),
                event,
            ));
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

fn automatic_retry_delay_secs(attempts: u32) -> u64 {
    if attempts == 0 {
        return 0;
    }
    1u64.checked_shl(attempts.saturating_sub(1).min(31))
        .unwrap_or(u64::MAX)
        .min(MAX_AUTOMATIC_RETRY_DELAY_SECS)
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
    use nostr::{EventBuilder, Keys, Kind};

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

    #[test]
    fn remove_group_entries_drops_pending_sends_for_deleted_chat() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("outbox.json");
        let mut outbox = OutboxState::load(Some(path.clone()));

        outbox
            .mark_pending(
                "deleted-group".into(),
                "deleted-message".into(),
                "wrapper-1".into(),
                "{}".into(),
                1,
            )
            .expect("mark pending deleted");
        outbox
            .mark_pending(
                "kept-group".into(),
                "kept-message".into(),
                "wrapper-2".into(),
                "{}".into(),
                1,
            )
            .expect("mark pending kept");
        outbox
            .remove_group_entries("deleted-group")
            .expect("remove group entries");

        let reloaded = OutboxState::load(Some(path));
        assert_eq!(reloaded.status_for_message("deleted-message"), None);
        assert_eq!(
            reloaded.status_for_message("kept-message"),
            Some(DeliveryState::Pending)
        );
    }

    #[test]
    fn retryable_events_purges_inactive_group_entries_before_decode() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("outbox.json");
        let mut outbox = OutboxState::load(Some(path.clone()));

        outbox
            .mark_pending(
                "deleted-group".into(),
                "deleted-message".into(),
                "wrapper".into(),
                "not-json".into(),
                1,
            )
            .expect("mark pending");

        let active_group_ids = HashSet::new();
        let events = outbox
            .retryable_events(2, &active_group_ids)
            .expect("retryable events");
        assert!(events.is_empty());

        let reloaded = OutboxState::load(Some(path));
        assert_eq!(reloaded.status_for_message("deleted-message"), None);
    }

    #[test]
    fn manual_retry_resets_failed_entry_and_backoff() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("outbox.json");
        let mut outbox = OutboxState::load(Some(path.clone()));
        let event = EventBuilder::new(Kind::TextNote, "encrypted payload")
            .sign_with_keys(&Keys::generate())
            .expect("signed event");

        outbox
            .mark_pending(
                "group".into(),
                "message".into(),
                event.id.to_hex(),
                event.as_json(),
                1,
            )
            .expect("mark pending");
        for attempt in 0..20 {
            outbox
                .mark_failed_by_message_id("message", format!("offline {attempt}"), 2)
                .expect("mark failed");
        }

        let (source_group, retried) = outbox
            .retry_failed_event("message", 3)
            .expect("manual retry");
        assert_eq!(source_group, "group");
        assert_eq!(retried.id, event.id);

        outbox
            .mark_failed_by_message_id("message", "still offline".into(), 4)
            .expect("mark failed after retry");
        let retryable = outbox
            .retryable_events(5, &HashSet::from(["group".to_string()]))
            .expect("manual retry reset backoff");
        assert_eq!(retryable.len(), 1);

        let reloaded = OutboxState::load(Some(path));
        assert_eq!(
            reloaded.status_for_message("message"),
            Some(DeliveryState::Pending)
        );
    }

    #[test]
    fn automatic_retry_does_not_exhaust_during_prolonged_outage() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("outbox.json");
        let mut outbox = OutboxState::load(Some(path.clone()));
        let event = EventBuilder::new(Kind::TextNote, "encrypted payload")
            .sign_with_keys(&Keys::generate())
            .expect("signed event");

        outbox
            .mark_pending(
                "group".into(),
                "message".into(),
                event.id.to_hex(),
                event.as_json(),
                1,
            )
            .expect("mark pending");
        for attempt in 0..100 {
            outbox
                .mark_failed_by_message_id("message", format!("offline {attempt}"), 2)
                .expect("mark failed");
        }

        let active = HashSet::from(["group".to_string()]);
        assert!(outbox
            .retryable_events(3, &active)
            .expect("backoff remains bounded")
            .is_empty());

        let retryable = outbox
            .retryable_events(32, &active)
            .expect("automatic retry remains available after a prolonged outage");
        assert_eq!(retryable.len(), 1);
        assert_eq!(retryable[0].2.id, event.id);

        let reloaded = OutboxState::load(Some(path));
        assert_eq!(
            reloaded.status_for_message("message"),
            Some(DeliveryState::Pending)
        );
    }

    #[test]
    fn automatic_retry_rebases_future_timestamp_after_clock_correction() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("outbox.json");
        let mut outbox = OutboxState::load(Some(path.clone()));
        let event = EventBuilder::new(Kind::TextNote, "encrypted payload")
            .sign_with_keys(&Keys::generate())
            .expect("signed event");

        outbox
            .mark_pending(
                "group".into(),
                "message".into(),
                event.id.to_hex(),
                event.as_json(),
                10_000,
            )
            .expect("mark pending");
        outbox
            .mark_failed_by_message_id("message", "offline".into(), 10_000)
            .expect("mark failed");

        let active = HashSet::from(["group".to_string()]);
        assert!(outbox
            .retryable_events(100, &active)
            .expect("future timestamp is rebased")
            .is_empty());
        let retryable = outbox
            .retryable_events(101, &active)
            .expect("bounded retry becomes due");
        assert_eq!(retryable.len(), 1);
        assert_eq!(retryable[0].2.id, event.id);

        let reloaded = OutboxState::load(Some(path));
        assert_eq!(
            reloaded.status_for_message("message"),
            Some(DeliveryState::Pending)
        );
    }

    #[test]
    fn automatic_retry_uses_exponential_backoff() {
        assert_eq!(automatic_retry_delay_secs(0), 0);
        assert_eq!(automatic_retry_delay_secs(1), 1);
        assert_eq!(automatic_retry_delay_secs(2), 2);
        assert_eq!(automatic_retry_delay_secs(5), 16);
        assert_eq!(automatic_retry_delay_secs(6), 30);
        assert_eq!(automatic_retry_delay_secs(u32::MAX), 30);
    }
}
