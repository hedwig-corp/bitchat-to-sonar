//! Decrypt-and-move for MDK 0.8 SQLCipher stores onto the 0.9 transcript sidecar.
//!
//! MDK 0.9 cannot open a 0.8 database in place:
//! - SQLCipher keying changed (`PRAGMA key = "x'<hex>'"` → passphrase `'<hex>'`)
//! - the schema moved from `mdk-sqlite-storage` to `storage-sqlite`
//! - the Marmot wire format moved `0xf2ee` → `0xf2f1`, so MLS group state
//!   cannot be imported
//!
//! What *can* be recovered without the 0.8 engine is the plaintext already
//! stored in the 0.8 `messages` table. This module opens that file with the
//! host's 32-byte key in the 0.8 raw-key form, copies chat rows into the
//! host-owned `.sonar-transcript.json` sidecar, quarantines the 0.8 file
//! (never deletes it), and lets [`crate::marmot::MarmotEngine::persistent`]
//! create a fresh 0.9 store beside the recovered history.
//!
//! Live 0.8 MLS membership is **not** reconstructed here. See
//! `docs/plans/2026-09-13-mdk-09-existing-chat-migration.md`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use nostr::prelude::*;
use rusqlite::Connection;

use crate::marmot::{
    ChatMessage, DeliveryState, MediaRef, MessageClassification, CHAT_RUMOR_KIND,
    TRANSCRIPT_FILE_SUFFIX,
};
use crate::{Error, GroupId, Result};
use sonar_stickers::parse_sticker_ref_tag;

/// Suffix appended to each 0.8 SQLCipher file after a successful extract.
pub(crate) const MDK08_BACKUP_SUFFIX: &str = ".mdk08.bak";

/// Group-name map written next to the transcript sidecar.
pub(crate) const HISTORICAL_GROUPS_FILE_SUFFIX: &str = ".sonar-historical-groups.json";

/// Member pubkeys recovered from 0.8 `admin_pubkeys`, every `messages.pubkey`,
/// and `p` tags. Needed so a chat you only ever sent into can still resume.
pub(crate) const HISTORICAL_MEMBERS_FILE_SUFFIX: &str = ".sonar-historical-members.json";

/// Marker written after a successful extract so operators can see what moved.
pub(crate) const MDK08_MIGRATED_MARKER_SUFFIX: &str = ".sonar-mdk08-migrated.json";

/// Chat rows and group titles recovered from a 0.8 store.
#[derive(Debug, Clone, Default)]
pub(crate) struct Mdk08Migration {
    pub messages: HashMap<GroupId, Vec<ChatMessage>>,
    pub group_names: HashMap<GroupId, String>,
    pub members: HashMap<GroupId, Vec<PublicKey>>,
}

/// Files moved aside so a fresh 0.9 store can occupy the original path.
pub(crate) struct Quarantine {
    moved: Vec<(PathBuf, PathBuf)>,
}

impl Quarantine {
    /// Put the 0.8 files back. Used only when creating the 0.9 store fails.
    pub(crate) fn restore(self) -> Result<()> {
        for (from, to) in self.moved.into_iter().rev() {
            if to.exists() {
                let _ = std::fs::remove_file(&to);
            }
            std::fs::rename(&from, &to).map_err(|e| {
                Error::Storage(format!(
                    "restore 0.8 store {} → {}: {e}",
                    from.display(),
                    to.display()
                ))
            })?;
        }
        Ok(())
    }
}

/// Probe `path` with the 0.8 raw-key encoding. `Ok(None)` means this is not a
/// readable 0.8 `messages` store under `key` (wrong key, 0.9 store, corrupt).
pub(crate) fn detect_and_extract(
    path: &Path,
    key: [u8; 32],
    local_pk: PublicKey,
) -> Result<Option<Mdk08Migration>> {
    let Some(conn) = open_mdk08(path, key)? else {
        return Ok(None);
    };
    if !table_exists(&conn, "messages")? {
        return Ok(None);
    }
    Ok(Some(extract_from_connection(&conn, local_pk)?))
}

