//! NIP-25 kind-7 reactions as Marmot application rumors.
//!
//! White Noise / Marmot carry unsigned kind-7 events *inside* MLS (kind 445),
//! not as public relay likes. This module is the only place that builds or
//! parses that rumor so a later MDK `reactToMessage` swap can sit behind the
//! same `send_reaction` / tally FFI.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use ::hkdf::Hkdf;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use mdk_storage_traits::messages::types::Message as StoredMessage;
use nostr::prelude::*;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::marmot::{ChatMessage, CHAT_RUMOR_KIND};
use crate::{Error, Result};

/// Inner reaction rumor kind (NIP-25). Matches White Noise / Marmot `03.md`.
pub const REACTION_RUMOR_KIND: u16 = 7;

/// Cap on reaction content so a kind-7 cannot become a chat body by accident.
const MAX_REACTION_CHARS: usize = 16;

/// One sender's emoji on a target message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedReaction {
    pub id: EventId,
    pub target_id: EventId,
    pub sender: PublicKey,
    pub emoji: String,
}

/// Aggregated chip for one emoji on one parent message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReactionTally {
    pub emoji: String,
    pub count: u32,
    /// True when the local identity is among the senders.
    pub mine: bool,
}

pub fn is_reaction_kind(kind: Kind) -> bool {
    kind == Kind::Reaction || kind.as_u16() == REACTION_RUMOR_KIND
}

/// Trim and bound reaction content. Empty / over-long is rejected — NIP-25
/// "like" (`+`) / "dislike" (`-`) are not Sonar chips.
pub fn normalize_emoji(content: &str) -> Result<String> {
    let trimmed = content.trim();
    if trimmed.is_empty() || trimmed == "+" || trimmed == "-" {
        return Err(Error::InvalidInput("reaction content empty".into()));
    }
    if trimmed.chars().count() > MAX_REACTION_CHARS {
        return Err(Error::InvalidInput("reaction content too long".into()));
    }
    Ok(trimmed.to_string())
}

/// NIP-25 tags: last `e` is the target, `p` is the author, `k` is parent kind.
pub fn reaction_tags(parent_id: &EventId, parent_pubkey: &PublicKey) -> Vec<Tag> {
    vec![
        Tag::from_standardized_without_cell(TagStandard::Event {
            event_id: *parent_id,
            relay_url: None,
            marker: None,
            public_key: Some(*parent_pubkey),
            uppercase: false,
        }),
        Tag::public_key(*parent_pubkey),
        Tag::custom(TagKind::Custom("k".into()), [CHAT_RUMOR_KIND.to_string()]),
    ]
}

/// Last `e` tag wins (NIP-25). Invalid ids are skipped.
pub fn parse_target_id<'a, I>(tags: I) -> Option<EventId>
where
    I: IntoIterator<Item = &'a Tag>,
{
    let mut last = None;
    for tag in tags {
        if let Some(TagStandard::Event { event_id, .. }) = tag.as_standardized() {
            last = Some(*event_id);
            continue;
        }
        let slice = tag.as_slice();
        if slice.first().map(|s| s.as_str()) != Some("e") || slice.len() < 2 {
            continue;
        }
        if let Ok(id) = EventId::from_hex(&slice[1]) {
            last = Some(id);
        }
    }
    last
}

pub fn parse_stored(message: &StoredMessage) -> Option<ParsedReaction> {
    if !is_reaction_kind(message.kind) {
        return None;
    }
    if message.state == mdk_storage_traits::messages::types::MessageState::Deleted {
        return None;
    }
    let emoji = normalize_emoji(&message.content).ok()?;
    let target_id = parse_target_id(message.tags.iter())?;
    Some(ParsedReaction {
        id: message.id,
        target_id,
        sender: message.pubkey,
        emoji,
    })
}

/// Unique `(sender, emoji)` per target. Count is distinct senders, not events,
/// so a duplicate kind-7 from the same pubkey does not inflate the chip.
pub fn tallies_for_target(
    reactions: &[ParsedReaction],
    target_id: &EventId,
    me: &PublicKey,
) -> Vec<ReactionTally> {
    let mut senders_by_emoji: HashMap<String, HashSet<PublicKey>> = HashMap::new();
    for r in reactions {
        if r.target_id != *target_id {
            continue;
        }
        senders_by_emoji
            .entry(r.emoji.clone())
            .or_default()
            .insert(r.sender);
    }
    let mut tallies: Vec<ReactionTally> = senders_by_emoji
        .into_iter()
        .map(|(emoji, senders)| ReactionTally {
            count: senders.len() as u32,
            mine: senders.contains(me),
            emoji,
        })
        .collect();
    tallies.sort_by(|a, b| {
        b.count
            .cmp(&a.count)
            .then_with(|| b.mine.cmp(&a.mine))
            .then_with(|| a.emoji.cmp(&b.emoji))
    });
    tallies
}

