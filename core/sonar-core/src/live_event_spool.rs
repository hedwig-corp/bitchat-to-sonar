//! Durable, bounded overflow queue for relay events waiting on the MLS drain.
//!
//! The notification callback is memory-bounded, but welcome/group events cannot
//! be silently discarded. Persistent clients move the oldest half of a full RAM
//! queue into this SQLite queue before releasing it. SQLite gives us atomic
//! append and incremental acknowledgement; per-row retry deadlines and welcome
//! priority prevent one undecryptable group event from blocking later welcomes.

use std::collections::{HashSet, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use nostr::{Event, JsonUtil, Kind};
use rusqlite::{params, types::Value, Connection, OptionalExtension};

use crate::{Error, Result};

pub(crate) const LIVE_EVENT_SPOOL_FILE_SUFFIX: &str = ".sonar-live-events.db";
const LEGACY_LIVE_EVENT_SPOOL_FILE_SUFFIX: &str = ".sonar-live-events.jsonl";
const LIVE_EVENT_RECOVERY_INTENT_FILE_SUFFIX: &str = ".recovery-intent";
const LIVE_EVENT_RECOVERY_INTENT_VERSION: u32 = 1;

/// Hard upper bound on durable pending rows. At the protocol's normal relay
/// event limit this is comfortably below the SQLite byte cap while covering a
/// very large offline burst. Exhaustion is explicit and schedules relay recovery.
pub(crate) const LIVE_EVENT_SPOOL_MAX_ROWS: usize = 16_384;
const LIVE_EVENT_SPOOL_MAX_PAGES: usize = 65_536; // <= 256 MiB at 4 KiB pages.
const LIVE_EVENT_RETRY_BASE_MS: u64 = 1_000;
const LIVE_EVENT_RETRY_MAX_MS: u64 = 30_000;
const LIVE_EVENT_QUARANTINE_LIMIT: usize = 64;
const LIVE_EVENT_QUARANTINE_SCAN_BUDGET: usize = 64;
/// Legacy migration examines only a bounded newest suffix and never allocates
/// a row above the protocol-friendly ceiling. Oversize prefixes/rows are
/// recoverable from relays and set the explicit recovery flag.
const LEGACY_MIGRATION_MAX_BYTES: u64 = 256 * 1024 * 1024;
const LEGACY_MIGRATION_MAX_ROW_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SpoolAppendOutcome {
    Persisted,
    Volatile,
    Full,
}

pub(crate) struct LiveEventSpool {
    path: Option<PathBuf>,
    recovery_intent_path: Option<PathBuf>,
    db: Option<Connection>,
    pending_count: usize,
    recovery_generation: u64,
    recovered_generation: u64,
    #[cfg(test)]
    fail_writes_for_test: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
struct RecoveryIntentDisk {
    version: u32,
    generation: u64,
    pending: bool,
}

impl RecoveryIntentDisk {
    fn pending(generation: u64) -> Self {
        Self {
            version: LIVE_EVENT_RECOVERY_INTENT_VERSION,
            generation,
            pending: true,
        }
    }

    fn cleared(generation: u64) -> Self {
        Self {
            version: LIVE_EVENT_RECOVERY_INTENT_VERSION,
            generation,
            pending: false,
        }
    }
}

impl std::fmt::Debug for LiveEventSpool {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LiveEventSpool")
            .field("path", &self.path)
            .field("recovery_intent_path", &self.recovery_intent_path)
            .field("pending_count", &self.pending_count)
            .field("recovery_generation", &self.recovery_generation)
            .field("recovered_generation", &self.recovered_generation)
            .finish()
    }
}

impl LiveEventSpool {
    pub(crate) fn load(path: Option<PathBuf>) -> Result<Self> {
        let Some(path) = path else {
            return Ok(Self {
                path: None,
                recovery_intent_path: None,
                db: None,
                pending_count: 0,
                recovery_generation: 0,
                recovered_generation: 0,
                #[cfg(test)]
                fail_writes_for_test: false,
            });
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|err| {
                Error::Storage(format!(
                    "create live-event queue dir {}: {err}",
                    parent.display()
                ))
            })?;
        }

        let recovery_intent_path = recovery_intent_path_for_queue(&path);
        let mut db = match open_queue(&path) {
            Ok(db) => db,
            Err(first_err) => {
                // A damaged overflow queue must not make the whole account
                // unopenable. Persist an owner-only recovery intent OUTSIDE the
                // SQLite file set before deleting anything. If the process is
                // killed in the destructive window, the next open imports this
                // intent into the replacement DB and still forces relay catch-up.
                tracing::error!(%first_err, "live-event queue damaged; rebuilding and scheduling recovery");
                persist_rebuild_recovery_intent(&recovery_intent_path)?;
                remove_sqlite_files(&path)?;
                sync_parent(&path)?;
                open_queue(&path)?
            }
        };
        let (recovery_generation, recovered_generation) =
            synchronize_recovery_intent(&mut db, &recovery_intent_path)?;
        let mut spool = Self {
            path: Some(path.clone()),
            recovery_intent_path: Some(recovery_intent_path),
            db: Some(db),
            pending_count: 0,
            recovery_generation,
            recovered_generation,
            #[cfg(test)]
            fail_writes_for_test: false,
        };

        let legacy_path = legacy_spool_path_for_queue(&path);
        if legacy_path.exists() {
            spool.import_legacy_jsonl(&legacy_path)?;
        }
        spool.pending_count = spool.count_rows()?;
        spool.enforce_private_permissions()?;
        Ok(spool)
    }

    pub(crate) fn pending_len(&self) -> usize {
        self.pending_count
    }

    pub(crate) fn recovery_required(&self) -> bool {
        self.recovery_generation > self.recovered_generation
    }

    /// Return the durable loss generation without consuming it. A local-only
    /// startup may inspect this state, but only a successful relay-backed
    /// forced recovery may acknowledge it with `complete_recovery`.
    pub(crate) fn pending_recovery_generation(&self) -> Option<u64> {
        self.recovery_required().then_some(self.recovery_generation)
    }

    /// Persist a new recovery requirement. Generations prevent a successful
    /// fetch from clearing a newer loss marker that arrives while it is running.
    pub(crate) fn mark_recovery_required(&mut self) -> Result<u64> {
        #[cfg(test)]
        if self.fail_writes_for_test {
            return Err(Error::Storage(
                "injected live-event recovery marker failure".into(),
            ));
        }
        let Some(db) = self.db.as_mut() else {
            self.recovery_generation = self.recovery_generation.saturating_add(1);
            return Ok(self.recovery_generation);
        };
        let tx = db
            .transaction()
            .map_err(|err| Error::Storage(format!("live-event recovery mark begin: {err}")))?;
        let generation = bump_recovery_generation(&tx)?;
        if let Some(path) = self.recovery_intent_path.as_ref() {
            // Write the external intent while SQLite's write transaction is
            // held. Every healthy connection therefore serializes generation
            // changes with the sidecar, and a crash before commit is safe: the
            // next open imports the already-durable pending intent.
            persist_recovery_intent(path, RecoveryIntentDisk::pending(generation))?;
        }
        // The sidecar is already durable. Keep the in-memory generation even
        // if the following SQLite commit reports an uncertain failure;
        // `complete_recovery` imports the intent back into SQLite before its
        // exact-generation compare, so the current process can still recover.
        self.recovery_generation = generation;
        tx.commit()
            .map_err(|err| Error::Storage(format!("live-event recovery mark commit: {err}")))?;
        self.after_write()?;
        Ok(generation)
    }

    /// Acknowledge exactly the generation covered by a successful forced relay
    /// sync. If a newer loss arrived concurrently, it remains pending.
    pub(crate) fn complete_recovery(&mut self, generation: u64) -> Result<bool> {
        let Some(db) = self.db.as_mut() else {
            if self.recovery_generation == generation {
                self.recovered_generation = generation;
            }
            return Ok(!self.recovery_required());
        };
        let generation_i64 = i64::try_from(generation)
            .map_err(|_| Error::Storage("live-event recovery generation overflow".into()))?;
        let tx = db
            .transaction()
            .map_err(|err| Error::Storage(format!("live-event recovery complete begin: {err}")))?;
        if let Some(path) = self.recovery_intent_path.as_ref() {
            synchronize_recovery_intent_in_transaction(&tx, path)?;
        }
        let changed = tx
            .execute(
                "UPDATE live_event_state
                 SET recovered_generation = ?1
                 WHERE singleton = 1
                   AND recovery_generation = ?1
                   AND recovery_generation > recovered_generation",
                params![generation_i64],
            )
            .map_err(|err| Error::Storage(format!("live-event recovery complete: {err}")))?;
        if changed > 0 {
            if let Some(path) = self.recovery_intent_path.as_ref() {
                // A logical tombstone avoids a read-then-unlink race with a
                // newer generation from another node/process. It is written
                // only while the exact DB generation is protected by the same
                // SQLite write transaction.
                persist_recovery_intent(path, RecoveryIntentDisk::cleared(generation))?;
            }
        }
        tx.commit()
            .map_err(|err| Error::Storage(format!("live-event recovery complete commit: {err}")))?;
        let (recovery_generation, recovered_generation) = read_recovery_state(db)?;
        self.recovery_generation = recovery_generation;
        self.recovered_generation = recovered_generation;
        if changed > 0 {
            self.after_write()?;
        }
        Ok(!self.recovery_required())
    }

    /// Append the full batch atomically. `Full` inserts nothing, allowing the
    /// caller to switch to explicit watermarked recovery without a partial copy.
    pub(crate) fn append_events(&mut self, events: &[Event]) -> Result<SpoolAppendOutcome> {
        if events.is_empty() {
            return Ok(SpoolAppendOutcome::Persisted);
        }
        #[cfg(test)]
        if self.fail_writes_for_test {
            return Err(Error::Storage(
                "injected live-event queue append failure".into(),
            ));
        }
        let Some(db) = self.db.as_mut() else {
            return Ok(SpoolAppendOutcome::Volatile);
        };

        let mut unique = Vec::with_capacity(events.len());
        let mut batch_ids = HashSet::with_capacity(events.len());
        for event in events {
            let id = event.id.to_hex();
            if batch_ids.insert(id.clone()) {
                unique.push((id, event.kind.as_u16(), event.as_json()));
            }
        }

        let tx = db
            .transaction()
            .map_err(|err| Error::Storage(format!("live-event append begin: {err}")))?;
        let mut new_rows = 0usize;
        {
            let mut exists = tx
                .prepare("SELECT EXISTS(SELECT 1 FROM live_event_queue WHERE event_id = ?1)")
                .map_err(|err| Error::Storage(format!("live-event exists prepare: {err}")))?;
            for (id, _, _) in &unique {
                let present: bool = exists
                    .query_row(params![id], |row| row.get(0))
                    .map_err(|err| Error::Storage(format!("live-event exists query: {err}")))?;
                if !present {
                    new_rows += 1;
                }
            }
        }
        if self.pending_count.saturating_add(new_rows) > LIVE_EVENT_SPOOL_MAX_ROWS {
            let generation = bump_recovery_generation(&tx)?;
            if let Some(path) = self.recovery_intent_path.as_ref() {
                persist_recovery_intent(path, RecoveryIntentDisk::pending(generation))?;
            }
            tx.commit().map_err(|err| {
                Error::Storage(format!("live-event overflow recovery mark commit: {err}"))
            })?;
            self.recovery_generation = generation;
            self.after_write()?;
            return Ok(SpoolAppendOutcome::Full);
        }
        {
            let mut insert = tx
                .prepare(
                    "INSERT OR IGNORE INTO live_event_queue
                        (event_id, kind, event_json, available_after_ms, attempts)
                     VALUES (?1, ?2, ?3, 0, 0)",
                )
                .map_err(|err| Error::Storage(format!("live-event insert prepare: {err}")))?;
            for (id, kind, json) in unique {
                insert
                    .execute(params![id, kind, json])
                    .map_err(|err| Error::Storage(format!("live-event insert: {err}")))?;
            }
        }
        tx.commit()
            .map_err(|err| Error::Storage(format!("live-event append commit: {err}")))?;
        self.pending_count = self.pending_count.saturating_add(new_rows);
        self.after_write()?;
        Ok(SpoolAppendOutcome::Persisted)
    }

    #[cfg(test)]
    pub(crate) fn fail_writes_for_test(&mut self) {
        self.fail_writes_for_test = true;
    }

    /// Read one ready page, always preferring welcomes over group messages.
    /// Within a class, fresh rows precede repeatedly-failing rows so retryable
    /// traffic rotates behind new work rather than monopolizing the head.
    pub(crate) fn read_batch(&mut self, limit: usize, now_ms: u64) -> Result<Vec<Event>> {
        if limit == 0 || self.pending_count == 0 {
            return Ok(Vec::new());
        }
        let Some(db) = self.db.as_mut() else {
            return Ok(Vec::new());
        };
        let scan_limit = limit.saturating_add(LIVE_EVENT_QUARANTINE_SCAN_BUDGET);
        let raw_rows = {
            let mut stmt = db
                .prepare(
                    "SELECT seq, event_id, kind, event_json
                 FROM live_event_queue
                 WHERE available_after_ms <= ?1
                 ORDER BY CASE WHEN kind = ?2 THEN 0 ELSE 1 END,
                          attempts ASC,
                          seq ASC
                 LIMIT ?3",
                )
                .map_err(|err| Error::Storage(format!("live-event batch prepare: {err}")))?;
            let rows = stmt
                .query_map(
                    params![
                        now_ms as i64,
                        Kind::GiftWrap.as_u16(),
                        i64::try_from(scan_limit).unwrap_or(i64::MAX)
                    ],
                    |row| {
                        Ok((
                            row.get::<_, i64>(0)?,
                            row.get::<_, Value>(1)?,
                            row.get::<_, Value>(2)?,
                            row.get::<_, Value>(3)?,
                        ))
                    },
                )
                .map_err(|err| Error::Storage(format!("live-event batch query: {err}")))?
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|err| Error::Storage(format!("live-event batch row: {err}")))?;
            rows
        };

        let mut events = Vec::with_capacity(limit.min(self.pending_count));
        let mut malformed = Vec::new();
        for (seq, event_id_value, kind_value, json_value) in raw_rows {
            let event_id = match event_id_value {
                Value::Text(value) => value,
                value => {
                    malformed.push((
                        seq,
                        format!("<invalid-event-id-{seq}>"),
                        quarantine_value(&json_value),
                        format!("event_id is {} instead of text", sqlite_value_kind(&value)),
                    ));
                    continue;
                }
            };
            let json = match json_value {
                Value::Text(value) => value,
                value => {
                    malformed.push((
                        seq,
                        event_id,
                        quarantine_value(&value),
                        format!(
                            "event_json is {} instead of text",
                            sqlite_value_kind(&value)
                        ),
                    ));
                    continue;
                }
            };
            let stored_kind = match kind_value {
                Value::Integer(value) if (0..=u16::MAX as i64).contains(&value) => value as u16,
                value => {
                    malformed.push((
                        seq,
                        event_id,
                        json,
                        format!(
                            "kind is {} instead of a u16 integer",
                            sqlite_value_kind(&value)
                        ),
                    ));
                    continue;
                }
            };
            match Event::from_json(&json) {
                Ok(event) if event.id.to_hex() != event_id => malformed.push((
                    seq,
                    event_id,
                    json,
                    format!("stored event_id differs from parsed event {}", event.id),
                )),
                Ok(event) if event.kind.as_u16() != stored_kind => malformed.push((
                    seq,
                    event_id,
                    json,
                    format!(
                        "stored kind {stored_kind} differs from parsed kind {}",
                        event.kind.as_u16()
                    ),
                )),
                Ok(event) if events.len() < limit => events.push(event),
                Ok(_) => break,
                Err(err) => malformed.push((seq, event_id, json, err.to_string())),
            }
        }

        if !malformed.is_empty() {
            let tx = db
                .transaction()
                .map_err(|err| Error::Storage(format!("live-event quarantine begin: {err}")))?;
            {
                let mut quarantine = tx
                    .prepare(
                        "INSERT OR REPLACE INTO live_event_quarantine
                            (seq, event_id, event_json, parse_error, quarantined_at_ms)
                         VALUES (?1, ?2, ?3, ?4, ?5)",
                    )
                    .map_err(|err| {
                        Error::Storage(format!("live-event quarantine prepare: {err}"))
                    })?;
                let mut delete = tx
                    .prepare("DELETE FROM live_event_queue WHERE seq = ?1")
                    .map_err(|err| {
                        Error::Storage(format!("live-event quarantine delete prepare: {err}"))
                    })?;
                for (seq, event_id, json, parse_error) in &malformed {
                    quarantine
                        .execute(params![seq, event_id, json, parse_error, now_ms as i64])
                        .map_err(|err| {
                            Error::Storage(format!("live-event quarantine insert: {err}"))
                        })?;
                    delete.execute(params![seq]).map_err(|err| {
                        Error::Storage(format!("live-event quarantine delete: {err}"))
                    })?;
                }
            }
            tx.execute(
                "DELETE FROM live_event_quarantine
                 WHERE seq NOT IN (
                    SELECT seq FROM live_event_quarantine
                    ORDER BY quarantined_at_ms DESC, seq DESC LIMIT ?1
                 )",
                params![LIVE_EVENT_QUARANTINE_LIMIT as i64],
            )
            .map_err(|err| Error::Storage(format!("live-event quarantine trim: {err}")))?;
            let generation = bump_recovery_generation(&tx)?;
            if let Some(path) = self.recovery_intent_path.as_ref() {
                persist_recovery_intent(path, RecoveryIntentDisk::pending(generation))?;
            }
            tx.commit()
                .map_err(|err| Error::Storage(format!("live-event quarantine commit: {err}")))?;
            self.pending_count = self.pending_count.saturating_sub(malformed.len());
            self.recovery_generation = generation;
            tracing::error!(
                quarantined = malformed.len(),
                "malformed durable live-event rows quarantined; relay recovery required"
            );
            self.after_write()?;
        }
        Ok(events)
    }

    /// Delete acknowledged rows and defer only the retryable rows from this
    /// page. Work beyond the page remains immediately available.
    pub(crate) fn complete_batch(
        &mut self,
        batch_ids: &[String],
        processed_ids: &HashSet<String>,
        now_ms: u64,
    ) -> Result<usize> {
        let Some(db) = self.db.as_mut() else {
            self.pending_count = 0;
            return Ok(0);
        };
        let tx = db
            .transaction()
            .map_err(|err| Error::Storage(format!("live-event complete begin: {err}")))?;
        let mut deleted = 0usize;
        {
            let mut delete = tx
                .prepare("DELETE FROM live_event_queue WHERE event_id = ?1")
                .map_err(|err| Error::Storage(format!("live-event delete prepare: {err}")))?;
            let mut defer = tx
                .prepare(
                    "UPDATE live_event_queue
                     SET attempts = attempts + 1,
                         available_after_ms = ?2 + MIN(?3, ?4 * (attempts + 1))
                     WHERE event_id = ?1",
                )
                .map_err(|err| Error::Storage(format!("live-event defer prepare: {err}")))?;
            for id in batch_ids {
                if processed_ids.contains(id) {
                    deleted += delete.execute(params![id]).map_err(|err| {
                        Error::Storage(format!("live-event incremental delete: {err}"))
                    })?;
                } else {
                    defer
                        .execute(params![
                            id,
                            now_ms as i64,
                            LIVE_EVENT_RETRY_MAX_MS as i64,
                            LIVE_EVENT_RETRY_BASE_MS as i64,
                        ])
                        .map_err(|err| Error::Storage(format!("live-event rotate retry: {err}")))?;
                }
            }
        }
        tx.commit()
            .map_err(|err| Error::Storage(format!("live-event complete commit: {err}")))?;
        self.pending_count = self.pending_count.saturating_sub(deleted);
        self.after_write()?;
        Ok(self.pending_count)
    }

    /// Delay until the first queued row becomes eligible. `None` means either
    /// no persistent queue or no pending rows.
    pub(crate) fn next_ready_in(&self, now_ms: u64) -> Result<Option<Duration>> {
        if self.pending_count == 0 {
            return Ok(None);
        }
        let Some(db) = self.db.as_ref() else {
            return Ok(None);
        };
        let earliest: Option<u64> = db
            .query_row(
                "SELECT MIN(available_after_ms) FROM live_event_queue",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(|err| Error::Storage(format!("live-event retry deadline: {err}")))?
            .flatten();
        Ok(earliest.map(|deadline| Duration::from_millis(deadline.saturating_sub(now_ms))))
    }

    fn count_rows(&self) -> Result<usize> {
        let Some(db) = self.db.as_ref() else {
            return Ok(0);
        };
        db.query_row("SELECT COUNT(*) FROM live_event_queue", [], |row| {
            row.get::<_, i64>(0)
        })
        .map(|count| count.max(0) as usize)
        .map_err(|err| Error::Storage(format!("live-event count: {err}")))
    }

    fn import_legacy_jsonl(&mut self, legacy_path: &Path) -> Result<()> {
        let (events, recovery_required) = read_legacy_events_bounded(legacy_path)?;
        if recovery_required {
            self.mark_recovery_required()?;
        }
        self.pending_count = self.count_rows()?;
        match self.append_events(&events)? {
            SpoolAppendOutcome::Persisted => {}
            SpoolAppendOutcome::Full => {
                tracing::warn!("legacy live-event import exceeded remaining queue capacity");
            }
            SpoolAppendOutcome::Volatile => unreachable!("persistent migration has a database"),
        }
        fs::remove_file(legacy_path).map_err(|err| {
            Error::Storage(format!(
                "remove migrated live-event spool {}: {err}",
                legacy_path.display()
            ))
        })?;
        sync_parent(legacy_path)?;
        Ok(())
    }

    fn after_write(&self) -> Result<()> {
        let Some(db) = self.db.as_ref() else {
            return Ok(());
        };
        db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA incremental_vacuum(64);")
            .map_err(|err| Error::Storage(format!("live-event queue checkpoint: {err}")))?;
        self.enforce_private_permissions()
    }

    fn enforce_private_permissions(&self) -> Result<()> {
        let Some(path) = self.path.as_ref() else {
            return Ok(());
        };
        for candidate in sqlite_files(path) {
            if candidate.exists() {
                set_private_permissions(&candidate)?;
            }
        }
        Ok(())
    }
}