/// Write the host sidecars **before** the 0.8 file is renamed.
pub(crate) fn write_sidecars(db_path: &Path, extracted: &Mdk08Migration) -> Result<()> {
    let keyed: HashMap<String, Vec<ChatMessage>> = extracted
        .messages
        .iter()
        .map(|(id, msgs)| (hex::encode(id.as_slice()), msgs.clone()))
        .collect();
    write_json(&sidecar_named(db_path, TRANSCRIPT_FILE_SUFFIX), &keyed)?;

    let names: HashMap<String, String> = extracted
        .group_names
        .iter()
        .map(|(id, name)| (hex::encode(id.as_slice()), name.clone()))
        .collect();
    write_json(
        &sidecar_named(db_path, HISTORICAL_GROUPS_FILE_SUFFIX),
        &names,
    )?;

    let members: HashMap<String, Vec<String>> = extracted
        .members
        .iter()
        .map(|(id, pks)| {
            (
                hex::encode(id.as_slice()),
                pks.iter().map(|pk| pk.to_hex()).collect(),
            )
        })
        .collect();
    write_json(
        &sidecar_named(db_path, HISTORICAL_MEMBERS_FILE_SUFFIX),
        &members,
    )?;

    let marker = serde_json::json!({
        "from": "mdk-0.8",
        "to": "mdk-0.9.14-transcript-sidecar",
        "groups": extracted.messages.len(),
        "messages": extracted.messages.values().map(|m| m.len()).sum::<usize>(),
        "wire": "0xf2ee-plaintext-only",
    });
    write_json(
        &sidecar_named(db_path, MDK08_MIGRATED_MARKER_SUFFIX),
        &marker,
    )?;
    Ok(())
}

/// Rename the 0.8 SQLCipher file (and WAL/SHM/journal) to `*.mdk08.bak`.
pub(crate) fn quarantine_store(path: &Path) -> Result<Quarantine> {
    let mut moved = Vec::new();
    for src in sqlite_file_set(path) {
        if !src.exists() {
            continue;
        }
        let dest = backup_path(&src);
        std::fs::rename(&src, &dest).map_err(|e| {
            Error::Storage(format!(
                "quarantine 0.8 store {} → {}: {e}",
                src.display(),
                dest.display()
            ))
        })?;
        moved.push((dest, src));
    }
    Ok(Quarantine { moved })
}

pub(crate) fn load_historical_group_names(db_path: &Path) -> HashMap<GroupId, String> {
    let path = sidecar_named(db_path, HISTORICAL_GROUPS_FILE_SUFFIX);
    let Ok(bytes) = std::fs::read(path) else {
        return HashMap::new();
    };
    serde_json::from_slice::<HashMap<String, String>>(&bytes)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(hex_id, name)| hex::decode(hex_id).ok().map(|b| (GroupId::new(b), name)))
        .collect()
}

pub(crate) fn load_historical_members(db_path: &Path) -> HashMap<GroupId, Vec<PublicKey>> {
    let path = sidecar_named(db_path, HISTORICAL_MEMBERS_FILE_SUFFIX);
    let Ok(bytes) = std::fs::read(path) else {
        return HashMap::new();
    };
    serde_json::from_slice::<HashMap<String, Vec<String>>>(&bytes)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(hex_id, pks)| {
            let id = hex::decode(hex_id).ok().map(GroupId::new)?;
            let mut members: Vec<PublicKey> =
                pks.iter().filter_map(|s| parse_pubkey_str(s)).collect();
            members.sort_by(|a, b| a.to_hex().cmp(&b.to_hex()));
            members.dedup();
            Some((id, members))
        })
        .collect()
}

pub(crate) fn wipe_mdk08_backups(db_path: &Path) -> Result<()> {
    for src in sqlite_file_set(db_path) {
        let bak = backup_path(&src);
        match std::fs::remove_file(&bak) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return Err(Error::Storage(format!(
                    "wipe 0.8 backup {}: {e}",
                    bak.display()
                )))
            }
        }
    }
    for suffix in [
        HISTORICAL_GROUPS_FILE_SUFFIX,
        HISTORICAL_MEMBERS_FILE_SUFFIX,
        MDK08_MIGRATED_MARKER_SUFFIX,
    ] {
        let path = sidecar_named(db_path, suffix);
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(Error::Storage(format!("wipe {}: {e}", path.display()))),
        }
    }
    Ok(())
}

