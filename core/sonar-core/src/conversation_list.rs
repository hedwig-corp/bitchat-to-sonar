//! The Marmot half of the Messages list, computed once in core.
//!
//! Both apps used to build these rows themselves from `groups()` +
//! `conversation_summaries()`: iOS in `SonarAppStore.buildHomeDMRows`
//! (`snCanonicalDirectMarmotGroups`, `hasUnreadMarmotMessage(in:)`), Compose in
//! `SonarAppState` (`dedupeDirectMarmotChats`, the presenter's unread sum). The
//! two copies drifted (R-052). This module is the one copy:
//!
//! - one row per conversation: duplicate direct groups with the same
//!   counterpart fold into one row (R-003);
//! - `group_ids` is the folded set. Unread is summed over it, and hosts
//!   mark exactly it read when the row opens, so a badge can always be
//!   cleared by opening its row;
//! - Note to Self is never unread and sorts first;
//! - rows are ordered newest first with a stable tie-break and paged by a
//!   cursor, so a host can paint a bounded window.
//!
//! What stays in the hosts, because core does not own it: kind-0 display
//! names, mute, verification, pending "setting up" rows, blocked senders, and
//! the Bluetooth fold (mesh state lives in the Swift/Kotlin engines). Hosts
//! overlay those on these rows.
//!
//! Everything here is local: the summary index and the MLS group table. No
//! relay work, so the list stays local-first (Signal-Comparable Performance
//! Rule).

use std::cmp::Ordering;
use std::collections::HashMap;

use crate::conversation_index::ConversationSummary;

/// What kind of conversation a row is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ConversationListKind {
    /// A 1:1: exactly one member besides us. Duplicates fold into one row.
    Direct,
    /// Any other group (several members, or a solo group that is not Note to
    /// Self).
    Group,
    /// This account's Note to Self group. Never unread; pinned first.
    NoteToSelf,
}

/// The shape of one MLS group, from its member list. Cached by the client per
/// `(group id, epoch)`: membership only changes with a commit, and every
/// commit moves the epoch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupShape {
    pub group_id_hex: String,
    pub name: String,
    pub kind: ConversationListKind,
    /// The other member's pubkey hex, for [`ConversationListKind::Direct`].
    pub counterpart_hex: Option<String>,
}

impl GroupShape {
    /// Classify a group from its members. `me_hex` and `members_hex` are
    /// lowercase 64-hex pubkeys. The rule matches what both apps folded on
    /// before this moved to core: exactly one member that is not us makes a
    /// direct chat, whatever the group's name or description.
    pub fn classify(
        group_id_hex: &str,
        name: &str,
        members_hex: &[String],
        me_hex: &str,
        is_note_to_self: bool,
    ) -> Self {
        let mut others: Vec<&String> = members_hex
            .iter()
            .filter(|m| !m.is_empty() && m.as_str() != me_hex)
            .collect();
        others.sort();
        others.dedup();
        let (kind, counterpart_hex) = if is_note_to_self {
            (ConversationListKind::NoteToSelf, None)
        } else if others.len() == 1 {
            (ConversationListKind::Direct, Some(others[0].clone()))
        } else {
            (ConversationListKind::Group, None)
        };
        Self {
            group_id_hex: group_id_hex.to_string(),
            name: name.to_string(),
            kind,
            counterpart_hex,
        }
    }
}

/// One Messages-list row: a conversation, with every group folded into it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationListRow {
    /// The group the row opens and sends to: the newest group in the set
    /// (lowest id on a tie), so both apps pick the same one.
    pub conversation_id: String,
    pub kind: ConversationListKind,
    /// Every group folded into the row, `conversation_id` first, then newest
    /// first. Unread is summed over it and mark-read clears all of it.
    pub group_ids: Vec<String>,
    /// The other member's pubkey hex for a direct chat.
    pub counterpart_hex: Option<String>,
    /// The group's MLS name (empty for most 1:1s). Hosts overlay kind-0 names.
    pub name: String,
    /// Preview of the newest message across the set (already classified and
    /// labelled by the index, see `index_preview`).
    pub latest_content: String,
    /// Sender pubkey hex of that message.
    pub latest_sender_hex: String,
    pub latest_at_secs: u64,
    pub latest_mine: bool,
    /// The group that newest message is in.
    pub latest_group_id: String,
    pub message_count: u64,
    /// Sum of unread over `group_ids`; always 0 for Note to Self.
    pub unread_count: u64,
    /// Changes whenever any folded group's summary changes or the set changes.
    /// A host cache key: equal versions mean an unchanged row.
    pub version: u64,
}