fn sqlite_value_kind(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Integer(_) => "integer",
        Value::Real(_) => "real",
        Value::Text(_) => "text",
        Value::Blob(_) => "blob",
    }
}

fn quarantine_value(value: &Value) -> String {
    match value {
        Value::Text(value) => value.clone(),
        Value::Blob(value) => format!("<non-text blob: {} bytes>", value.len()),
        Value::Null => "<non-text null>".into(),
        Value::Integer(value) => format!("<non-text integer: {value}>"),
        Value::Real(value) => format!("<non-text real: {value}>"),
    }
}

fn recovery_intent_path_for_queue(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-live-events.db");
    path.with_file_name(format!("{name}{LIVE_EVENT_RECOVERY_INTENT_FILE_SUFFIX}"))
}

/// Persist crash evidence before deleting a damaged SQLite file set. This must
/// complete (including the parent-directory fsync) before the first unlink.
fn persist_rebuild_recovery_intent(path: &Path) -> Result<u64> {
    let prior_generation = match read_recovery_intent(path) {
        Ok(Some(intent)) => intent.generation,
        Ok(None) => 0,
        Err(err) => {
            // A malformed intent is itself evidence that recovery state cannot
            // be trusted. Overwrite it with a fresh pending generation; I/O
            // failures still abort before destructive removal.
            tracing::error!(%err, "live-event recovery intent damaged; replacing before rebuild");
            0
        }
    };
    let generation = prior_generation.saturating_add(1).max(1);
    persist_recovery_intent(path, RecoveryIntentDisk::pending(generation))?;
    Ok(generation)
}

