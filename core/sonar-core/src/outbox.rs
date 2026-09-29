//! Durable local outbox metadata for Signal-style sends.
//!
//! Message bodies stay in MDK's encrypted SQLCipher store. This sidecar stores
//! only the already-encrypted relay event plus delivery metadata so a local
//! pending message can survive restart and be retried when relays attach.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostr::{Event, JsonUtil};
use serde::{Deserialize, Serialize};

use crate::marmot::DeliveryState;
use crate::{Error, Result};

pub(crate) const OUTBOX_STATE_FILE_SUFFIX: &str = ".sonar-outbox.json";
const OUTBOX_STATE_VERSION: u32 = 1;
pub(crate) const OUTBOX_RETRY_ATTEMPT_LIMIT: u32 = 20;

/// Backoff before core auto-retries a failed publish. Hosts also call
/// `retry_outbox` on idle/reconnect; this schedule keeps a transient outage
/// from stranding the row until app restart while an active chat keeps the
/// wake loop busy (idle `ensure_subscriptions` never runs).
pub(crate) fn outbox_auto_retry_delay_secs(attempts: u32) -> u64 {
    match attempts {
        0 | 1 => 2,
        2 => 4,
        3 => 8,
        4 => 16,
        _ => 30,
    }
}

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
    /// Depth of `suspend_saves` holds; writes resume at zero.
    saves_suspended: u32,
    /// Sidecar writes so far. Tests and the bench measure coalescing with it.
    saves: u64,
}

/// How long the ack path waits before flushing the sidecar, so a burst of acks
/// rewrites it once. A crash inside the window leaves acked rows Pending; the
/// next `retry_outbox` republishes them and relays drop the duplicate by id.
pub(crate) const OUTBOX_ACK_FLUSH_DELAY: Duration = Duration::from_millis(100);

/// Flush the sidecar once, `delay` after the first request of a burst. The
/// flag clears before the write, so a row marked after the write (and before
/// this task ends) schedules the next flush instead of being lost.
pub(crate) fn schedule_outbox_flush(
    outbox: Arc<Mutex<OutboxState>>,
    pending: Arc<AtomicBool>,
    delay: Duration,
) {
    if pending.swap(true, Ordering::AcqRel) {
        return;
    }
    tokio::spawn(async move {
        tokio::time::sleep(delay).await;
        pending.store(false, Ordering::Release);
        let result = outbox.lock().unwrap().save_if_dirty();
        if let Err(err) = result {
            tracing::debug!(%err, "outbox flush failed");
        }
    });
}

/// Holds the sidecar's disk writes for the life of a batch that mutates many
/// rows (the local-time fan-out): one write at the end instead of one per row.
/// Every row of such a batch carries the same one fact, so a crash inside it
/// costs at most that batch, never a chat message.
pub(crate) struct OutboxSaveBatch {
    outbox: Arc<Mutex<OutboxState>>,
}

impl OutboxSaveBatch {
    pub(crate) fn begin(outbox: &Arc<Mutex<OutboxState>>) -> Self {
        outbox.lock().unwrap().suspend_saves();
        Self {
            outbox: outbox.clone(),
        }
    }
}

