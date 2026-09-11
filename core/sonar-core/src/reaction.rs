//! NIP-25 kind-7 reactions as Marmot application rumors.
//!
//! White Noise / Marmot carry unsigned kind-7 events *inside* MLS (kind 445),
//! not as public relay likes. This module is the only place that builds or
//! parses that rumor so a later MDK `reactToMessage` swap can sit behind the
//! same `send_reaction` / tally FFI.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use mdk_storage_traits::messages::types::Message as StoredMessage;
use nostr::prelude::*;
use serde::{Deserialize, Serialize};

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
#[derive(Default)]
pub struct ReactionStore {
    by_target: HashMap<(Vec<u8>, EventId), Vec<ParsedReaction>>,
}

pub(crate) const REACTION_STORE_FILE_SUFFIX: &str = ".sonar-reactions.json";
const REACTION_STORE_VERSION: u32 = 1;

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

/// True when the sidecar is missing or unreadable, so the derived index must
/// be rebuilt from the encrypted DB (account restore, first open, corrupt file).
pub(crate) fn reaction_store_needs_rebuild(path: &Path) -> bool {
    let Ok(bytes) = fs::read(path) else {
        return true;
    };
    let Ok(disk) = serde_json::from_slice::<ReactionStoreDisk>(&bytes) else {
        return true;
    };
    disk.version != REACTION_STORE_VERSION
}

/// Drop the derived sidecar so a restore cannot keep post-backup ghost chips.
pub(crate) fn remove_reaction_store_files(db_path: &Path) {
    let path = reaction_store_path_for_db(db_path);
    let tmp = reaction_store_tmp_path(&path);
    let _ = fs::remove_file(&path);
    let _ = fs::remove_file(&tmp);
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
    pub fn load(path: Option<&Path>) -> Self {
        let Some(path) = path else {
            return Self::default();
        };
        let Ok(bytes) = fs::read(path) else {
            return Self::default();
        };
        let Ok(disk) = serde_json::from_slice::<ReactionStoreDisk>(&bytes) else {
            return Self::default();
        };
        if disk.version != REACTION_STORE_VERSION {
            return Self::default();
        }
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

    pub fn save(&self, path: &Path) -> Result<()> {
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
        let bytes = serde_json::to_vec(&disk)?;
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
        store.save(&path).expect("save");
        store.record(&group, rx(2, parent, me, "🔥"));
        store.save(&path).expect("replace existing sidecar");
        let loaded = ReactionStore::load(Some(&path));
        let mut targets = HashSet::new();
        targets.insert(parent);
        let found = loaded.for_targets(&group, &targets);
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].emoji, "👍");
        assert_eq!(found[0].sender, me);
    }
}