pub fn attach_tallies(messages: &mut [ChatMessage], reactions: &[ParsedReaction], me: PublicKey) {
    if messages.is_empty() || reactions.is_empty() {
        return;
    }
    let targets: HashSet<EventId> = messages.iter().map(|m| m.id).collect();
    let relevant: Vec<&ParsedReaction> = reactions
        .iter()
        .filter(|r| targets.contains(&r.target_id))
        .collect();
    if relevant.is_empty() {
        return;
    }
    // Clone once into a vec so tallies_for_target can take a slice.
    let relevant_owned: Vec<ParsedReaction> = relevant.into_iter().cloned().collect();
    for m in messages.iter_mut() {
        m.reactions = tallies_for_target(&relevant_owned, &m.id, &me);
    }
}

/// In-process kind-7 index keyed by `(group, target)`.
///
/// MDK only offers newest-first row scans, so a later reaction on an older
/// parent is invisible to a cursor page. This map is filled on every processed
/// kind-7 and persisted beside the DB so restart/backscroll is a HashMap
/// lookup, not a 10,000-row scan. Newest-page open still uses only the page-local
/// scan plus this index.
///
/// The sidecar holds decrypted chat data — who reacted with what, to which
/// message, in which group — so it is sealed with a key derived from the
/// SQLCipher key ([`ReactionStoreKey::derive`]), never written as plaintext
/// (the outbox sidecar's rule: message content stays behind the DB key).
#[derive(Default)]
pub struct ReactionStore {
    by_target: HashMap<(Vec<u8>, EventId), Vec<ParsedReaction>>,
}

/// Historical name: the file is a sealed blob, not JSON. Kept so a sealed
/// write replaces a plaintext sidecar left by a pre-release build in place,
/// and the wipe/restore paths keep covering it.
pub(crate) const REACTION_STORE_FILE_SUFFIX: &str = ".sonar-reactions.json";
pub(crate) const REACTION_STORE_DIRTY_SUFFIX: &str = ".sonar-reactions.dirty";
/// Version 1 was a plaintext JSON file; it never decodes as a sealed blob, so
/// a v1 sidecar is rebuilt from SQLCipher and overwritten on first open.
const REACTION_STORE_VERSION: u32 = 2;
/// `magic || nonce || ChaCha20-Poly1305(JSON)`.
const REACTION_STORE_MAGIC: &[u8; 4] = b"SRX2";
const REACTION_STORE_NONCE_LEN: usize = 12;
const REACTION_STORE_HKDF_SALT: &[u8] = b"sonar-reaction-index";
const REACTION_STORE_HKDF_INFO: &[u8] = b"sonar-reaction-index/v2";

/// Sealing key for the reaction sidecar, derived from the SQLCipher key so the
/// index is exactly as readable as the database it mirrors.
#[derive(Clone, Copy)]
pub(crate) struct ReactionStoreKey([u8; 32]);

impl ReactionStoreKey {
    pub(crate) fn derive(db_key: &[u8; 32]) -> Self {
        let hkdf = Hkdf::<Sha256>::new(Some(REACTION_STORE_HKDF_SALT), db_key);
        let mut key = [0u8; 32];
        hkdf.expand(REACTION_STORE_HKDF_INFO, &mut key)
            .expect("32 bytes is a valid HKDF-SHA256 output length");
        Self(key)
    }

    fn cipher(&self) -> ChaCha20Poly1305 {
        ChaCha20Poly1305::new_from_slice(&self.0).expect("ChaCha20-Poly1305 key is 32 bytes")
    }
}

impl std::fmt::Debug for ReactionStoreKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ReactionStoreKey(..)")
    }
}

