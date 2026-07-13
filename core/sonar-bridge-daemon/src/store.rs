use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sonar_core::marmot::{ChatMessage, MessageClassification};
use zeroize::Zeroize;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaDto {
    pub url: String,
    pub mime_type: String,
    pub filename: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageDto {
    pub id: String,
    pub group_id: String,
    pub sender: String,
    pub content: String,
    pub created_at_secs: u64,
    pub mine: bool,
    pub media: Vec<MediaDto>,
}

impl TryFrom<&ChatMessage> for MessageDto {
    type Error = String;

    fn try_from(message: &ChatMessage) -> Result<Self, Self::Error> {
        if !matches!(message.classification, MessageClassification::Text) {
            return Err("control messages are not bridged".into());
        }
        Ok(Self {
            id: message.id.to_hex(),
            group_id: hex::encode(message.group_id.as_slice()),
            sender: message.sender.to_hex(),
            content: message.content.clone(),
            created_at_secs: message.created_at.as_secs(),
            mine: message.mine,
            media: message
                .media
                .iter()
                .map(|media| MediaDto {
                    url: media.url.clone(),
                    mime_type: media.mime_type.clone(),
                    filename: sanitize_filename(&media.filename),
                    width: media.width,
                    height: media.height,
                    duration_ms: media.duration_ms,
                })
                .collect(),
        })
    }
}

#[derive(Debug, Clone)]
pub struct JournalEntry {
    pub txn_key: String,
    pub peer_hex: String,
    pub kind: String,
    pub body: String,
    pub media_path: Option<String>,
    pub filename: Option<String>,
    pub mime: Option<String>,
    pub caption: Option<String>,
    pub status: String,
    pub group_id: Option<String>,
    pub message_id: Option<String>,
    pub error: Option<String>,
}

pub struct Store {
    db: Connection,
}

impl Store {
    pub fn open(path: &Path, mut key: [u8; 32]) -> Result<Self, String> {
        let db = Connection::open(path).map_err(|error| format!("open bridge state: {error}"))?;
        let mut unlock = format!(
            "PRAGMA key = \"x'{}'\"; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;",
            hex::encode(key)
        );
        key.zeroize();
        let unlock_result = db.execute_batch(&unlock);
        unlock.zeroize();
        unlock_result.map_err(|error| format!("unlock bridge state: {error}"))?;
        let schema_version: i64 = db
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(|error| format!("read bridge schema version: {error}"))?;
        if schema_version > 1 {
            return Err(format!(
                "bridge state schema {schema_version} is newer than supported version 1"
            ));
        }
        db.execute_batch(
            "CREATE TABLE IF NOT EXISTS outbound_journal (
                txn_key TEXT PRIMARY KEY,
                peer_hex TEXT NOT NULL,
                kind TEXT NOT NULL,
                body TEXT NOT NULL DEFAULT '',
                media_path TEXT,
                filename TEXT,
                mime TEXT,
                caption TEXT,
                status TEXT NOT NULL DEFAULT 'pending',
                group_id TEXT,
                message_id TEXT,
                error TEXT,
                created_at INTEGER NOT NULL DEFAULT (unixepoch()),
                updated_at INTEGER NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE IF NOT EXISTS peer_group (
                peer_hex TEXT PRIMARY KEY,
                group_id TEXT NOT NULL,
                updated_at INTEGER NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE IF NOT EXISTS inbound_event (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id TEXT NOT NULL UNIQUE,
                group_id TEXT NOT NULL,
                peer_hex TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                created_at INTEGER NOT NULL DEFAULT (unixepoch())
            );
            PRAGMA user_version=1;",
        )
        .map_err(|error| format!("migrate bridge state: {error}"))?;
        Ok(Self { db })
    }

    pub fn put_text(
        &mut self,
        txn_key: &str,
        peer_hex: &str,
        body: &str,
    ) -> Result<JournalEntry, String> {
        let transaction = self.db.transaction().map_err(|error| error.to_string())?;
        transaction
            .execute(
                "INSERT OR IGNORE INTO outbound_journal (txn_key, peer_hex, kind, body)
                 VALUES (?1, ?2, 'text', ?3)",
                params![txn_key, peer_hex, body],
            )
            .map_err(|error| format!("journal text command: {error}"))?;
        let entry = query_journal(&transaction, txn_key)?
            .ok_or_else(|| "journaled command disappeared".to_string())?;
        if entry.peer_hex != peer_hex || entry.kind != "text" || entry.body != body {
            return Err("transaction key was already used with different content".into());
        }
        transaction.commit().map_err(|error| error.to_string())?;
        Ok(entry)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn put_media(
        &mut self,
        txn_key: &str,
        peer_hex: &str,
        content_hash: &str,
        media_path: &str,
        filename: &str,
        mime: &str,
        caption: &str,
    ) -> Result<JournalEntry, String> {
        let transaction = self.db.transaction().map_err(|error| error.to_string())?;
        transaction
            .execute(
                "INSERT OR IGNORE INTO outbound_journal
                 (txn_key, peer_hex, kind, body, media_path, filename, mime, caption)
                 VALUES (?1, ?2, 'media', ?3, ?4, ?5, ?6, ?7)",
                params![
                    txn_key,
                    peer_hex,
                    content_hash,
                    media_path,
                    filename,
                    mime,
                    caption
                ],
            )
            .map_err(|error| format!("journal media command: {error}"))?;
        let entry = query_journal(&transaction, txn_key)?
            .ok_or_else(|| "journaled command disappeared".to_string())?;
        if entry.peer_hex != peer_hex
            || entry.kind != "media"
            || entry.body != content_hash
            || entry.media_path.as_deref() != Some(media_path)
            || entry.filename.as_deref() != Some(filename)
            || entry.mime.as_deref() != Some(mime)
            || entry.caption.as_deref() != Some(caption)
        {
            return Err("transaction key was already used with different content".into());
        }
        transaction.commit().map_err(|error| error.to_string())?;
        Ok(entry)
    }

    pub fn journal(&self, txn_key: &str) -> Result<Option<JournalEntry>, String> {
        query_journal(&self.db, txn_key)
    }

    pub fn complete(&self, txn_key: &str, group_id: &str, message_id: &str) -> Result<(), String> {
        let changed = self
            .db
            .execute(
                "UPDATE outbound_journal
                 SET status='sent', group_id=?2, message_id=?3, error=NULL, updated_at=unixepoch()
                 WHERE txn_key=?1",
                params![txn_key, group_id, message_id],
            )
            .map_err(|error| format!("complete journal command: {error}"))?;
        if changed != 1 {
            return Err("journal command disappeared before completion".into());
        }
        Ok(())
    }

    /// Claim a pending command before any MLS side effect. A crash leaves it in
    /// `sending`, which is surfaced as indeterminate and never blindly retried.
    pub fn begin_attempt(&self, txn_key: &str) -> Result<bool, String> {
        let changed = self
            .db
            .execute(
                "UPDATE outbound_journal SET status='sending', updated_at=unixepoch()
                 WHERE txn_key=?1 AND status='pending'",
                params![txn_key],
            )
            .map_err(|error| format!("claim journal command: {error}"))?;
        Ok(changed == 1)
    }

    pub fn record_attempt_error(&self, txn_key: &str, error: &str) -> Result<(), String> {
        self.db
            .execute(
                "UPDATE outbound_journal
                 SET error=?2, updated_at=unixepoch() WHERE txn_key=?1 AND status='sending'",
                params![txn_key, error],
            )
            .map_err(|failure| format!("record journal attempt error: {failure}"))?;
        Ok(())
    }

    pub fn set_group(&self, peer_hex: &str, group_id: &str) -> Result<(), String> {
        self.db
            .execute(
                "INSERT INTO peer_group (peer_hex, group_id) VALUES (?1, ?2)
                 ON CONFLICT(peer_hex) DO UPDATE SET group_id=excluded.group_id, updated_at=unixepoch()",
                params![peer_hex, group_id],
            )
            .map_err(|error| format!("persist peer group: {error}"))?;
        Ok(())
    }

    pub fn group_for_peer(&self, peer_hex: &str) -> Result<Option<String>, String> {
        self.db
            .query_row(
                "SELECT group_id FROM peer_group WHERE peer_hex=?1",
                params![peer_hex],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| format!("load peer group: {error}"))
    }

    pub fn append_inbound(&self, peer_hex: &str, message: &MessageDto) -> Result<(), String> {
        if message.mine {
            return Ok(());
        }
        let payload = serde_json::to_string(message).map_err(|error| error.to_string())?;
        self.db
            .execute(
                "INSERT OR IGNORE INTO inbound_event (message_id, group_id, peer_hex, payload_json)
                 VALUES (?1, ?2, ?3, ?4)",
                params![message.id, message.group_id, peer_hex, payload],
            )
            .map_err(|error| format!("append inbound event: {error}"))?;
        Ok(())
    }

    pub fn events_after(&self, after: u64, limit: usize) -> Result<Vec<serde_json::Value>, String> {
        let mut stmt = self
            .db
            .prepare(
                "SELECT seq, peer_hex, payload_json FROM inbound_event
                 WHERE seq>?1 ORDER BY seq LIMIT ?2",
            )
            .map_err(|error| error.to_string())?;
        let rows = stmt
            .query_map(params![after as i64, limit.clamp(1, 100) as i64], |row| {
                let seq: i64 = row.get(0)?;
                let peer: String = row.get(1)?;
                let payload: String = row.get(2)?;
                Ok((seq, peer, payload))
            })
            .map_err(|error| error.to_string())?;
        let mut events = Vec::new();
        for row in rows {
            let (seq, peer, payload) = row.map_err(|error| error.to_string())?;
            let message: serde_json::Value =
                serde_json::from_str(&payload).map_err(|error| error.to_string())?;
            events.push(serde_json::json!({"seq": seq, "peer_hex": peer, "message": message}));
        }
        Ok(events)
    }

    pub fn acknowledge_events(&self, through: u64) -> Result<(), String> {
        self.db
            .execute(
                "DELETE FROM inbound_event WHERE seq<=?1",
                params![through as i64],
            )
            .map_err(|error| format!("acknowledge inbound events: {error}"))?;
        Ok(())
    }

    pub fn purge_inbound_group(&self, group_id: &str) -> Result<(), String> {
        self.db
            .execute(
                "DELETE FROM inbound_event WHERE group_id=?1",
                params![group_id],
            )
            .map_err(|error| format!("purge non-DM events: {error}"))?;
        Ok(())
    }
}

fn query_journal(connection: &Connection, txn_key: &str) -> Result<Option<JournalEntry>, String> {
    connection
        .query_row(
            "SELECT txn_key, peer_hex, kind, body, media_path, filename, mime, caption,
                    status, group_id, message_id, error
             FROM outbound_journal WHERE txn_key=?1",
            params![txn_key],
            map_journal,
        )
        .optional()
        .map_err(|error| error.to_string())
}

fn map_journal(row: &rusqlite::Row<'_>) -> rusqlite::Result<JournalEntry> {
    Ok(JournalEntry {
        txn_key: row.get(0)?,
        peer_hex: row.get(1)?,
        kind: row.get(2)?,
        body: row.get(3)?,
        media_path: row.get(4)?,
        filename: row.get(5)?,
        mime: row.get(6)?,
        caption: row.get(7)?,
        status: row.get(8)?,
        group_id: row.get(9)?,
        message_id: row.get(10)?,
        error: row.get(11)?,
    })
}

fn sanitize_filename(filename: &str) -> String {
    let clean = filename
        .chars()
        .filter(|character| !character.is_control() && !matches!(character, '/' | '\\'))
        .take(255)
        .collect::<String>();
    if clean.trim().is_empty() {
        "attachment".into()
    } else {
        clean
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transaction_key_is_idempotent_and_content_bound() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("state.db"), [3u8; 32]).unwrap();
        store.put_text("m1", "aa", "hello").unwrap();
        store.put_text("m1", "aa", "hello").unwrap();
        assert!(store.put_text("m1", "aa", "different").is_err());
        store.complete("m1", "group", "event").unwrap();
        assert_eq!(
            store.journal("m1").unwrap().unwrap().message_id.as_deref(),
            Some("event")
        );
        store.set_group("aa", "group").unwrap();
        assert_eq!(
            store.group_for_peer("aa").unwrap().as_deref(),
            Some("group")
        );
    }

    #[test]
    fn filename_cannot_escape_temp_directory() {
        assert_eq!(sanitize_filename("../bad\n/name.txt"), "..badname.txt");
        assert_eq!(sanitize_filename("\n\r"), "attachment");
    }

    #[test]
    fn inbound_events_replay_until_acknowledged() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(&dir.path().join("state.db"), [4u8; 32]).unwrap();
        let message = MessageDto {
            id: "event-1".into(),
            group_id: "group".into(),
            sender: "peer".into(),
            content: "hello".into(),
            created_at_secs: 1,
            mine: false,
            media: Vec::new(),
        };
        store.append_inbound("peer", &message).unwrap();
        let first = store.events_after(0, 10).unwrap();
        let sequence = first[0]["seq"].as_u64().unwrap();
        assert_eq!(store.events_after(0, 10).unwrap().len(), 1);
        store.acknowledge_events(sequence).unwrap();
        assert!(store.events_after(0, 10).unwrap().is_empty());
    }

    #[test]
    fn purging_a_proven_non_dm_preserves_other_replay_rows() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(&dir.path().join("state.db"), [5u8; 32]).unwrap();
        for (id, group) in [("event-dm", "dm"), ("event-group", "group")] {
            let message = MessageDto {
                id: id.into(),
                group_id: group.into(),
                sender: "peer".into(),
                content: "hello".into(),
                created_at_secs: 1,
                mine: false,
                media: Vec::new(),
            };
            store.append_inbound("peer", &message).unwrap();
        }

        store.purge_inbound_group("group").unwrap();
        let replay = store.events_after(0, 10).unwrap();
        assert_eq!(replay.len(), 1);
        assert_eq!(replay[0]["message"]["group_id"], "dm");
    }
}