fn open_mdk08(path: &Path, key: [u8; 32]) -> Result<Option<Connection>> {
    let conn = Connection::open(path)
        .map_err(|e| Error::Storage(format!("mdk08 open {}: {e}", path.display())))?;
    let hex_key = hex::encode(key);
    if conn
        .execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
        .is_err()
    {
        return Ok(None);
    }
    // Wrong key / 0.9 passphrase store fails here with "file is not a database".
    match conn.query_row("SELECT count(*) FROM sqlite_master", [], |row| {
        row.get::<_, i64>(0)
    }) {
        Ok(_) => Ok(Some(conn)),
        Err(_) => Ok(None),
    }
}

fn extract_from_connection(conn: &Connection, local_pk: PublicKey) -> Result<Mdk08Migration> {
    let mut extracted = Mdk08Migration::default();
    if table_exists(conn, "groups")? {
        let has_admins = column_exists(conn, "groups", "admin_pubkeys")?;
        let sql = if has_admins {
            "SELECT mls_group_id, name, admin_pubkeys FROM groups"
        } else {
            "SELECT mls_group_id, name, NULL FROM groups"
        };
        let mut stmt = conn
            .prepare(sql)
            .map_err(|e| Error::Storage(format!("mdk08 groups prepare: {e}")))?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, Vec<u8>>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })
            .map_err(|e| Error::Storage(format!("mdk08 groups query: {e}")))?;
        for row in rows {
            let (id, name, admins) =
                row.map_err(|e| Error::Storage(format!("mdk08 groups row: {e}")))?;
            if id.is_empty() {
                continue;
            }
            let group_id = GroupId::new(id);
            extracted.group_names.insert(group_id.clone(), name);
            if let Some(raw) = admins {
                for pk in parse_admin_pubkeys(&raw) {
                    note_member(&mut extracted, &group_id, pk);
                }
            }
        }
    }

    let has_state = column_exists(conn, "messages", "state")?;
    let has_tags = column_exists(conn, "messages", "tags")?;
    let has_event = column_exists(conn, "messages", "event")?;
    let sql = format!(
        "SELECT mls_group_id, id, pubkey, kind, created_at, content, {}, {}, {} FROM messages",
        if has_state { "state" } else { "NULL" },
        if has_tags { "tags" } else { "NULL" },
        if has_event { "event" } else { "NULL" },
    );
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| Error::Storage(format!("mdk08 messages prepare: {e}")))?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, Vec<u8>>(0)?,
                row.get::<_, Vec<u8>>(1)?,
                row.get::<_, Vec<u8>>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, Option<String>>(8)?,
            ))
        })
        .map_err(|e| Error::Storage(format!("mdk08 messages query: {e}")))?;

    for row in rows {
        let (group_id, id, pubkey, kind, created_at, content, state, tags_raw, event_raw) =
            row.map_err(|e| Error::Storage(format!("mdk08 messages row: {e}")))?;
        let tags = merge_stored_tags(tags_raw.as_deref(), event_raw.as_deref());
        if !group_id.is_empty() {
            let gid = GroupId::new(group_id.clone());
            if let Ok(pk) = PublicKey::from_slice(&pubkey) {
                note_member(&mut extracted, &gid, pk);
            }
            for pk in p_tag_pubkeys(&tags) {
                note_member(&mut extracted, &gid, pk);
            }
        }
        if kind as u16 != CHAT_RUMOR_KIND {
            continue;
        }
        if state.as_deref().is_some_and(is_invalid_message_state) {
            continue;
        }
        let Some(msg) = chat_from_mdk08_row(
            &group_id, &id, &pubkey, created_at, content, local_pk, &tags,
        ) else {
            continue;
        };
        extracted
            .messages
            .entry(msg.group_id.clone())
            .or_default()
            .push(msg);
    }
    Ok(extracted)
}

fn note_member(extracted: &mut Mdk08Migration, group_id: &GroupId, pk: PublicKey) {
    let members = extracted.members.entry(group_id.clone()).or_default();
    if !members.contains(&pk) {
        members.push(pk);
    }
}

fn parse_admin_pubkeys(raw: &str) -> Vec<PublicKey> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(raw) else {
        return Vec::new();
    };
    let Some(items) = value.as_array() else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| {
            if let Some(s) = item.as_str() {
                parse_pubkey_str(s)
            } else {
                None
            }
        })
        .collect()
}

