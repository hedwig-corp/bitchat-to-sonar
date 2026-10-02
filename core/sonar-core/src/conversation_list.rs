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
//! Each row is a screen model, not raw data: a resolved title (the
//! counterpart's cached kind-0 name for a 1:1) and a semantic preview the
//! hosts only localize. What stays in the hosts, because core does not own
//! it: mute, verification, pending "setting up" rows, blocked senders, and the
//! Bluetooth fold (mesh state lives in the Swift/Kotlin engines). Hosts
//! overlay those on these rows.
//!
//! Everything here is local: the summary index and the MLS group table. No
//! relay work, so the list stays local-first (Signal-Comparable Performance
//! Rule).

use std::cmp::Ordering;
use std::collections::HashMap;

use crate::conversation_index::ConversationSummary;
use crate::notification::{classify_content, NotificationKind};

/// What a row's newest message is, for the hosts to word in their language.
/// The one decoder for chat-list previews on both apps.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConversationPreview {
    /// No message yet.
    Empty,
    /// Plain text, shown as is.
    Text(String),
    /// One or more photos (a caption, if any, arrives as `Text`).
    Photos(u32),
    Videos(u32),
    VoiceNote,
    /// A file attachment; the name when the sender gave one.
    File(String),
    Sticker,
    VoiceCall,
    Nudge,
    Payment,
    /// Machine JSON (bots, interop control); never shown raw.
    JsonPayload,
}

/// Decode a stored `(latest_kind, latest_content)` pair. Rows written before
/// `latest_kind` existed carry an empty kind and an English label from
/// `index_preview`; those labels are mapped back so old chats keep a
/// localizable preview.
pub fn preview_for(kind: &str, content: &str) -> ConversationPreview {
    let count = |rest: &str| rest.parse::<u32>().unwrap_or(1).max(1);
    match kind {
        "sticker" => return ConversationPreview::Sticker,
        "voice" => return ConversationPreview::VoiceNote,
        "json" => return ConversationPreview::JsonPayload,
        "file" => {
            let name = if content == "File" { String::new() } else { content.to_string() };
            return ConversationPreview::File(name);
        }
        k if k.starts_with("photo:") => return ConversationPreview::Photos(count(&k[6..])),
        k if k.starts_with("video:") => return ConversationPreview::Videos(count(&k[6..])),
        _ => {}
    }
    if content.is_empty() {
        return ConversationPreview::Empty;
    }
    match classify_content(content) {
        NotificationKind::Call => return ConversationPreview::VoiceCall,
        NotificationKind::Payment => return ConversationPreview::Payment,
        NotificationKind::Trill => return ConversationPreview::Nudge,
        _ => {}
    }
    if kind.is_empty() {
        // Legacy row: undo index_preview's English labels.
        match content {
            "Sticker" => return ConversationPreview::Sticker,
            "Photo" => return ConversationPreview::Photos(1),
            "Video" => return ConversationPreview::Videos(1),
            "Voice note" => return ConversationPreview::VoiceNote,
            "File" => return ConversationPreview::File(String::new()),
            "JSON payload" => return ConversationPreview::JsonPayload,
            _ => {}
        }
        if let Some(n) = content.strip_suffix(" photos").and_then(|n| n.parse::<u32>().ok()) {
            return ConversationPreview::Photos(n);
        }
        if let Some(n) = content.strip_suffix(" videos").and_then(|n| n.parse::<u32>().ok()) {
            return ConversationPreview::Videos(n);
        }
    }
    ConversationPreview::Text(content.to_string())
}

/// One transcript page across a conversation's groups (see
/// `SonarClient::conversation_cursor_page`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ConversationPage {
    /// Newest first, `(created_at DESC, id DESC)`.
    pub rows: Vec<crate::marmot::ChatMessage>,
    /// More rows exist past the last one.
    pub has_more: bool,
}

/// Merge the per-group answers of one cursor read: one order, one copy of
/// each event id, the first `limit` rows. `has_more` when anything was cut.
pub fn merge_conversation_page(
    mut rows: Vec<crate::marmot::ChatMessage>,
    limit: usize,
) -> (Vec<crate::marmot::ChatMessage>, bool) {
    rows.sort_by(|a, b| {
        b.created_at
            .as_secs()
            .cmp(&a.created_at.as_secs())
            .then_with(|| b.id.cmp(&a.id))
    });
    rows.dedup_by(|later, earlier| later.id == earlier.id);
    let has_more = rows.len() > limit;
    rows.truncate(limit);
    (rows, has_more)
}

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
    /// The group's MLS name (empty for most 1:1s).
    pub name: String,
    /// The title to show: the counterpart's cached display name for a 1:1,
    /// else the group name. `None` means the host shows its localized
    /// fallback ("Note to Self", "Group chat", or the short npub of
    /// `counterpart_hex`).
    pub title: Option<String>,
    /// The newest message, ready to localize.
    pub preview: ConversationPreview,
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