fn synchronize_recovery_intent(db: &mut Connection, intent_path: &Path) -> Result<(u64, u64)> {
    let tx = db
        .transaction()
        .map_err(|err| Error::Storage(format!("live-event intent import begin: {err}")))?;
    synchronize_recovery_intent_in_transaction(&tx, intent_path)?;
    tx.commit()
        .map_err(|err| Error::Storage(format!("live-event intent import commit: {err}")))?;
    read_recovery_state(db)
}

/// Reconcile the SQLite generation with the atomically persisted sidecar while
/// the caller holds SQLite's write transaction. DB-pending always wins over a
/// stale cleared tombstone; a pending sidecar always creates a pending DB
/// generation, including the crash window after DB completion but before the
/// sidecar transition committed.
fn synchronize_recovery_intent_in_transaction(
    tx: &rusqlite::Transaction<'_>,
    intent_path: &Path,
) -> Result<()> {
    let (required, recovered) = read_recovery_state(tx)?;
    let intent = match read_recovery_intent(intent_path) {
        Ok(intent) => intent,
        Err(err) => {
            tracing::error!(%err, "live-event recovery intent unreadable; forcing relay recovery");
            let generation = required.max(recovered).saturating_add(1).max(1);
            let intent = RecoveryIntentDisk::pending(generation);
            persist_recovery_intent(intent_path, intent)?;
            Some(intent)
        }
    };

    let target = match intent {
        Some(intent) if intent.pending => {
            let mut target = required.max(intent.generation).max(1);
            if target <= recovered {
                target = recovered.saturating_add(1);
            }
            if intent.generation != target {
                persist_recovery_intent(intent_path, RecoveryIntentDisk::pending(target))?;
            }
            Some(target)
        }
        Some(_) | None if required > recovered => {
            persist_recovery_intent(intent_path, RecoveryIntentDisk::pending(required))?;
            Some(required)
        }
        Some(_) | None => None,
    };

    if let Some(target) = target {
        let target = i64::try_from(target)
            .map_err(|_| Error::Storage("live-event recovery intent generation overflow".into()))?;
        tx.execute(
            "UPDATE live_event_state
             SET recovery_generation = ?1
             WHERE singleton = 1 AND recovery_generation < ?1",
            params![target],
        )
        .map_err(|err| Error::Storage(format!("live-event recovery intent import: {err}")))?;
    }
    Ok(())
}