fn parse_pubkey_str(raw: &str) -> Option<PublicKey> {
    let trimmed = raw.trim();
    PublicKey::from_hex(trimmed)
        .ok()
        .or_else(|| PublicKey::parse(trimmed).ok())
}

fn chat_from_mdk08_row(
    group_id: &[u8],
    id: &[u8],
    pubkey: &[u8],
    created_at: i64,
    content: String,
    local_pk: PublicKey,
    tags: &[Tag],
) -> Option<ChatMessage> {
    if group_id.is_empty() {
        return None;
    }
    let event_id = EventId::from_slice(id).ok()?;
    let sender = PublicKey::from_slice(pubkey).ok()?;
    let mine = sender == local_pk;
    let media = media_refs_from_tags(tags);
    let sticker_ref = tags.iter().find_map(|t| parse_sticker_ref_tag(t).ok());
    let (content, reply) = crate::reply::project_application_content(&content, tags.iter());
    Some(ChatMessage {
        id: event_id,
        group_id: GroupId::new(group_id.to_vec()),
        sender,
        classification: MessageClassification::of(&content),
        content,
        created_at: Timestamp::from_secs(created_at.max(0) as u64),
        mine,
        delivery_state: if mine {
            DeliveryState::Sent
        } else {
            DeliveryState::Received
        },
        media,
        sticker_ref,
        reply,
    })
}

fn merge_stored_tags(tags_raw: Option<&str>, event_raw: Option<&str>) -> Vec<Tag> {
    let mut tags = parse_tags_json(tags_raw.unwrap_or(""));
    if tags.is_empty() {
        if let Some(event) = event_raw {
            if let Ok(value) = serde_json::from_str::<serde_json::Value>(event) {
                if let Some(event_tags) = value.get("tags") {
                    tags = parse_tags_value(event_tags);
                }
            }
        }
    }
    tags
}

fn parse_tags_json(raw: &str) -> Vec<Tag> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(raw) else {
        return Vec::new();
    };
    parse_tags_value(&value)
}

fn parse_tags_value(value: &serde_json::Value) -> Vec<Tag> {
    let Some(rows) = value.as_array() else {
        return Vec::new();
    };
    rows.iter()
        .filter_map(|row| {
            let cells = row.as_array()?;
            let strings: Vec<String> = cells
                .iter()
                .filter_map(|cell| cell.as_str().map(str::to_owned))
                .collect();
            if strings.is_empty() {
                return None;
            }
            Tag::parse(strings).ok()
        })
        .collect()
}

fn p_tag_pubkeys(tags: &[Tag]) -> Vec<PublicKey> {
    tags.iter()
        .filter_map(|tag| {
            let slice = tag.as_slice();
            if slice.first().map(|s| s.as_str()) != Some("p") {
                return None;
            }
            slice.get(1).and_then(|s| parse_pubkey_str(s))
        })
        .collect()
}

fn media_refs_from_tags(tags: &[Tag]) -> Vec<MediaRef> {
    tags.iter()
        .filter(|tag| tag.kind() == TagKind::Custom("imeta".into()))
        .filter_map(|tag| {
            if let Ok(parsed) = crate::media_crypto::parse_imeta_tag(tag) {
                return Some(MediaRef::from(&parsed));
            }
            lenient_media_ref(tag)
        })
        .collect()
}

fn lenient_media_ref(tag: &Tag) -> Option<MediaRef> {
    let mut fields = HashMap::new();
    for value in tag.as_slice().iter().skip(1) {
        if let Some((key, rest)) = value.split_once(' ') {
            fields.insert(key.to_owned(), rest.to_owned());
        }
    }
    let url = fields.get("url")?.clone();
    if url.is_empty() {
        return None;
    }
    let dim = fields.get("dim").and_then(|raw| {
        let (w, h) = raw.split_once('x')?;
        Some((w.parse().ok()?, h.parse().ok()?))
    });
    Some(MediaRef {
        url,
        mime_type: fields
            .get("m")
            .cloned()
            .unwrap_or_else(|| "application/octet-stream".into()),
        filename: fields.get("filename").cloned().unwrap_or_default(),
        width: dim.map(|(w, _)| w),
        height: dim.map(|(_, h)| h),
        duration_ms: fields.get("duration").and_then(|raw| {
            raw.parse::<f64>()
                .ok()
                .map(|secs| (secs * 1000.0).round() as u64)
        }),
        original_hash: fields
            .get("x")
            .and_then(|raw| hex::decode(raw).ok())
            .and_then(|b| b.try_into().ok()),
        nonce: fields
            .get("n")
            .and_then(|raw| hex::decode(raw).ok())
            .and_then(|b| b.try_into().ok()),
    })
}