/// Position after which a page starts: the last row of the previous page.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationListCursor {
    pub latest_at_secs: u64,
    pub conversation_id: String,
    /// Whether that row was Note to Self (sorted before every other row).
    pub pinned: bool,
}

impl ConversationListRow {
    pub fn cursor(&self) -> ConversationListCursor {
        ConversationListCursor {
            latest_at_secs: self.latest_at_secs,
            conversation_id: self.conversation_id.clone(),
            pinned: self.kind == ConversationListKind::NoteToSelf,
        }
    }
}

/// List order: Note to Self first, then newest first, then conversation id.
fn order(
    a_pinned: bool,
    a_latest: u64,
    a_id: &str,
    b_pinned: bool,
    b_latest: u64,
    b_id: &str,
) -> Ordering {
    b_pinned
        .cmp(&a_pinned)
        .then(b_latest.cmp(&a_latest))
        .then(a_id.cmp(b_id))
}

fn row_order(a: &ConversationListRow, b: &ConversationListRow) -> Ordering {
    order(
        a.kind == ConversationListKind::NoteToSelf,
        a.latest_at_secs,
        &a.conversation_id,
        b.kind == ConversationListKind::NoteToSelf,
        b.latest_at_secs,
        &b.conversation_id,
    )
}

/// Build every row from the groups' shapes and the summary index.
///
/// `shapes` is every active group. A group with no summary row (just created,
/// index not yet written) still gets a row, with an empty preview. O(groups):
/// one pass to bucket direct groups by counterpart, one sort.
pub fn build_rows(
    shapes: &[GroupShape],
    summaries: &HashMap<String, ConversationSummary>,
) -> Vec<ConversationListRow> {
    // Direct groups bucket by counterpart; everything else is its own row.
    let mut buckets: Vec<Vec<&GroupShape>> = Vec::new();
    let mut by_counterpart: HashMap<&str, usize> = HashMap::new();
    for shape in shapes {
        match (&shape.kind, &shape.counterpart_hex) {
            (ConversationListKind::Direct, Some(peer)) => {
                if let Some(&i) = by_counterpart.get(peer.as_str()) {
                    buckets[i].push(shape);
                } else {
                    by_counterpart.insert(peer.as_str(), buckets.len());
                    buckets.push(vec![shape]);
                }
            }
            _ => buckets.push(vec![shape]),
        }
    }

    let latest_of = |gid: &str| summaries.get(gid).map_or(0, |s| s.latest_at_secs);
    let mut rows: Vec<ConversationListRow> = buckets
        .into_iter()
        .map(|mut set| {
            // Newest first, lowest id on a tie: set[0] is the row's group.
            set.sort_by(|a, b| {
                latest_of(&b.group_id_hex)
                    .cmp(&latest_of(&a.group_id_hex))
                    .then(a.group_id_hex.cmp(&b.group_id_hex))
            });
            let head = set[0];
            let note_to_self = head.kind == ConversationListKind::NoteToSelf;
            let mut row = ConversationListRow {
                conversation_id: head.group_id_hex.clone(),
                kind: head.kind,
                group_ids: set.iter().map(|s| s.group_id_hex.clone()).collect(),
                counterpart_hex: head.counterpart_hex.clone(),
                name: head.name.clone(),
                latest_content: String::new(),
                latest_sender_hex: String::new(),
                latest_at_secs: 0,
                latest_mine: false,
                latest_group_id: head.group_id_hex.clone(),
                message_count: 0,
                unread_count: 0,
                // The set's size is part of the key: folding in a new, empty
                // duplicate must still change the row.
                version: set.len() as u64,
            };
            for shape in &set {
                if row.name.is_empty() && !shape.name.is_empty() {
                    row.name = shape.name.clone();
                }
                let Some(summary) = summaries.get(&shape.group_id_hex) else {
                    continue;
                };
                row.message_count += summary.message_count;
                if !note_to_self {
                    row.unread_count += summary.unread_count;
                }
                row.version = row
                    .version
                    .wrapping_mul(1_000_003)
                    .wrapping_add(summary.version);
                // `set` is newest first, so the first summary with a message
                // is the preview.
                if row.latest_group_id == head.group_id_hex
                    && row.latest_at_secs == 0
                    && summary.latest_at_secs > 0
                {
                    row.latest_content = summary.latest_content.clone();
                    row.latest_sender_hex = summary.latest_sender.clone();
                    row.latest_at_secs = summary.latest_at_secs;
                    row.latest_mine = summary.latest_mine;
                    row.latest_group_id = summary.group_id_hex.clone();
                }
            }
            row
        })
        .collect();
    rows.sort_by(row_order);
    rows
}

