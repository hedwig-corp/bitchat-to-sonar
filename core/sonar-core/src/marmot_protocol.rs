//! Per-contact Marmot protocol detection for the MDK 0.8 → v0.14 flag day.
//!
//! Sonar ships on MDK 0.8 ("Marmot v1", `NostrGroupData` extension `0xf2ee`).
//! MDK v0.14 ("Marmot v2", identity-proof extension `0xf2f1` plus MIP app
//! components) cannot read a v1 group and v1 cannot read a v2 one. A v1 user
//! writing to someone who already moved to v2 would publish into the old v1
//! group, which the other side can no longer decrypt, while the sender sees
//! "sent". This module tells a v1 install, per contact, whether that contact
//! has moved, so the apps can stop the send and point at the update.
//!
//! **The signal is the KeyPackage, not the Sonar descriptor.** The descriptor
//! (kind 30078, fixed d-tags) is one per ACCOUNT and the last device to publish
//! wins, so an iPhone still on v1 and a Mac on v2 would flip it back and forth.
//! KeyPackages (kind 30443) are one per INSTALL, each under its own `d` slot, so
//! reading every slot answers "does at least one of their installs still read
//! v1?". An install that updates republishes into the SAME slot (v2 reads the
//! `.sonar-keypackage-slot` file v1 wrote), so its v1 package is replaced, not
//! left behind.
//!
//! Fan-out bounds (CLAUDE.md No Performance Regression Rule):
//! - nothing runs at startup: the cache loads lazily and the first background
//!   scan waits [`FIRST_SCAN_DELAY`];
//! - only the open chat ([`OPEN_CHAT_TTL`]) and the [`RECENT_CHAT_LIMIT`] most
//!   recently active chats ([`RECENT_CHAT_TTL`]) are refreshed;
//! - one relay REQ per batch of at most [`REFRESH_BATCH`] authors, one batch per
//!   trigger, the rest on the idle heartbeat;
//! - a pubkey is fetched by one task at a time (in-flight set), and a failed
//!   fetch backs off [`FAILED_FETCH_BACKOFF`] in memory without touching disk;
//! - a batch writes its records in ONE index transaction.

use std::collections::{HashMap, HashSet, VecDeque};
use std::time::{Duration, Instant};

use nostr::{Event, Kind, PublicKey};

/// Kind of a Marmot KeyPackage event (addressable).
const KEY_PACKAGE_KIND: u16 = crate::marmot::KEY_PACKAGE_KIND;

/// MDK 0.8 `NostrGroupData` extension: every v1 KeyPackage lists it in
/// `mls_extensions`. Same test as `is_legacy_mdk08_key_package` on the v2
/// branch (hedwig-corp/bitchat-to-sonar#683).
pub const MARMOT_V1_EXTENSION: &str = "0xf2ee";
/// MDK v0.14 account identity-proof extension (`ACCOUNT_IDENTITY_PROOF_EXTENSION_TYPE`).
pub const MARMOT_V2_EXTENSION: &str = "0xf2f1";
/// Tag only MDK ≥ 0.9 KeyPackages carry (MIP app components).
const APP_COMPONENTS_TAG: &str = "app_components";
const MLS_EXTENSIONS_TAG: &str = "mls_extensions";

/// A v1 slot whose newest package is this much older than the contact's newest
/// v2 package is treated as an abandoned install, not a live one. Every install
/// republishes its package on each relay connect, so a v1 device opened in the
/// last two weeks is still counted; older slots are reinstalls and pre-slot
/// orphans that would otherwise make an updated contact look "Mixed" forever.
pub const STALE_V1_SLOT_SECS: u64 = 14 * 24 * 60 * 60;