fn read_recovery_intent(path: &Path) -> Result<Option<RecoveryIntentDisk>> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(err) => {
            return Err(Error::Storage(format!(
                "read live-event recovery intent {}: {err}",
                path.display()
            )))
        }
    };
    let intent: RecoveryIntentDisk = serde_json::from_slice(&bytes).map_err(|err| {
        Error::Storage(format!(
            "decode live-event recovery intent {}: {err}",
            path.display()
        ))
    })?;
    if intent.version != LIVE_EVENT_RECOVERY_INTENT_VERSION || intent.generation == 0 {
        return Err(Error::Storage(format!(
            "invalid live-event recovery intent {}",
            path.display()
        )));
    }
    Ok(Some(intent))
}

/// Owner-only atomic replace with file fsync + parent-directory fsync. Keeping
/// the cleared generation as a tombstone avoids an unlink racing a newer marker
/// from another node while still making `pending = false` explicit on restart.
fn persist_recovery_intent(path: &Path, intent: RecoveryIntentDisk) -> Result<()> {
    let parent = path.parent().ok_or_else(|| {
        Error::Storage(format!(
            "live-event recovery intent has no parent: {}",
            path.display()
        ))
    })?;
    fs::create_dir_all(parent).map_err(|err| {
        Error::Storage(format!(
            "create live-event recovery intent dir {}: {err}",
            parent.display()
        ))
    })?;
    let bytes = serde_json::to_vec(&intent)
        .map_err(|err| Error::Storage(format!("encode live-event recovery intent: {err}")))?;
    let mut random = [0_u8; 8];
    getrandom::getrandom(&mut random)
        .map_err(|err| Error::Storage(format!("recovery intent temp name: {err}")))?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-live-event-recovery");
    let tmp = path.with_file_name(format!(
        ".{file_name}.tmp-{}-{}",
        std::process::id(),
        hex::encode(random)
    ));
    let result = (|| -> Result<()> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&tmp).map_err(|err| {
            Error::Storage(format!(
                "create live-event recovery intent temp {}: {err}",
                tmp.display()
            ))
        })?;
        file.write_all(&bytes).map_err(|err| {
            Error::Storage(format!(
                "write live-event recovery intent temp {}: {err}",
                tmp.display()
            ))
        })?;
        file.sync_all().map_err(|err| {
            Error::Storage(format!(
                "sync live-event recovery intent temp {}: {err}",
                tmp.display()
            ))
        })?;
        atomic_replace_file(&tmp, path).map_err(|err| {
            Error::Storage(format!(
                "commit live-event recovery intent {}: {err}",
                path.display()
            ))
        })?;
        set_private_permissions(path)?;
        sync_parent(path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
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

fn read_recovery_state(db: &Connection) -> Result<(u64, u64)> {
    db.query_row(
        "SELECT recovery_generation, recovered_generation
         FROM live_event_state WHERE singleton = 1",
        [],
        |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
    )
    .map(|(required, recovered)| (required.max(0) as u64, recovered.max(0) as u64))
    .map_err(|err| Error::Storage(format!("live-event recovery state read: {err}")))
}

fn bump_recovery_generation(tx: &rusqlite::Transaction<'_>) -> Result<u64> {
    tx.execute(
        "UPDATE live_event_state
         SET recovery_generation = recovery_generation + 1
         WHERE singleton = 1",
        [],
    )
    .map_err(|err| Error::Storage(format!("live-event recovery state update: {err}")))?;
    let generation = tx
        .query_row(
            "SELECT recovery_generation FROM live_event_state WHERE singleton = 1",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(|err| Error::Storage(format!("live-event recovery generation read: {err}")))?;
    u64::try_from(generation)
        .map_err(|_| Error::Storage("live-event recovery generation is negative".into()))
}

pub(crate) fn live_event_spool_path_for_db(db_path: &Path) -> PathBuf {
    let name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar.db");
    db_path.with_file_name(format!("{name}{LIVE_EVENT_SPOOL_FILE_SUFFIX}"))
}

pub(crate) fn live_event_spool_now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

pub(crate) fn wipe_live_event_spool_for_db(db_path: &Path) -> Result<()> {
    let path = live_event_spool_path_for_db(db_path);
    let legacy = legacy_spool_path_for_queue(&path);
    let recovery_intent = recovery_intent_path_for_queue(&path);
    for candidate in sqlite_files(&path).into_iter().chain([
        legacy.clone(),
        legacy.with_extension("jsonl.corrupt"),
        recovery_intent,
    ]) {
        match fs::remove_file(&candidate) {
            Ok(()) => {}
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
            Err(err) => {
                return Err(Error::Storage(format!(
                    "wipe live-event queue {}: {err}",
                    candidate.display()
                )))
            }
        }
    }
    sync_parent(&path)?;
    Ok(())
}

fn open_queue(path: &Path) -> Result<Connection> {
    create_private_file(path)?;
    let db = Connection::open(path)
        .map_err(|err| Error::Storage(format!("live-event queue open: {err}")))?;
    db.busy_timeout(Duration::from_secs(2))
        .map_err(|err| Error::Storage(format!("live-event busy timeout: {err}")))?;
    db.execute_batch(&format!(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = FULL;
         PRAGMA temp_store = MEMORY;
         PRAGMA auto_vacuum = INCREMENTAL;
         PRAGMA max_page_count = {LIVE_EVENT_SPOOL_MAX_PAGES};
         CREATE TABLE IF NOT EXISTS live_event_queue (
             seq INTEGER PRIMARY KEY AUTOINCREMENT,
             event_id TEXT NOT NULL UNIQUE,
             kind INTEGER NOT NULL,
             event_json TEXT NOT NULL,
             available_after_ms INTEGER NOT NULL DEFAULT 0,
             attempts INTEGER NOT NULL DEFAULT 0
         );
         CREATE INDEX IF NOT EXISTS idx_live_event_ready
             ON live_event_queue(available_after_ms, kind, attempts, seq);
         CREATE TABLE IF NOT EXISTS live_event_quarantine (
             seq INTEGER PRIMARY KEY,
             event_id TEXT NOT NULL,
             event_json TEXT NOT NULL,
             parse_error TEXT NOT NULL,
             quarantined_at_ms INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS live_event_state (
             singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
             recovery_generation INTEGER NOT NULL DEFAULT 0,
             recovered_generation INTEGER NOT NULL DEFAULT 0
         );
         INSERT OR IGNORE INTO live_event_state
             (singleton, recovery_generation, recovered_generation)
         VALUES (1, 0, 0);"
    ))
    .map_err(|err| Error::Storage(format!("live-event queue schema: {err}")))?;
    set_private_permissions(path)?;
    Ok(db)
}

fn create_private_file(path: &Path) -> Result<()> {
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path).map_err(|err| {
        Error::Storage(format!("create live-event queue {}: {err}", path.display()))
    })?;
    set_private_permissions(path)
}

fn set_private_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|err| {
            Error::Storage(format!(
                "set live-event queue permissions {}: {err}",
                path.display()
            ))
        })?;
    }
    Ok(())
}