/// One page of `rows` (already in list order): up to `limit` rows after
/// `after`. `limit == 0` means no limit.
pub fn page(
    rows: Vec<ConversationListRow>,
    limit: usize,
    after: Option<&ConversationListCursor>,
) -> Vec<ConversationListRow> {
    let start = match after {
        None => 0,
        Some(cursor) => rows.partition_point(|row| {
            order(
                row.kind == ConversationListKind::NoteToSelf,
                row.latest_at_secs,
                &row.conversation_id,
                cursor.pinned,
                cursor.latest_at_secs,
                &cursor.conversation_id,
            ) != Ordering::Greater
        }),
    };
    let rest = rows.into_iter().skip(start);
    if limit == 0 {
        rest.collect()
    } else {
        rest.take(limit).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ME: &str = "aa";
    const SARA: &str = "bb";
    const LUCA: &str = "cc";

    fn shape(gid: &str, name: &str, members: &[&str]) -> GroupShape {
        let members: Vec<String> = members.iter().map(|m| m.to_string()).collect();
        GroupShape::classify(gid, name, &members, ME, false)
    }

    fn summary(gid: &str, latest: u64, unread: u64, version: u64) -> ConversationSummary {
        ConversationSummary {
            group_id_hex: gid.into(),
            name: String::new(),
            latest_content: format!("msg in {gid}"),
            latest_sender: SARA.into(),
            latest_at_secs: latest,
            latest_mine: false,
            message_count: 1,
            unread_count: unread,
            version,
        }
    }

    fn index(items: &[ConversationSummary]) -> HashMap<String, ConversationSummary> {
        items
            .iter()
            .map(|s| (s.group_id_hex.clone(), s.clone()))
            .collect()
    }

    #[test]
    fn classify_matches_the_hosts_fold_rule() {
        assert_eq!(shape("g", "", &[ME, SARA]).kind, ConversationListKind::Direct);
        assert_eq!(shape("g", "", &[ME, SARA]).counterpart_hex.as_deref(), Some(SARA));
        // A named 2-member group is still a 1:1 for the list (iOS
        // snDirectMarmotPeerKey ignores the name).
        assert_eq!(shape("g", "trip", &[ME, SARA]).kind, ConversationListKind::Direct);
        assert_eq!(shape("g", "x", &[ME, SARA, LUCA]).kind, ConversationListKind::Group);
        // A solo group that is not the account's Note to Self is a group.
        assert_eq!(shape("g", "Note to Self", &[ME]).kind, ConversationListKind::Group);
        let nts = GroupShape::classify("g", "Note to Self", &[ME.into()], ME, true);
        assert_eq!(nts.kind, ConversationListKind::NoteToSelf);
    }

    /// R-003 + R-052 in one row: duplicate 1:1 groups are one row, whose
    /// unread is the sum over the set that mark-read clears.
    #[test]
    fn duplicate_direct_groups_fold_into_one_row_that_sums_unread() {
        let shapes = [
            shape("g1", "", &[ME, SARA]),
            shape("g2", "", &[ME, SARA]),
            shape("g3", "", &[ME, LUCA]),
        ];
        let rows = build_rows(
            &shapes,
            &index(&[summary("g1", 100, 2, 1), summary("g2", 300, 1, 1), summary("g3", 200, 0, 1)]),
        );
        assert_eq!(rows.len(), 2);
        let sara = &rows[0];
        assert_eq!(sara.conversation_id, "g2", "the newest group is the row's group");
        assert_eq!(sara.group_ids, vec!["g2".to_string(), "g1".to_string()]);
        assert_eq!(sara.unread_count, 3);
        assert_eq!(sara.latest_content, "msg in g2");
        assert_eq!(sara.latest_group_id, "g2");
        assert_eq!(sara.message_count, 2);
        assert_eq!(rows[1].conversation_id, "g3");
    }

    #[test]
    fn note_to_self_is_pinned_first_and_never_unread() {
        let nts = GroupShape::classify("g0", "Note to Self", &[ME.into()], ME, true);
        let shapes = [shape("g1", "", &[ME, SARA]), nts];
        let rows = build_rows(&shapes, &index(&[summary("g1", 500, 4, 1), summary("g0", 10, 3, 1)]));
        assert_eq!(rows[0].kind, ConversationListKind::NoteToSelf);
        assert_eq!(rows[0].unread_count, 0);
        assert_eq!(rows[1].unread_count, 4);
    }

    #[test]
    fn a_group_without_a_summary_still_gets_a_row() {
        let rows = build_rows(&[shape("g9", "New group", &[ME, SARA, LUCA])], &HashMap::new());
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].name, "New group");
        assert_eq!(rows[0].latest_at_secs, 0);
        assert_eq!(rows[0].latest_group_id, "g9");
    }

    #[test]
    fn equal_timestamps_order_by_id_so_both_apps_agree() {
        let shapes = [shape("gb", "", &[ME, SARA]), shape("ga", "", &[ME, LUCA])];
        let rows = build_rows(&shapes, &index(&[summary("gb", 100, 0, 1), summary("ga", 100, 0, 1)]));
        let ids: Vec<_> = rows.iter().map(|r| r.conversation_id.as_str()).collect();
        assert_eq!(ids, vec!["ga", "gb"]);
    }

    #[test]
    fn version_changes_when_a_folded_group_changes_or_joins() {
        let one = [shape("g1", "", &[ME, SARA])];
        let two = [shape("g1", "", &[ME, SARA]), shape("g2", "", &[ME, SARA])];
        let base = build_rows(&one, &index(&[summary("g1", 100, 0, 1)]))[0].version;
        let bumped = build_rows(&one, &index(&[summary("g1", 100, 0, 2)]))[0].version;
        let joined = build_rows(&two, &index(&[summary("g1", 100, 0, 1)]))[0].version;
        assert_ne!(base, bumped);
        assert_ne!(base, joined);
    }

    #[test]
    fn pages_walk_every_row_exactly_once() {
        let nts = GroupShape::classify("g0", "Note to Self", &[ME.into()], ME, true);
        let mut shapes = vec![nts];
        let mut sums = vec![summary("g0", 1, 0, 1)];
        for i in 1..=7u64 {
            let gid = format!("g{i}");
            let peer = format!("p{i}");
            shapes.push(GroupShape::classify(&gid, "", &[ME.into(), peer], ME, false));
            // Two rows share each timestamp, so the tie-break is exercised.
            sums.push(summary(&gid, 100 * (i / 2), 0, 1));
        }
        let all = build_rows(&shapes, &index(&sums));
        let mut walked = Vec::new();
        let mut after: Option<ConversationListCursor> = None;
        loop {
            let chunk = page(all.clone(), 3, after.as_ref());
            if chunk.is_empty() {
                break;
            }
            after = Some(chunk.last().unwrap().cursor());
            walked.extend(chunk);
        }
        assert_eq!(walked, all);
        assert_eq!(page(all.clone(), 0, None).len(), 8);
    }
}
