use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension};

use crate::marmot::MarmotEngine;
use crate::Result;

const SCHEMA_VERSION: u32 = 1;

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
            .execute_batch(
                "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);",
            )
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

        if current.unwrap_or(0) < SCHEMA_VERSION {
            self.db
                .execute_batch(
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

            self.db
                .execute(
                    "INSERT OR REPLACE INTO schema_version(version) VALUES (?1)",
                    params![SCHEMA_VERSION],
                )
                .map_err(|e| crate::Error::Storage(format!("index version write: {e}")))?;
        }

        Ok(())
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
        self.db
            .execute(
                "INSERT INTO conversation_summary
                    (group_id_hex, name, latest_content, latest_sender, latest_at_secs, latest_mine, message_count, unread_count)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, ?7)
                 ON CONFLICT(group_id_hex) DO UPDATE SET
                    name = CASE WHEN ?2 != '' THEN ?2 ELSE name END,
                    latest_content = CASE WHEN ?5 >= latest_at_secs THEN ?3 ELSE latest_content END,
                    latest_sender = CASE WHEN ?5 >= latest_at_secs THEN ?4 ELSE latest_sender END,
                    latest_at_secs = CASE WHEN ?5 >= latest_at_secs THEN ?5 ELSE latest_at_secs END,
                    latest_mine = CASE WHEN ?5 >= latest_at_secs THEN ?6 ELSE latest_mine END,
                    message_count = message_count + 1,
                    unread_count = CASE WHEN ?6 = 0 THEN unread_count + 1 ELSE unread_count END",
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
                "UPDATE conversation_summary SET unread_count = 0 WHERE group_id_hex = ?1",
                params![group_id_hex],
            )
            .map_err(|e| crate::Error::Storage(format!("index mark_read: {e}")))?;
        Ok(())
    }

    pub fn update_group_name(&self, group_id_hex: &str, name: &str) -> Result<()> {
        self.db
            .execute(
                "UPDATE conversation_summary SET name = ?2 WHERE group_id_hex = ?1",
                params![group_id_hex, name],
            )
            .map_err(|e| crate::Error::Storage(format!("index update_name: {e}")))?;
        Ok(())
    }

    pub fn remove_group(&self, group_id_hex: &str) -> Result<()> {
        self.db
            .execute(
                "DELETE FROM conversation_summary WHERE group_id_hex = ?1",
                params![group_id_hex],
            )
            .map_err(|e| crate::Error::Storage(format!("index remove: {e}")))?;
        Ok(())
    }

    pub fn summaries_ordered(&self) -> Result<Vec<ConversationSummary>> {
        let mut stmt = self
            .db
            .prepare(
                "SELECT group_id_hex, name, latest_content, latest_sender,
                        latest_at_secs, latest_mine, message_count, unread_count
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
                })
            })
            .map_err(|e| crate::Error::Storage(format!("index summaries query: {e}")))?;

        let mut result = Vec::new();
        for row in rows {
            result
                .push(row.map_err(|e| crate::Error::Storage(format!("index summaries row: {e}")))?);
        }
        Ok(result)
    }

    pub fn summary(&self, group_id_hex: &str) -> Result<Option<ConversationSummary>> {
        self.db
            .query_row(
                "SELECT group_id_hex, name, latest_content, latest_sender,
                        latest_at_secs, latest_mine, message_count, unread_count
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
                    })
                },
            )
            .optional()
            .map_err(|e| crate::Error::Storage(format!("index summary: {e}")))
    }

    pub fn is_empty(&self) -> bool {
        self.db
            .query_row(
                "SELECT COUNT(*) FROM conversation_summary",
                [],
                |row| row.get::<_, i64>(0),
            )
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
                let total = engine.messages(&group.mls_group_id)?.len() as u64;
                if total > 1 {
                    self.db
                        .execute(
                            "UPDATE conversation_summary SET message_count = ?2, unread_count = 0 WHERE group_id_hex = ?1",
                            params![group_id_hex, total as i64],
                        )
                        .map_err(|e| crate::Error::Storage(format!("index materialize count: {e}")))?;
                }
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
