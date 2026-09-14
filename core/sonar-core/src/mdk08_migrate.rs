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

use std::collections::{HashMap, HashSet};
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
/// hex group id → original 0.8 member_count (pending + processed welcomes).
pub(crate) const HISTORICAL_MEMBER_COUNTS_SUFFIX: &str = ".sonar-historical-member-counts.json";
/// hex group id → 0.8 `groups.description` / welcome `group_description`.
pub(crate) const HISTORICAL_DESCRIPTIONS_SUFFIX: &str = ".sonar-historical-descriptions.json";
/// Marker value written after descriptions + all-welcome counts are copied.
const METADATA_BACKFILL_VERSION: &str = "v2";

/// Marker written after a successful extract so operators can see what moved.
pub(crate) const MDK08_MIGRATED_MARKER_SUFFIX: &str = ".sonar-mdk08-migrated.json";

/// 0.8 `group_exporter_secrets` rows with label `encrypted-media`.
/// Used to decrypt recovered MIP-04 blobs without importing MLS state.
pub(crate) const HISTORICAL_EXPORTER_SECRETS_SUFFIX: &str =
    ".sonar-historical-exporter-secrets.json";

/// Newest chat rows copied onto the sidecar before `connectLocal` returns.
/// Older rows stay in `*.mdk08.bak` until [`detect_and_extract_remainder`].
pub(crate) const FIRST_PAINT_MESSAGES_PER_GROUP: usize = 80;

/// Chat rows copied from `*.mdk08.bak` on one idle / `messages()` tick.
/// Ids are ranked without payloads; only this many blobs are joined.
pub(crate) const REMAINDER_MESSAGES_PER_TICK: usize = 400;

/// Chat rows and group titles recovered from a 0.8 store.
#[derive(Debug, Clone, Default)]
pub(crate) struct Mdk08Migration {
    pub messages: HashMap<GroupId, Vec<ChatMessage>>,
    pub group_names: HashMap<GroupId, String>,
    /// 0.8 `groups.description` / welcome `group_description`.
    pub group_descriptions: HashMap<GroupId, String>,
    pub members: HashMap<GroupId, Vec<PublicKey>>,
    /// Original 0.8 `welcomes.member_count` (any state). A 3+ room must not
    /// resume as a DM just because only the welcomer is known after extract.
    pub member_counts: HashMap<GroupId, u32>,
    /// MIP-04 exporter secrets copied from `group_exporter_secrets`.
    pub media_exporter_secrets: HashMap<GroupId, Vec<Vec<u8>>>,
    /// True when at least one group has more kind-9 rows than the first-paint
    /// window. The rest must be copied from `*.mdk08.bak`.
    pub truncated: bool,
}

/// Enough to reopen the quarantined 0.8 file and copy the remaining rows.
#[derive(Debug, Clone)]
pub(crate) struct PendingMdk08Remainder {
    pub bak_path: PathBuf,
    pub key: [u8; 32],
    pub local_pk: PublicKey,
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
/// Production uses first-paint + remainder pages; this full extract is for tests.
#[cfg(test)]
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
    Ok(Some(extract_from_connection(&conn, local_pk, None)?))
}

/// Same probe, but only the newest [`FIRST_PAINT_MESSAGES_PER_GROUP`] chat
/// rows per group. Group titles and resume members are still complete.
pub(crate) fn detect_and_extract_first_paint(
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
    Ok(Some(extract_from_connection(
        &conn,
        local_pk,
        Some(FIRST_PAINT_MESSAGES_PER_GROUP),
    )?))
}

/// Next bounded page of leftover kind-9 rows. `skip` is event ids already
/// on the transcript (the first-paint window plus earlier remainder ticks).
/// `more` is true when another tick is still needed.
pub(crate) fn detect_and_extract_remainder(
    path: &Path,
    key: [u8; 32],
    local_pk: PublicKey,
    skip: &HashSet<EventId>,
    budget: usize,
    only_group: Option<&GroupId>,
    omit_groups: &HashSet<GroupId>,
) -> Result<Option<(Mdk08Migration, bool)>> {
    let Some(conn) = open_mdk08(path, key)? else {
        return Ok(None);
    };
    if !table_exists(&conn, "messages")? {
        return Ok(None);
    }
    let budget = budget.max(1);
    let (extracted, more) =
        extract_remainder_page(&conn, local_pk, skip, budget, only_group, omit_groups)?;
    Ok(Some((extracted, more)))
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
    write_group_descriptions(db_path, &extracted.group_descriptions)?;

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
    write_member_counts(db_path, &extracted.member_counts)?;

    if !extracted.media_exporter_secrets.is_empty() {
        let secrets: HashMap<String, Vec<String>> = extracted
            .media_exporter_secrets
            .iter()
            .map(|(id, values)| {
                (
                    hex::encode(id.as_slice()),
                    values.iter().map(hex::encode).collect(),
                )
            })
            .collect();
        write_json(
            &sidecar_named(db_path, HISTORICAL_EXPORTER_SECRETS_SUFFIX),
            &secrets,
        )?;
    }

    let marker = serde_json::json!({
        "from": "mdk-0.8",
        "to": "mdk-0.9.14-transcript-sidecar",
        "status": if extracted.truncated { "partial" } else { "complete" },
        "first_paint_per_group": FIRST_PAINT_MESSAGES_PER_GROUP,
        "groups": extracted.messages.len(),
        "messages": extracted.messages.values().map(|m| m.len()).sum::<usize>(),
        "wire": "0xf2ee-plaintext-only",
        "metadata_backfill": METADATA_BACKFILL_VERSION,
    });
    write_json(
        &sidecar_named(db_path, MDK08_MIGRATED_MARKER_SUFFIX),
        &marker,
    )?;
    Ok(())
}

/// One-shot: copy pending welcomes, processed-welcome counts, group
/// descriptions, and labeled media secrets from `*.mdk08.bak` onto the host
/// sidecars. Used when an earlier 0.9 open already quarantined the 0.8 file
/// before those columns were extracted. Does not join chat payloads —
/// remainder still owns leftover history. `metadata_backfill=v2` also
/// re-runs for installs that only have the older `complete` marker.
pub(crate) fn backfill_metadata_from_bak(db_path: &Path, key: [u8; 32]) -> Result<bool> {
    if !metadata_backfill_pending(db_path) {
        return Ok(false);
    }
    let Some(conn) = open_mdk08(&backup_path(db_path), key)? else {
        return Ok(false);
    };
    let mut extracted = Mdk08Migration::default();
    extract_metadata(&conn, &mut extracted)?;
    merge_historical_sidecars(db_path, &extracted)?;
    mark_metadata_backfill_complete(db_path)?;
    Ok(true)
}

fn metadata_backfill_pending(db_path: &Path) -> bool {
    if !backup_path(db_path).exists() {
        return false;
    }
    metadata_backfill_status(db_path).as_deref() != Some(METADATA_BACKFILL_VERSION)
}

fn metadata_backfill_status(db_path: &Path) -> Option<String> {
    let bytes = std::fs::read(sidecar_named(db_path, MDK08_MIGRATED_MARKER_SUFFIX)).ok()?;
    serde_json::from_slice::<serde_json::Value>(&bytes)
        .ok()?
        .get("metadata_backfill")?
        .as_str()
        .map(str::to_owned)
}

fn mark_metadata_backfill_complete(db_path: &Path) -> Result<()> {
    let path = sidecar_named(db_path, MDK08_MIGRATED_MARKER_SUFFIX);
    let mut marker = if let Ok(bytes) = std::fs::read(&path) {
        serde_json::from_slice::<serde_json::Value>(&bytes)
            .unwrap_or_else(|_| serde_json::json!({}))
    } else {
        serde_json::json!({})
    };
    if let Some(obj) = marker.as_object_mut() {
        obj.insert(
            "metadata_backfill".into(),
            serde_json::Value::String(METADATA_BACKFILL_VERSION.into()),
        );
    }
    write_json(&path, &marker)
}

