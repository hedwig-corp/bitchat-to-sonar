use std::path::{Path, PathBuf};

use rusqlite::{params, Connection, OptionalExtension};

use crate::marmot::MarmotEngine;
use crate::Result;

const SCHEMA_VERSION: u32 = 4;
const NOTIFICATION_OUTBOX_LIMIT: i64 = 512;
const NOTIFICATION_JOURNAL_LIMIT: i64 = 4096;

pub struct ConversationIndex {
    db: Connection,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationSummary {
    pub group_id_hex: String,
    pub name: String,
    pub latest_content: String,
    pub latest_sender: String,
    pub latest_at_secs: u64,
    pub latest_mine: bool,
    pub message_count: u64,
    pub unread_count: u64,
    /// Monotonic per-conversation change counter: bumped on every summary
    /// mutation (new message, read-state change, rename). Hosts use it as a
    /// cheap cache key to skip rebuilding render state for unchanged chats.
    pub version: u64,
}

/// One stable, index-backed group row used by bounded notification recovery.
/// Paging this table avoids materializing MDK's complete group catalog inside
/// an OS wake; the caller resolves only the returned MLS ids through MDK.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationGroupCandidate {
    pub group_id_hex: String,
    pub name: String,
}

/// Durable, encrypted notification obligation. Rows are keyed by the stable
/// Marmot message id and remain until a host explicitly acknowledges the OS
/// post (or call-cancellation action) succeeded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingNotification {
    pub message_id: String,
    pub group_id: String,
    pub created_at_secs: u64,
    pub sender_pubkey: String,
    pub group_name: String,
    pub content_preview: String,
}

pub trait ConversationChangeListener: Send + Sync {
    fn on_conversation_changed(&self, group_id_hex: String);
}

pub const INDEX_DB_SUFFIX: &str = ".sonar-index.db";

pub fn index_db_path_for_db(db_path: &Path) -> std::path::PathBuf {
    let file_name = db_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("sonar");
    db_path.with_file_name(format!("{file_name}{INDEX_DB_SUFFIX}"))
}

pub fn wipe_index_for_db(db_path: &Path) -> Result<()> {
    for path in sqlite_file_set(index_db_path_for_db(db_path)) {
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
            Err(err) => {
                return Err(crate::Error::Storage(format!(
                    "index db wipe {}: {err}",
                    path.display()
                )));
            }
        }
    }
    Ok(())
}

fn sqlite_file_set(path: PathBuf) -> Vec<PathBuf> {
    vec![
        path.clone(),
        path.with_extension(format!(
            "{}-wal",
            path.extension().and_then(|ext| ext.to_str()).unwrap_or("")
        )),
        path.with_extension(format!(
            "{}-shm",
            path.extension().and_then(|ext| ext.to_str()).unwrap_or("")
        )),
        path.with_extension(format!(
            "{}-journal",
            path.extension().and_then(|ext| ext.to_str()).unwrap_or("")
        )),
    ]
}

impl ConversationIndex {
    pub fn open(path: &Path, key: [u8; 32]) -> Result<Self> {
        let db = Connection::open(path)
            .map_err(|e| crate::Error::Storage(format!("index db open: {e}")))?;
        let hex_key = hex::encode(key);
        db.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .map_err(|e| crate::Error::Storage(format!("index db key: {e}")))?;
        db.execute_batch("PRAGMA journal_mode = WAL;")
            .map_err(|e| crate::Error::Storage(format!("index db wal: {e}")))?;
        let idx = Self { db };
        idx.migrate()?;
        Ok(idx)
    }

    pub fn open_in_memory() -> Result<Self> {
        let db = Connection::open_in_memory()
            .map_err(|e| crate::Error::Storage(format!("index db memory: {e}")))?;
        let idx = Self { db };
        idx.migrate()?;
        Ok(idx)
    }