fn seal_store(key: &ReactionStoreKey, plaintext: &[u8]) -> Result<Vec<u8>> {
    // A dead CSPRNG fails the write (Randomness Rule); the dirty marker then
    // stays set and the next open rebuilds from SQLCipher.
    let mut nonce = [0u8; REACTION_STORE_NONCE_LEN];
    getrandom::getrandom(&mut nonce)?;
    let ciphertext = key
        .cipher()
        .encrypt(Nonce::from_slice(&nonce), plaintext)
        .map_err(|e| Error::Storage(format!("seal reaction store: {e}")))?;
    let mut out = Vec::with_capacity(
        REACTION_STORE_MAGIC.len() + REACTION_STORE_NONCE_LEN + ciphertext.len(),
    );
    out.extend_from_slice(REACTION_STORE_MAGIC);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

/// `None` for anything that is not a blob sealed under `key`: a plaintext v1
/// file, another account's key, truncation or corruption.
fn open_store(key: &ReactionStoreKey, sealed: &[u8]) -> Option<ReactionStoreDisk> {
    let body = sealed.strip_prefix(REACTION_STORE_MAGIC.as_slice())?;
    if body.len() <= REACTION_STORE_NONCE_LEN {
        return None;
    }
    let (nonce, ciphertext) = body.split_at(REACTION_STORE_NONCE_LEN);
    let plaintext = key
        .cipher()
        .decrypt(Nonce::from_slice(nonce), ciphertext)
        .ok()?;
    let disk: ReactionStoreDisk = serde_json::from_slice(&plaintext).ok()?;
    (disk.version == REACTION_STORE_VERSION).then_some(disk)
}

fn read_store(path: &Path, key: &ReactionStoreKey) -> Option<ReactionStoreDisk> {
    open_store(key, &fs::read(path).ok()?)
}

#[derive(Serialize, Deserialize)]
struct ReactionStoreDisk {
    version: u32,
    entries: Vec<ReactionStoreDiskEntry>,
}

#[derive(Serialize, Deserialize)]
struct ReactionStoreDiskEntry {
    group_id_hex: String,
    target_id_hex: String,
    id_hex: String,
    sender: String,
    emoji: String,
}

fn group_key(group_id: &mdk_core::GroupId) -> Vec<u8> {
    group_id.as_slice().to_vec()
}

pub(crate) fn reaction_store_path_for_db(db_path: &Path) -> PathBuf {
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("marmot.sqlite");
    db_path.with_file_name(format!("{file_name}{REACTION_STORE_FILE_SUFFIX}"))
}

pub(crate) fn reaction_store_tmp_path(path: &Path) -> PathBuf {
    path.with_file_name(format!(
        "{}.tmp",
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("sonar-reactions.json")
    ))
}

pub(crate) fn reaction_store_dirty_path_for_db(db_path: &Path) -> PathBuf {
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("marmot.sqlite");
    db_path.with_file_name(format!("{file_name}{REACTION_STORE_DIRTY_SUFFIX}"))
}

pub(crate) fn mark_reaction_store_dirty(db_path: &Path) {
    let _ = fs::write(reaction_store_dirty_path_for_db(db_path), b"");
}

pub(crate) fn clear_reaction_store_dirty(db_path: &Path) {
    let _ = fs::remove_file(reaction_store_dirty_path_for_db(db_path));
}

pub(crate) fn reaction_store_is_dirty(db_path: &Path) -> bool {
    reaction_store_dirty_path_for_db(db_path).exists()
}

/// True when the sidecar is missing, unreadable (not sealed under `key`), or
/// marked dirty, so the derived index must be rebuilt from the encrypted DB
/// (account restore, first open, corrupt or plaintext v1 file, or a
/// crash/persist failure after MDK committed a kind-7). Never run this rebuild
/// on the chat-open paging path.
pub(crate) fn reaction_store_needs_rebuild(db_path: &Path, key: &ReactionStoreKey) -> bool {
    reaction_store_is_dirty(db_path)
        || read_store(&reaction_store_path_for_db(db_path), key).is_none()
}

/// Drop the derived sidecar so a restore cannot keep post-backup ghost chips.
pub(crate) fn remove_reaction_store_files(db_path: &Path) {
    let path = reaction_store_path_for_db(db_path);
    let tmp = reaction_store_tmp_path(&path);
    let _ = fs::remove_file(&path);
    let _ = fs::remove_file(&tmp);
    clear_reaction_store_dirty(db_path);
}

#[cfg(not(windows))]
fn atomic_replace_file(from: &Path, to: &Path) -> std::io::Result<()> {
    fs::rename(from, to)
}

#[cfg(windows)]
fn atomic_replace_file(from: &Path, to: &Path) -> std::io::Result<()> {
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
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

impl ReactionStore {
    pub(crate) fn load(path: &Path, key: &ReactionStoreKey) -> Self {
        let Some(disk) = read_store(path, key) else {
            return Self::default();
        };
        let mut store = Self::default();
        for entry in disk.entries {
            let Ok(group_bytes) = hex::decode(&entry.group_id_hex) else {
                continue;
            };
            if group_bytes.is_empty() {
                continue;
            }
            let Ok(target_id) = EventId::from_hex(&entry.target_id_hex) else {
                continue;
            };
            let Ok(id) = EventId::from_hex(&entry.id_hex) else {
                continue;
            };
            let Ok(sender) = PublicKey::parse(&entry.sender) else {
                continue;
            };
            let group = mdk_core::GroupId::from_slice(&group_bytes);
            store.record(
                &group,
                ParsedReaction {
                    id,
                    target_id,
                    sender,
                    emoji: entry.emoji,
                },
            );
        }
        store
    }

    pub(crate) fn save(&self, path: &Path, key: &ReactionStoreKey) -> Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| {
                Error::Storage(format!(
                    "create reaction-store dir {}: {e}",
                    parent.display()
                ))
            })?;
        }
        let mut entries: Vec<ReactionStoreDiskEntry> = Vec::new();
        for ((group, target), reactions) in &self.by_target {
            for r in reactions {
                entries.push(ReactionStoreDiskEntry {
                    group_id_hex: hex::encode(group),
                    target_id_hex: target.to_hex(),
                    id_hex: r.id.to_hex(),
                    sender: r.sender.to_hex(),
                    emoji: r.emoji.clone(),
                });
            }
        }
        entries.sort_by(|a, b| {
            a.group_id_hex
                .cmp(&b.group_id_hex)
                .then_with(|| a.target_id_hex.cmp(&b.target_id_hex))
                .then_with(|| a.id_hex.cmp(&b.id_hex))
        });
        let disk = ReactionStoreDisk {
            version: REACTION_STORE_VERSION,
            entries,
        };
        let bytes = seal_store(key, &serde_json::to_vec(&disk)?)?;
        let tmp = reaction_store_tmp_path(path);
        fs::write(&tmp, bytes)
            .map_err(|e| Error::Storage(format!("write reaction store {}: {e}", tmp.display())))?;
        atomic_replace_file(&tmp, path).map_err(|e| {
            let _ = fs::remove_file(&tmp);
            Error::Storage(format!("replace reaction store {}: {e}", path.display()))
        })?;
        Ok(())
    }

    /// Returns true when the reaction was newly inserted.
    ///
    /// Tallies are unique `(sender, emoji)` per target, so a flood of distinct
    /// kind-7 ids for the same chip is stored once. First event wins; a later
    /// distinct id is ignored unless [`Self::remove_id`] dropped the first.
    pub fn record(&mut self, group_id: &mdk_core::GroupId, reaction: ParsedReaction) -> bool {
        let key = (group_key(group_id), reaction.target_id);
        let entries = self.by_target.entry(key).or_default();
        if entries.iter().any(|e| e.id == reaction.id) {
            return false;
        }
        if entries
            .iter()
            .any(|e| e.sender == reaction.sender && e.emoji == reaction.emoji)
        {
            return false;
        }
        entries.push(reaction);
        true
    }

    /// Drop a rumor by id so a retry with a new id can occupy the chip slot.
    pub fn remove_id(&mut self, id: EventId) -> bool {
        let mut changed = false;
        self.by_target.retain(|_, entries| {
            let before = entries.len();
            entries.retain(|e| e.id != id);
            changed |= entries.len() != before;
            !entries.is_empty()
        });
        changed
    }

    /// Drop every reaction belonging to a locally deleted group.
    pub fn remove_group(&mut self, group_id: &mdk_core::GroupId) -> bool {
        let gk = group_key(group_id);
        let before = self.by_target.len();
        self.by_target.retain(|(g, _), _| g != &gk);
        self.by_target.len() != before
    }

    pub fn for_targets(
        &self,
        group_id: &mdk_core::GroupId,
        targets: &HashSet<EventId>,
    ) -> Vec<ParsedReaction> {
        let gk = group_key(group_id);
        let mut out = Vec::new();
        for target in targets {
            if let Some(entries) = self.by_target.get(&(gk.clone(), *target)) {
                out.extend(entries.iter().cloned());
            }
        }
        out
    }
}