impl Drop for OutboxSaveBatch {
    fn drop(&mut self) {
        if let Ok(mut outbox) = self.outbox.lock() {
            if let Err(err) = outbox.resume_saves() {
                tracing::debug!(%err, "outbox batch flush failed");
            }
        }
    }
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
            saves_suspended: 0,
            saves: 0,
        }
    }

    pub fn status_for_message(&self, message_id_hex: &str) -> Option<DeliveryState> {
        self.entries.get(message_id_hex).map(|entry| entry.state)
    }

    #[cfg(test)]
    pub(crate) fn recorded_count(&self) -> usize {
        self.entries.len()
    }

    /// Hold disk writes while a caller mutates many rows. Holds nest; the
    /// last `resume_saves` writes whatever is dirty.
    pub fn suspend_saves(&mut self) {
        self.saves_suspended += 1;
    }

    pub fn resume_saves(&mut self) -> Result<()> {
        self.saves_suspended = self.saves_suspended.saturating_sub(1);
        if self.saves_suspended == 0 {
            self.save_if_dirty()
        } else {
            Ok(())
        }
    }

    /// `mark_sent_by_message_id` without the disk write. The caller owes a
    /// `schedule_outbox_flush`, which lets an ack burst rewrite the sidecar
    /// once instead of once per ack.
    pub fn mark_sent_by_message_id_lazy(&mut self, message_id_hex: &str) {
        if self.entries.remove(message_id_hex).is_some() {
            self.dirty = true;
        }
    }

    /// Sidecar writes so far.
    pub(crate) fn save_count(&self) -> u64 {
        self.saves
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

    /// Detach from durable storage and drop in-memory rows. Used when the owning
    /// [`crate::client::SonarClient`] is dropped so a still-running publish /
    /// auto-retry task cannot recreate a wiped `.sonar-outbox.json` sidecar.
    pub fn detach(&mut self) {
        self.path = None;
        self.entries.clear();
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

    /// Marks the row failed and returns the new attempt count when the entry
    /// still existed. `None` means the row was already compacted (sent) or never
    /// recorded — callers must not schedule another auto-retry in that case.
    pub fn mark_failed_by_message_id(
        &mut self,
        message_id_hex: &str,
        error: String,
        now_secs: u64,
    ) -> Result<Option<u32>> {
        let attempts = if let Some(entry) = self.entries.get_mut(message_id_hex) {
            entry.state = DeliveryState::Failed;
            entry.updated_at_secs = now_secs;
            entry.attempts = entry.attempts.saturating_add(1);
            entry.last_error = Some(error);
            self.dirty = true;
            Some(entry.attempts)
        } else {
            None
        };
        self.save_if_dirty()?;
        Ok(attempts)
    }

    /// Move one failed row back to pending for a core-owned automatic retry.
    /// Unlike [`Self::retry_failed_event`], this preserves the attempt budget so
    /// a flaky relay cannot republish forever.
    pub fn prepare_auto_retry(
        &mut self,
        message_id_hex: &str,
        now_secs: u64,
    ) -> Result<Option<(String, Event)>> {
        let entry = match self.entries.get_mut(message_id_hex) {
            Some(entry) => entry,
            None => return Ok(None),
        };
        if entry.state != DeliveryState::Failed {
            return Ok(None);
        }
        if entry.attempts >= OUTBOX_RETRY_ATTEMPT_LIMIT {
            return Ok(None);
        }
        let event = Event::from_json(&entry.event_json)
            .map_err(|e| Error::Storage(format!("outbox event decode: {e}")))?;
        let group_id_hex = entry.group_id_hex.clone();
        let previous_error = entry.last_error.clone();
        entry.state = DeliveryState::Pending;
        entry.updated_at_secs = now_secs;
        entry.last_error = None;
        self.dirty = true;
        if let Err(err) = self.save_if_dirty() {
            // Roll back so a disk error cannot strand the row as Pending
            // (invisible to later prepare_auto_retry / Failed UI).
            if let Some(entry) = self.entries.get_mut(message_id_hex) {
                entry.state = DeliveryState::Failed;
                entry.last_error = previous_error;
                self.dirty = true;
            }
            return Err(err);
        }
        Ok(Some((group_id_hex, event)))
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
            if entry.attempts >= OUTBOX_RETRY_ATTEMPT_LIMIT {
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

    /// Rumor ids whose automatic publish budget is exhausted. Restart recovery
    /// skips these; kind-7 hydrate must too, or a `mine` chip looks sent forever.
    pub fn terminal_failed_message_ids(&self) -> Vec<String> {
        self.entries
            .values()
            .filter(|entry| entry.attempts >= OUTBOX_RETRY_ATTEMPT_LIMIT)
            .map(|entry| entry.message_id_hex.clone())
            .collect()
    }

    fn save_if_dirty(&mut self) -> Result<()> {
        if !self.dirty || self.saves_suspended > 0 {
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
        self.saves += 1;
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
    fn detach_clears_entries_and_blocks_further_saves() {
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
        assert!(path.exists());

        outbox.detach();
        assert_eq!(outbox.status_for_message("message"), None);

        // A late mark after detach must not recreate the sidecar.
        let _ = std::fs::remove_file(&path);
        outbox
            .mark_pending(
                "group".into(),
                "message-2".into(),
                "wrapper-2".into(),
                "{}".into(),
                2,
            )
            .expect("mark pending after detach");
        assert!(!path.exists());
    }

    #[test]
    fn auto_retry_backoff_grows_then_caps() {
        assert_eq!(outbox_auto_retry_delay_secs(1), 2);
        assert_eq!(outbox_auto_retry_delay_secs(2), 4);
        assert_eq!(outbox_auto_retry_delay_secs(3), 8);
        assert_eq!(outbox_auto_retry_delay_secs(4), 16);
        assert_eq!(outbox_auto_retry_delay_secs(5), 30);
        assert_eq!(outbox_auto_retry_delay_secs(20), 30);
    }

    #[test]
    fn prepare_auto_retry_rolls_back_on_save_failure() {
        // Detached outbox: save is a no-op success. Use a path whose parent
        // cannot be created so save_if_dirty fails after mutation.
        let path = PathBuf::from("/dev/null/definitely-not-a-dir/outbox.json");
        let mut outbox = OutboxState::load(Some(path));
        let event = EventBuilder::new(Kind::TextNote, "encrypted payload")
            .sign_with_keys(&Keys::generate())
            .expect("signed event");
        // Bypass save by marking with path=None first, then reattach a bad path.
        outbox.path = None;
        outbox
            .mark_pending(
                "group".into(),
                "message".into(),
                event.id.to_hex(),
                event.as_json(),
                1,
            )
            .expect("mark pending in memory");
        outbox
            .mark_failed_by_message_id("message", "offline".into(), 2)
            .expect("mark failed");
        outbox.path = Some(PathBuf::from("/dev/null/definitely-not-a-dir/outbox.json"));
        outbox.dirty = false;
        // Force dirty via prepare — save should fail and leave Failed.
        let err = outbox
            .prepare_auto_retry("message", 3)
            .expect_err("save must fail");
        let _ = err;
        assert_eq!(
            outbox.status_for_message("message"),
            Some(DeliveryState::Failed)
        );
    }

    #[test]
    fn prepare_auto_retry_preserves_attempt_budget() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("outbox.json");
        let mut outbox = OutboxState::load(Some(path));
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
        let attempts = outbox
            .mark_failed_by_message_id("message", "offline".into(), 2)
            .expect("mark failed")
            .expect("entry present");
        assert_eq!(attempts, 1);

        let (group_id, retried) = outbox
            .prepare_auto_retry("message", 3)
            .expect("prepare")
            .expect("auto retryable");
        assert_eq!(group_id, "group");
        assert_eq!(retried.id, event.id);
        assert_eq!(
            outbox.status_for_message("message"),
            Some(DeliveryState::Pending)
        );

        let attempts = outbox
            .mark_failed_by_message_id("message", "still offline".into(), 4)
            .expect("mark failed again")
            .expect("entry present");
        assert_eq!(attempts, 2);
    }

    #[test]
    fn prepare_auto_retry_stops_at_attempt_limit() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("outbox.json");
        let mut outbox = OutboxState::load(Some(path));
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
        for attempt in 0..OUTBOX_RETRY_ATTEMPT_LIMIT {
            outbox
                .mark_failed_by_message_id("message", format!("offline {attempt}"), 2)
                .expect("mark failed");
        }
        assert!(outbox
            .prepare_auto_retry("message", 3)
            .expect("prepare")
            .is_none());
        assert_eq!(
            outbox.terminal_failed_message_ids(),
            vec!["message".to_string()]
        );
    }

    #[test]
    fn manual_retry_resets_failed_entry_and_attempt_budget() {
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
        for attempt in 0..OUTBOX_RETRY_ATTEMPT_LIMIT {
            outbox
                .mark_failed_by_message_id("message", format!("offline {attempt}"), 2)
                .expect("mark failed");
        }

        let (source_group, retried) = outbox
            .retry_failed_event("message", 3)
            .expect("manual retry");
        assert_eq!(source_group, "group");
        assert_eq!(retried.id, event.id);
        assert_eq!(
            outbox.status_for_message("message"),
            Some(DeliveryState::Pending)
        );

        outbox
            .mark_failed_by_message_id("message", "still offline".into(), 4)
            .expect("mark failed after retry");
        let retryable = outbox
            .retryable_events(5, &HashSet::from(["group".to_string()]))
            .expect("automatic retry budget was reset");
        assert_eq!(retryable.len(), 1);

        let reloaded = OutboxState::load(Some(path));
        assert_eq!(
            reloaded.status_for_message("message"),
            Some(DeliveryState::Pending)
        );
    }
}

#[cfg(test)]
mod coalescing_tests {
    use super::*;

    fn pending(outbox: &mut OutboxState, i: u32, json: &str) {
        let id = format!("{i:064x}");
        outbox
            .mark_pending("g".into(), id.clone(), id, json.to_owned(), 1)
            .unwrap();
    }

    #[test]
    fn suspended_saves_write_once_on_resume() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("outbox.json");
        let mut outbox = OutboxState::load(Some(path.clone()));
        outbox.suspend_saves();
        outbox.suspend_saves();
        for i in 0..5 {
            pending(&mut outbox, i, "{}");
        }
        assert_eq!(outbox.save_count(), 0);
        assert!(!path.exists(), "no write while a hold is open");
        outbox.resume_saves().unwrap();
        assert_eq!(outbox.save_count(), 0, "the outer hold is still open");
        outbox.resume_saves().unwrap();
        assert_eq!(outbox.save_count(), 1);
        assert_eq!(OutboxState::load(Some(path)).recorded_count(), 5);
    }

    #[tokio::test]
    async fn ack_flush_coalesces_a_burst() {
        // Real time: `start_paused` needs tokio's test-util feature.
        let delay = Duration::from_millis(10);
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("outbox.json");
        let outbox = Arc::new(Mutex::new(OutboxState::load(Some(path.clone()))));
        for i in 0..20 {
            pending(&mut outbox.lock().unwrap(), i, "{}");
        }
        let before = outbox.lock().unwrap().save_count();
        let pending_flag = Arc::new(AtomicBool::new(false));
        for i in 0..20u32 {
            outbox
                .lock()
                .unwrap()
                .mark_sent_by_message_id_lazy(&format!("{i:064x}"));
            schedule_outbox_flush(outbox.clone(), pending_flag.clone(), delay);
        }
        assert_eq!(
            outbox.lock().unwrap().save_count(),
            before,
            "nothing written yet"
        );
        tokio::time::sleep(delay * 6).await;
        assert_eq!(
            outbox.lock().unwrap().save_count(),
            before + 1,
            "one write for 20 acks"
        );
        assert_eq!(OutboxState::load(Some(path)).recorded_count(), 0);
        assert!(
            !pending_flag.load(Ordering::Acquire),
            "a later burst can schedule again"
        );
    }

    /// Measures item 1 of the alpha.15 plan: 256 pending + 256 sent rows,
    /// row by row versus under one hold. Run with
    /// `cargo test -p sonar-core --release -- --ignored --nocapture bench_outbox`.
    #[test]
    #[ignore]
    fn bench_outbox_rewrite_cost() {
        let json = "x".repeat(994); // a real kind-445 share wrapper is 994 bytes
        for (label, hold) in [("row_by_row", false), ("one_hold", true)] {
            let dir = tempfile::tempdir().unwrap();
            let path = dir.path().join("outbox.json");
            let mut outbox = OutboxState::load(Some(path.clone()));
            let mut bytes = 0u64;
            let started = std::time::Instant::now();
            if hold {
                outbox.suspend_saves();
            }
            for i in 0..256 {
                pending(&mut outbox, i, &json);
                bytes += fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            }
            for i in 0..256u32 {
                if hold {
                    outbox.mark_sent_by_message_id_lazy(&format!("{i:064x}"));
                } else {
                    outbox
                        .mark_sent_by_message_id(&format!("{i:064x}"), 1)
                        .unwrap();
                }
                bytes += fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            }
            if hold {
                outbox.resume_saves().unwrap();
                bytes += fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            }
            println!(
                "BENCH outbox_{label} writes={} bytes_written_kb={} ms={:.1}",
                outbox.save_count(),
                bytes / 1024,
                started.elapsed().as_secs_f64() * 1e3
            );
        }
    }
}