    fn migrate(&self) -> Result<()> {
        self.db
            .execute_batch("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);")
            .map_err(|e| crate::Error::Storage(format!("index schema_version: {e}")))?;

        let current: Option<u32> = self
            .db
            .query_row(
                "SELECT version FROM schema_version ORDER BY version DESC LIMIT 1",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| crate::Error::Storage(format!("index version read: {e}")))?;

        let current = current.unwrap_or(0);
        if current >= SCHEMA_VERSION {
            return Ok(());
        }

        // One transaction for ALL migration steps + the schema_version bump:
        // SQLite DDL is transactional, and without this a process kill between
        // an autocommitted ALTER and the version write leaves the db in a
        // state where the next open re-runs the ALTER and fails forever
        // ("duplicate column name"), silently degrading the index.
        let tx = self
            .db
            .unchecked_transaction()
            .map_err(|e| crate::Error::Storage(format!("index migrate begin: {e}")))?;

        if current < 1 {
            tx.execute_batch(
                "CREATE TABLE IF NOT EXISTS conversation_summary (
                    group_id_hex    TEXT PRIMARY KEY,
                    name            TEXT NOT NULL DEFAULT '',
                    latest_content  TEXT NOT NULL DEFAULT '',
                    latest_sender   TEXT NOT NULL DEFAULT '',
                    latest_at_secs  INTEGER NOT NULL DEFAULT 0,
                    latest_mine     INTEGER NOT NULL DEFAULT 0,
                    message_count   INTEGER NOT NULL DEFAULT 0,
                    unread_count    INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS idx_summary_recency
                    ON conversation_summary(latest_at_secs DESC);",
            )
            .map_err(|e| crate::Error::Storage(format!("index create table: {e}")))?;
        }

        if current < 2 && !Self::has_column(&tx, "conversation_summary", "version")? {
            // Additive per-conversation change counter (see ConversationSummary
            // docs). Existing rows start at 0; every mutation bumps it. The
            // column-existence guard makes the step idempotent even against a
            // db that somehow recorded the old schema version with the column
            // already present.
            tx.execute_batch(
                "ALTER TABLE conversation_summary
                    ADD COLUMN version INTEGER NOT NULL DEFAULT 0;",
            )
            .map_err(|e| crate::Error::Storage(format!("index add version column: {e}")))?;
        }

        if current < 3 {
            // This table lives in the same SQLCipher database as conversation
            // summaries: previews/control lines must never leak into the
            // plaintext outbox sidecar. INSERT OR IGNORE makes relay replay and
            // process restart idempotent by stable message id.
            tx.execute_batch(
                "CREATE TABLE IF NOT EXISTS notification_outbox (
                    message_id       TEXT PRIMARY KEY,
                    group_id         TEXT NOT NULL,
                    created_at_secs  INTEGER NOT NULL,
                    sender_pubkey    TEXT NOT NULL,
                    group_name       TEXT NOT NULL DEFAULT '',
                    content_preview  TEXT NOT NULL DEFAULT '',
                    acknowledged     INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS idx_notification_outbox_order
                    ON notification_outbox(created_at_secs ASC, message_id ASC);",
            )
            .map_err(|e| crate::Error::Storage(format!("index notification outbox: {e}")))?;
        }

        if current < 4 && !Self::has_column(&tx, "notification_outbox", "acknowledged")? {
            // Keep bounded acknowledgement tombstones. A notification wake can
            // crash after MDK commits a message but before this sidecar records
            // its host obligation; reconciliation replays recent committed
            // messages into this table. A tombstone prevents an already-posted
            // notification from being resurrected by that replay.
            tx.execute_batch(
                "ALTER TABLE notification_outbox
                    ADD COLUMN acknowledged INTEGER NOT NULL DEFAULT 0;",
            )
            .map_err(|e| crate::Error::Storage(format!("index add notification ack: {e}")))?;
        }

        tx.execute(
            "INSERT OR REPLACE INTO schema_version(version) VALUES (?1)",
            params![SCHEMA_VERSION],
        )
        .map_err(|e| crate::Error::Storage(format!("index version write: {e}")))?;

        tx.commit()
            .map_err(|e| crate::Error::Storage(format!("index migrate commit: {e}")))?;

        Ok(())
    }

    fn has_column(db: &Connection, table: &str, column: &str) -> Result<bool> {
        let mut stmt = db
            .prepare(&format!("PRAGMA table_info({table})"))
            .map_err(|e| crate::Error::Storage(format!("index table_info: {e}")))?;
        let names = stmt
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(|e| crate::Error::Storage(format!("index table_info query: {e}")))?;
        for name in names {
            let name =
                name.map_err(|e| crate::Error::Storage(format!("index table_info row: {e}")))?;
            if name == column {
                return Ok(true);
            }
        }
        Ok(false)
    }

    pub fn upsert_summary(
        &self,
        group_id_hex: &str,
        name: &str,
        content: &str,
        sender: &str,
        at_secs: u64,
        mine: bool,
    ) -> Result<()> {
        Self::upsert_summary_on(&self.db, group_id_hex, name, content, sender, at_secs, mine)
    }