/// Most authors in one relay REQ.
pub const REFRESH_BATCH: usize = 8;
/// Most pubkeys waiting in the refresh queue. A 300-member group cannot grow
/// it past this; the rest are picked up by later scans.
pub const MAX_QUEUED: usize = 64;
/// Recheck the open chat's members this often. Short on purpose: between a
/// contact's update and our next check, a send still looks fine and is lost.
/// One single-author REQ per opened chat per window is the whole cost.
pub const OPEN_CHAT_TTL: Duration = Duration::from_secs(2 * 60);
/// Recheck members of recently active chats this often.
pub const RECENT_CHAT_TTL: Duration = Duration::from_secs(6 * 60 * 60);
/// How many of the most recently active chats the heartbeat keeps fresh.
pub const RECENT_CHAT_LIMIT: usize = 8;
/// A chat whose newest message is older than this is not "recently active".
pub const RECENT_CHAT_WINDOW_SECS: u64 = 30 * 24 * 60 * 60;
/// Members read per chat when planning a refresh (bounds big groups).
pub const MEMBERS_PER_CHAT: usize = 32;
/// How often the heartbeat re-plans from the recent chats.
pub const RECENT_SCAN_INTERVAL: Duration = Duration::from_secs(10 * 60);
/// The first heartbeat scan waits this long after the client starts, so the
/// check never competes with cold-start sync.
pub const FIRST_SCAN_DELAY: Duration = Duration::from_secs(60);
/// After a failed fetch, the same pubkey is not retried for this long.
pub const FAILED_FETCH_BACKOFF: Duration = Duration::from_secs(2 * 60);

/// What one KeyPackage event says about the install that published it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyPackageProtocol {
    /// MDK 0.8 (`0xf2ee`): reads Marmot v1 groups only.
    V1,
    /// MDK ≥ 0.9 (`0xf2f1` or MIP app components, no `0xf2ee`).
    V2,
    /// Neither marker: another client or a malformed package. Ignored.
    Unrecognized,
}

/// A contact's Marmot protocol, folded over every install's KeyPackage.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PeerMarmotProtocol {
    /// Never checked, nothing on the relays, or only unrecognized packages.
    Unknown,
    /// Every live install is still on v1: sending works.
    V1Only,
    /// At least one install still reads v1 and at least one moved to v2.
    Mixed,
    /// Every live install moved to v2: a v1 send is unreadable.
    V2Only,
}

impl PeerMarmotProtocol {
    pub(crate) fn to_db(self) -> i64 {
        match self {
            Self::Unknown => 0,
            Self::V1Only => 1,
            Self::Mixed => 2,
            Self::V2Only => 3,
        }
    }

    pub(crate) fn from_db(value: i64) -> Self {
        match value {
            1 => Self::V1Only,
            2 => Self::Mixed,
            3 => Self::V2Only,
            _ => Self::Unknown,
        }
    }
}

/// Classify one KeyPackage event.
pub fn classify_key_package(event: &Event) -> KeyPackageProtocol {
    let mut v1 = false;
    let mut v2 = false;
    for tag in event.tags.iter() {
        let values = tag.as_slice();
        match values.first().map(String::as_str) {
            Some(MLS_EXTENSIONS_TAG) => {
                for value in values.iter().skip(1) {
                    if value.eq_ignore_ascii_case(MARMOT_V1_EXTENSION) {
                        v1 = true;
                    } else if value.eq_ignore_ascii_case(MARMOT_V2_EXTENSION) {
                        v2 = true;
                    }
                }
            }
            Some(APP_COMPONENTS_TAG) => v2 = true,
            _ => {}
        }
    }
    // `0xf2ee` wins: an install that still advertises the v1 extension can be
    // admitted to a v1 group, whatever else it lists.
    if v1 {
        KeyPackageProtocol::V1
    } else if v2 {
        KeyPackageProtocol::V2
    } else {
        KeyPackageProtocol::Unrecognized
    }
}