/// What opening a conversation hands the transcript (see
/// `SonarClient::open_conversation`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationOpen {
    /// Every group folded into the conversation, row group first.
    pub group_ids: Vec<String>,
    /// Unread at the moment of opening (before it was marked read).
    pub unread_count: u64,
    /// The oldest unread message: the divider goes above it. `None` when
    /// nothing was unread.
    pub unread_anchor_id: Option<nostr::EventId>,
    /// Newest message second across the set: a host's transcript is not
    /// complete until it holds a row this new.
    pub newest_at_secs: u64,
}

/// The oldest unread message among `rows` (any order; sorted here newest
/// first by `(created_at, id)`): the `unread`-th visible message from someone
/// else, or the oldest such message read when there are fewer.
pub fn unread_anchor(
    rows: &mut [crate::marmot::ChatMessage],
    unread: u64,
) -> Option<nostr::EventId> {
    rows.sort_by(|a, b| b.created_at.cmp(&a.created_at).then(b.id.cmp(&a.id)));
    let mut counted = 0u64;
    let mut last = None;
    for row in rows.iter() {
        if row.mine || !row.classification.is_transcript_visible() {
            continue;
        }
        counted += 1;
        last = Some(row.id);
        if counted == unread {
            break;
        }
    }
    last
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
    build_rows_with_names(shapes, summaries, &HashMap::new())
}

/// [`build_rows`] with display names (pubkey hex → name) for titling 1:1s.
pub fn build_rows_with_names(
    shapes: &[GroupShape],
    summaries: &HashMap<String, ConversationSummary>,
    names: &HashMap<String, String>,
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
                title: None,
                preview: ConversationPreview::Empty,
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
                    row.preview = preview_for(&summary.latest_kind, &summary.latest_content);
                    row.latest_content = summary.latest_content.clone();
                    row.latest_sender_hex = summary.latest_sender.clone();
                    row.latest_at_secs = summary.latest_at_secs;
                    row.latest_mine = summary.latest_mine;
                    row.latest_group_id = summary.group_id_hex.clone();
                }
            }
            row.title = match row.kind {
                ConversationListKind::NoteToSelf => None,
                ConversationListKind::Direct => row
                    .counterpart_hex
                    .as_ref()
                    .and_then(|peer| names.get(peer))
                    .cloned()
                    .or_else(|| (!row.name.is_empty()).then(|| row.name.clone())),
                ConversationListKind::Group => (!row.name.is_empty()).then(|| row.name.clone()),
            };
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
            latest_kind: "text".into(),
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

    #[test]
    fn previews_are_semantic_for_new_and_legacy_rows() {
        use ConversationPreview as P;
        assert_eq!(preview_for("text", "hello"), P::Text("hello".into()));
        assert_eq!(preview_for("photo:3", "3 photos"), P::Photos(3));
        assert_eq!(preview_for("video:1", "Video"), P::Videos(1));
        assert_eq!(preview_for("voice", "Voice note"), P::VoiceNote);
        assert_eq!(preview_for("file", "report.pdf"), P::File("report.pdf".into()));
        assert_eq!(preview_for("sticker", "Sticker"), P::Sticker);
        assert_eq!(preview_for("json", "JSON payload"), P::JsonPayload);
        assert_eq!(preview_for("text", "⚡TRILL|1|abc123"), P::Nudge);
        assert_eq!(preview_for("", ""), P::Empty);
        // Legacy rows (no kind): English labels map back.
        assert_eq!(preview_for("", "2 photos"), P::Photos(2));
        assert_eq!(preview_for("", "Voice note"), P::VoiceNote);
        // But a NEW row whose text happens to be "Photo" stays text.
        assert_eq!(preview_for("text", "Photo"), P::Text("Photo".into()));
    }

    #[test]
    fn titles_come_from_the_counterparts_name_then_the_group_name() {
        let nts = GroupShape::classify("g0", "Note to Self", &[ME.into()], ME, true);
        let shapes = [
            shape("g1", "", &[ME, SARA]),
            shape("g2", "old name", &[ME, LUCA]),
            shape("g3", "Team", &[ME, SARA, LUCA]),
            shape("g4", "", &[ME, "dd"]),
            nts,
        ];
        let names: HashMap<String, String> =
            [(SARA.to_string(), "Sara".to_string()), (LUCA.to_string(), "Luca".to_string())].into();
        let rows = build_rows_with_names(&shapes, &HashMap::new(), &names);
        let title = |gid: &str| rows.iter().find(|r| r.conversation_id == gid).unwrap().title.clone();
        assert_eq!(title("g1").as_deref(), Some("Sara"));
        assert_eq!(title("g2").as_deref(), Some("Luca"), "the live name beats a frozen group name");
        assert_eq!(title("g3").as_deref(), Some("Team"));
        assert_eq!(title("g4"), None, "no name known: the host shows the short npub");
        assert_eq!(title("g0"), None, "Note to Self is localized by the host");
    }
}