fn merge_historical_sidecars(db_path: &Path, extracted: &Mdk08Migration) -> Result<()> {
    let mut names = load_historical_group_names(db_path);
    for (id, name) in &extracted.group_names {
        let entry = names.entry(id.clone()).or_default();
        if entry.is_empty() && !name.is_empty() {
            *entry = name.clone();
        }
    }
    let mut members = load_historical_members(db_path);
    for (id, pks) in &extracted.members {
        let entry = members.entry(id.clone()).or_default();
        for pk in pks {
            if !entry.contains(pk) {
                entry.push(*pk);
            }
        }
        entry.sort_by(|a, b| a.to_hex().cmp(&b.to_hex()));
        entry.dedup();
    }
    let mut secrets = load_historical_media_secrets(db_path);
    for (id, values) in &extracted.media_exporter_secrets {
        let entry = secrets.entry(id.clone()).or_default();
        for secret in values {
            if !entry.iter().any(|existing| existing == secret) {
                entry.push(secret.clone());
            }
        }
    }
    if !names.is_empty() {
        let keyed: HashMap<String, String> = names
            .iter()
            .map(|(id, name)| (hex::encode(id.as_slice()), name.clone()))
            .collect();
        write_json(
            &sidecar_named(db_path, HISTORICAL_GROUPS_FILE_SUFFIX),
            &keyed,
        )?;
    }
    let mut descriptions = load_historical_group_descriptions(db_path);
    for (id, desc) in &extracted.group_descriptions {
        let entry = descriptions.entry(id.clone()).or_default();
        if entry.is_empty() && !desc.is_empty() {
            *entry = desc.clone();
        }
    }
    write_group_descriptions(db_path, &descriptions)?;
    if !members.is_empty() {
        let keyed: HashMap<String, Vec<String>> = members
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
            &keyed,
        )?;
    }
    let mut counts = load_historical_member_counts(db_path);
    for (id, count) in &extracted.member_counts {
        let entry = counts.entry(id.clone()).or_insert(0);
        *entry = (*entry).max(*count);
    }
    write_member_counts(db_path, &counts)?;
    if !secrets.is_empty() {
        let keyed: HashMap<String, Vec<String>> = secrets
            .iter()
            .map(|(id, values)| {
                (
                    hex::encode(id.as_slice()),
                    values.iter().map(hex::encode).collect(),
                )
            })
            .collect();
        write_json(
            &sidecar_named(db_path, HISTORICAL_EXPORTER_SECRETS_SUFFIX),
            &keyed,
        )?;
    }
    Ok(())
}

pub(crate) fn mark_remainder_complete(db_path: &Path) -> Result<()> {
    let path = sidecar_named(db_path, MDK08_MIGRATED_MARKER_SUFFIX);
    let mut marker = if let Ok(bytes) = std::fs::read(&path) {
        serde_json::from_slice::<serde_json::Value>(&bytes)
            .unwrap_or_else(|_| serde_json::json!({}))
    } else {
        serde_json::json!({})
    };
    if let Some(obj) = marker.as_object_mut() {
        obj.insert(
            "status".into(),
            serde_json::Value::String("complete".into()),
        );
    }
    write_json(&path, &marker)
}