/// Fold `author`'s KeyPackage events into one protocol.
///
/// Per addressable slot (`d` tag) only the newest event counts: a relay that
/// missed an install's v2 republish still serves the v1 package it replaced.
/// v1 slots more than [`STALE_V1_SLOT_SECS`] older than the newest v2 package
/// are abandoned installs and do not count.
pub fn classify_peer_key_packages<'a>(
    author: &PublicKey,
    events: impl IntoIterator<Item = &'a Event>,
) -> PeerMarmotProtocol {
    let mut newest_per_slot: HashMap<String, &Event> = HashMap::new();
    for event in events {
        if event.pubkey != *author || event.kind != Kind::Custom(KEY_PACKAGE_KIND) {
            continue;
        }
        let slot = event
            .tags
            .identifier()
            .map(str::to_owned)
            .unwrap_or_else(|| format!("id:{}", event.id.to_hex()));
        match newest_per_slot.get(&slot) {
            Some(current) if (current.created_at, current.id) >= (event.created_at, event.id) => {}
            _ => {
                newest_per_slot.insert(slot, event);
            }
        }
    }

    let mut v1_slots: Vec<u64> = Vec::new();
    let mut newest_v2: Option<u64> = None;
    for event in newest_per_slot.values() {
        let at = event.created_at.as_secs();
        match classify_key_package(event) {
            KeyPackageProtocol::V1 => v1_slots.push(at),
            KeyPackageProtocol::V2 => newest_v2 = Some(newest_v2.map_or(at, |n| n.max(at))),
            KeyPackageProtocol::Unrecognized => {}
        }
    }
    let live_v1 = v1_slots
        .iter()
        .any(|&at| newest_v2.is_none_or(|v2| v2.saturating_sub(at) <= STALE_V1_SLOT_SECS));
    match (live_v1, newest_v2.is_some()) {
        (true, true) => PeerMarmotProtocol::Mixed,
        (true, false) => PeerMarmotProtocol::V1Only,
        (false, true) => PeerMarmotProtocol::V2Only,
        (false, false) => PeerMarmotProtocol::Unknown,
    }
}

/// What a chat's composer may do, from its other members' protocols.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChatProtocolGate {
    /// Nobody here moved to v2, or we cannot tell: send normally.
    Open,
    /// Every other member moved to v2: a send would be unreadable.
    Blocked { updated: Vec<PublicKey> },
    /// Some members moved to v2 and will not read new messages; others still
    /// can. Sending stays allowed, the apps show a note.
    PartlyUpdated { updated: Vec<PublicKey> },
}

impl ChatProtocolGate {
    pub fn is_blocked(&self) -> bool {
        matches!(self, Self::Blocked { .. })
    }
}

/// The gate for a chat whose other members (never ourselves) have these
/// protocols. `Mixed` and `Unknown` never block: they keep the composer open.
pub fn chat_gate(others: &[(PublicKey, PeerMarmotProtocol)]) -> ChatProtocolGate {
    if others.is_empty() {
        return ChatProtocolGate::Open;
    }
    let updated: Vec<PublicKey> = others
        .iter()
        .filter(|(_, p)| *p == PeerMarmotProtocol::V2Only)
        .map(|(pk, _)| *pk)
        .collect();
    if updated.is_empty() {
        ChatProtocolGate::Open
    } else if updated.len() == others.len() {
        ChatProtocolGate::Blocked { updated }
    } else {
        ChatProtocolGate::PartlyUpdated { updated }
    }
}

/// One contact's cached classification.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PeerProtocolRecord {
    pub protocol: PeerMarmotProtocol,
    /// Unix seconds of the last successful relay check.
    pub checked_at_secs: u64,
}

/// The record to store after a successful fetch. An empty answer never
/// downgrades what we knew: relays that lost a package (or answered from a
/// partial set) must not reopen a composer that was correctly blocked.
pub fn merge_fetched(
    previous: Option<PeerProtocolRecord>,
    fetched: PeerMarmotProtocol,
    now_secs: u64,
) -> PeerProtocolRecord {
    let protocol = match (previous, fetched) {
        (Some(prev), PeerMarmotProtocol::Unknown) => prev.protocol,
        (_, fetched) => fetched,
    };
    PeerProtocolRecord {
        protocol,
        checked_at_secs: now_secs,
    }
}

/// True when a record is missing or older than `ttl`.
pub fn is_stale(record: Option<PeerProtocolRecord>, ttl: Duration, now_secs: u64) -> bool {
    record.is_none_or(|r| now_secs.saturating_sub(r.checked_at_secs) >= ttl.as_secs())
}

