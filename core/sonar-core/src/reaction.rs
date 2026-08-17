//! NIP-25 kind-7 reactions as Marmot application rumors.
//!
//! White Noise / Marmot carry unsigned kind-7 events *inside* MLS (kind 445),
//! not as public relay likes. This module is the only place that builds or
//! parses that rumor so a later MDK `reactToMessage` swap can sit behind the
//! same `send_reaction` / tally FFI.

use std::collections::{HashMap, HashSet};

use mdk_storage_traits::messages::types::Message as StoredMessage;
use nostr::prelude::*;

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
}