/// Where and how the index is persisted: beside the SQLCipher DB, sealed with
/// a key derived from the DB key. Absent for in-memory engines.
struct ReactionPersist {
    db_path: PathBuf,
    key: ReactionStoreKey,
}

/// The engine's kind-7 index: the target-keyed store, the rumor ids whose
/// publish terminally failed, and the sealed sidecar that mirrors the store.
///
/// Crash protocol: a write that can commit a kind-7 to MDK first sets the
/// on-disk dirty marker ([`Self::begin_write`]); the marker is cleared only
/// once the sidecar matches SQLCipher again — the sidecar was replaced, or the
/// write changed nothing. A marker left behind by a crash or a failed replace
/// makes the next open rebuild from SQLCipher.
pub(crate) struct ReactionIndex {
    store: Mutex<ReactionStore>,
    suppressed: Mutex<HashSet<EventId>>,
    persist: Option<ReactionPersist>,
    /// The open-time rebuild failed, so the in-memory store may be missing
    /// rows SQLCipher holds: keep the dirty marker until a later open rebuilds.
    rebuild_pending: std::sync::atomic::AtomicBool,
}

impl ReactionIndex {
    pub(crate) fn in_memory() -> Self {
        Self {
            store: Mutex::new(ReactionStore::default()),
            suppressed: Mutex::new(HashSet::new()),
            persist: None,
            rebuild_pending: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// Load the sealed sidecar beside `db_path`. The bool is true when it must
    /// be rebuilt from SQLCipher (missing, dirty, plaintext v1, wrong key).
    pub(crate) fn open(db_path: &Path, db_key: &[u8; 32]) -> (Self, bool) {
        let key = ReactionStoreKey::derive(db_key);
        let needs_rebuild = reaction_store_needs_rebuild(db_path, &key);
        let store = if needs_rebuild {
            ReactionStore::default()
        } else {
            ReactionStore::load(&reaction_store_path_for_db(db_path), &key)
        };
        let index = Self {
            store: Mutex::new(store),
            suppressed: Mutex::new(HashSet::new()),
            persist: Some(ReactionPersist {
                db_path: db_path.to_path_buf(),
                key,
            }),
            rebuild_pending: std::sync::atomic::AtomicBool::new(false),
        };
        (index, needs_rebuild)
    }

    /// Install a store rebuilt from SQLCipher and persist it.
    pub(crate) fn install_rebuilt(&self, rebuilt: ReactionStore) {
        {
            let suppressed = self.suppressed.lock().unwrap();
            let mut rebuilt = rebuilt;
            for id in suppressed.iter() {
                rebuilt.remove_id(*id);
            }
            *self.store.lock().unwrap() = rebuilt;
        }
        self.rebuild_pending
            .store(false, std::sync::atomic::Ordering::Relaxed);
        self.persist();
    }

    /// The open-time rebuild could not read SQLCipher: serve what we have and
    /// leave the dirty marker for the next open to retry.
    pub(crate) fn mark_rebuild_failed(&self) {
        self.rebuild_pending
            .store(true, std::sync::atomic::Ordering::Relaxed);
        if let Some(p) = &self.persist {
            mark_reaction_store_dirty(&p.db_path);
        }
    }

    /// Set the dirty marker before an MDK write that may commit a kind-7. The
    /// guard restores the previous marker state on every exit path unless
    /// [`ReactionWriteGuard::commit_changed`] failed to persist.
    pub(crate) fn begin_write(&self) -> ReactionWriteGuard<'_> {
        let restore_clean = match &self.persist {
            Some(p) => {
                let was_dirty = reaction_store_is_dirty(&p.db_path);
                mark_reaction_store_dirty(&p.db_path);
                !was_dirty
            }
            None => false,
        };
        ReactionWriteGuard {
            index: self,
            restore_clean,
            keep_dirty: false,
        }
    }

    /// Insert without persisting. False for a duplicate `(sender, emoji)`, a
    /// known rumor id, or a suppressed (terminally failed) rumor.
    pub(crate) fn record(&self, group_id: &mdk_core::GroupId, reaction: ParsedReaction) -> bool {
        if self.is_suppressed(&reaction.id) {
            return false;
        }
        self.store.lock().unwrap().record(group_id, reaction)
    }

    /// Record rows found by a read of already-committed MDK rows, persisting
    /// once if any was new.
    pub(crate) fn record_all<I>(&self, group_id: &mdk_core::GroupId, reactions: I)
    where
        I: IntoIterator<Item = ParsedReaction>,
    {
        let mut inserted = false;
        for r in reactions {
            inserted |= self.record(group_id, r);
        }
        if inserted {
            self.persist();
        }
    }

    pub(crate) fn is_suppressed(&self, id: &EventId) -> bool {
        self.suppressed.lock().unwrap().contains(id)
    }

    /// Roll back a locally echoed kind-7 whose publish exhausted auto-retries,
    /// so a retry with a new rumor id can occupy the chip.
    pub(crate) fn suppress<I>(&self, ids: I)
    where
        I: IntoIterator<Item = EventId>,
    {
        let mut removed = false;
        {
            let mut suppressed = self.suppressed.lock().unwrap();
            let mut store = self.store.lock().unwrap();
            for id in ids {
                suppressed.insert(id);
                removed |= store.remove_id(id);
            }
        }
        if removed {
            self.persist();
        }
    }

    /// Drop a locally deleted group's rows. Returns whether anything changed.
    pub(crate) fn remove_group(&self, group_id: &mdk_core::GroupId) -> bool {
        self.store.lock().unwrap().remove_group(group_id)
    }

    /// Reactions on `targets`, minus suppressed rumors.
    pub(crate) fn for_targets(
        &self,
        group_id: &mdk_core::GroupId,
        targets: &HashSet<EventId>,
    ) -> Vec<ParsedReaction> {
        let mut out = self.store.lock().unwrap().for_targets(group_id, targets);
        out.retain(|r| !self.is_suppressed(&r.id));
        out
    }

    /// Replace the sidecar with the in-memory store. True when the sidecar now
    /// matches it (and the dirty marker was cleared).
    fn persist(&self) -> bool {
        let Some(p) = &self.persist else {
            return true;
        };
        mark_reaction_store_dirty(&p.db_path);
        let path = reaction_store_path_for_db(&p.db_path);
        let saved = self.store.lock().unwrap().save(&path, &p.key);
        match saved {
            Ok(())
                if !self
                    .rebuild_pending
                    .load(std::sync::atomic::Ordering::Relaxed) =>
            {
                clear_reaction_store_dirty(&p.db_path);
                true
            }
            Ok(()) => false,
            Err(err) => {
                tracing::warn!(%err, "reaction store persist failed");
                false
            }
        }
    }
}

/// See [`ReactionIndex::begin_write`].
pub(crate) struct ReactionWriteGuard<'a> {
    index: &'a ReactionIndex,
    /// The marker was clear before this write: clear it again on drop.
    restore_clean: bool,
    keep_dirty: bool,
}