/// In-memory refresh planner: queue, in-flight set, failure backoff and the
/// chats to notify. Durable results live in the conversation index.
#[derive(Debug)]
pub struct ProtocolRefreshState {
    queue: VecDeque<PublicKey>,
    in_flight: HashSet<PublicKey>,
    failed_at: HashMap<PublicKey, Instant>,
    /// Chats (MLS group id hex) to notify when a queued pubkey's protocol
    /// changes. Entries leave with their pubkey's batch.
    watchers: HashMap<PublicKey, HashSet<String>>,
    started_at: Instant,
    last_recent_scan: Option<Instant>,
}

impl ProtocolRefreshState {
    pub fn new(now: Instant) -> Self {
        Self {
            queue: VecDeque::new(),
            in_flight: HashSet::new(),
            failed_at: HashMap::new(),
            watchers: HashMap::new(),
            started_at: now,
            last_recent_scan: None,
        }
    }

    /// Queue `pubkeys` for `group_id_hex`. `urgent` puts them at the front (the
    /// chat on screen); otherwise they go to the back. A pubkey already queued
    /// keeps one place (moved to the front when urgent); one in flight is only
    /// watched. The queue never grows past [`MAX_QUEUED`]: an urgent entry
    /// pushes the oldest background one out, a background one is dropped.
    pub fn enqueue(&mut self, pubkeys: &[PublicKey], group_id_hex: &str, urgent: bool) {
        for pk in pubkeys {
            self.watchers
                .entry(*pk)
                .or_default()
                .insert(group_id_hex.to_owned());
            if self.in_flight.contains(pk) {
                continue;
            }
            if let Some(pos) = self.queue.iter().position(|q| q == pk) {
                if urgent && pos != 0 {
                    self.queue.remove(pos);
                    self.queue.push_front(*pk);
                }
                continue;
            }
            if self.queue.len() >= MAX_QUEUED {
                if !urgent {
                    self.watchers.remove(pk);
                    continue;
                }
                if let Some(dropped) = self.queue.pop_back() {
                    self.watchers.remove(&dropped);
                }
            }
            if urgent {
                self.queue.push_front(*pk);
            } else {
                self.queue.push_back(*pk);
            }
        }
    }

    /// Take up to [`REFRESH_BATCH`] queued pubkeys that are not in flight and
    /// not backing off, and mark them in flight.
    pub fn take_batch(&mut self, now: Instant) -> Vec<PublicKey> {
        self.failed_at
            .retain(|_, at| now.saturating_duration_since(*at) < FAILED_FETCH_BACKOFF);
        let mut batch = Vec::new();
        let mut kept = VecDeque::with_capacity(self.queue.len());
        while let Some(pk) = self.queue.pop_front() {
            if batch.len() < REFRESH_BATCH
                && !self.in_flight.contains(&pk)
                && !self.failed_at.contains_key(&pk)
            {
                self.in_flight.insert(pk);
                batch.push(pk);
            } else {
                kept.push_back(pk);
            }
        }
        self.queue = kept;
        batch
    }

    /// A batch finished. Returns the chats watching its pubkeys. On failure the
    /// pubkeys back off and nobody is notified.
    pub fn finish(
        &mut self,
        batch: &[PublicKey],
        ok: bool,
        now: Instant,
    ) -> HashMap<PublicKey, HashSet<String>> {
        let mut watchers = HashMap::new();
        for pk in batch {
            self.in_flight.remove(pk);
            if let Some(w) = self.watchers.remove(pk) {
                watchers.insert(*pk, w);
            }
            if !ok {
                self.failed_at.insert(*pk, now);
            }
        }
        watchers
    }

    /// Whether the heartbeat should re-plan from the recent chats now.
    pub fn recent_scan_due(&mut self, now: Instant) -> bool {
        if now.saturating_duration_since(self.started_at) < FIRST_SCAN_DELAY {
            return false;
        }
        let due = self
            .last_recent_scan
            .is_none_or(|at| now.saturating_duration_since(at) >= RECENT_SCAN_INTERVAL);
        if due {
            self.last_recent_scan = Some(now);
        }
        due
    }