/// True while leftover 0.8 rows still live only in `*.mdk08.bak`.
///
/// Remainder ticks use this. Account backup uses
/// [`bak_needed_for_backup`] so a completed remainder can still pack the
/// bak until pending welcomes / labeled media secrets have been copied.
pub(crate) fn leftover_bak_needed(db_path: &Path) -> bool {
    if !backup_path(db_path).exists() {
        return false;
    }
    let marker_path = sidecar_named(db_path, MDK08_MIGRATED_MARKER_SUFFIX);
    let status = std::fs::read(&marker_path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .and_then(|value| {
            value
                .get("status")
                .and_then(|s| s.as_str())
                .map(str::to_owned)
        });
    let transcript_exists = sidecar_named(db_path, TRANSCRIPT_FILE_SUFFIX).exists();
    match status.as_deref() {
        // Complete (or a pre-window full extract) only if the transcript is
        // actually on disk. A missing sidecar means the bak is the last copy.
        Some("complete") | None if transcript_exists => false,
        _ => true,
    }
}

/// Pack `*.mdk08.bak` in an account backup while remainder is pending **or**
/// metadata backfill has not landed. An early 0.9 open may have finished
/// leftover rows before welcomes/secrets were extracted; omitting the bak
/// then drops those on nsec restore.
pub(crate) fn bak_needed_for_backup(db_path: &Path) -> bool {
    leftover_bak_needed(db_path) || metadata_backfill_pending(db_path)
}

/// Recovered 0.8 group id hex + title from a quarantined store.
/// Preview subtracts `dropped` ids so a leave/delete is not listed again.
pub(crate) fn preview_groups_from_bak(bak_path: &Path, key: [u8; 32]) -> Vec<(String, String)> {
    let Some(conn) = open_mdk08(bak_path, key).ok().flatten() else {
        return Vec::new();
    };
    let mut extracted = Mdk08Migration::default();
    if extract_metadata(&conn, &mut extracted).is_err() {
        return Vec::new();
    }
    let mut rows: Vec<(String, String)> = extracted
        .group_names
        .into_iter()
        .filter(|(_, name)| !name.is_empty())
        .map(|(id, name)| (hex::encode(id.as_slice()), name))
        .collect();
    rows.sort_by(|a, b| a.0.cmp(&b.0));
    rows.dedup_by(|a, b| a.0 == b.0);
    rows
}

/// Forget recovered metadata for groups the user already deleted / left.
/// The 0.8 bak is left intact; Settings preview subtracts these ids instead.
pub(crate) fn forget_historical_metadata(db_path: &Path, ids: &[GroupId]) {
    if ids.is_empty() {
        return;
    }
    let drop: HashSet<GroupId> = ids.iter().cloned().collect();
    forget_named_map(
        db_path,
        HISTORICAL_GROUPS_FILE_SUFFIX,
        load_historical_group_names(db_path),
        &drop,
    );
    forget_named_map(
        db_path,
        HISTORICAL_DESCRIPTIONS_SUFFIX,
        load_historical_group_descriptions(db_path),
        &drop,
    );
    forget_members_map(db_path, &drop);
    forget_counts_map(db_path, &drop);
    forget_secrets_map(db_path, &drop);
}

fn forget_named_map(
    db_path: &Path,
    suffix: &str,
    mut map: HashMap<GroupId, String>,
    drop: &HashSet<GroupId>,
) {
    let before = map.len();
    map.retain(|id, _| !drop.contains(id));
    if map.len() == before {
        return;
    }
    rewrite_string_map(db_path, suffix, &map);
}

fn forget_members_map(db_path: &Path, drop: &HashSet<GroupId>) {
    let mut members = load_historical_members(db_path);
    let before = members.len();
    members.retain(|id, _| !drop.contains(id));
    if members.len() == before {
        return;
    }
    if members.is_empty() {
        let _ = std::fs::remove_file(sidecar_named(db_path, HISTORICAL_MEMBERS_FILE_SUFFIX));
        return;
    }
    let keyed: HashMap<String, Vec<String>> = members
        .iter()
        .map(|(id, pks)| {
            (
                hex::encode(id.as_slice()),
                pks.iter().map(|pk| pk.to_hex()).collect(),
            )
        })
        .collect();
    let _ = write_json(
        &sidecar_named(db_path, HISTORICAL_MEMBERS_FILE_SUFFIX),
        &keyed,
    );
}

fn forget_counts_map(db_path: &Path, drop: &HashSet<GroupId>) {
    let mut counts = load_historical_member_counts(db_path);
    let before = counts.len();
    counts.retain(|id, _| !drop.contains(id));
    if counts.len() == before {
        return;
    }
    if counts.is_empty() {
        let _ = std::fs::remove_file(sidecar_named(db_path, HISTORICAL_MEMBER_COUNTS_SUFFIX));
        return;
    }
    let _ = write_member_counts(db_path, &counts);
}

fn forget_secrets_map(db_path: &Path, drop: &HashSet<GroupId>) {
    let mut secrets = load_historical_media_secrets(db_path);
    let before = secrets.len();
    secrets.retain(|id, _| !drop.contains(id));
    if secrets.len() == before {
        return;
    }
    if secrets.is_empty() {
        let _ = std::fs::remove_file(sidecar_named(db_path, HISTORICAL_EXPORTER_SECRETS_SUFFIX));
        return;
    }
    let keyed: HashMap<String, Vec<String>> = secrets
        .iter()
        .map(|(id, values)| {
            (
                hex::encode(id.as_slice()),
                values.iter().map(hex::encode).collect(),
            )
        })
        .collect();
    let _ = write_json(
        &sidecar_named(db_path, HISTORICAL_EXPORTER_SECRETS_SUFFIX),
        &keyed,
    );
}

fn rewrite_string_map(db_path: &Path, suffix: &str, map: &HashMap<GroupId, String>) {
    if map.is_empty() {
        let _ = std::fs::remove_file(sidecar_named(db_path, suffix));
        return;
    }
    let keyed: HashMap<String, String> = map
        .iter()
        .filter(|(_, value)| !value.is_empty())
        .map(|(id, value)| (hex::encode(id.as_slice()), value.clone()))
        .collect();
    if keyed.is_empty() {
        let _ = std::fs::remove_file(sidecar_named(db_path, suffix));
        return;
    }
    let _ = write_json(&sidecar_named(db_path, suffix), &keyed);
}

/// Resume leftover 0.8 rows from the quarantined file after first paint.
pub(crate) fn pending_remainder(
    db_path: &Path,
    key: [u8; 32],
    local_pk: PublicKey,
) -> Option<PendingMdk08Remainder> {
    leftover_bak_needed(db_path).then(|| PendingMdk08Remainder {
        bak_path: backup_path(db_path),
        key,
        local_pk,
    })
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

pub(crate) fn load_historical_group_descriptions(db_path: &Path) -> HashMap<GroupId, String> {
    let path = sidecar_named(db_path, HISTORICAL_DESCRIPTIONS_SUFFIX);
    let Ok(bytes) = std::fs::read(path) else {
        return HashMap::new();
    };
    serde_json::from_slice::<HashMap<String, String>>(&bytes)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(hex_id, desc)| hex::decode(hex_id).ok().map(|b| (GroupId::new(b), desc)))
        .collect()
}

fn write_group_descriptions(db_path: &Path, descriptions: &HashMap<GroupId, String>) -> Result<()> {
    let keyed: HashMap<String, String> = descriptions
        .iter()
        .filter(|(_, desc)| !desc.is_empty())
        .map(|(id, desc)| (hex::encode(id.as_slice()), desc.clone()))
        .collect();
    if keyed.is_empty() {
        return Ok(());
    }
    write_json(
        &sidecar_named(db_path, HISTORICAL_DESCRIPTIONS_SUFFIX),
        &keyed,
    )
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

pub(crate) fn load_historical_member_counts(db_path: &Path) -> HashMap<GroupId, u32> {
    let path = sidecar_named(db_path, HISTORICAL_MEMBER_COUNTS_SUFFIX);
    let Ok(bytes) = std::fs::read(path) else {
        return HashMap::new();
    };
    serde_json::from_slice::<HashMap<String, u32>>(&bytes)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(hex_id, count)| {
            hex::decode(hex_id)
                .ok()
                .filter(|_| count > 0)
                .map(|b| (GroupId::new(b), count))
        })
        .collect()
}

fn write_member_counts(db_path: &Path, counts: &HashMap<GroupId, u32>) -> Result<()> {
    if counts.is_empty() {
        return Ok(());
    }
    let keyed: HashMap<String, u32> = counts
        .iter()
        .filter(|(_, count)| **count > 0)
        .map(|(id, count)| (hex::encode(id.as_slice()), *count))
        .collect();
    if keyed.is_empty() {
        return Ok(());
    }
    write_json(
        &sidecar_named(db_path, HISTORICAL_MEMBER_COUNTS_SUFFIX),
        &keyed,
    )
}

pub(crate) fn load_historical_media_secrets(db_path: &Path) -> HashMap<GroupId, Vec<Vec<u8>>> {
    let path = sidecar_named(db_path, HISTORICAL_EXPORTER_SECRETS_SUFFIX);
    let Ok(bytes) = std::fs::read(path) else {
        return HashMap::new();
    };
    serde_json::from_slice::<HashMap<String, Vec<String>>>(&bytes)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(hex_id, secrets)| {
            let id = hex::decode(hex_id).ok().map(GroupId::new)?;
            let values: Vec<Vec<u8>> = secrets
                .into_iter()
                .filter_map(|hex_secret| hex::decode(hex_secret).ok())
                .filter(|secret| secret.len() >= 32)
                .collect();
            if values.is_empty() {
                None
            } else {
                Some((id, values))
            }
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
        HISTORICAL_DESCRIPTIONS_SUFFIX,
        HISTORICAL_MEMBERS_FILE_SUFFIX,
        HISTORICAL_MEMBER_COUNTS_SUFFIX,
        HISTORICAL_EXPORTER_SECRETS_SUFFIX,
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

fn extract_from_connection(
    conn: &Connection,
    local_pk: PublicKey,
    per_group_limit: Option<usize>,
) -> Result<Mdk08Migration> {
    let mut extracted = Mdk08Migration::default();
    extract_metadata(conn, &mut extracted)?;
    extract_chat_rows(conn, local_pk, per_group_limit, &mut extracted)?;
    Ok(extracted)
}

fn extract_metadata(conn: &Connection, extracted: &mut Mdk08Migration) -> Result<()> {
    if table_exists(conn, "groups")? {
        let has_admins = column_exists(conn, "groups", "admin_pubkeys")?;
        let has_desc = column_exists(conn, "groups", "description")?;
        let sql = match (has_desc, has_admins) {
            (true, true) => "SELECT mls_group_id, name, description, admin_pubkeys FROM groups",
            (true, false) => "SELECT mls_group_id, name, description, NULL FROM groups",
            (false, true) => "SELECT mls_group_id, name, NULL, admin_pubkeys FROM groups",
            (false, false) => "SELECT mls_group_id, name, NULL, NULL FROM groups",
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
                    row.get::<_, Option<String>>(3)?,
                ))
            })
            .map_err(|e| Error::Storage(format!("mdk08 groups query: {e}")))?;
        for row in rows {
            let (id, name, description, admins) =
                row.map_err(|e| Error::Storage(format!("mdk08 groups row: {e}")))?;
            if id.is_empty() {
                continue;
            }
            let group_id = GroupId::new(id);
            extracted.group_names.insert(group_id.clone(), name);
            if let Some(desc) = description {
                if !desc.is_empty() {
                    extracted
                        .group_descriptions
                        .entry(group_id.clone())
                        .or_insert(desc);
                }
            }
            if let Some(raw) = admins {
                for pk in parse_admin_pubkeys(&raw) {
                    note_member(extracted, &group_id, pk);
                }
            }
        }
    }

    extract_pending_welcomes(conn, extracted)?;
    extract_media_exporter_secrets(conn, extracted)?;
    extract_message_members(conn, extracted)
}

fn extract_pending_welcomes(conn: &Connection, extracted: &mut Mdk08Migration) -> Result<()> {
    if !table_exists(conn, "welcomes")? {
        return Ok(());
    }
    if !column_exists(conn, "welcomes", "state")? {
        return Ok(());
    }
    let has_count = column_exists(conn, "welcomes", "member_count")?;
    let has_desc = column_exists(conn, "welcomes", "group_description")?;
    let sql = match (has_desc, has_count) {
        (true, true) => {
            "SELECT mls_group_id, group_name, group_description, group_admin_pubkeys, welcomer, member_count
             FROM welcomes WHERE state = 'pending'"
        }
        (true, false) => {
            "SELECT mls_group_id, group_name, group_description, group_admin_pubkeys, welcomer, NULL
             FROM welcomes WHERE state = 'pending'"
        }
        (false, true) => {
            "SELECT mls_group_id, group_name, NULL, group_admin_pubkeys, welcomer, member_count
             FROM welcomes WHERE state = 'pending'"
        }
        (false, false) => {
            "SELECT mls_group_id, group_name, NULL, group_admin_pubkeys, welcomer, NULL
             FROM welcomes WHERE state = 'pending'"
        }
    };
    let mut stmt = conn
        .prepare(sql)
        .map_err(|e| Error::Storage(format!("mdk08 welcomes prepare: {e}")))?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, Vec<u8>>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Vec<u8>>(4)?,
                row.get::<_, Option<i64>>(5)?,
            ))
        })
        .map_err(|e| Error::Storage(format!("mdk08 welcomes query: {e}")))?;
    for row in rows {
        let (id, name, description, admins, welcomer, member_count) =
            row.map_err(|e| Error::Storage(format!("mdk08 welcomes row: {e}")))?;
        if id.is_empty() {
            continue;
        }
        let group_id = GroupId::new(id);
        extracted
            .group_names
            .entry(group_id.clone())
            .or_insert(name);
        if let Some(desc) = description {
            if !desc.is_empty() {
                extracted
                    .group_descriptions
                    .entry(group_id.clone())
                    .or_insert(desc);
            }
        }
        if let Some(raw) = admins {
            for pk in parse_admin_pubkeys(&raw) {
                note_member(extracted, &group_id, pk);
            }
        }
        if let Ok(pk) = PublicKey::from_slice(&welcomer) {
            note_member(extracted, &group_id, pk);
        }
        if let Some(count) = member_count {
            if count > 0 {
                note_member_count(extracted, &group_id, count as u32);
            }
        }
    }
    extract_welcome_member_counts(conn, extracted)
}