fn is_invalid_message_state(state: &str) -> bool {
    let lowered = state.to_ascii_lowercase();
    lowered.contains("invalid") || lowered == "failed"
}

fn table_exists(conn: &Connection, name: &str) -> Result<bool> {
    let count: i64 = conn
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [name],
            |row| row.get(0),
        )
        .map_err(|e| Error::Storage(format!("mdk08 sqlite_master: {e}")))?;
    Ok(count > 0)
}

fn column_exists(conn: &Connection, table: &str, column: &str) -> Result<bool> {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|e| Error::Storage(format!("mdk08 table_info {table}: {e}")))?;
    let rows = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|e| Error::Storage(format!("mdk08 table_info query: {e}")))?;
    for row in rows {
        let name = row.map_err(|e| Error::Storage(format!("mdk08 table_info row: {e}")))?;
        if name == column {
            return Ok(true);
        }
    }
    Ok(false)
}

fn write_json<T: serde::Serialize>(path: &Path, value: &T) -> Result<()> {
    let bytes = serde_json::to_vec(value)
        .map_err(|e| Error::Storage(format!("mdk08 sidecar encode {}: {e}", path.display())))?;
    let tmp = path.with_file_name(format!(
        "{}.tmp",
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("sidecar")
    ));
    std::fs::write(&tmp, bytes)
        .and_then(|()| std::fs::rename(&tmp, path))
        .map_err(|e| Error::Storage(format!("mdk08 sidecar write {}: {e}", path.display())))
}

fn sidecar_named(base: &Path, suffix: &str) -> PathBuf {
    let name = base
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default();
    base.with_file_name(format!("{name}{suffix}"))
}

fn sqlite_file_set(path: &Path) -> Vec<PathBuf> {
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("marmot.sqlite");
    vec![
        path.to_path_buf(),
        path.with_file_name(format!("{name}-wal")),
        path.with_file_name(format!("{name}-shm")),
        path.with_file_name(format!("{name}-journal")),
    ]
}