impl ReactionWriteGuard<'_> {
    /// The write changed the in-memory store: replace the sidecar. When that
    /// fails the marker stays, so the next open rebuilds from SQLCipher.
    pub(crate) fn commit_changed(mut self) {
        if !self.index.persist() {
            self.keep_dirty = true;
        }
    }

    /// MDK may hold a kind-7 the index never saw: leave the marker set so the
    /// next open rebuilds from SQLCipher.
    pub(crate) fn keep_dirty(mut self) {
        self.keep_dirty = true;
    }
}

impl Drop for ReactionWriteGuard<'_> {
    fn drop(&mut self) {
        if self.restore_clean && !self.keep_dirty {
            if let Some(p) = &self.index.persist {
                clear_reaction_store_dirty(&p.db_path);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids() -> (EventId, EventId, PublicKey, PublicKey) {
        let a = Keys::generate().public_key();
        let b = Keys::generate().public_key();
        let parent = EventId::from_slice(&[0x11u8; 32]).expect("id");
        let other = EventId::from_slice(&[0x22u8; 32]).expect("id");
        (parent, other, a, b)
    }

    fn rx(id_seed: u8, target: EventId, sender: PublicKey, emoji: &str) -> ParsedReaction {
        ParsedReaction {
            id: EventId::from_slice(&[id_seed; 32]).expect("id"),
            target_id: target,
            sender,
            emoji: emoji.to_string(),
        }
    }

    #[test]
    fn reaction_tags_are_e_p_k() {
        let (parent, _, pk, _) = ids();
        let tags = reaction_tags(&parent, &pk);
        assert_eq!(tags[0].as_slice()[0], "e");
        assert_eq!(tags[0].as_slice()[1], parent.to_hex());
        assert_eq!(tags[1].as_slice()[0], "p");
        assert_eq!(tags[2].as_slice()[0], "k");
        assert_eq!(tags[2].as_slice()[1], "9");
        assert_eq!(parse_target_id(tags.iter()), Some(parent));
    }

    #[test]
    fn last_e_tag_is_the_target() {
        let (parent, other, pk, _) = ids();
        let tags = vec![
            Tag::event(other),
            Tag::from_standardized_without_cell(TagStandard::Event {
                event_id: parent,
                relay_url: None,
                marker: None,
                public_key: Some(pk),
                uppercase: false,
            }),
        ];
        assert_eq!(parse_target_id(tags.iter()), Some(parent));
    }

    #[test]
    fn normalize_rejects_empty_and_overlong() {
        assert!(normalize_emoji("  ").is_err());
        assert!(normalize_emoji("").is_err());
        assert!(normalize_emoji("+").is_err());
        assert!(normalize_emoji("-").is_err());
        assert_eq!(normalize_emoji(" 👍 ").unwrap(), "👍");
        assert!(normalize_emoji(&"😀".repeat(17)).is_err());
    }

    #[test]
    fn multi_emoji_same_sender_are_independent_chips() {
        let (parent, _, me, other) = ids();
        let reactions = vec![
            rx(1, parent, me, "👍"),
            rx(2, parent, me, "🔥"),
            rx(3, parent, other, "👍"),
        ];
        let tallies = tallies_for_target(&reactions, &parent, &me);
        assert_eq!(tallies.len(), 2);
        assert_eq!(tallies[0].emoji, "👍");
        assert_eq!(tallies[0].count, 2);
        assert!(tallies[0].mine);
        assert_eq!(tallies[1].emoji, "🔥");
        assert_eq!(tallies[1].count, 1);
        assert!(tallies[1].mine);
    }

    #[test]
    fn duplicate_kind7_from_same_sender_does_not_inflate_count() {
        let (parent, _, me, _) = ids();
        let reactions = vec![rx(1, parent, me, "❤️"), rx(2, parent, me, "❤️")];
        let tallies = tallies_for_target(&reactions, &parent, &me);
        assert_eq!(tallies.len(), 1);
        assert_eq!(tallies[0].count, 1);
        assert!(tallies[0].mine);
    }

    #[test]
    fn other_target_is_ignored() {
        let (parent, other, me, _) = ids();
        let reactions = vec![rx(1, other, me, "👍")];
        assert!(tallies_for_target(&reactions, &parent, &me).is_empty());
    }

    #[test]
    fn attach_tallies_is_window_local() {
        let (parent, other, me, _) = ids();
        let mut messages = vec![ChatMessage {
            id: parent,
            group_id: mdk_core::GroupId::from_slice(&[0u8; 32]),
            sender: me,
            classification: crate::marmot::MessageClassification::Text,
            content: "hi".into(),
            created_at: Timestamp::now(),
            mine: true,
            delivery_state: crate::marmot::DeliveryState::Sent,
            media: Vec::new(),
            sticker_ref: None,
            reply: None,
            reactions: Vec::new(),
        }];
        let reactions = vec![rx(1, parent, me, "👍"), rx(2, other, me, "🔥")];
        attach_tallies(&mut messages, &reactions, me);
        assert_eq!(messages[0].reactions.len(), 1);
        assert_eq!(messages[0].reactions[0].emoji, "👍");
    }

    #[test]
    fn store_lookup_is_target_keyed() {
        let (parent, other, me, _) = ids();
        let group = mdk_core::GroupId::from_slice(&[0u8; 32]);
        let mut store = ReactionStore::default();
        store.record(&group, rx(1, parent, me, "👍"));
        store.record(&group, rx(2, other, me, "🔥"));
        let mut targets = HashSet::new();
        targets.insert(parent);
        let found = store.for_targets(&group, &targets);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].emoji, "👍");
    }

    #[test]
    fn store_compacts_duplicate_sender_emoji() {
        let (parent, _, me, _) = ids();
        let group = mdk_core::GroupId::from_slice(&[0xABu8; 16]);
        let mut store = ReactionStore::default();
        assert!(store.record(&group, rx(1, parent, me, "👍")));
        assert!(!store.record(&group, rx(2, parent, me, "👍")));
        let mut targets = HashSet::new();
        targets.insert(parent);
        let found = store.for_targets(&group, &targets);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].id, rx(1, parent, me, "👍").id);
    }

    #[test]
    fn store_remove_id_allows_retry_after_terminal_failure() {
        let (parent, _, me, _) = ids();
        let group = mdk_core::GroupId::from_slice(&[0xABu8; 16]);
        let mut store = ReactionStore::default();
        store.record(&group, rx(1, parent, me, "👍"));
        assert!(store.remove_id(rx(1, parent, me, "👍").id));
        assert!(store.record(&group, rx(2, parent, me, "👍")));
        let mut targets = HashSet::new();
        targets.insert(parent);
        let found = store.for_targets(&group, &targets);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].id, rx(2, parent, me, "👍").id);
    }

    #[test]
    fn store_remove_group_drops_that_group_only() {
        let (parent, other, me, _) = ids();
        let group_a = mdk_core::GroupId::from_slice(&[0xABu8; 16]);
        let group_b = mdk_core::GroupId::from_slice(&[0xCDu8; 16]);
        let mut store = ReactionStore::default();
        store.record(&group_a, rx(1, parent, me, "👍"));
        store.record(&group_b, rx(2, other, me, "🔥"));
        assert!(store.remove_group(&group_a));
        let mut targets = HashSet::new();
        targets.insert(parent);
        assert!(store.for_targets(&group_a, &targets).is_empty());
        targets.insert(other);
        assert_eq!(store.for_targets(&group_b, &targets).len(), 1);
    }

    #[test]
    fn store_round_trips_through_sidecar() {
        let (parent, _, me, _) = ids();
        // MLS GroupId is 16 bytes. Filtering `len() != 32` on load would pass a
        // 32-byte fixture here and drop every real group on reopen.
        let group = mdk_core::GroupId::from_slice(&[0xABu8; 16]);
        let mut store = ReactionStore::default();
        store.record(&group, rx(1, parent, me, "👍"));
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("marmot.sqlite.sonar-reactions.json");
        let key = ReactionStoreKey::derive(&[7u8; 32]);
        store.save(&path, &key).expect("save");
        store.record(&group, rx(2, parent, me, "🔥"));
        store.save(&path, &key).expect("replace existing sidecar");
        let loaded = ReactionStore::load(&path, &key);
        let mut targets = HashSet::new();
        targets.insert(parent);
        let found = loaded.for_targets(&group, &targets);
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].emoji, "👍");
        assert_eq!(found[0].sender, me);
    }

    #[test]
    fn needs_rebuild_when_sidecar_is_valid_but_dirty() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("marmot.sqlite");
        let sidecar = reaction_store_path_for_db(&db_path);
        let key = ReactionStoreKey::derive(&[7u8; 32]);
        ReactionStore::default()
            .save(&sidecar, &key)
            .expect("valid sidecar");
        assert!(
            !reaction_store_needs_rebuild(&db_path, &key),
            "valid sidecar with no dirty marker must be trusted"
        );
        mark_reaction_store_dirty(&db_path);
        assert!(
            reaction_store_needs_rebuild(&db_path, &key),
            "a dirty marker must force rebuild even when the sidecar is valid"
        );
        clear_reaction_store_dirty(&db_path);
        assert!(!reaction_store_needs_rebuild(&db_path, &key));
    }

    #[test]
    fn sidecar_is_sealed_not_plaintext() {
        let (parent, _, me, _) = ids();
        let group = mdk_core::GroupId::from_slice(&[0xABu8; 16]);
        let mut store = ReactionStore::default();
        store.record(&group, rx(1, parent, me, "👍"));
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("marmot.sqlite");
        let sidecar = reaction_store_path_for_db(&db_path);
        let key = ReactionStoreKey::derive(&[7u8; 32]);
        store.save(&sidecar, &key).expect("save");

        // Nothing a reader of the app container could use: no group id,
        // target id, reactor pubkey or emoji in the clear.
        let bytes = fs::read(&sidecar).expect("sidecar");
        let haystack = String::from_utf8_lossy(&bytes);
        for needle in [
            hex::encode(group.as_slice()),
            parent.to_hex(),
            me.to_hex(),
            "👍".to_string(),
            "entries".to_string(),
        ] {
            assert!(!haystack.contains(&needle), "sidecar leaks {needle}");
        }

        // Only the DB key opens it; anything else is rebuilt, never trusted.
        let other = ReactionStoreKey::derive(&[8u8; 32]);
        assert!(reaction_store_needs_rebuild(&db_path, &other));
        let mut targets = HashSet::new();
        targets.insert(parent);
        assert!(ReactionStore::load(&sidecar, &other)
            .for_targets(&group, &targets)
            .is_empty());
        assert_eq!(
            ReactionStore::load(&sidecar, &key)
                .for_targets(&group, &targets)
                .len(),
            1
        );
    }

    #[test]
    fn plaintext_v1_sidecar_is_rebuilt_not_trusted() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("marmot.sqlite");
        let sidecar = reaction_store_path_for_db(&db_path);
        fs::write(&sidecar, r#"{"version":1,"entries":[]}"#).expect("v1 sidecar");
        let key = ReactionStoreKey::derive(&[7u8; 32]);
        assert!(reaction_store_needs_rebuild(&db_path, &key));
    }

    #[test]
    fn write_guard_restores_a_clean_marker_when_nothing_changed() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("marmot.sqlite");
        let (index, _) = ReactionIndex::open(&db_path, &[7u8; 32]);
        index.install_rebuilt(ReactionStore::default());
        assert!(!reaction_store_is_dirty(&db_path));
        {
            let _write = index.begin_write();
            assert!(
                reaction_store_is_dirty(&db_path),
                "marked before the MDK write"
            );
            // An early return (MDK error, duplicate kind-7) drops the guard.
        }
        assert!(
            !reaction_store_is_dirty(&db_path),
            "a write that changed nothing must not force a rebuild on every open"
        );
        index.begin_write().keep_dirty();
        assert!(
            reaction_store_is_dirty(&db_path),
            "keep_dirty leaves the marker for the next open"
        );
    }
}