/// Processed / accepted welcomes still carry the original room size. A joined
/// 3-person room must keep that count even when only one peer ever sent.
fn extract_welcome_member_counts(conn: &Connection, extracted: &mut Mdk08Migration) -> Result<()> {
    if !column_exists(conn, "welcomes", "member_count")? {
        return Ok(());
    }
    let mut stmt = conn
        .prepare("SELECT mls_group_id, member_count FROM welcomes")
        .map_err(|e| Error::Storage(format!("mdk08 welcome counts prepare: {e}")))?;
    let rows = stmt
        .query_map([], |row| {
            Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, i64>(1)?))
        })
        .map_err(|e| Error::Storage(format!("mdk08 welcome counts query: {e}")))?;
    for row in rows {
        let (id, count) =
            row.map_err(|e| Error::Storage(format!("mdk08 welcome counts row: {e}")))?;
        if id.is_empty() || count <= 0 {
            continue;
        }
        note_member_count(extracted, &GroupId::new(id), count as u32);
    }
    Ok(())
}

fn extract_media_exporter_secrets(conn: &Connection, extracted: &mut Mdk08Migration) -> Result<()> {
    if !table_exists(conn, "group_exporter_secrets")? {
        return Ok(());
    }
    // Pre-V005 rows are MIP-03 `group-event` secrets, not media keys.
    if !column_exists(conn, "group_exporter_secrets", "label")? {
        return Ok(());
    }
    let mut stmt = conn
        .prepare(
            "SELECT mls_group_id, secret FROM group_exporter_secrets
             WHERE label = 'encrypted-media'",
        )
        .map_err(|e| Error::Storage(format!("mdk08 exporter prepare: {e}")))?;
    let rows = stmt
        .query_map([], |row| {
            Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, Vec<u8>>(1)?))
        })
        .map_err(|e| Error::Storage(format!("mdk08 exporter query: {e}")))?;
    for row in rows {
        let (id, secret) = row.map_err(|e| Error::Storage(format!("mdk08 exporter row: {e}")))?;
        if id.is_empty() || secret.len() < 32 {
            continue;
        }
        let group_id = GroupId::new(id);
        let secrets = extracted
            .media_exporter_secrets
            .entry(group_id)
            .or_default();
        if !secrets.iter().any(|existing| existing == &secret) {
            secrets.push(secret);
        }
    }
    Ok(())
}

struct MessageSelectColumns {
    has_state: bool,
    state: &'static str,
    tags: &'static str,
    event: &'static str,
}

fn message_select_columns(conn: &Connection) -> Result<MessageSelectColumns> {
    let has_state = column_exists(conn, "messages", "state")?;
    Ok(MessageSelectColumns {
        has_state,
        state: if has_state { "m.state" } else { "NULL" },
        tags: if column_exists(conn, "messages", "tags")? {
            "m.tags"
        } else {
            "NULL"
        },
        event: if column_exists(conn, "messages", "event")? {
            "m.event"
        } else {
            "NULL"
        },
    })
}

fn kind9_filter(has_state: bool) -> &'static str {
    if has_state {
        "kind = 9 AND (state IS NULL OR (state != 'invalid' AND state != 'failed'))"
    } else {
        "kind = 9"
    }
}

fn kind9_exceeds_limit(conn: &Connection, limit: usize) -> Result<bool> {
    let has_state = column_exists(conn, "messages", "state")?;
    let sql = format!(
        "SELECT 1 FROM messages WHERE {} \
         GROUP BY mls_group_id HAVING COUNT(*) > ?1 LIMIT 1",
        kind9_filter(has_state)
    );
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| Error::Storage(format!("mdk08 count prepare: {e}")))?;
    let mut rows = stmt
        .query(rusqlite::params![limit as i64])
        .map_err(|e| Error::Storage(format!("mdk08 count query: {e}")))?;
    Ok(rows
        .next()
        .map_err(|e| Error::Storage(format!("mdk08 count row: {e}")))?
        .is_some())
}

/// Rank on `mls_group_id` / `id` / `created_at` only, then join payloads.
/// The ranking subquery must not project `content`, `tags`, or `event`.
fn first_paint_window_sql(cols: &MessageSelectColumns) -> String {
    format!(
        "SELECT m.mls_group_id, m.id, m.pubkey, m.kind, m.created_at, m.content, \
                {}, {}, {} \
         FROM messages m \
         INNER JOIN ( \
            SELECT mls_group_id, id \
            FROM ( \
                SELECT mls_group_id, id, \
                       ROW_NUMBER() OVER ( \
                           PARTITION BY mls_group_id \
                           ORDER BY created_at DESC, id DESC \
                       ) AS rn \
                FROM messages \
                WHERE {} \
            ) \
            WHERE rn <= ?1 \
         ) w ON m.mls_group_id = w.mls_group_id AND m.id = w.id",
        cols.state,
        cols.tags,
        cols.event,
        kind9_filter(cols.has_state),
    )
}

fn first_paint_per_group_sql(cols: &MessageSelectColumns) -> String {
    format!(
        "SELECT m.mls_group_id, m.id, m.pubkey, m.kind, m.created_at, m.content, \
                {}, {}, {} \
         FROM messages m \
         INNER JOIN ( \
            SELECT id \
            FROM messages \
            WHERE mls_group_id = ?1 AND {} \
            ORDER BY created_at DESC, id DESC \
            LIMIT ?2 \
         ) w ON m.mls_group_id = ?1 AND m.id = w.id",
        cols.state,
        cols.tags,
        cols.event,
        kind9_filter(cols.has_state),
    )
}

fn extract_chat_rows(
    conn: &Connection,
    local_pk: PublicKey,
    per_group_limit: Option<usize>,
    extracted: &mut Mdk08Migration,
) -> Result<()> {
    let cols = message_select_columns(conn)?;
    if let Some(limit) = per_group_limit {
        extracted.truncated = kind9_exceeds_limit(conn, limit)?;
        match conn.prepare(&first_paint_window_sql(&cols)) {
            Ok(mut stmt) => {
                ingest_message_rows(
                    &mut stmt,
                    rusqlite::params![limit as i64],
                    local_pk,
                    extracted,
                )?;
                return Ok(());
            }
            Err(err) => {
                tracing::warn!(
                    error = %err,
                    "0.8 first-paint window query unsupported; using per-group LIMIT"
                );
                extract_newest_kind9_per_group(conn, local_pk, limit, &cols, extracted)?;
                return Ok(());
            }
        }
    }

    let sql = format!(
        "SELECT m.mls_group_id, m.id, m.pubkey, m.kind, m.created_at, m.content, \
                {}, {}, {} \
         FROM messages m \
         WHERE {}",
        cols.state,
        cols.tags,
        cols.event,
        kind9_filter(cols.has_state),
    );
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| Error::Storage(format!("mdk08 messages prepare: {e}")))?;
    ingest_message_rows(&mut stmt, (), local_pk, extracted)
}

fn extract_newest_kind9_per_group(
    conn: &Connection,
    local_pk: PublicKey,
    limit: usize,
    cols: &MessageSelectColumns,
    extracted: &mut Mdk08Migration,
) -> Result<()> {
    let mut groups = conn
        .prepare("SELECT DISTINCT mls_group_id FROM messages")
        .map_err(|e| Error::Storage(format!("mdk08 group ids prepare: {e}")))?;
    let group_ids: Vec<Vec<u8>> = groups
        .query_map((), |row| row.get(0))
        .map_err(|e| Error::Storage(format!("mdk08 group ids query: {e}")))?
        .collect::<std::result::Result<_, _>>()
        .map_err(|e| Error::Storage(format!("mdk08 group ids row: {e}")))?;
    let mut stmt = conn
        .prepare(&first_paint_per_group_sql(cols))
        .map_err(|e| Error::Storage(format!("mdk08 per-group prepare: {e}")))?;
    for group_id in group_ids {
        if group_id.is_empty() {
            continue;
        }
        ingest_message_rows(
            &mut stmt,
            rusqlite::params![group_id, limit as i64],
            local_pk,
            extracted,
        )?;
    }
    Ok(())
}

fn remainder_candidate_sql(has_state: bool, only_group: bool) -> String {
    if only_group {
        format!(
            "SELECT mls_group_id, id FROM messages WHERE {} AND mls_group_id = ?1 \
             ORDER BY created_at DESC, id DESC",
            kind9_filter(has_state)
        )
    } else {
        format!(
            "SELECT mls_group_id, id FROM messages WHERE {} \
             ORDER BY created_at DESC, id DESC",
            kind9_filter(has_state)
        )
    }
}