/// Stream the newest bounded suffix of the legacy JSONL once. A malicious or
/// corrupted line never grows the allocation beyond MAX_ROW_BYTES; excess
/// rows evict from the front so retained memory and imported row count stay
/// bounded. A malformed unterminated tail is truncated at its row boundary.
fn read_legacy_events_bounded(path: &Path) -> Result<(Vec<Event>, bool)> {
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(|err| Error::Storage(format!("open legacy spool {}: {err}", path.display())))?;
    let len = file
        .metadata()
        .map_err(|err| Error::Storage(format!("stat legacy spool {}: {err}", path.display())))?
        .len();
    let start = len.saturating_sub(LEGACY_MIGRATION_MAX_BYTES);
    file.seek(SeekFrom::Start(start))
        .map_err(|err| Error::Storage(format!("seek legacy spool {}: {err}", path.display())))?;

    let mut reader = BufReader::with_capacity(8 * 1024, file);
    let mut recovery_required = start > 0;
    let mut position = start;
    let mut line = Vec::with_capacity(8 * 1024);
    if start > 0 {
        // The byte ceiling normally lands in the middle of a row. Discard that
        // partial prefix before interpreting complete JSONL records.
        let (consumed, _, _) =
            read_bounded_line(&mut reader, &mut line, LEGACY_MIGRATION_MAX_ROW_BYTES).map_err(
                |err| Error::Storage(format!("read legacy prefix {}: {err}", path.display())),
            )?;
        position = position.saturating_add(consumed as u64);
    }

    let mut events = VecDeque::with_capacity(LIVE_EVENT_SPOOL_MAX_ROWS);
    let mut truncate_at = None;
    loop {
        let row_start = position;
        let (consumed, terminated, overflow) =
            read_bounded_line(&mut reader, &mut line, LEGACY_MIGRATION_MAX_ROW_BYTES).map_err(
                |err| Error::Storage(format!("read legacy row {}: {err}", path.display())),
            )?;
        if consumed == 0 {
            break;
        }
        position = position.saturating_add(consumed as u64);
        if overflow {
            recovery_required = true;
            if !terminated {
                truncate_at = Some(row_start);
                break;
            }
            continue;
        }
        if line.iter().all(|byte| byte.is_ascii_whitespace()) {
            if !terminated {
                break;
            }
            continue;
        }
        match std::str::from_utf8(&line)
            .ok()
            .and_then(|json| Event::from_json(json).ok())
        {
            Some(event) => {
                if events.len() == LIVE_EVENT_SPOOL_MAX_ROWS {
                    events.pop_front();
                    recovery_required = true;
                }
                events.push_back(event);
            }
            None => {
                recovery_required = true;
                if !terminated {
                    truncate_at = Some(row_start);
                    break;
                }
                tracing::error!(
                    "malformed complete row in legacy live-event spool; recovery required"
                );
            }
        }
        if !terminated {
            break;
        }
    }

    let file = reader.into_inner();
    if let Some(length) = truncate_at {
        file.set_len(length)
            .and_then(|_| file.sync_all())
            .map_err(|err| {
                Error::Storage(format!(
                    "truncate torn legacy spool tail {}: {err}",
                    path.display()
                ))
            })?;
        sync_parent(path)?;
    }
    Ok((events.into_iter().collect(), recovery_required))
}