fn backup_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("marmot.sqlite");
    path.with_file_name(format!("{name}{MDK08_BACKUP_SUFFIX}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;

    const KEY: [u8; 32] = [0x42; 32];

    fn write_mdk08_fixture(path: &Path, local: &Identity, peer: PublicKey, body: &str) -> EventId {
        let conn = Connection::open(path).unwrap();
        let hex_key = hex::encode(KEY);
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .unwrap();
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                epoch INTEGER,
                PRIMARY KEY (mls_group_id, id)
            );",
        )
        .unwrap();
        let group_id = vec![0x11u8; 16];
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'alice & bob', '')",
            rusqlite::params![group_id.clone(), vec![0x22u8; 32]],
        )
        .unwrap();
        let event_id = EventId::from_slice(&[0xABu8; 32]).unwrap();
        conn.execute(
            "INSERT INTO messages
                (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                 wrapper_event_id, state, epoch)
             VALUES (?1, ?2, ?3, 9, 1_700_000_000, ?4, '[]', '{}', ?2, 'processed', 1)",
            rusqlite::params![
                group_id,
                event_id.as_bytes().to_vec(),
                peer.to_bytes().to_vec(),
                body,
            ],
        )
        .unwrap();
        // Non-chat row must be ignored.
        conn.execute(
            "INSERT INTO messages
                (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                 wrapper_event_id, state, epoch)
             VALUES (?1, ?2, ?3, 445, 1_700_000_001, 'commit', '[]', '{}', ?2, 'processed', 1)",
            rusqlite::params![
                vec![0x11u8; 16],
                vec![0xCDu8; 32],
                local.public_key().to_bytes().to_vec(),
            ],
        )
        .unwrap();
        event_id
    }

    #[test]
    fn extracts_plaintext_chat_and_ignores_non_chat_rows() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let peer = Identity::generate().public_key();
        let event_id = write_mdk08_fixture(&path, &local, peer, "hello from 0.8");

        let extracted = detect_and_extract(&path, KEY, local.public_key())
            .unwrap()
            .expect("0.8 store detected");
        assert_eq!(extracted.messages.len(), 1);
        let msgs = extracted.messages.values().next().unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].id, event_id);
        assert_eq!(msgs[0].content, "hello from 0.8");
        assert_eq!(msgs[0].sender, peer);
        assert!(!msgs[0].mine);
        assert_eq!(
            extracted.group_names.values().next().map(String::as_str),
            Some("alice & bob")
        );
    }

    #[test]
    fn outbound_only_chat_keeps_admin_peer() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let peer = Identity::generate().public_key();
        let conn = Connection::open(&path).unwrap();
        let hex_key = hex::encode(KEY);
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .unwrap();
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL,
                admin_pubkeys TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );",
        )
        .unwrap();
        let group_id = vec![0x33u8; 16];
        let admins = serde_json::json!([local.public_key().to_hex(), peer.to_hex()]).to_string();
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description, admin_pubkeys)
             VALUES (?1, ?2, 'just alice sent', '', ?3)",
            rusqlite::params![group_id.clone(), vec![0x44u8; 32], admins],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO messages
                (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                 wrapper_event_id, state)
             VALUES (?1, ?2, ?3, 9, 1_700_000_000, 'only me', '[]', '{}', ?2, 'processed')",
            rusqlite::params![
                group_id,
                vec![0xABu8; 32],
                local.public_key().to_bytes().to_vec(),
            ],
        )
        .unwrap();

        let extracted = detect_and_extract(&path, KEY, local.public_key())
            .unwrap()
            .expect("0.8 store detected");
        let members = extracted.members.values().next().expect("members");
        assert!(members.contains(&peer), "silent peer must survive extract");
        assert!(members.contains(&local.public_key()));
    }

    #[test]
    fn copies_imeta_and_p_tags_from_stored_message_tags() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let peer = Identity::generate().public_key();
        let conn = Connection::open(&path).unwrap();
        let hex_key = hex::encode(KEY);
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .unwrap();
        conn.execute_batch(
            "CREATE TABLE groups (
                mls_group_id BLOB PRIMARY KEY,
                nostr_group_id BLOB NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL
            );
            CREATE TABLE messages (
                mls_group_id BLOB NOT NULL,
                id BLOB NOT NULL,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL,
                PRIMARY KEY (mls_group_id, id)
            );",
        )
        .unwrap();
        let group_id = vec![0x77u8; 16];
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'photo chat', '')",
            rusqlite::params![group_id.clone(), vec![0x88u8; 32]],
        )
        .unwrap();
        let tags = serde_json::json!([
            ["p", peer.to_hex()],
            [
                "imeta",
                "url https://blossom.example/abc",
                "m image/jpeg",
                "filename sunset.jpg",
                "dim 800x600"
            ]
        ])
        .to_string();
        conn.execute(
            "INSERT INTO messages
                (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                 wrapper_event_id, state)
             VALUES (?1, ?2, ?3, 9, 1_700_000_000, '', ?4, '{}', ?2, 'processed')",
            rusqlite::params![
                group_id,
                vec![0xABu8; 32],
                local.public_key().to_bytes().to_vec(),
                tags,
            ],
        )
        .unwrap();

        let extracted = detect_and_extract(&path, KEY, local.public_key())
            .unwrap()
            .expect("0.8 store detected");
        let members = extracted.members.values().next().expect("members");
        assert!(
            members.contains(&peer),
            "p-tag peer must be a resume target"
        );
        let msg = &extracted.messages.values().next().unwrap()[0];
        assert_eq!(msg.media.len(), 1);
        assert_eq!(msg.media[0].url, "https://blossom.example/abc");
        assert_eq!(msg.media[0].filename, "sunset.jpg");
        assert_eq!(msg.media[0].width, Some(800));
        assert_eq!(msg.media[0].nonce, None);
    }

    #[test]
    fn wrong_key_is_not_a_0_8_store() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let peer = Identity::generate().public_key();
        write_mdk08_fixture(&path, &local, peer, "secret");
        assert!(detect_and_extract(&path, [0x13; 32], local.public_key())
            .unwrap()
            .is_none());
        assert!(path.exists(), "failed probe must not delete the 0.8 file");
    }
}