fn remainder_payload_sql(cols: &MessageSelectColumns, n: usize) -> String {
    let placeholders = (1..=n)
        .map(|i| format!("?{i}"))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "SELECT m.mls_group_id, m.id, m.pubkey, m.kind, m.created_at, m.content, \
                {}, {}, {} \
         FROM messages m \
         WHERE m.id IN ({placeholders})",
        cols.state, cols.tags, cols.event
    )
}

fn remainder_has_unskipped(
    conn: &Connection,
    has_state: bool,
    skip: &HashSet<EventId>,
    extra: &HashSet<EventId>,
    omit_groups: &HashSet<GroupId>,
) -> Result<bool> {
    let mut stmt = conn
        .prepare(&remainder_candidate_sql(has_state, false))
        .map_err(|e| Error::Storage(format!("mdk08 remainder more prepare: {e}")))?;
    let rows = stmt
        .query_map((), |row| {
            Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, Vec<u8>>(1)?))
        })
        .map_err(|e| Error::Storage(format!("mdk08 remainder more query: {e}")))?;
    for row in rows {
        let (group_id, id) =
            row.map_err(|e| Error::Storage(format!("mdk08 remainder more row: {e}")))?;
        if omit_groups.contains(&GroupId::new(group_id)) {
            continue;
        }
        let Ok(event_id) = EventId::from_slice(&id) else {
            continue;
        };
        if skip.contains(&event_id) || extra.contains(&event_id) {
            continue;
        }
        return Ok(true);
    }
    Ok(false)
}

fn remainder_candidate_ids(
    conn: &Connection,
    has_state: bool,
    only_group: Option<&GroupId>,
) -> Result<Vec<(Vec<u8>, Vec<u8>)>> {
    let mut stmt = conn
        .prepare(&remainder_candidate_sql(has_state, only_group.is_some()))
        .map_err(|e| Error::Storage(format!("mdk08 remainder ids prepare: {e}")))?;
    let map_row =
        |row: &rusqlite::Row<'_>| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, Vec<u8>>(1)?));
    let mapped = if let Some(group_id) = only_group {
        stmt.query_map(rusqlite::params![group_id.as_slice()], map_row)
    } else {
        stmt.query_map((), map_row)
    }
    .map_err(|e| Error::Storage(format!("mdk08 remainder ids query: {e}")))?;
    mapped
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|e| Error::Storage(format!("mdk08 remainder ids row: {e}")))
}

fn extract_remainder_page(
    conn: &Connection,
    local_pk: PublicKey,
    skip: &HashSet<EventId>,
    budget: usize,
    only_group: Option<&GroupId>,
    omit_groups: &HashSet<GroupId>,
) -> Result<(Mdk08Migration, bool)> {
    let cols = message_select_columns(conn)?;
    let mut extracted = Mdk08Migration::default();
    let candidates = remainder_candidate_ids(conn, cols.has_state, only_group)?;
    let mut chosen: Vec<Vec<u8>> = Vec::new();
    let mut chosen_ids = HashSet::new();
    let mut hit_budget = false;
    for (group_id, id) in candidates {
        if omit_groups.contains(&GroupId::new(group_id)) {
            continue;
        }
        let Ok(event_id) = EventId::from_slice(&id) else {
            continue;
        };
        if skip.contains(&event_id) {
            continue;
        }
        if chosen.len() >= budget {
            hit_budget = true;
            break;
        }
        chosen_ids.insert(event_id);
        chosen.push(id);
    }
    let more = if only_group.is_some() {
        remainder_has_unskipped(conn, cols.has_state, skip, &chosen_ids, omit_groups)?
    } else {
        hit_budget
    };
    if chosen.is_empty() {
        return Ok((extracted, more));
    }
    let mut payload = conn
        .prepare(&remainder_payload_sql(&cols, chosen.len()))
        .map_err(|e| Error::Storage(format!("mdk08 remainder payload prepare: {e}")))?;
    ingest_message_rows(
        &mut payload,
        rusqlite::params_from_iter(chosen),
        local_pk,
        &mut extracted,
    )?;
    extracted.truncated = more;
    Ok((extracted, more))
}