/// Read one logical line while retaining at most `max_bytes` of content. The
/// newline is consumed but excluded from `out`.
fn read_bounded_line<R: BufRead>(
    reader: &mut R,
    out: &mut Vec<u8>,
    max_bytes: usize,
) -> std::io::Result<(usize, bool, bool)> {
    out.clear();
    let mut consumed_total = 0usize;
    let mut overflow = false;
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return Ok((consumed_total, false, overflow));
        }
        let newline = available.iter().position(|byte| *byte == b'\n');
        let consumed = newline.map_or(available.len(), |index| index + 1);
        let content_len = newline.unwrap_or(consumed);
        if !overflow {
            let remaining = max_bytes.saturating_sub(out.len());
            if content_len <= remaining {
                out.extend_from_slice(&available[..content_len]);
            } else {
                out.extend_from_slice(&available[..remaining]);
                overflow = true;
            }
        }
        reader.consume(consumed);
        consumed_total = consumed_total.saturating_add(consumed);
        if newline.is_some() {
            return Ok((consumed_total, true, overflow));
        }
    }
}

fn legacy_spool_path_for_queue(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-live-events.db");
    let stem = name
        .strip_suffix(LIVE_EVENT_SPOOL_FILE_SUFFIX)
        .unwrap_or(name);
    path.with_file_name(format!("{stem}{LEGACY_LIVE_EVENT_SPOOL_FILE_SUFFIX}"))
}

fn sqlite_files(path: &Path) -> Vec<PathBuf> {
    vec![
        path.to_path_buf(),
        PathBuf::from(format!("{}-wal", path.display())),
        PathBuf::from(format!("{}-shm", path.display())),
        PathBuf::from(format!("{}-journal", path.display())),
    ]
}

fn remove_sqlite_files(path: &Path) -> Result<()> {
    for candidate in sqlite_files(path) {
        match fs::remove_file(&candidate) {
            Ok(()) => {}
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
            Err(err) => {
                return Err(Error::Storage(format!(
                    "remove damaged live-event queue {}: {err}",
                    candidate.display()
                )))
            }
        }
    }
    Ok(())
}

#[cfg(not(windows))]
fn sync_parent(path: &Path) -> Result<()> {
    let Some(parent) = path.parent() else {
        return Ok(());
    };
    File::open(parent)
        .and_then(|dir| dir.sync_all())
        .map_err(|err| Error::Storage(format!("sync queue directory {}: {err}", parent.display())))
}