    fn upsert_summary_on(
        db: &Connection,
        group_id_hex: &str,
        name: &str,
        content: &str,
        sender: &str,
        at_secs: u64,
        mine: bool,
    ) -> Result<()> {
        db.execute(
            "INSERT INTO conversation_summary
                    (group_id_hex, name, latest_content, latest_sender, latest_at_secs, latest_mine, message_count, unread_count, version)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, ?7, 1)
                 ON CONFLICT(group_id_hex) DO UPDATE SET
                    name = CASE WHEN ?2 != '' THEN ?2 ELSE name END,
                    latest_content = CASE WHEN ?5 >= latest_at_secs THEN ?3 ELSE latest_content END,
                    latest_sender = CASE WHEN ?5 >= latest_at_secs THEN ?4 ELSE latest_sender END,
                    latest_at_secs = CASE WHEN ?5 >= latest_at_secs THEN ?5 ELSE latest_at_secs END,
                    latest_mine = CASE WHEN ?5 >= latest_at_secs THEN ?6 ELSE latest_mine END,
                    message_count = message_count + 1,
                    unread_count = CASE WHEN ?6 = 0 THEN unread_count + 1 ELSE unread_count END,
                    version = version + 1",
            params![
                group_id_hex,
                name,
                content,
                sender,
                at_secs as i64,
                mine as i32,
                if mine { 0i32 } else { 1i32 },
            ],
        )
        .map_err(|e| crate::Error::Storage(format!("index upsert: {e}")))?;
        Ok(())
    }

    pub fn ensure_group(&self, group_id_hex: &str, name: &str) -> Result<()> {
        self.db
            .execute(
                "INSERT OR IGNORE INTO conversation_summary (group_id_hex, name) VALUES (?1, ?2)",
                params![group_id_hex, name],
            )
            .map_err(|e| crate::Error::Storage(format!("index ensure_group: {e}")))?;
        Ok(())
    }

    pub fn mark_read(&self, group_id_hex: &str) -> Result<()> {
        self.db
            .execute(
                "UPDATE conversation_summary
                    SET unread_count = 0, version = version + 1
                    WHERE group_id_hex = ?1 AND unread_count != 0",
                params![group_id_hex],
            )
            .map_err(|e| crate::Error::Storage(format!("index mark_read: {e}")))?;
        Ok(())
    }

    pub fn update_group_name(&self, group_id_hex: &str, name: &str) -> Result<()> {
        self.db
            .execute(
                "UPDATE conversation_summary
                    SET name = ?2, version = version + 1
                    WHERE group_id_hex = ?1 AND name != ?2",
                params![group_id_hex, name],
            )
            .map_err(|e| crate::Error::Storage(format!("index update_name: {e}")))?;
        Ok(())
    }

    pub fn remove_group(&self, group_id_hex: &str) -> Result<()> {
        let tx = self
            .db
            .unchecked_transaction()
            .map_err(|e| crate::Error::Storage(format!("index remove begin: {e}")))?;
        tx.execute(
            "DELETE FROM conversation_summary WHERE group_id_hex = ?1",
            params![group_id_hex],
        )
        .map_err(|e| crate::Error::Storage(format!("index remove: {e}")))?;
        tx.execute(
            "DELETE FROM notification_outbox WHERE group_id = ?1",
            params![group_id_hex],
        )
        .map_err(|e| crate::Error::Storage(format!("index remove notifications: {e}")))?;
        tx.commit()
            .map_err(|e| crate::Error::Storage(format!("index remove commit: {e}")))?;
        Ok(())
    }

    pub fn enqueue_notification(&self, notification: &PendingNotification) -> Result<()> {
        let tx = self
            .db
            .unchecked_transaction()
            .map_err(|e| crate::Error::Storage(format!("notification enqueue begin: {e}")))?;
        tx.execute(
            "INSERT OR IGNORE INTO notification_outbox
                (message_id, group_id, created_at_secs, sender_pubkey, group_name, content_preview,
                 acknowledged)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0)",
            params![
                notification.message_id,
                notification.group_id,
                notification.created_at_secs as i64,
                notification.sender_pubkey,
                notification.group_name,
                notification.content_preview,
            ],
        )
        .map_err(|e| crate::Error::Storage(format!("notification enqueue: {e}")))?;
        Self::bound_notification_journal(&tx)?;
        tx.commit()
            .map_err(|e| crate::Error::Storage(format!("notification enqueue commit: {e}")))?;
        Ok(())
    }

    /// Commit the chat-list mutation and notification obligation in one
    /// SQLCipher transaction. Returns true only when the stable notification
    /// id was new. Reconciliation uses this after an MDK/index crash boundary:
    /// acknowledged tombstones make replay idempotent, while a missing row
    /// proves the summary transaction never landed and is safe to rebuild.
    pub fn record_incoming_message_and_notification(
        &self,
        notification: &PendingNotification,
        summary_content: &str,
        mine: bool,
    ) -> Result<bool> {
        let tx = self
            .db
            .unchecked_transaction()
            .map_err(|e| crate::Error::Storage(format!("notification record begin: {e}")))?;
        let inserted = tx
            .execute(
                "INSERT OR IGNORE INTO notification_outbox
                    (message_id, group_id, created_at_secs, sender_pubkey, group_name,
                     content_preview, acknowledged)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0)",
                params![
                    notification.message_id,
                    notification.group_id,
                    notification.created_at_secs as i64,
                    notification.sender_pubkey,
                    notification.group_name,
                    notification.content_preview,
                ],
            )
            .map_err(|e| crate::Error::Storage(format!("notification record insert: {e}")))?
            != 0;
        if inserted {
            Self::upsert_summary_on(
                &tx,
                &notification.group_id,
                &notification.group_name,
                summary_content,
                &notification.sender_pubkey,
                notification.created_at_secs,
                mine,
            )?;
        }
        Self::bound_notification_journal(&tx)?;
        tx.commit()
            .map_err(|e| crate::Error::Storage(format!("notification record commit: {e}")))?;
        Ok(inserted)
    }

    fn bound_notification_journal(db: &Connection) -> Result<()> {
        // Permission-disabled hosts may intentionally leave rows pending. Keep
        // the encrypted obligation bounded while retaining stable tombstones
        // for replay suppression. Capacity eviction is an explicit policy ACK,
        // not deletion, so crash reconciliation cannot resurrect it.
        db.execute(
            "UPDATE notification_outbox SET acknowledged = 1
             WHERE message_id IN (
                 SELECT message_id FROM notification_outbox
                 WHERE acknowledged = 0
                 ORDER BY created_at_secs ASC, message_id ASC
                 LIMIT MAX(0, (SELECT COUNT(*) FROM notification_outbox WHERE acknowledged = 0) - ?1)
             )",
            params![NOTIFICATION_OUTBOX_LIMIT],
        )
        .map_err(|e| crate::Error::Storage(format!("notification outbox cap: {e}")))?;
        db.execute(
            "DELETE FROM notification_outbox
             WHERE message_id IN (
                 SELECT message_id FROM notification_outbox
                 WHERE acknowledged = 1
                 ORDER BY created_at_secs ASC, message_id ASC
                 LIMIT MAX(0, (SELECT COUNT(*) FROM notification_outbox) - ?1)
             )",
            params![NOTIFICATION_JOURNAL_LIMIT],
        )
        .map_err(|e| crate::Error::Storage(format!("notification journal cap: {e}")))?;
        Ok(())
    }

    pub fn pending_notifications(&self) -> Result<Vec<PendingNotification>> {
        let mut stmt = self
            .db
            .prepare(
                "SELECT message_id, group_id, created_at_secs, sender_pubkey,
                        group_name, content_preview
                 FROM notification_outbox
                 WHERE acknowledged = 0
                 ORDER BY created_at_secs ASC, message_id ASC",
            )
            .map_err(|e| crate::Error::Storage(format!("notification peek prepare: {e}")))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(PendingNotification {
                    message_id: row.get(0)?,
                    group_id: row.get(1)?,
                    created_at_secs: row.get::<_, i64>(2)? as u64,
                    sender_pubkey: row.get(3)?,
                    group_name: row.get(4)?,
                    content_preview: row.get(5)?,
                })
            })
            .map_err(|e| crate::Error::Storage(format!("notification peek query: {e}")))?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(|e| crate::Error::Storage(format!("notification peek row: {e}")))
    }

    pub fn acknowledge_notifications(&self, message_ids: &[String]) -> Result<usize> {
        if message_ids.is_empty() {
            return Ok(0);
        }
        let tx = self
            .db
            .unchecked_transaction()
            .map_err(|e| crate::Error::Storage(format!("notification ack begin: {e}")))?;
        let mut acknowledged = 0;
        for message_id in message_ids {
            acknowledged += tx
                .execute(
                    "UPDATE notification_outbox SET acknowledged = 1
                     WHERE message_id = ?1 AND acknowledged = 0",
                    params![message_id],
                )
                .map_err(|e| crate::Error::Storage(format!("notification ack: {e}")))?;
        }
        tx.commit()
            .map_err(|e| crate::Error::Storage(format!("notification ack commit: {e}")))?;
        Ok(acknowledged)
    }

    pub fn summaries_ordered(&self) -> Result<Vec<ConversationSummary>> {
        let mut stmt = self
            .db
            .prepare(
                "SELECT group_id_hex, name, latest_content, latest_sender,
                        latest_at_secs, latest_mine, message_count, unread_count, version
                 FROM conversation_summary
                 ORDER BY latest_at_secs DESC",
            )
            .map_err(|e| crate::Error::Storage(format!("index summaries prepare: {e}")))?;

        let rows = stmt
            .query_map([], |row| {
                Ok(ConversationSummary {
                    group_id_hex: row.get(0)?,
                    name: row.get(1)?,
                    latest_content: row.get(2)?,
                    latest_sender: row.get(3)?,
                    latest_at_secs: row.get::<_, i64>(4)? as u64,
                    latest_mine: row.get::<_, i32>(5)? != 0,
                    message_count: row.get::<_, i64>(6)? as u64,
                    unread_count: row.get::<_, i64>(7)? as u64,
                    version: row.get::<_, i64>(8)? as u64,
                })
            })
            .map_err(|e| crate::Error::Storage(format!("index summaries query: {e}")))?;

        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(|e| crate::Error::Storage(format!("index summaries row: {e}")))
    }

    pub fn summary(&self, group_id_hex: &str) -> Result<Option<ConversationSummary>> {
        self.db
            .query_row(
                "SELECT group_id_hex, name, latest_content, latest_sender,
                        latest_at_secs, latest_mine, message_count, unread_count, version
                 FROM conversation_summary
                 WHERE group_id_hex = ?1",
                params![group_id_hex],
                |row| {
                    Ok(ConversationSummary {
                        group_id_hex: row.get(0)?,
                        name: row.get(1)?,
                        latest_content: row.get(2)?,
                        latest_sender: row.get(3)?,
                        latest_at_secs: row.get::<_, i64>(4)? as u64,
                        latest_mine: row.get::<_, i32>(5)? != 0,
                        message_count: row.get::<_, i64>(6)? as u64,
                        unread_count: row.get::<_, i64>(7)? as u64,
                        version: row.get::<_, i64>(8)? as u64,
                    })
                },
            )
            .optional()
            .map_err(|e| crate::Error::Storage(format!("index summary: {e}")))
    }

    /// Return one keyset-paged group window in stable MLS-id order. The
    /// primary-key range plus LIMIT is bounded even for very large accounts;
    /// unlike `MarmotEngine::groups`, it never builds or sorts the full set.
    pub fn notification_group_candidates_after(
        &self,
        after_group_id_hex: Option<&str>,
        limit: usize,
    ) -> Result<Vec<NotificationGroupCandidate>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let map_row = |row: &rusqlite::Row<'_>| {
            Ok(NotificationGroupCandidate {
                group_id_hex: row.get(0)?,
                name: row.get(1)?,
            })
        };
        let collected = if let Some(after) = after_group_id_hex {
            let mut stmt = self
                .db
                .prepare(
                    "SELECT group_id_hex, name
                     FROM conversation_summary
                     WHERE group_id_hex > ?1
                     ORDER BY group_id_hex ASC
                     LIMIT ?2",
                )
                .map_err(|e| crate::Error::Storage(format!("notification groups prepare: {e}")))?;
            let rows = stmt
                .query_map(params![after, limit as i64], map_row)
                .map_err(|e| crate::Error::Storage(format!("notification groups query: {e}")))?;
            rows.collect::<std::result::Result<Vec<_>, _>>()
        } else {
            let mut stmt = self
                .db
                .prepare(
                    "SELECT group_id_hex, name
                     FROM conversation_summary
                     ORDER BY group_id_hex ASC
                     LIMIT ?1",
                )
                .map_err(|e| crate::Error::Storage(format!("notification groups prepare: {e}")))?;
            let rows = stmt
                .query_map(params![limit as i64], map_row)
                .map_err(|e| crate::Error::Storage(format!("notification groups query: {e}")))?;
            rows.collect::<std::result::Result<Vec<_>, _>>()
        };
        collected.map_err(|e| crate::Error::Storage(format!("notification groups row: {e}")))
    }

    pub fn is_empty(&self) -> bool {
        self.db
            .query_row("SELECT COUNT(*) FROM conversation_summary", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap_or(0)
            == 0
    }

    pub fn materialize_from(&self, engine: &MarmotEngine) -> Result<()> {
        let groups = engine.groups()?;
        for group in &groups {
            let group_id_hex = hex::encode(group.mls_group_id.as_slice());
            let page = engine.messages_page(&group.mls_group_id, 1, 0)?;
            if let Some(msg) = page.first() {
                let sender = msg.sender.to_string();
                self.upsert_summary(
                    &group_id_hex,
                    &group.name,
                    &msg.content,
                    &sender,
                    msg.created_at.as_secs(),
                    msg.mine,
                )?;
                self.db
                    .execute(
                        "UPDATE conversation_summary SET unread_count = 0 WHERE group_id_hex = ?1",
                        params![group_id_hex],
                    )
                    .map_err(|e| {
                        crate::Error::Storage(format!("index materialize unread reset: {e}"))
                    })?;
            } else {
                self.ensure_group(&group_id_hex, &group.name)?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_in_memory_and_migrate() {
        let idx = ConversationIndex::open_in_memory().unwrap();
        assert!(idx.is_empty());
        assert!(idx.summaries_ordered().unwrap().is_empty());
    }

    #[test]
    fn notification_outbox_peeks_until_explicit_ack() {
        let idx = ConversationIndex::open_in_memory().unwrap();
        let notification = PendingNotification {
            message_id: "message-1".into(),
            group_id: "group-1".into(),
            created_at_secs: 7,
            sender_pubkey: "npub".into(),
            group_name: "Alice".into(),
            content_preview: "secret".into(),
        };
        idx.enqueue_notification(&notification).unwrap();
        idx.enqueue_notification(&notification).unwrap();

        assert_eq!(
            idx.pending_notifications().unwrap(),
            vec![notification.clone()]
        );
        assert_eq!(idx.pending_notifications().unwrap().len(), 1);
        assert_eq!(
            idx.acknowledge_notifications(&["message-1".into()])
                .unwrap(),
            1
        );
        assert!(idx.pending_notifications().unwrap().is_empty());

        // Crash reconciliation must not resurrect a notification whose host
        // action already succeeded.
        idx.enqueue_notification(&notification).unwrap();
        assert!(idx.pending_notifications().unwrap().is_empty());
    }

    #[test]
    fn incoming_summary_and_notification_replay_are_atomic_and_idempotent() {
        let idx = ConversationIndex::open_in_memory().unwrap();
        let notification = PendingNotification {
            message_id: "message-atomic".into(),
            group_id: "group-atomic".into(),
            created_at_secs: 9,
            sender_pubkey: "npub".into(),
            group_name: "Alice".into(),
            content_preview: "short preview".into(),
        };
        assert!(idx
            .record_incoming_message_and_notification(&notification, "complete body", false)
            .unwrap());
        assert!(!idx
            .record_incoming_message_and_notification(&notification, "complete body", false)
            .unwrap());

        let summary = idx.summary("group-atomic").unwrap().unwrap();
        assert_eq!(summary.latest_content, "complete body");
        assert_eq!(summary.message_count, 1);
        assert_eq!(idx.pending_notifications().unwrap(), vec![notification]);
    }

    #[test]
    fn notification_outbox_survives_reopen_and_group_delete() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.db");
        let key = [9u8; 32];
        let notification = PendingNotification {
            message_id: "message-1".into(),
            group_id: "group-1".into(),
            created_at_secs: 7,
            sender_pubkey: "npub".into(),
            group_name: "Alice".into(),
            content_preview: "secret".into(),
        };
        ConversationIndex::open(&path, key)
            .unwrap()
            .enqueue_notification(&notification)
            .unwrap();

        let reopened = ConversationIndex::open(&path, key).unwrap();
        assert_eq!(
            reopened.pending_notifications().unwrap(),
            vec![notification]
        );
        reopened.remove_group("group-1").unwrap();
        assert!(reopened.pending_notifications().unwrap().is_empty());
    }

    #[test]
    fn wipe_index_removes_db_and_sqlite_sidecars() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        let index_path = index_db_path_for_db(&db_path);
        let paths = sqlite_file_set(index_path);
        for path in &paths {
            std::fs::write(path, b"test").unwrap();
            assert!(path.exists());
        }

        wipe_index_for_db(&db_path).unwrap();

        for path in paths {
            assert!(!path.exists(), "{} should be wiped", path.display());
        }
    }

    #[test]
    fn upsert_and_ordering() {
        let idx = ConversationIndex::open_in_memory().unwrap();

        idx.upsert_summary("group_a", "Alice", "hello", "npub_alice", 100, false)
            .unwrap();
        idx.upsert_summary("group_b", "Bob", "world", "npub_bob", 200, true)
            .unwrap();

        let summaries = idx.summaries_ordered().unwrap();
        assert_eq!(summaries.len(), 2);
        assert_eq!(summaries[0].group_id_hex, "group_b");
        assert_eq!(summaries[0].latest_at_secs, 200);
        assert_eq!(summaries[0].latest_mine, true);
        assert_eq!(summaries[0].unread_count, 0);
        assert_eq!(summaries[1].group_id_hex, "group_a");
        assert_eq!(summaries[1].latest_at_secs, 100);
        assert_eq!(summaries[1].unread_count, 1);
    }

    #[test]
    fn upsert_only_updates_when_newer() {
        let idx = ConversationIndex::open_in_memory().unwrap();

        idx.upsert_summary("g1", "Chat", "newer msg", "sender_b", 200, false)
            .unwrap();
        idx.upsert_summary("g1", "Chat", "older msg", "sender_a", 100, true)
            .unwrap();

        let s = idx.summary("g1").unwrap().unwrap();
        assert_eq!(s.latest_content, "newer msg");
        assert_eq!(s.latest_at_secs, 200);
        assert_eq!(s.message_count, 2);
    }

    #[test]
    fn mark_read_resets_unread() {
        let idx = ConversationIndex::open_in_memory().unwrap();

        idx.upsert_summary("g1", "Chat", "msg1", "sender", 100, false)
            .unwrap();
        idx.upsert_summary("g1", "Chat", "msg2", "sender", 200, false)
            .unwrap();

        let s = idx.summary("g1").unwrap().unwrap();
        assert_eq!(s.unread_count, 2);

        idx.mark_read("g1").unwrap();
        let s = idx.summary("g1").unwrap().unwrap();
        assert_eq!(s.unread_count, 0);
    }

    #[test]
    fn remove_group_deletes_summary() {
        let idx = ConversationIndex::open_in_memory().unwrap();
        idx.upsert_summary("g1", "Chat", "msg", "s", 100, true)
            .unwrap();
        assert!(!idx.is_empty());

        idx.remove_group("g1").unwrap();
        assert!(idx.is_empty());
        assert!(idx.summary("g1").unwrap().is_none());
    }

    #[test]
    fn ensure_group_does_not_overwrite() {
        let idx = ConversationIndex::open_in_memory().unwrap();
        idx.upsert_summary("g1", "Chat", "msg", "s", 100, true)
            .unwrap();
        idx.ensure_group("g1", "New Name").unwrap();

        let s = idx.summary("g1").unwrap().unwrap();
        assert_eq!(s.name, "Chat");
        assert_eq!(s.latest_content, "msg");
    }

    #[test]
    fn update_group_name() {
        let idx = ConversationIndex::open_in_memory().unwrap();
        idx.upsert_summary("g1", "Old", "msg", "s", 100, true)
            .unwrap();
        idx.update_group_name("g1", "New").unwrap();

        let s = idx.summary("g1").unwrap().unwrap();
        assert_eq!(s.name, "New");
    }

    #[test]
    fn version_bumps_on_every_visible_mutation() {
        let idx = ConversationIndex::open_in_memory().unwrap();

        idx.upsert_summary("g1", "Chat", "msg1", "peer", 100, false)
            .unwrap();
        assert_eq!(idx.summary("g1").unwrap().unwrap().version, 1);

        idx.upsert_summary("g1", "Chat", "msg2", "peer", 200, false)
            .unwrap();
        assert_eq!(idx.summary("g1").unwrap().unwrap().version, 2);

        idx.mark_read("g1").unwrap();
        assert_eq!(idx.summary("g1").unwrap().unwrap().version, 3);

        // No-op mutations must NOT bump: version is a cache key, and a bump
        // with no visible change would force hosts to rebuild for nothing.
        idx.mark_read("g1").unwrap();
        assert_eq!(idx.summary("g1").unwrap().unwrap().version, 3);
        idx.update_group_name("g1", "Chat").unwrap();
        assert_eq!(idx.summary("g1").unwrap().unwrap().version, 3);

        idx.update_group_name("g1", "Renamed").unwrap();
        assert_eq!(idx.summary("g1").unwrap().unwrap().version, 4);
    }

    #[test]
    fn migrates_v1_schema_adding_version_column() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.db");
        let key = [0x11u8; 32];

        // Hand-craft a v1 database: old schema, one existing summary row.
        {
            let db = Connection::open(&path).unwrap();
            let hex_key = hex::encode(key);
            db.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
                .unwrap();
            db.execute_batch(
                "CREATE TABLE schema_version (version INTEGER NOT NULL);
                 CREATE TABLE conversation_summary (
                    group_id_hex    TEXT PRIMARY KEY,
                    name            TEXT NOT NULL DEFAULT '',
                    latest_content  TEXT NOT NULL DEFAULT '',
                    latest_sender   TEXT NOT NULL DEFAULT '',
                    latest_at_secs  INTEGER NOT NULL DEFAULT 0,
                    latest_mine     INTEGER NOT NULL DEFAULT 0,
                    message_count   INTEGER NOT NULL DEFAULT 0,
                    unread_count    INTEGER NOT NULL DEFAULT 0
                 );
                 INSERT INTO schema_version(version) VALUES (1);
                 INSERT INTO conversation_summary
                    (group_id_hex, name, latest_content, latest_sender,
                     latest_at_secs, latest_mine, message_count, unread_count)
                    VALUES ('g1', 'Chat', 'old msg', 'peer', 100, 0, 3, 1);",
            )
            .unwrap();
        }

        let idx = ConversationIndex::open(&path, key).unwrap();
        let s = idx.summary("g1").unwrap().unwrap();
        assert_eq!(s.latest_content, "old msg");
        assert_eq!(s.message_count, 3);
        assert_eq!(s.version, 0, "pre-migration rows start at version 0");

        idx.upsert_summary("g1", "Chat", "new msg", "peer", 200, false)
            .unwrap();
        assert_eq!(idx.summary("g1").unwrap().unwrap().version, 1);
    }

    #[test]
    fn migrates_v3_notification_rows_to_replay_safe_journal() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.db");
        let key = [0x33u8; 32];
        {
            let db = Connection::open(&path).unwrap();
            let hex_key = hex::encode(key);
            db.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
                .unwrap();
            db.execute_batch(
                "CREATE TABLE schema_version (version INTEGER NOT NULL);
                 CREATE TABLE conversation_summary (
                    group_id_hex TEXT PRIMARY KEY,
                    name TEXT NOT NULL DEFAULT '',
                    latest_content TEXT NOT NULL DEFAULT '',
                    latest_sender TEXT NOT NULL DEFAULT '',
                    latest_at_secs INTEGER NOT NULL DEFAULT 0,
                    latest_mine INTEGER NOT NULL DEFAULT 0,
                    message_count INTEGER NOT NULL DEFAULT 0,
                    unread_count INTEGER NOT NULL DEFAULT 0,
                    version INTEGER NOT NULL DEFAULT 0
                 );
                 CREATE TABLE notification_outbox (
                    message_id TEXT PRIMARY KEY,
                    group_id TEXT NOT NULL,
                    created_at_secs INTEGER NOT NULL,
                    sender_pubkey TEXT NOT NULL,
                    group_name TEXT NOT NULL DEFAULT '',
                    content_preview TEXT NOT NULL DEFAULT ''
                 );
                 INSERT INTO schema_version(version) VALUES (3);
                 INSERT INTO notification_outbox
                    (message_id, group_id, created_at_secs, sender_pubkey,
                     group_name, content_preview)
                    VALUES ('m1', 'g1', 7, 'npub', 'Alice', 'secret');",
            )
            .unwrap();
        }

        let idx = ConversationIndex::open(&path, key).unwrap();
        let pending = idx.pending_notifications().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(idx.acknowledge_notifications(&["m1".into()]).unwrap(), 1);
        idx.enqueue_notification(&pending[0]).unwrap();
        assert!(idx.pending_notifications().unwrap().is_empty());
    }

    #[test]
    fn migration_is_idempotent_when_version_column_already_exists() {
        // A db that already has the version column but still records schema
        // version 1 (the state a non-atomic migration could have produced).
        // Opening must not fail with "duplicate column name".
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.db");
        let key = [0x22u8; 32];
        {
            let db = Connection::open(&path).unwrap();
            let hex_key = hex::encode(key);
            db.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
                .unwrap();
            db.execute_batch(
                "CREATE TABLE schema_version (version INTEGER NOT NULL);
                 CREATE TABLE conversation_summary (
                    group_id_hex    TEXT PRIMARY KEY,
                    name            TEXT NOT NULL DEFAULT '',
                    latest_content  TEXT NOT NULL DEFAULT '',
                    latest_sender   TEXT NOT NULL DEFAULT '',
                    latest_at_secs  INTEGER NOT NULL DEFAULT 0,
                    latest_mine     INTEGER NOT NULL DEFAULT 0,
                    message_count   INTEGER NOT NULL DEFAULT 0,
                    unread_count    INTEGER NOT NULL DEFAULT 0,
                    version         INTEGER NOT NULL DEFAULT 0
                 );
                 INSERT INTO schema_version(version) VALUES (1);",
            )
            .unwrap();
        }

        let idx = ConversationIndex::open(&path, key).expect("open must not fail");
        idx.upsert_summary("g1", "Chat", "msg", "peer", 100, false)
            .unwrap();
        assert_eq!(idx.summary("g1").unwrap().unwrap().version, 1);

        // Reopen: schema_version is now 2, migration is a no-op.
        drop(idx);
        let idx = ConversationIndex::open(&path, key).expect("reopen must not fail");
        assert_eq!(idx.summary("g1").unwrap().unwrap().version, 1);
    }

    #[test]
    fn mine_messages_do_not_increment_unread() {
        let idx = ConversationIndex::open_in_memory().unwrap();
        idx.upsert_summary("g1", "Chat", "msg1", "me", 100, true)
            .unwrap();
        idx.upsert_summary("g1", "Chat", "msg2", "me", 200, true)
            .unwrap();

        let s = idx.summary("g1").unwrap().unwrap();
        assert_eq!(s.unread_count, 0);
        assert_eq!(s.message_count, 2);
    }
}