    pub fn queued_len(&self) -> usize {
        self.queue.len()
    }

    pub fn in_flight_len(&self) -> usize {
        self.in_flight.len()
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use nostr::{EventBuilder, Keys, Tag, TagKind, Timestamp};

    fn key_package(
        keys: &Keys,
        slot: &str,
        extensions: &[&str],
        app_components: bool,
        at: u64,
    ) -> Event {
        let mut tags = vec![
            Tag::identifier(slot),
            Tag::custom(TagKind::custom("mls_protocol_version"), ["1.0"]),
            Tag::custom(TagKind::custom("mls_ciphersuite"), ["0x0001"]),
            Tag::custom(
                TagKind::custom("mls_extensions"),
                extensions.iter().copied(),
            ),
        ];
        if app_components {
            tags.push(Tag::custom(
                TagKind::custom("app_components"),
                ["0x8006", "0x8008"],
            ));
        }
        EventBuilder::new(Kind::Custom(KEY_PACKAGE_KIND), "a2V5cGFja2FnZQ==")
            .tags(tags)
            .custom_created_at(Timestamp::from(at))
            .sign_with_keys(keys)
            .expect("signs")
    }

    /// MDK 0.8 tags (`mdk-core` `tags_30443`): `0x000a` + `0xf2ee`.
    pub(crate) fn v1_key_package(keys: &Keys, slot: &str, at: u64) -> Event {
        key_package(keys, slot, &["0x000a", "0xf2ee"], false, at)
    }

    /// MDK v0.14 tags (`transport-nostr-adapter` `NostrKeyPackagePublication`).
    pub(crate) fn v2_key_package(keys: &Keys, slot: &str, at: u64) -> Event {
        key_package(keys, slot, &["0x0006", "0xf2f1", "0x000a"], true, at)
    }

    const NOW: u64 = 1_800_000_000;
    const DAY: u64 = 24 * 60 * 60;

    #[test]
    fn classifies_single_key_packages() {
        let keys = Keys::generate();
        assert_eq!(
            classify_key_package(&v1_key_package(&keys, "a", NOW)),
            KeyPackageProtocol::V1
        );
        assert_eq!(
            classify_key_package(&v2_key_package(&keys, "a", NOW)),
            KeyPackageProtocol::V2
        );
        // A v0.14 package whose leaves carry only the current proof component.
        assert_eq!(
            classify_key_package(&key_package(&keys, "a", &["0x0006", "0x000a"], true, NOW)),
            KeyPackageProtocol::V2
        );
        assert_eq!(
            classify_key_package(&key_package(&keys, "a", &["0x000a"], false, NOW)),
            KeyPackageProtocol::Unrecognized
        );
        // Case-insensitive, like the #683 classifier.
        assert_eq!(
            classify_key_package(&key_package(&keys, "a", &["0x000A", "0xF2EE"], false, NOW)),
            KeyPackageProtocol::V1
        );
    }

    #[test]
    fn folds_installs_into_v1_only_v2_only_mixed_and_unknown() {
        let keys = Keys::generate();
        let pk = keys.public_key();
        let v1 = v1_key_package(&keys, "phone", NOW);
        let v2 = v2_key_package(&keys, "mac", NOW);
        assert_eq!(
            classify_peer_key_packages(&pk, [&v1]),
            PeerMarmotProtocol::V1Only
        );
        assert_eq!(
            classify_peer_key_packages(&pk, [&v2]),
            PeerMarmotProtocol::V2Only
        );
        assert_eq!(
            classify_peer_key_packages(&pk, [&v1, &v2]),
            PeerMarmotProtocol::Mixed
        );
        assert_eq!(
            classify_peer_key_packages(&pk, []),
            PeerMarmotProtocol::Unknown
        );
        let other = key_package(&keys, "x", &["0x000a"], false, NOW);
        assert_eq!(
            classify_peer_key_packages(&pk, [&other]),
            PeerMarmotProtocol::Unknown
        );
    }

    #[test]
    fn an_install_that_updated_in_place_is_v2_even_where_a_relay_kept_its_old_package() {
        let keys = Keys::generate();
        let pk = keys.public_key();
        let old = v1_key_package(&keys, "phone", NOW - 60);
        let new = v2_key_package(&keys, "phone", NOW);
        assert_eq!(
            classify_peer_key_packages(&pk, [&old, &new]),
            PeerMarmotProtocol::V2Only
        );
        assert_eq!(
            classify_peer_key_packages(&pk, [&new, &old]),
            PeerMarmotProtocol::V2Only
        );
    }

    #[test]
    fn an_abandoned_v1_slot_does_not_keep_an_updated_contact_mixed() {
        let keys = Keys::generate();
        let pk = keys.public_key();
        let v2 = v2_key_package(&keys, "phone", NOW);
        let orphan = v1_key_package(&keys, "old-install", NOW - 40 * DAY);
        assert_eq!(
            classify_peer_key_packages(&pk, [&v2, &orphan]),
            PeerMarmotProtocol::V2Only
        );
        // A v1 device opened inside the horizon still reads the old group.
        let live = v1_key_package(&keys, "ipad", NOW - 3 * DAY);
        assert_eq!(
            classify_peer_key_packages(&pk, [&v2, &orphan, &live]),
            PeerMarmotProtocol::Mixed
        );
        // Without any v2 package, age is irrelevant: an old v1 is still v1.
        assert_eq!(
            classify_peer_key_packages(&pk, [&orphan]),
            PeerMarmotProtocol::V1Only
        );
    }

    #[test]
    fn ignores_events_from_other_authors_and_kinds() {
        let keys = Keys::generate();
        let stranger = Keys::generate();
        let v2_of_stranger = v2_key_package(&stranger, "s", NOW);
        assert_eq!(
            classify_peer_key_packages(&keys.public_key(), [&v2_of_stranger]),
            PeerMarmotProtocol::Unknown
        );
    }

    #[test]
    fn gate_blocks_only_when_every_other_member_moved() {
        let a = Keys::generate().public_key();
        let b = Keys::generate().public_key();
        use PeerMarmotProtocol::*;
        assert_eq!(chat_gate(&[]), ChatProtocolGate::Open);
        assert_eq!(chat_gate(&[(a, V1Only)]), ChatProtocolGate::Open);
        assert_eq!(chat_gate(&[(a, Mixed)]), ChatProtocolGate::Open);
        assert_eq!(chat_gate(&[(a, Unknown)]), ChatProtocolGate::Open);
        assert_eq!(
            chat_gate(&[(a, V2Only)]),
            ChatProtocolGate::Blocked { updated: vec![a] }
        );
        assert_eq!(
            chat_gate(&[(a, V2Only), (b, V2Only)]),
            ChatProtocolGate::Blocked {
                updated: vec![a, b]
            }
        );
        assert_eq!(
            chat_gate(&[(a, V2Only), (b, V1Only)]),
            ChatProtocolGate::PartlyUpdated { updated: vec![a] }
        );
        assert_eq!(
            chat_gate(&[(a, V2Only), (b, Unknown)]),
            ChatProtocolGate::PartlyUpdated { updated: vec![a] }
        );
    }

    #[test]
    fn an_empty_answer_never_downgrades_a_known_protocol() {
        let known = PeerProtocolRecord {
            protocol: PeerMarmotProtocol::V2Only,
            checked_at_secs: 1,
        };
        assert_eq!(
            merge_fetched(Some(known), PeerMarmotProtocol::Unknown, 9),
            PeerProtocolRecord {
                protocol: PeerMarmotProtocol::V2Only,
                checked_at_secs: 9
            }
        );
        assert_eq!(
            merge_fetched(Some(known), PeerMarmotProtocol::Mixed, 9).protocol,
            PeerMarmotProtocol::Mixed
        );
        assert_eq!(
            merge_fetched(None, PeerMarmotProtocol::Unknown, 9).protocol,
            PeerMarmotProtocol::Unknown
        );
    }

    #[test]
    fn staleness_follows_the_ttl() {
        let rec = PeerProtocolRecord {
            protocol: PeerMarmotProtocol::V1Only,
            checked_at_secs: 1000,
        };
        assert!(is_stale(None, OPEN_CHAT_TTL, 1000));
        assert!(!is_stale(
            Some(rec),
            OPEN_CHAT_TTL,
            1000 + OPEN_CHAT_TTL.as_secs() - 1
        ));
        assert!(is_stale(
            Some(rec),
            OPEN_CHAT_TTL,
            1000 + OPEN_CHAT_TTL.as_secs()
        ));
    }

    fn pks(n: usize) -> Vec<PublicKey> {
        (0..n).map(|_| Keys::generate().public_key()).collect()
    }

    #[test]
    fn batches_are_bounded_and_single_flight() {
        let t0 = Instant::now();
        let mut s = ProtocolRefreshState::new(t0);
        let many = pks(20);
        s.enqueue(&many, "g", false);
        let first = s.take_batch(t0);
        assert_eq!(first.len(), REFRESH_BATCH);
        // The same pubkeys re-requested while in flight are watched, not queued.
        s.enqueue(&first, "h", true);
        assert_eq!(s.queued_len(), 20 - REFRESH_BATCH);
        let second = s.take_batch(t0);
        assert_eq!(second.len(), REFRESH_BATCH);
        assert!(second.iter().all(|pk| !first.contains(pk)));
        let watchers = s.finish(&first, true, t0);
        assert!(watchers
            .values()
            .all(|w| w.contains("g") && w.contains("h")));
        assert_eq!(s.in_flight_len(), REFRESH_BATCH);
    }

    #[test]
    fn the_open_chat_jumps_the_queue() {
        let t0 = Instant::now();
        let mut s = ProtocolRefreshState::new(t0);
        s.enqueue(&pks(20), "recent", false);
        let open = Keys::generate().public_key();
        s.enqueue(&[open], "open", true);
        assert_eq!(s.take_batch(t0)[0], open);
    }

    #[test]
    fn the_queue_never_grows_past_its_cap() {
        let t0 = Instant::now();
        let mut s = ProtocolRefreshState::new(t0);
        s.enqueue(&pks(MAX_QUEUED + 40), "big-group", false);
        assert_eq!(s.queued_len(), MAX_QUEUED);
        let open = Keys::generate().public_key();
        s.enqueue(&[open], "open", true);
        assert_eq!(
            s.queued_len(),
            MAX_QUEUED,
            "urgent entries displace, never grow"
        );
        assert_eq!(s.take_batch(t0)[0], open);
        assert!(s.watchers.len() <= MAX_QUEUED + REFRESH_BATCH);
    }

    #[test]
    fn a_failed_fetch_backs_off_without_retrying_in_a_loop() {
        let t0 = Instant::now();
        let mut s = ProtocolRefreshState::new(t0);
        let one = pks(1);
        s.enqueue(&one, "g", true);
        let batch = s.take_batch(t0);
        assert!(s.finish(&batch, false, t0).contains_key(&one[0]));
        s.enqueue(&one, "g", true);
        assert!(
            s.take_batch(t0 + Duration::from_secs(5)).is_empty(),
            "backing off"
        );
        assert_eq!(s.take_batch(t0 + FAILED_FETCH_BACKOFF), one);
    }

    #[test]
    fn the_background_scan_waits_out_cold_start_and_then_paces_itself() {
        let t0 = Instant::now();
        let mut s = ProtocolRefreshState::new(t0);
        assert!(!s.recent_scan_due(t0));
        assert!(!s.recent_scan_due(t0 + FIRST_SCAN_DELAY - Duration::from_secs(1)));
        assert!(s.recent_scan_due(t0 + FIRST_SCAN_DELAY));
        assert!(!s.recent_scan_due(t0 + FIRST_SCAN_DELAY + Duration::from_secs(30)));
        assert!(s.recent_scan_due(t0 + FIRST_SCAN_DELAY + RECENT_SCAN_INTERVAL));
    }
}