#[cfg(windows)]
fn sync_parent(_path: &Path) -> Result<()> {
    // `atomic_replace_file` uses MOVEFILE_WRITE_THROUGH on Windows. Opening a
    // directory as `std::fs::File` is not supported there; the write-through
    // replace is the platform durability primitive for the recovery intent.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, Keys, Timestamp};

    fn event(keys: &Keys, kind: Kind, second: u64, body: &str) -> Event {
        EventBuilder::new(kind, body)
            .custom_created_at(Timestamp::from_secs(second))
            .sign_with_keys(keys)
            .expect("event signs")
    }

    #[test]
    fn appended_rows_survive_reopen_and_delete_incrementally_after_ack() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("live.db");
        let keys = Keys::generate();
        let first = event(&keys, Kind::MlsGroupMessage, 1, "one");
        let second = event(&keys, Kind::MlsGroupMessage, 2, "two");

        let mut spool = LiveEventSpool::load(Some(path.clone())).expect("open");
        assert_eq!(
            spool
                .append_events(&[first.clone(), second.clone()])
                .expect("append"),
            SpoolAppendOutcome::Persisted
        );
        drop(spool);

        let mut reopened = LiveEventSpool::load(Some(path)).expect("reopen");
        assert_eq!(reopened.pending_len(), 2);
        assert_eq!(
            reopened.read_batch(1, 0).expect("batch"),
            vec![first.clone()]
        );
        let batch_ids = vec![first.id.to_hex()];
        let processed = HashSet::from([first.id.to_hex()]);
        assert_eq!(
            reopened
                .complete_batch(&batch_ids, &processed, 1_000)
                .expect("complete"),
            1
        );
        assert_eq!(
            reopened.read_batch(10, 1_000).expect("remaining"),
            vec![second]
        );
    }

    #[test]
    fn recovery_marker_survives_observation_and_reopen_until_exact_generation_completes() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("live.db");
        let intent_path = recovery_intent_path_for_queue(&path);
        let mut spool = LiveEventSpool::load(Some(path.clone())).expect("open");
        let first_generation = spool.mark_recovery_required().expect("mark recovery");
        assert_eq!(
            read_recovery_intent(&intent_path).expect("read first intent"),
            Some(RecoveryIntentDisk::pending(first_generation))
        );

        assert_eq!(spool.pending_recovery_generation(), Some(first_generation));
        assert_eq!(
            spool.pending_recovery_generation(),
            Some(first_generation),
            "observing recovery must not consume the durable marker"
        );
        drop(spool);

        let mut reopened = LiveEventSpool::load(Some(path.clone())).expect("reopen");
        assert_eq!(
            reopened.pending_recovery_generation(),
            Some(first_generation)
        );
        let newer_generation = reopened
            .mark_recovery_required()
            .expect("mark concurrent loss");
        assert!(
            !reopened
                .complete_recovery(first_generation)
                .expect("complete stale generation"),
            "a recovery may not clear a newer loss marker"
        );
        assert_eq!(
            reopened.pending_recovery_generation(),
            Some(newer_generation)
        );
        assert_eq!(
            read_recovery_intent(&intent_path).expect("read newer intent"),
            Some(RecoveryIntentDisk::pending(newer_generation)),
            "a stale completion may not clear the newer external intent"
        );
        assert!(reopened
            .complete_recovery(newer_generation)
            .expect("complete current generation"));
        assert_eq!(
            read_recovery_intent(&intent_path).expect("read cleared intent"),
            Some(RecoveryIntentDisk::cleared(newer_generation)),
            "only exact-generation success writes the cleared tombstone"
        );
        drop(reopened);

        let cleared = LiveEventSpool::load(Some(path)).expect("reopen cleared marker");
        assert_eq!(cleared.pending_recovery_generation(), None);
    }

    #[test]
    fn pre_delete_recovery_intent_survives_destructive_crash_window_and_reopen() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("live.db");
        let intent_path = recovery_intent_path_for_queue(&path);
        drop(LiveEventSpool::load(Some(path.clone())).expect("create queue"));

        // This is the exact kill window in `load`: intent committed + parent
        // fsynced, damaged SQLite files removed, replacement DB not opened yet.
        let generation = persist_rebuild_recovery_intent(&intent_path)
            .expect("persist pre-delete recovery intent");
        remove_sqlite_files(&path).expect("simulate destructive removal");
        sync_parent(&path).expect("sync simulated removal");

        let reopened = LiveEventSpool::load(Some(path)).expect("restart after kill window");
        assert_eq!(
            reopened.pending_recovery_generation(),
            Some(generation),
            "the clean replacement DB must import the pre-delete intent"
        );
        assert_eq!(
            read_recovery_intent(&intent_path).expect("read imported intent"),
            Some(RecoveryIntentDisk::pending(generation))
        );
    }

    #[test]
    fn welcomes_bypass_retryable_group_rows_and_failed_rows_rotate() {
        let dir = tempfile::tempdir().expect("tempdir");
        let keys = Keys::generate();
        let mut spool = LiveEventSpool::load(Some(dir.path().join("live.db"))).expect("open");
        let stuck = event(&keys, Kind::MlsGroupMessage, 1, "stuck");
        let fresh = event(&keys, Kind::MlsGroupMessage, 2, "fresh");
        spool.append_events(&[stuck.clone()]).expect("append stuck");
        spool
            .complete_batch(&[stuck.id.to_hex()], &HashSet::new(), 1_000)
            .expect("defer stuck");
        spool.append_events(&[fresh.clone()]).expect("append fresh");
        let welcome = event(&keys, Kind::GiftWrap, 3, "welcome");
        spool
            .append_events(&[welcome.clone()])
            .expect("append welcome");

        assert_eq!(
            spool.read_batch(2, 1_000).expect("ready priority"),
            vec![welcome.clone(), fresh.clone()],
            "deferred head cannot starve a newer welcome or group row"
        );
        assert_eq!(
            spool.read_batch(10, 2_000).expect("retry due"),
            vec![welcome.clone(), fresh.clone(), stuck],
            "once due, lower-attempt work still precedes the retry"
        );
    }

    #[test]
    fn malformed_sqlite_row_is_quarantined_and_later_valid_work_drains() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("live.db");
        let keys = Keys::generate();
        let valid = event(&keys, Kind::MlsGroupMessage, 2, "valid");
        let mut spool = LiveEventSpool::load(Some(path.clone())).expect("open");
        spool
            .db
            .as_ref()
            .expect("persistent db")
            .execute(
                "INSERT INTO live_event_queue
                    (event_id, kind, event_json, available_after_ms, attempts)
                 VALUES ('corrupt', ?1, '{not-json', 0, 0)",
                params![Kind::MlsGroupMessage.as_u16()],
            )
            .expect("seed malformed row");
        spool
            .db
            .as_ref()
            .expect("persistent db")
            .execute(
                "INSERT INTO live_event_queue
                    (event_id, kind, event_json, available_after_ms, attempts)
                 VALUES (?1, ?2, ?3, 0, 0)",
                params![vec![0xff_u8], Kind::MlsGroupMessage.as_u16(), vec![0xfe_u8]],
            )
            .expect("seed non-text row");
        spool.pending_count += 2;
        spool.append_events(&[valid.clone()]).expect("append valid");

        assert_eq!(
            spool.read_batch(1, 0).expect("read past bad row"),
            vec![valid]
        );
        assert!(spool.recovery_required());
        assert_eq!(spool.pending_len(), 1, "only the valid unacked row remains");
        let quarantined: i64 = spool
            .db
            .as_ref()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM live_event_quarantine", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(quarantined, 2);
        let generation = spool
            .pending_recovery_generation()
            .expect("quarantine marks recovery");
        drop(spool);
        let reopened = LiveEventSpool::load(Some(path)).expect("reopen quarantine marker");
        assert_eq!(
            reopened.pending_recovery_generation(),
            Some(generation),
            "malformed-row loss marker must survive process restart"
        );
    }

    #[test]
    fn sqlite_identity_and_kind_mismatches_are_quarantined_without_retrying() {
        let dir = tempfile::tempdir().expect("tempdir");
        let keys = Keys::generate();
        let wrong_id = event(&keys, Kind::MlsGroupMessage, 1, "wrong id");
        let wrong_kind = event(&keys, Kind::MlsGroupMessage, 2, "wrong kind");
        let survivor = event(&keys, Kind::MlsGroupMessage, 3, "survivor");
        let mut spool = LiveEventSpool::load(Some(dir.path().join("live.db"))).expect("open");
        let db = spool.db.as_ref().expect("persistent db");
        db.execute(
            "INSERT INTO live_event_queue
                (event_id, kind, event_json, available_after_ms, attempts)
             VALUES (?1, ?2, ?3, 0, 0)",
            params![
                "00".repeat(32),
                Kind::MlsGroupMessage.as_u16(),
                wrong_id.as_json(),
            ],
        )
        .expect("seed mismatched id");
        db.execute(
            "INSERT INTO live_event_queue
                (event_id, kind, event_json, available_after_ms, attempts)
             VALUES (?1, ?2, ?3, 0, 0)",
            params![
                wrong_kind.id.to_hex(),
                Kind::GiftWrap.as_u16(),
                wrong_kind.as_json(),
            ],
        )
        .expect("seed mismatched kind");
        spool.pending_count += 2;
        spool
            .append_events(&[survivor.clone()])
            .expect("append survivor");

        assert_eq!(
            spool.read_batch(1, 0).expect("read survivor"),
            vec![survivor.clone()]
        );
        assert_eq!(spool.pending_len(), 1, "mismatched rows are deleted by seq");
        assert_eq!(
            spool.read_batch(1, 0).expect("read again"),
            vec![survivor],
            "mismatched rows must not reappear in an immediate retry loop",
        );
        assert!(spool.recovery_required());
        let quarantined: i64 = spool
            .db
            .as_ref()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM live_event_quarantine", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(quarantined, 2);
    }

    #[test]
    fn hard_row_bound_rejects_whole_batch_without_partial_insert() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("live.db");
        let keys = Keys::generate();
        let mut spool = LiveEventSpool::load(Some(path.clone())).expect("open");
        let events: Vec<_> = (0..=LIVE_EVENT_SPOOL_MAX_ROWS)
            .map(|index| event(&keys, Kind::MlsGroupMessage, index as u64 + 1, "row"))
            .collect();
        assert_eq!(
            spool.append_events(&events).expect("bounded append"),
            SpoolAppendOutcome::Full
        );
        assert_eq!(spool.pending_len(), 0);
        let generation = spool
            .pending_recovery_generation()
            .expect("overflow marks recovery");
        drop(spool);
        let reopened = LiveEventSpool::load(Some(path)).expect("reopen overflow marker");
        assert_eq!(reopened.pending_recovery_generation(), Some(generation));
    }

    #[test]
    fn in_memory_spool_declines_persistence_without_losing_caller_rows() {
        let keys = Keys::generate();
        let row = event(&keys, Kind::MlsGroupMessage, 1, "one");
        let mut spool = LiveEventSpool::load(None).expect("open");
        assert_eq!(
            spool.append_events(&[row]).expect("append"),
            SpoolAppendOutcome::Volatile
        );
        assert_eq!(spool.pending_len(), 0);
    }

    #[test]
    fn restart_repairs_complete_no_newline_tail_and_truncates_torn_tail() {
        let dir = tempfile::tempdir().expect("tempdir");
        let queue_path = dir.path().join("account.sonar-live-events.db");
        let legacy_path = legacy_spool_path_for_queue(&queue_path);
        let keys = Keys::generate();
        let first = event(&keys, Kind::MlsGroupMessage, 1, "one");
        let second = event(&keys, Kind::MlsGroupMessage, 2, "two");
        fs::write(
            &legacy_path,
            format!("{}\n{}", first.as_json(), second.as_json()),
        )
        .expect("seed complete no-newline tail");

        let spool = LiveEventSpool::load(Some(queue_path.clone())).expect("migrate complete tail");
        assert_eq!(
            spool.pending_len(),
            2,
            "complete final JSON is repaired, not lost"
        );
        drop(spool);

        // Simulate an older JSONL file left by a crash with one valid row and
        // one incomplete final write. Restart must truncate only the torn tail.
        remove_sqlite_files(&queue_path).expect("reset queue");
        fs::write(&legacy_path, format!("{}\n{{\"id\":", first.as_json())).expect("seed torn tail");
        let mut restarted = LiveEventSpool::load(Some(queue_path)).expect("restart migration");
        assert_eq!(restarted.pending_len(), 1);
        assert!(restarted.recovery_required());
        assert_eq!(restarted.read_batch(10, 0).expect("survivor"), vec![first]);
        assert!(
            !legacy_path.exists(),
            "legacy file is removed after durable import"
        );
    }

    #[test]
    fn legacy_migration_skips_oversize_row_with_bounded_buffer_and_keeps_later_event() {
        let dir = tempfile::tempdir().expect("tempdir");
        let queue_path = dir.path().join("account.sonar-live-events.db");
        let legacy_path = legacy_spool_path_for_queue(&queue_path);
        let keys = Keys::generate();
        let survivor = event(&keys, Kind::MlsGroupMessage, 7, "survivor");
        let mut bytes = vec![b'x'; LEGACY_MIGRATION_MAX_ROW_BYTES + 1];
        bytes.push(b'\n');
        bytes.extend_from_slice(survivor.as_json().as_bytes());
        bytes.push(b'\n');
        fs::write(&legacy_path, bytes).expect("seed bounded migration");

        let mut spool = LiveEventSpool::load(Some(queue_path)).expect("migrate");

        assert!(spool.recovery_required());
        assert_eq!(spool.read_batch(10, 0).expect("survivor"), vec![survivor]);
    }

    #[cfg(unix)]
    #[test]
    fn queue_database_is_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("live.db");
        let mut spool = LiveEventSpool::load(Some(path.clone())).expect("open");
        spool.mark_recovery_required().expect("persist intent");
        for candidate in sqlite_files(&path)
            .into_iter()
            .chain([recovery_intent_path_for_queue(&path)])
        {
            if candidate.exists() {
                assert_eq!(
                    fs::metadata(&candidate)
                        .expect("metadata")
                        .permissions()
                        .mode()
                        & 0o777,
                    0o600,
                    "{} must be owner-only",
                    candidate.display()
                );
            }
        }
    }
}