fn ingest_message_rows(
    stmt: &mut rusqlite::Statement<'_>,
    params: impl rusqlite::Params,
    local_pk: PublicKey,
    extracted: &mut Mdk08Migration,
) -> Result<()> {
    let rows = stmt
        .query_map(params, |row| {
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
        if kind as u16 != CHAT_RUMOR_KIND {
            continue;
        }
        if state.as_deref().is_some_and(is_invalid_message_state) {
            continue;
        }
        if group_id.is_empty() {
            continue;
        }
        let gid = GroupId::new(group_id.clone());
        let tags = merge_stored_tags(tags_raw.as_deref(), event_raw.as_deref());
        if let Ok(pk) = PublicKey::from_slice(&pubkey) {
            note_member(extracted, &gid, pk);
        }
        for pk in p_tag_pubkeys(&tags) {
            note_member(extracted, &gid, pk);
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
    Ok(())
}

fn extract_message_members(conn: &Connection, extracted: &mut Mdk08Migration) -> Result<()> {
    let mut stmt = conn
        .prepare("SELECT DISTINCT mls_group_id, pubkey FROM messages")
        .map_err(|e| Error::Storage(format!("mdk08 members prepare: {e}")))?;
    let rows = stmt
        .query_map([], |row| {
            Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, Vec<u8>>(1)?))
        })
        .map_err(|e| Error::Storage(format!("mdk08 members query: {e}")))?;
    for row in rows {
        let (group_id, pubkey) =
            row.map_err(|e| Error::Storage(format!("mdk08 members row: {e}")))?;
        if group_id.is_empty() {
            continue;
        }
        if let Ok(pk) = PublicKey::from_slice(&pubkey) {
            note_member(extracted, &GroupId::new(group_id), pk);
        }
    }
    Ok(())
}

fn note_member(extracted: &mut Mdk08Migration, group_id: &GroupId, pk: PublicKey) {
    let members = extracted.members.entry(group_id.clone()).or_default();
    if !members.contains(&pk) {
        members.push(pk);
    }
}

fn note_member_count(extracted: &mut Mdk08Migration, group_id: &GroupId, count: u32) {
    let entry = extracted.member_counts.entry(group_id.clone()).or_insert(0);
    *entry = (*entry).max(count);
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
             VALUES (?1, ?2, 'alice & bob', 'sonar.direct-dm.v1')",
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
    fn leftover_bak_needed_follows_transcript_not_just_the_marker() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        std::fs::write(&db, b"live").unwrap();
        std::fs::write(backup_path(&db), b"bak").unwrap();
        write_json(
            &sidecar_named(&db, MDK08_MIGRATED_MARKER_SUFFIX),
            &serde_json::json!({ "status": "complete" }),
        )
        .unwrap();
        assert!(
            leftover_bak_needed(&db),
            "complete marker without a transcript still needs the bak"
        );
        write_json(
            &sidecar_named(&db, TRANSCRIPT_FILE_SUFFIX),
            &serde_json::json!({}),
        )
        .unwrap();
        assert!(
            !leftover_bak_needed(&db),
            "complete + transcript is the durable copy"
        );
        assert!(
            bak_needed_for_backup(&db),
            "pre-welcome extracts must still pack the bak so restore can backfill"
        );
        mark_metadata_backfill_complete(&db).unwrap();
        assert!(
            !bak_needed_for_backup(&db),
            "once metadata is copied the bak can drop from later backups"
        );
    }

    #[test]
    fn leftover_bak_needed_is_true_while_remainder_is_partial() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        std::fs::write(&db, b"live").unwrap();
        std::fs::write(backup_path(&db), b"bak").unwrap();
        write_json(
            &sidecar_named(&db, MDK08_MIGRATED_MARKER_SUFFIX),
            &serde_json::json!({ "status": "partial" }),
        )
        .unwrap();
        write_json(
            &sidecar_named(&db, TRANSCRIPT_FILE_SUFFIX),
            &serde_json::json!({}),
        )
        .unwrap();
        assert!(leftover_bak_needed(&db));
    }

    #[test]
    fn metadata_backfill_is_one_shot_after_the_marker_lands() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("marmot.sqlite");
        std::fs::write(&db, b"live").unwrap();
        std::fs::write(backup_path(&db), b"bak").unwrap();
        write_json(
            &sidecar_named(&db, MDK08_MIGRATED_MARKER_SUFFIX),
            &serde_json::json!({ "status": "complete" }),
        )
        .unwrap();
        assert!(
            metadata_backfill_pending(&db),
            "pre-welcome extracts must backfill once from the bak"
        );
        mark_metadata_backfill_complete(&db).unwrap();
        assert!(!metadata_backfill_pending(&db));
        write_json(
            &sidecar_named(&db, MDK08_MIGRATED_MARKER_SUFFIX),
            &serde_json::json!({ "status": "complete", "metadata_backfill": "complete" }),
        )
        .unwrap();
        assert!(
            metadata_backfill_pending(&db),
            "pre-description extracts (metadata_backfill=complete) must run v2"
        );
        mark_metadata_backfill_complete(&db).unwrap();
        assert!(!metadata_backfill_pending(&db));
        assert_eq!(
            backfill_metadata_from_bak(&db, KEY).unwrap(),
            false,
            "complete backfill must not reopen the bak"
        );
    }

    #[test]
    fn empty_named_group_is_kept_for_resume() {
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
        let group_id = vec![0x55u8; 16];
        let admins = serde_json::json!([local.public_key().to_hex(), peer.to_hex()]).to_string();
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description, admin_pubkeys)
             VALUES (?1, ?2, 'quiet room', '', ?3)",
            rusqlite::params![group_id.clone(), vec![0x66u8; 32], admins],
        )
        .unwrap();
        drop(conn);

        let extracted = detect_and_extract_first_paint(&path, KEY, local.public_key())
            .unwrap()
            .expect("0.8 store detected");
        assert!(
            extracted.messages.values().all(|msgs| msgs.is_empty()),
            "no chat rows; the group still has to resume"
        );
        assert_eq!(
            extracted.group_names.values().next().map(String::as_str),
            Some("quiet room")
        );
        let members = extracted.members.values().next().expect("admins");
        assert!(members.contains(&peer));
        assert!(!extracted.truncated);
    }

    #[test]
    fn pending_welcome_is_kept_for_resume() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let welcomer = Identity::generate().public_key();
        let conn = Connection::open(&path).unwrap();
        let hex_key = hex::encode(KEY);
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .unwrap();
        conn.execute_batch(
            "CREATE TABLE messages (
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
            );
            CREATE TABLE welcomes (
                id BLOB PRIMARY KEY,
                event TEXT NOT NULL,
                mls_group_id BLOB NOT NULL,
                nostr_group_id BLOB NOT NULL,
                group_name TEXT NOT NULL,
                group_description TEXT NOT NULL,
                group_admin_pubkeys TEXT NOT NULL,
                group_relays TEXT NOT NULL,
                welcomer BLOB NOT NULL,
                member_count INTEGER NOT NULL,
                state TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL
            );",
        )
        .unwrap();
        let group_id = vec![0x77u8; 16];
        let admins =
            serde_json::json!([local.public_key().to_hex(), welcomer.to_hex()]).to_string();
        conn.execute(
            "INSERT INTO welcomes
                (id, event, mls_group_id, nostr_group_id, group_name, group_description,
                 group_admin_pubkeys, group_relays, welcomer, member_count, state,
                 wrapper_event_id)
             VALUES (?1, '{}', ?2, ?3, 'pending room', '', ?4, '[]', ?5, 3, 'pending', ?1)",
            rusqlite::params![
                vec![0xAAu8; 32],
                group_id.clone(),
                vec![0xBBu8; 32],
                admins,
                welcomer.to_bytes().to_vec(),
            ],
        )
        .unwrap();
        drop(conn);

        let extracted = detect_and_extract_first_paint(&path, KEY, local.public_key())
            .unwrap()
            .expect("0.8 store detected");
        assert_eq!(
            extracted.group_names.values().next().map(String::as_str),
            Some("pending room")
        );
        let members = extracted.members.values().next().expect("welcome members");
        assert!(members.contains(&welcomer));
        assert_eq!(
            extracted.member_counts.values().next().copied(),
            Some(3),
            "pending room size must survive extract so resume does not start_dm"
        );
    }

    #[test]
    fn named_joined_room_description_is_copied() {
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
                id BLOB PRIMARY KEY,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL
            );",
        )
        .unwrap();
        let group_id = vec![0x91u8; 16];
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'team chat', 'weekend hike')",
            rusqlite::params![group_id.clone(), vec![0x92u8; 32]],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO messages
                (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                 wrapper_event_id, state)
             VALUES (?1, ?2, ?3, 9, 1_700_000_000, 'hey', '[]', '{}', ?2, 'processed')",
            rusqlite::params![group_id, vec![0xABu8; 32], peer.to_bytes().to_vec(),],
        )
        .unwrap();
        drop(conn);

        let extracted = detect_and_extract(&path, KEY, local.public_key())
            .unwrap()
            .expect("0.8 store detected");
        assert_eq!(
            extracted
                .group_descriptions
                .values()
                .next()
                .map(String::as_str),
            Some("weekend hike")
        );
        assert_eq!(
            extracted.group_names.values().next().map(String::as_str),
            Some("team chat")
        );
    }

    #[test]
    fn processed_welcome_member_count_survives_extract() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let welcomer = Identity::generate().public_key();
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
                id BLOB PRIMARY KEY,
                pubkey BLOB NOT NULL,
                kind INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                content TEXT NOT NULL,
                tags TEXT NOT NULL,
                event TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL,
                state TEXT NOT NULL
            );
            CREATE TABLE welcomes (
                id BLOB PRIMARY KEY,
                event TEXT NOT NULL,
                mls_group_id BLOB NOT NULL,
                nostr_group_id BLOB NOT NULL,
                group_name TEXT NOT NULL,
                group_description TEXT NOT NULL,
                group_admin_pubkeys TEXT NOT NULL,
                group_relays TEXT NOT NULL,
                welcomer BLOB NOT NULL,
                member_count INTEGER NOT NULL,
                state TEXT NOT NULL,
                wrapper_event_id BLOB NOT NULL
            );",
        )
        .unwrap();
        let group_id = vec![0x93u8; 16];
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'joined room', '')",
            rusqlite::params![group_id.clone(), vec![0x94u8; 32]],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO messages
                (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                 wrapper_event_id, state)
             VALUES (?1, ?2, ?3, 9, 1_700_000_000, 'only the welcomer spoke', '[]', '{}', ?2, 'processed')",
            rusqlite::params![
                group_id.clone(),
                vec![0xABu8; 32],
                welcomer.to_bytes().to_vec(),
            ],
        )
        .unwrap();
        let admins =
            serde_json::json!([local.public_key().to_hex(), welcomer.to_hex()]).to_string();
        conn.execute(
            "INSERT INTO welcomes
                (id, event, mls_group_id, nostr_group_id, group_name, group_description,
                 group_admin_pubkeys, group_relays, welcomer, member_count, state,
                 wrapper_event_id)
             VALUES (?1, '{}', ?2, ?3, 'joined room', '', ?4, '[]', ?5, 4, 'processed', ?1)",
            rusqlite::params![
                vec![0xCCu8; 32],
                group_id,
                vec![0xDDu8; 32],
                admins,
                welcomer.to_bytes().to_vec(),
            ],
        )
        .unwrap();
        drop(conn);

        let extracted = detect_and_extract(&path, KEY, local.public_key())
            .unwrap()
            .expect("0.8 store detected");
        assert_eq!(
            extracted.member_counts.values().next().copied(),
            Some(4),
            "processed welcome size must keep a joined room off start_dm"
        );
    }

    #[test]
    fn labeled_media_exporter_secret_is_copied_unlabeled_is_not() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let conn = Connection::open(&path).unwrap();
        let hex_key = hex::encode(KEY);
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .unwrap();
        conn.execute_batch(
            "CREATE TABLE messages (
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
            );
            CREATE TABLE group_exporter_secrets (
                mls_group_id BLOB NOT NULL,
                epoch INTEGER NOT NULL,
                label TEXT NOT NULL,
                secret BLOB NOT NULL,
                PRIMARY KEY (mls_group_id, epoch, label)
            );",
        )
        .unwrap();
        let group_id = vec![0x88u8; 16];
        let media_secret = vec![0xCDu8; 32];
        let event_secret = vec![0xEFu8; 32];
        conn.execute(
            "INSERT INTO group_exporter_secrets (mls_group_id, epoch, label, secret)
             VALUES (?1, 1, 'encrypted-media', ?2), (?1, 1, 'group-event', ?3)",
            rusqlite::params![group_id.clone(), media_secret.clone(), event_secret],
        )
        .unwrap();
        drop(conn);

        let extracted = detect_and_extract_first_paint(&path, KEY, local.public_key())
            .unwrap()
            .expect("0.8 store detected");
        let gid = GroupId::new(group_id);
        let secrets = extracted
            .media_exporter_secrets
            .get(&gid)
            .expect("media secret");
        assert_eq!(secrets, &vec![media_secret.clone()]);
        write_sidecars(&path, &extracted).unwrap();
        let loaded = load_historical_media_secrets(&path);
        assert_eq!(
            loaded.get(&gid),
            Some(&vec![media_secret]),
            "labeled MIP-04 secret must survive the sidecar write"
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
             VALUES (?1, ?2, 'just alice sent', 'sonar.direct-dm.v1', ?3)",
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
    fn first_paint_keeps_newest_window_and_marks_truncated() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let peer = Identity::generate().public_key();
        write_mdk08_fixture(&path, &local, peer, "oldest");
        let conn = Connection::open(&path).unwrap();
        let hex_key = hex::encode(KEY);
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .unwrap();
        let group_id = vec![0x11u8; 16];
        for i in 1..=FIRST_PAINT_MESSAGES_PER_GROUP {
            let mut id = [0u8; 32];
            id[0] = i as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state, epoch)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed', 1)",
                rusqlite::params![
                    group_id.clone(),
                    id.to_vec(),
                    peer.to_bytes().to_vec(),
                    1_700_000_000 + i as i64,
                    format!("msg-{i}"),
                ],
            )
            .unwrap();
        }
        drop(conn);

        let window = detect_and_extract_first_paint(&path, KEY, local.public_key())
            .unwrap()
            .expect("0.8 store detected");
        let msgs = window.messages.values().next().unwrap();
        assert_eq!(msgs.len(), FIRST_PAINT_MESSAGES_PER_GROUP);
        assert!(window.truncated);
        assert!(msgs.iter().any(|m| m.content == "msg-80"));
        assert!(!msgs.iter().any(|m| m.content == "oldest"));

        let full = detect_and_extract(&path, KEY, local.public_key())
            .unwrap()
            .expect("full extract");
        assert_eq!(
            full.messages.values().next().unwrap().len(),
            FIRST_PAINT_MESSAGES_PER_GROUP + 1
        );
        assert!(!full.truncated);
    }

    #[test]
    fn first_paint_window_sql_ranks_ids_without_payload_columns() {
        let sql = first_paint_window_sql(&MessageSelectColumns {
            has_state: true,
            state: "m.state",
            tags: "m.tags",
            event: "m.event",
        });
        let ranking = sql
            .split("INNER JOIN")
            .nth(1)
            .expect("id-join ranking subquery");
        assert!(sql.contains("ROW_NUMBER()"));
        assert!(
            !ranking.contains("content"),
            "ranking must not load content overflow pages"
        );
        assert!(!ranking.contains("tags") && !ranking.contains("event"));
        assert!(kind9_filter(true).contains("state != 'invalid'"));
    }

    #[test]
    fn first_paint_skips_invalid_and_non_chat_rows_in_the_window() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let peer = Identity::generate().public_key();
        write_mdk08_fixture(&path, &local, peer, "oldest");
        let conn = Connection::open(&path).unwrap();
        let hex_key = hex::encode(KEY);
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .unwrap();
        let group_id = vec![0x11u8; 16];
        for i in 1..=FIRST_PAINT_MESSAGES_PER_GROUP {
            let mut id = [0u8; 32];
            id[0] = i as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state, epoch)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed', 1)",
                rusqlite::params![
                    group_id.clone(),
                    id.to_vec(),
                    peer.to_bytes().to_vec(),
                    1_700_000_100 + i as i64,
                    format!("keep-{i}"),
                ],
            )
            .unwrap();
        }
        for (i, (kind, state, body)) in [
            (9i64, "invalid", "bad-invalid"),
            (9, "failed", "bad-failed"),
            (445, "processed", "commit-noise"),
        ]
        .into_iter()
        .enumerate()
        {
            let mut id = [0xFFu8; 32];
            id[1] = i as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state, epoch)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, '[]', '{}', ?2, ?7, 1)",
                rusqlite::params![
                    group_id.clone(),
                    id.to_vec(),
                    peer.to_bytes().to_vec(),
                    kind,
                    1_700_000_400 + i as i64,
                    body,
                    state,
                ],
            )
            .unwrap();
        }
        drop(conn);

        let window = detect_and_extract_first_paint(&path, KEY, local.public_key())
            .unwrap()
            .expect("0.8 store detected");
        let msgs = window.messages.values().next().unwrap();
        assert_eq!(msgs.len(), FIRST_PAINT_MESSAGES_PER_GROUP);
        assert!(window.truncated);
        assert!(msgs.iter().any(|m| m.content == "keep-80"));
        assert!(!msgs.iter().any(|m| m.content == "oldest"));
        assert!(!msgs.iter().any(|m| m.content.starts_with("bad-")));
        assert!(!msgs.iter().any(|m| m.content == "commit-noise"));
    }

    #[test]
    fn first_paint_per_group_fallback_keeps_newest_window() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let peer = Identity::generate().public_key();
        write_mdk08_fixture(&path, &local, peer, "oldest");
        let conn = Connection::open(&path).unwrap();
        let hex_key = hex::encode(KEY);
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .unwrap();
        let group_id = vec![0x11u8; 16];
        for i in 1..=FIRST_PAINT_MESSAGES_PER_GROUP {
            let mut id = [0u8; 32];
            id[0] = i as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state, epoch)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed', 1)",
                rusqlite::params![
                    group_id.clone(),
                    id.to_vec(),
                    peer.to_bytes().to_vec(),
                    1_700_000_000 + i as i64,
                    format!("msg-{i}"),
                ],
            )
            .unwrap();
        }
        let cols = message_select_columns(&conn).unwrap();
        let mut extracted = Mdk08Migration::default();
        extract_newest_kind9_per_group(
            &conn,
            local.public_key(),
            FIRST_PAINT_MESSAGES_PER_GROUP,
            &cols,
            &mut extracted,
        )
        .unwrap();
        let msgs = extracted.messages.values().next().unwrap();
        assert_eq!(msgs.len(), FIRST_PAINT_MESSAGES_PER_GROUP);
        assert!(msgs.iter().any(|m| m.content == "msg-80"));
        assert!(!msgs.iter().any(|m| m.content == "oldest"));
    }

    #[test]
    fn first_paint_windows_each_group_independently() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let peer = Identity::generate().public_key();
        write_mdk08_fixture(&path, &local, peer, "g1-oldest");
        let conn = Connection::open(&path).unwrap();
        let hex_key = hex::encode(KEY);
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .unwrap();
        let group_a = vec![0x11u8; 16];
        let group_b = vec![0x33u8; 16];
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'carol', '')",
            rusqlite::params![group_b.clone(), vec![0x44u8; 32]],
        )
        .unwrap();
        for (group_id, prefix) in [(&group_a, "a"), (&group_b, "b")] {
            for i in 1..=FIRST_PAINT_MESSAGES_PER_GROUP {
                let mut id = [0u8; 32];
                id[0] = if prefix == "a" { 0xA0 } else { 0xB0 };
                id[1] = i as u8;
                conn.execute(
                    "INSERT INTO messages
                        (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                         wrapper_event_id, state, epoch)
                     VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed', 1)",
                    rusqlite::params![
                        group_id.clone(),
                        id.to_vec(),
                        peer.to_bytes().to_vec(),
                        1_700_000_000 + i as i64,
                        format!("{prefix}-{i}"),
                    ],
                )
                .unwrap();
            }
        }
        drop(conn);

        let window = detect_and_extract_first_paint(&path, KEY, local.public_key())
            .unwrap()
            .expect("0.8 store detected");
        assert!(window.truncated);
        assert_eq!(window.messages.len(), 2);
        for msgs in window.messages.values() {
            assert_eq!(msgs.len(), FIRST_PAINT_MESSAGES_PER_GROUP);
            assert!(!msgs
                .iter()
                .any(|m| m.content.ends_with("-oldest") || m.content == "g1-oldest"));
        }
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

    #[test]
    fn remainder_candidate_sql_ranks_ids_without_payload_columns() {
        let sql = remainder_candidate_sql(true, false);
        assert!(sql.contains("ORDER BY created_at DESC"));
        assert!(!sql.contains("content"));
        assert!(!sql.contains("tags"));
        assert!(!sql.contains("event"));
    }

    #[test]
    fn remainder_page_skips_copied_ids_and_reports_more() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let peer = Identity::generate().public_key();
        write_mdk08_fixture(&path, &local, peer, "seed");
        let conn = Connection::open(&path).unwrap();
        let hex_key = hex::encode(KEY);
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .unwrap();
        let group_id = vec![0x11u8; 16];
        for i in 1..=105 {
            let mut id = [0u8; 32];
            id[0] = i as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state, epoch)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed', 1)",
                rusqlite::params![
                    group_id.clone(),
                    id.to_vec(),
                    peer.to_bytes().to_vec(),
                    1_700_000_000 + i as i64,
                    format!("msg-{i}"),
                ],
            )
            .unwrap();
        }
        drop(conn);

        let window = detect_and_extract_first_paint(&path, KEY, local.public_key())
            .unwrap()
            .expect("first paint");
        let skip: HashSet<EventId> = window
            .messages
            .values()
            .flatten()
            .map(|msg| msg.id)
            .collect();
        assert_eq!(skip.len(), FIRST_PAINT_MESSAGES_PER_GROUP);

        let (page, more) = detect_and_extract_remainder(
            &path,
            KEY,
            local.public_key(),
            &skip,
            10,
            None,
            &HashSet::new(),
        )
        .unwrap()
        .expect("remainder page");
        let msgs = page.messages.values().next().unwrap();
        assert!(more);
        assert_eq!(msgs.len(), 10);
        assert!(msgs.iter().any(|m| m.content == "msg-25"));
        assert!(msgs.iter().any(|m| m.content == "msg-16"));
        assert!(!msgs.iter().any(|m| m.content == "msg-105"));
        assert!(!msgs.iter().any(|m| m.content == "seed"));

        let mut skip = skip;
        skip.extend(msgs.iter().map(|m| m.id));
        let (rest, more) = detect_and_extract_remainder(
            &path,
            KEY,
            local.public_key(),
            &skip,
            400,
            None,
            &HashSet::new(),
        )
        .unwrap()
        .expect("remainder tail");
        assert!(!more);
        let rest_len = rest.messages.values().map(|m| m.len()).sum::<usize>();
        // seed + msg-1..15 remain after the first-paint 80 and the 10-row page.
        assert_eq!(rest_len, 16);
    }

    #[test]
    fn remainder_page_can_target_one_group_without_clearing_others() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let peer = Identity::generate().public_key();
        write_mdk08_fixture(&path, &local, peer, "g1-oldest");
        let conn = Connection::open(&path).unwrap();
        let hex_key = hex::encode(KEY);
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .unwrap();
        let group_a = vec![0x11u8; 16];
        let group_b = vec![0x33u8; 16];
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'carol', '')",
            rusqlite::params![group_b.clone(), vec![0x44u8; 32]],
        )
        .unwrap();
        for i in 1..=FIRST_PAINT_MESSAGES_PER_GROUP {
            let mut id = [0u8; 32];
            id[0] = 0xA0;
            id[1] = i as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state, epoch)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed', 1)",
                rusqlite::params![
                    group_a.clone(),
                    id.to_vec(),
                    peer.to_bytes().to_vec(),
                    1_700_000_000 + i as i64,
                    format!("a-{i}"),
                ],
            )
            .unwrap();
        }
        for i in 1..=(FIRST_PAINT_MESSAGES_PER_GROUP + 5) {
            let mut id = [0u8; 32];
            id[0] = 0xB0;
            id[1] = i as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state, epoch)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed', 1)",
                rusqlite::params![
                    group_b.clone(),
                    id.to_vec(),
                    peer.to_bytes().to_vec(),
                    1_800_000_000 + i as i64,
                    format!("b-{i}"),
                ],
            )
            .unwrap();
        }
        drop(conn);

        let window = detect_and_extract_first_paint(&path, KEY, local.public_key())
            .unwrap()
            .expect("first paint");
        let skip: HashSet<EventId> = window
            .messages
            .values()
            .flatten()
            .map(|msg| msg.id)
            .collect();
        let (page, more) = detect_and_extract_remainder(
            &path,
            KEY,
            local.public_key(),
            &skip,
            5,
            Some(&GroupId::new(group_b)),
            &HashSet::new(),
        )
        .unwrap()
        .expect("group-b remainder");
        assert!(more, "group a leftover must keep the bak pending");
        assert_eq!(page.messages.len(), 1);
        let msgs = page.messages.values().next().unwrap();
        assert_eq!(msgs.len(), 5);
        assert!(msgs.iter().all(|m| m.content.starts_with("b-")));
        assert!(!msgs
            .iter()
            .any(|m| m.content.starts_with("a-") || m.content.contains("oldest")));
    }

    #[test]
    fn remainder_page_skips_omitted_groups() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let local = Identity::generate();
        let peer = Identity::generate().public_key();
        write_mdk08_fixture(&path, &local, peer, "keep-oldest");
        let conn = Connection::open(&path).unwrap();
        let hex_key = hex::encode(KEY);
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex_key}'\";"))
            .unwrap();
        let keep = vec![0x11u8; 16];
        let gone = vec![0x33u8; 16];
        conn.execute(
            "INSERT INTO groups (mls_group_id, nostr_group_id, name, description)
             VALUES (?1, ?2, 'deleted room', '')",
            rusqlite::params![gone.clone(), vec![0x44u8; 32]],
        )
        .unwrap();
        for i in 1..=(FIRST_PAINT_MESSAGES_PER_GROUP + 5) {
            let mut keep_id = [0u8; 32];
            keep_id[0] = 0xA0;
            keep_id[1] = i as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state, epoch)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed', 1)",
                rusqlite::params![
                    keep.clone(),
                    keep_id.to_vec(),
                    peer.to_bytes().to_vec(),
                    1_700_000_000 + i as i64,
                    format!("keep-{i}"),
                ],
            )
            .unwrap();
            let mut gone_id = [0u8; 32];
            gone_id[0] = 0xB0;
            gone_id[1] = i as u8;
            conn.execute(
                "INSERT INTO messages
                    (mls_group_id, id, pubkey, kind, created_at, content, tags, event,
                     wrapper_event_id, state, epoch)
                 VALUES (?1, ?2, ?3, 9, ?4, ?5, '[]', '{}', ?2, 'processed', 1)",
                rusqlite::params![
                    gone.clone(),
                    gone_id.to_vec(),
                    peer.to_bytes().to_vec(),
                    1_800_000_000 + i as i64,
                    format!("gone-{i}"),
                ],
            )
            .unwrap();
        }
        drop(conn);

        let window = detect_and_extract_first_paint(&path, KEY, local.public_key())
            .unwrap()
            .expect("first paint");
        let skip: HashSet<EventId> = window
            .messages
            .values()
            .flatten()
            .map(|msg| msg.id)
            .collect();
        let omit = HashSet::from([GroupId::new(gone)]);
        let (page, more) =
            detect_and_extract_remainder(&path, KEY, local.public_key(), &skip, 400, None, &omit)
                .unwrap()
                .expect("remainder after omit");
        assert!(
            !more,
            "leftover rows that only belong to omitted groups must not keep remainder pending"
        );
        let msgs: Vec<&ChatMessage> = page.messages.values().flatten().collect();
        assert_eq!(msgs.len(), 6, "seed + 5 leftover keep-group rows");
        assert!(msgs.iter().all(|m| !m.content.starts_with("gone-")));
        assert!(msgs.iter().any(|m| m.content == "keep-oldest"));

        let (empty, more) = detect_and_extract_remainder(
            &path,
            KEY,
            local.public_key(),
            &HashSet::new(),
            400,
            Some(&GroupId::new(keep.clone())),
            &HashSet::from([GroupId::new(keep), GroupId::new(vec![0x33u8; 16])]),
        )
        .unwrap()
        .expect("omitted target group");
        assert!(empty.messages.is_empty());
        assert!(
            !more,
            "when every leftover group is omitted, remainder must go idle"
        );
    }

    #[test]
    fn forget_historical_metadata_drops_deleted_sidecar_rows() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("marmot.sqlite");
        let keep = GroupId::new(vec![0x11u8; 16]);
        let gone = GroupId::new(vec![0x22u8; 16]);
        let mut names = HashMap::new();
        names.insert(keep.clone(), "keep room".into());
        names.insert(gone.clone(), "deleted room".into());
        rewrite_string_map(&db_path, HISTORICAL_GROUPS_FILE_SUFFIX, &names);
        forget_historical_metadata(&db_path, &[gone]);
        let remaining = load_historical_group_names(&db_path);
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining.get(&keep).map(String::as_str), Some("keep room"));
        assert!(!remaining.contains_key(&GroupId::new(vec![0x22u8; 16])));
    }
}
