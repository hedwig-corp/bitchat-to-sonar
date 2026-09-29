//! Relay routes: where this account's public records live, and where a
//! peer's do (#626).
//!
//! Sonar's Marmot pool (`SonarClient::nostr`) is a fixed set of relays every
//! publish and subscription goes to. That is fine between two Sonar installs,
//! which share the set, and useless to everyone else: a client that does not
//! happen to sit on one of those relays cannot find our profile or KeyPackage,
//! and we cannot find theirs. The Nostr answer is the outbox model — an
//! account publishes small relay lists saying where it writes (kind `10002`,
//! NIP-65) and where it reads gift wraps (kind `10050`, NIP-17), spreads those
//! lists to a handful of public *indexer* relays that exist only to serve
//! them, and everyone else looks the lists up there before fetching or
//! delivering. Marmot builds on the same two lists: KeyPackages go to the
//! `10002` write set, welcomes to the `10050` inbox set
//! (`marmot/transports/nostr.md`). The older kind `10051` KeyPackage list is
//! gone from the spec but still read by archived White Noise and by Amethyst,
//! so it is published as a compatibility twin of the write set.
//!
//! This module owns that traffic. It has two halves:
//!
//! - **Our records.** `RelayRouter::distribute_account_records` looks our
//!   lists up first (own relays plus the lookup set) and only then decides:
//!   nothing anywhere → publish Sonar's defaults; a list that already names
//!   one of our relays → copy the *existing signed event* unchanged; a list
//!   from another client that does not name us → leave it alone and adopt it
//!   (KeyPackages also go to its write set). A lookup that reached no relay
//!   publishes nothing: kinds `10002`/`10050` are replaceable, so publishing
//!   defaults over an imported account's real lists would replace them
//!   network-wide, and "nobody answered" must never read as "nobody has one".
//! - **Peer routes.** `RelayRouter::resolve_peer_routes` reads a peer's lists
//!   from own relays plus the lookup set, caches them with a TTL, and hands
//!   back the write / read / inbox sets callers need to fetch a KeyPackage or
//!   deliver a welcome where the peer actually listens.
//!
//! Everything foreign goes through a **second relay pool**, never the Marmot
//! pool: nostr-sdk's pool-wide `send_event` fans out to every WRITE relay and
//! `subscribe` to every READ relay, and `send_event_to` refuses a relay that
//! lacks WRITE, so an indexer added to the main pool would receive every
//! group message and welcome we ever send. Route relays are connected on
//! demand, released when the operation ends, and are never handed to the
//! sync path.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use nostr::prelude::*;
use nostr_sdk::{Client, RelayStatus};
use serde::{Deserialize, Serialize};

use crate::identity::Identity;
use crate::{Error, Result};

/// Sidecar holding what we last distributed per record kind
/// (`sonar.db` → `sonar.db.sonar-relay-records.json`).
pub(crate) const RELAY_RECORDS_FILE_SUFFIX: &str = ".sonar-relay-records.json";
/// Sidecar caching peers' relay lists
/// (`sonar.db` → `sonar.db.sonar-peer-routes.json`).
pub(crate) const PEER_ROUTES_FILE_SUFFIX: &str = ".sonar-peer-routes.json";
const RELAY_RECORDS_VERSION: u32 = 1;
const PEER_ROUTES_VERSION: u32 = 1;

/// Public indexers we read relay lists from. Lookups only: none of these is
/// ever adopted as a Marmot relay or listed inside our own lists.
const PUBLIC_LOOKUP_RELAYS: &[&str] = &[
    "wss://purplepag.es",
    "wss://user.kindpag.es",
    "wss://indexer.coracle.social",
    "wss://relay.ditto.pub",
    "wss://index.hzrd149.com",
];

/// Public indexers we copy records to, with the kinds each one accepts
/// (NIP-11 documents and relay sources, checked 2026-09-28). Sending a kind a
/// relay rejects is not harmful, only noisy, but the allow-list keeps the
/// publish honest about what will land. No indexer takes kind `30443`, so
/// KeyPackages stay on the write relays the lists point at.
const PUBLIC_INDEXERS: &[(&str, &[u16])] = &[
    ("wss://purplepag.es", &[0, 10002, 10050, 10051]),
    ("wss://user.kindpag.es", &[0, 10002]),
    ("wss://indexer.coracle.social", &[10002]),
    ("wss://profiles.nostr1.com", &[0, 10002, 10050]),
    ("wss://relay.ditto.pub", &[0, 10002, 10050]),
    ("wss://index.hzrd149.com", &[0, 10002]),
];

/// NIP-65 SHOULD: 2–4 relays per category.
pub const MAX_WRITE_RELAYS: usize = 4;
pub const MAX_READ_RELAYS: usize = 4;
/// NIP-17 SHOULD: keep the inbox list small (1–3).
pub const MAX_INBOX_RELAYS: usize = 3;
/// Marmot routing component maximum.
pub const MAX_GROUP_RELAYS: usize = 16;
/// Legacy kind-10051 lists are read for compatibility only; same bound as write.
pub const MAX_LEGACY_KEY_PACKAGE_RELAYS: usize = 4;

/// How long a resolved peer route stays fresh. Relay lists change rarely;
/// a stale list costs one missed fetch, which the caller's fallback covers.
pub const PEER_ROUTES_TTL: Duration = Duration::from_secs(6 * 60 * 60);
/// A peer with no lists is re-checked sooner: they may publish theirs any
/// minute (a fresh install typically does within its first session).
pub const PEER_ROUTES_NEGATIVE_TTL: Duration = Duration::from_secs(15 * 60);
/// Bound on cached peers; oldest fetch is evicted first.
pub const PEER_ROUTES_CACHE_CAP: usize = 512;
/// Our records are re-checked and re-spread at most this often. Every pass is
/// a lookup round trip plus a publish fan-out, and every publish is another
/// chance to hit a bad network, so a connect storm must not become a
/// republish storm (the kind-0 churn lesson from #584).
pub const DISTRIBUTION_MIN_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);

/// Per-relay connect wait for route relays. They are contacted off the
/// critical path, so this is generous next to the Marmot pool's quorum wait.
pub const ROUTE_CONNECT_TIMEOUT: Duration = Duration::from_secs(4);
/// Per-relay fetch bound on route relays.
pub const ROUTE_FETCH_TIMEOUT: Duration = Duration::from_secs(8);
/// Per-relay publish bound on route relays.
pub const ROUTE_PUBLISH_TIMEOUT: Duration = Duration::from_secs(8);

/// Kind `10051`: the pre-2026-06 Marmot KeyPackage relay list. nostr 0.44
/// names it `Kind::MlsKeyPackageRelays` after the superseded NIP-EE.
pub const LEGACY_KEY_PACKAGE_RELAYS_KIND: Kind = Kind::MlsKeyPackageRelays;

/// One indexer and the record kinds it accepts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IndexerRelay {
    pub url: RelayUrl,
    pub kinds: Vec<Kind>,
}

/// Where to look lists up and where to copy ours.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RelayRoutesConfig {
    /// Read-only lookup relays, queried alongside our own relays.
    pub lookup_relays: Vec<RelayUrl>,
    /// Publish targets for our records, per kind.
    pub indexers: Vec<IndexerRelay>,
}

impl RelayRoutesConfig {
    /// The public indexer set. What production installs use.
    pub fn public() -> Self {
        let lookup_relays = PUBLIC_LOOKUP_RELAYS
            .iter()
            .filter_map(|u| RelayUrl::parse(u).ok())
            .collect();
        let indexers = PUBLIC_INDEXERS
            .iter()
            .filter_map(|(url, kinds)| {
                Some(IndexerRelay {
                    url: RelayUrl::parse(url).ok()?,
                    kinds: kinds.iter().map(|k| Kind::from(*k)).collect(),
                })
            })
            .collect();
        Self {
            lookup_relays,
            indexers,
        }
    }

    /// No lookups, no indexers: in-memory / probe sessions stay network-free
    /// beyond the relays they were given.
    pub fn disabled() -> Self {
        Self {
            lookup_relays: Vec::new(),
            indexers: Vec::new(),
        }
    }

    /// Every given relay is both a lookup relay and an indexer for every
    /// record kind. For tests and private deployments with one directory
    /// relay.
    pub fn local(relays: Vec<RelayUrl>) -> Self {
        let kinds = vec![
            Kind::Metadata,
            Kind::RelayList,
            Kind::InboxRelays,
            LEGACY_KEY_PACKAGE_RELAYS_KIND,
        ];
        Self {
            indexers: relays
                .iter()
                .cloned()
                .map(|url| IndexerRelay {
                    url,
                    kinds: kinds.clone(),
                })
                .collect(),
            lookup_relays: relays,
        }
    }

    pub fn is_disabled(&self) -> bool {
        self.lookup_relays.is_empty() && self.indexers.is_empty()
    }

    /// Indexers that accept `kind`.
    pub fn indexers_for(&self, kind: Kind) -> Vec<RelayUrl> {
        self.indexers
            .iter()
            .filter(|i| i.kinds.contains(&kind))
            .map(|i| i.url.clone())
            .collect()
    }
}

// ── Peer routes ──────────────────────────────────────────────────────────────

/// A peer's advertised relays, one bounded set per role.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PeerRoutes {
    /// NIP-65 write set: `r` entries marked `write` or unmarked. Where the
    /// peer publishes, including (per Marmot) its KeyPackages.
    pub write: Vec<RelayUrl>,
    /// NIP-65 read set: `r` entries marked `read` or unmarked. Where the
    /// peer looks for events that tag it.
    pub read: Vec<RelayUrl>,
    /// NIP-17 inbox set (kind `10050`): where gift wraps for the peer go.
    pub inbox: Vec<RelayUrl>,
    /// Kind `10051`, read for peers on pre-2026-06 Marmot clients only.
    pub legacy_key_package: Vec<RelayUrl>,
}

impl PeerRoutes {
    /// Build from whatever list events a lookup returned. Only events signed
    /// by `author` count; the newest per kind wins; every set is sanitized
    /// and capped.
    pub fn from_events<'a>(
        events: impl IntoIterator<Item = &'a Event>,
        author: &PublicKey,
    ) -> Self {
        let mut newest: HashMap<Kind, &Event> = HashMap::new();
        for event in events {
            if event.pubkey != *author {
                continue;
            }
            match event.kind {
                Kind::RelayList | Kind::InboxRelays | Kind::MlsKeyPackageRelays => {}
                _ => continue,
            }
            let replace = newest
                .get(&event.kind)
                .is_none_or(|cur| (event.created_at, event.id) > (cur.created_at, cur.id));
            if replace {
                newest.insert(event.kind, event);
            }
        }
        let mut routes = Self::default();
        if let Some(list) = newest.get(&Kind::RelayList) {
            let (write, read) = nip65_sets(list);
            routes.write = bounded(write, MAX_WRITE_RELAYS);
            routes.read = bounded(read, MAX_READ_RELAYS);
        }
        if let Some(list) = newest.get(&Kind::InboxRelays) {
            routes.inbox = bounded(relay_tags(list), MAX_INBOX_RELAYS);
        }
        if let Some(list) = newest.get(&LEGACY_KEY_PACKAGE_RELAYS_KIND) {
            routes.legacy_key_package = bounded(relay_tags(list), MAX_LEGACY_KEY_PACKAGE_RELAYS);
        }
        routes
    }

    pub fn is_empty(&self) -> bool {
        self.write.is_empty()
            && self.read.is_empty()
            && self.inbox.is_empty()
            && self.legacy_key_package.is_empty()
    }

    /// Where the peer's KeyPackages should be: the write set, then any
    /// legacy kind-10051 relays.
    pub fn key_package_relays(&self) -> Vec<RelayUrl> {
        dedupe(
            self.write
                .iter()
                .chain(self.legacy_key_package.iter())
                .cloned(),
        )
    }

    /// Where a welcome for the peer should go: the inbox set, or — when the
    /// peer never published one — the read set, which is at least where they
    /// look for things addressed to them. The spec hard-fails without an
    /// inbox list; the contextual hint the sender adds (our own relays, from
    /// the Marmot pool) keeps that from stranding Sonar↔Sonar chats.
    pub fn welcome_relays(&self) -> Vec<RelayUrl> {
        if !self.inbox.is_empty() {
            self.inbox.clone()
        } else {
            self.read.clone()
        }
    }
}

/// NIP-65 `r` tags split into (write, read). An unmarked entry is both.
fn nip65_sets(event: &Event) -> (Vec<RelayUrl>, Vec<RelayUrl>) {
    let mut write = Vec::new();
    let mut read = Vec::new();
    for (url, marker) in nostr::nips::nip65::extract_relay_list(event) {
        if !usable_relay(url) {
            continue;
        }
        match marker {
            Some(RelayMetadata::Write) => write.push(url.clone()),
            Some(RelayMetadata::Read) => read.push(url.clone()),
            None => {
                write.push(url.clone());
                read.push(url.clone());
            }
        }
    }
    (write, read)
}

/// `relay` tags of a kind-10050 / kind-10051 list.
fn relay_tags(event: &Event) -> Vec<RelayUrl> {
    event
        .tags
        .iter()
        .filter_map(|tag| match tag.as_standardized() {
            Some(TagStandard::Relay(url)) if usable_relay(url) => Some(url.clone()),
            _ => None,
        })
        .collect()
}

/// A relay list is attacker-supplied. Only TLS relays are followed, plus
/// plaintext loopback for local relays in tests and private deployments —
/// a peer's list must never make us open a plaintext socket to the internet.
pub(crate) fn usable_relay(url: &RelayUrl) -> bool {
    let s = url.as_str();
    if s.starts_with("wss://") {
        true
    } else if s.starts_with("ws://") {
        url.is_local_addr()
    } else {
        false
    }
}

fn dedupe(urls: impl IntoIterator<Item = RelayUrl>) -> Vec<RelayUrl> {
    let mut seen = HashSet::new();
    urls.into_iter()
        .filter(|u| seen.insert(u.clone()))
        .collect()
}

fn bounded(urls: Vec<RelayUrl>, cap: usize) -> Vec<RelayUrl> {
    dedupe(urls).into_iter().take(cap).collect()
}

/// Relays for a new group: ours first (we read there), then each invitee's
/// write relays interleaved, so every member's own relays are in the list
/// and a member on a disjoint set still receives what the others publish.
/// Capped at the Marmot routing maximum.
pub fn group_relays_for(own: &[RelayUrl], invitees: &[PeerRoutes]) -> Vec<RelayUrl> {
    let mut out = dedupe(own.iter().cloned());
    let mut cursors: Vec<std::slice::Iter<'_, RelayUrl>> =
        invitees.iter().map(|r| r.write.iter()).collect();
    let mut progressed = true;
    while progressed && out.len() < MAX_GROUP_RELAYS {
        progressed = false;
        for cursor in cursors.iter_mut() {
            if out.len() >= MAX_GROUP_RELAYS {
                break;
            }
            if let Some(url) = cursor.next() {
                progressed = true;
                if !out.contains(url) {
                    out.push(url.clone());
                }
            }
        }
    }
    out
}

// ── Our records ──────────────────────────────────────────────────────────────

/// What to do with one of our record kinds after the lookup.
#[derive(Debug)]
pub enum RecordAction {
    /// No current list anywhere we looked: publish Sonar's default.
    Publish(Event),
    /// The current list already names one of our relays: copy it unchanged,
    /// so indexers and our relays hold the same signed event.
    Rebroadcast(Event),
    /// The current list comes from another client and does not name our
    /// relays. Left alone (changing it needs the user's say-so); the relays
    /// it names become extra targets for our KeyPackage.
    Adopt(Event),
}

/// The relays a list names, for the "does it name one of ours" test.
fn list_relays(event: &Event) -> Vec<RelayUrl> {
    match event.kind {
        Kind::RelayList => nip65_sets(event).0,
        _ => relay_tags(event),
    }
}

/// Decide one record kind. Pure; the lookup outcome is the caller's job.
pub fn plan_record(
    existing: Option<Event>,
    own: &[RelayUrl],
    build_default: impl FnOnce() -> Result<Event>,
) -> Result<RecordAction> {
    match existing {
        None => Ok(RecordAction::Publish(build_default()?)),
        Some(event) => {
            let names_us = list_relays(&event).iter().any(|u| own.contains(u));
            if names_us {
                Ok(RecordAction::Rebroadcast(event))
            } else {
                Ok(RecordAction::Adopt(event))
            }
        }
    }
}

/// Sonar's default inbox list: the Sonar-operated relay first (it is the one
/// we control the retention of), then the first of the others, capped per
/// NIP-17. Deterministic across installs so two devices of one account agree.
pub fn default_inbox_relays(own: &[RelayUrl]) -> Vec<RelayUrl> {
    let mut ordered: Vec<RelayUrl> = own
        .iter()
        .filter(|u| u.domain().is_some_and(|d| d.contains("hedwig")))
        .cloned()
        .collect();
    ordered.extend(own.iter().cloned());
    bounded(ordered, MAX_INBOX_RELAYS)
}

/// Build the signed default record of `kind` for `own` relays.
pub fn default_record(identity: &Identity, kind: Kind, own: &[RelayUrl]) -> Result<Event> {
    let builder = match kind {
        Kind::RelayList => EventBuilder::relay_list(own.iter().map(|u| (u.clone(), None))),
        Kind::InboxRelays => EventBuilder::new(Kind::InboxRelays, "")
            .tags(default_inbox_relays(own).into_iter().map(Tag::relay)),
        Kind::MlsKeyPackageRelays => EventBuilder::new(LEGACY_KEY_PACKAGE_RELAYS_KIND, "")
            .tags(own.iter().cloned().map(Tag::relay)),
        other => {
            return Err(Error::InvalidInput(format!(
                "no default record for kind {}",
                other.as_u16()
            )))
        }
    };
    Ok(builder
        .build(identity.public_key())
        .sign_with_keys(identity.keys())?)
}

/// The record kinds the distribution pass handles, in publish order.
pub const RECORD_KINDS: [Kind; 4] = [
    Kind::RelayList,
    Kind::InboxRelays,
    LEGACY_KEY_PACKAGE_RELAYS_KIND,
    Kind::Metadata,
];

/// What we last did for one record kind.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecordState {
    pub event_id: String,
    pub created_at: u64,
    pub distributed_at: u64,
    /// The list is another client's and was left alone.
    pub adopted: bool,
    /// Relays the list names (write set for `10002`), kept so an adopted
    /// list's relays are usable without re-parsing the event.
    pub relays: Vec<RelayUrl>,
}

#[derive(Default, Serialize, Deserialize)]
struct RelayRecordsDisk {
    version: u32,
    /// Keyed by kind number.
    records: BTreeMap<u16, RecordState>,
}

/// Outcome of one distribution pass.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DistributionReport {
    /// The pass ran within `DISTRIBUTION_MIN_INTERVAL` of the last one.
    pub skipped_fresh: bool,
    /// No lookup relay answered, so nothing was decided or published.
    pub lookup_failed: bool,
    /// Per kind: what happened.
    pub actions: BTreeMap<u16, RecordOutcome>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecordOutcome {
    Published {
        accepted: usize,
    },
    Rebroadcast {
        accepted: usize,
    },
    Adopted {
        relays: usize,
    },
    /// Kind 0 with no profile anywhere yet: the profile publish creates it.
    Absent,
}

#[derive(Default, Serialize, Deserialize)]
struct PeerRoutesDisk {
    version: u32,
    peers: HashMap<String, CachedPeerRoutes>,
}

#[derive(Clone, Serialize, Deserialize)]
struct CachedPeerRoutes {
    routes: PeerRoutes,
    fetched_at: u64,
    found: bool,
}

/// Result of a per-relay fetch: the events, and how many relays answered
/// (reached EOSE) inside the bound. `completed == 0` is "nobody answered",
/// which is not the same thing as "nobody has it".
#[derive(Debug, Default)]
pub struct RouteFetch {
    pub events: Vec<Event>,
    pub completed: usize,
    pub attempted: usize,
}

/// Result of a targeted publish.
#[derive(Debug, Default)]
pub struct RoutePublish {
    pub accepted: Vec<RelayUrl>,
    pub failed: Vec<(RelayUrl, String)>,
}

impl RoutePublish {
    pub fn any_accepted(&self) -> bool {
        !self.accepted.is_empty()
    }
}

pub(crate) fn relay_records_path_for_db(db_path: &Path) -> PathBuf {
    sidecar_path(db_path, RELAY_RECORDS_FILE_SUFFIX)
}

pub(crate) fn peer_routes_path_for_db(db_path: &Path) -> PathBuf {
    sidecar_path(db_path, PEER_ROUTES_FILE_SUFFIX)
}

fn sidecar_path(db_path: &Path, suffix: &str) -> PathBuf {
    let name = db_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("sonar.db");
    db_path.with_file_name(format!("{name}{suffix}"))
}

/// Remove both sidecars (account wipe). Missing files are fine.
pub(crate) fn wipe_relay_routes_for_db(db_path: &Path) -> Result<()> {
    for path in [
        relay_records_path_for_db(db_path),
        peer_routes_path_for_db(db_path),
    ] {
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return Err(Error::Storage(format!(
                    "relay routes wipe {}: {e}",
                    path.display()
                )))
            }
        }
    }
    Ok(())
}

fn load_json<T: Default + for<'de> Deserialize<'de>>(path: Option<&Path>) -> T {
    let Some(path) = path else {
        return T::default();
    };
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|err| {
            tracing::warn!(%err, path = %path.display(), "relay routes sidecar unreadable; starting empty");
            T::default()
        }),
        Err(_) => T::default(),
    }
}

/// Atomic write (`<file>.tmp` + rename), like every other sidecar here.
fn store_json<T: Serialize>(path: Option<&Path>, value: &T) {
    let Some(path) = path else { return };
    let bytes = match serde_json::to_vec(value) {
        Ok(b) => b,
        Err(err) => {
            tracing::warn!(%err, "relay routes sidecar serialize failed");
            return;
        }
    };
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default();
    let tmp = path.with_file_name(format!("{name}.tmp"));
    if let Err(err) = std::fs::write(&tmp, bytes).and_then(|()| std::fs::rename(&tmp, path)) {
        tracing::warn!(%err, path = %path.display(), "relay routes sidecar write failed");
        let _ = std::fs::remove_file(&tmp);
    }
}

fn now_secs() -> u64 {
    Timestamp::now().as_secs()
}

/// The route pool plus the state behind it. One per `SonarClient`.
pub struct RelayRouter {
    /// The second pool. Signer-less: every event it sends is signed by us.
    nostr: Client,
    config: RelayRoutesConfig,
    own_relays: Vec<RelayUrl>,
    records_path: Option<PathBuf>,
    peer_routes_path: Option<PathBuf>,
    records: Mutex<RelayRecordsDisk>,
    peer_routes: Mutex<PeerRoutesDisk>,
    /// Route relays a caller wants kept open (group relays of active chats).
    sticky: Mutex<HashSet<RelayUrl>>,
    /// Route relays in use by in-flight operations, so one operation's
    /// release cannot close a socket another still needs.
    in_use: Mutex<HashMap<RelayUrl, usize>>,
}

impl RelayRouter {
    pub fn new(
        config: RelayRoutesConfig,
        own_relays: Vec<RelayUrl>,
        db_path: Option<&Path>,
    ) -> Self {
        let records_path = db_path.map(relay_records_path_for_db);
        let peer_routes_path = db_path.map(peer_routes_path_for_db);
        let mut records: RelayRecordsDisk = load_json(records_path.as_deref());
        if records.version != RELAY_RECORDS_VERSION {
            records = RelayRecordsDisk::default();
        }
        let mut peers: PeerRoutesDisk = load_json(peer_routes_path.as_deref());
        if peers.version != PEER_ROUTES_VERSION {
            peers = PeerRoutesDisk::default();
        }
        Self {
            nostr: Client::default(),
            config,
            own_relays: dedupe(own_relays),
            records_path,
            peer_routes_path,
            records: Mutex::new(records),
            peer_routes: Mutex::new(peers),
            sticky: Mutex::new(HashSet::new()),
            in_use: Mutex::new(HashMap::new()),
        }
    }

    pub fn config(&self) -> &RelayRoutesConfig {
        &self.config
    }

    /// Relays not in the Marmot pool — the ones this router has to carry.
    pub fn foreign(&self, urls: impl IntoIterator<Item = RelayUrl>) -> Vec<RelayUrl> {
        dedupe(urls)
            .into_iter()
            .filter(|u| !self.own_relays.contains(u) && usable_relay(u))
            .collect()
    }

    /// Keep these route relays connected across operations (a group whose
    /// relays are not ours). Idempotent.
    pub fn keep_open(&self, urls: &[RelayUrl]) {
        let mut sticky = self.sticky.lock().unwrap();
        for url in urls {
            sticky.insert(url.clone());
        }
    }

    /// What we last distributed for `kind`, if anything.
    pub fn record_state(&self, kind: Kind) -> Option<RecordState> {
        self.records
            .lock()
            .unwrap()
            .records
            .get(&kind.as_u16())
            .cloned()
    }

    /// Relays an adopted kind-10002 names: extra KeyPackage targets, so a
    /// peer following the user's real list still finds us.
    pub fn adopted_write_relays(&self) -> Vec<RelayUrl> {
        match self.record_state(Kind::RelayList) {
            Some(state) if state.adopted => self.foreign(state.relays),
            _ => Vec::new(),
        }
    }

    fn distributed_recently(&self, now: u64) -> bool {
        let records = self.records.lock().unwrap();
        if records.records.is_empty() {
            return false;
        }
        records
            .records
            .values()
            .all(|r| now.saturating_sub(r.distributed_at) < DISTRIBUTION_MIN_INTERVAL.as_secs())
    }

    // ── Route pool plumbing ──

    /// Add (if needed) and connect `urls`, returning the ones connected
    /// within `ROUTE_CONNECT_TIMEOUT`. Each connected relay is marked in use
    /// until `release` is called with it.
    async fn acquire(&self, urls: &[RelayUrl]) -> Vec<RelayUrl> {
        let mut handles = Vec::with_capacity(urls.len());
        for url in dedupe(urls.iter().cloned()) {
            if let Err(err) = self.nostr.add_relay(url.clone()).await {
                tracing::debug!(%err, relay = %url, "route relay add failed");
                continue;
            }
            match self.nostr.relay(url.clone()).await {
                Ok(handle) => {
                    if handle.status() != RelayStatus::Connected {
                        handle.connect();
                    }
                    handles.push((url, handle));
                }
                Err(err) => tracing::debug!(%err, relay = %url, "route relay handle missing"),
            }
        }
        let waits = handles.iter().map(|(url, handle)| {
            let url = url.clone();
            let handle = handle.clone();
            async move {
                handle.wait_for_connection(ROUTE_CONNECT_TIMEOUT).await;
                (url, handle.status() == RelayStatus::Connected)
            }
        });
        let results = futures_util::future::join_all(waits).await;
        let mut in_use = self.in_use.lock().unwrap();
        results
            .into_iter()
            .filter_map(|(url, connected)| {
                if connected {
                    *in_use.entry(url.clone()).or_insert(0) += 1;
                    Some(url)
                } else {
                    tracing::debug!(relay = %url, "route relay not connected in time");
                    None
                }
            })
            .collect()
    }

    /// Drop the in-use mark; take relays nobody needs any more out of the
    /// pool so indexers do not stay open (and auto-reconnecting) in the
    /// background. Removed, not disconnected: a disconnected relay is
    /// `Terminated`, and nostr-sdk 0.44 never brings a terminated relay back
    /// through `connect()` (the second use in one pass — lookup, then
    /// publish — silently reached nothing). A removed relay is re-added
    /// fresh by the next `acquire`.
    async fn release(&self, urls: &[RelayUrl]) {
        let to_close: Vec<RelayUrl> = {
            let mut in_use = self.in_use.lock().unwrap();
            let sticky = self.sticky.lock().unwrap();
            urls.iter()
                .filter(|url| {
                    let count = in_use.entry((*url).clone()).or_insert(0);
                    *count = count.saturating_sub(1);
                    *count == 0 && !sticky.contains(*url)
                })
                .cloned()
                .collect()
        };
        for url in to_close {
            if let Err(err) = self.nostr.remove_relay(url.clone()).await {
                tracing::debug!(%err, relay = %url, "route relay remove failed");
            }
        }
    }

    /// Fetch `filter` from every route relay in `urls`, one REQ per relay,
    /// counting the relays that answered (EOSE) inside the bound.
    pub async fn fetch_from(&self, urls: &[RelayUrl], filter: Filter) -> RouteFetch {
        let connected = self.acquire(urls).await;
        let outcome = fetch_per_relay(&self.nostr, &connected, filter, ROUTE_FETCH_TIMEOUT).await;
        self.release(&connected).await;
        RouteFetch {
            attempted: urls.len(),
            ..outcome
        }
    }

    /// Publish `event` to every route relay in `urls`; each send is bounded.
    pub async fn publish_to(&self, urls: &[RelayUrl], event: &Event) -> RoutePublish {
        let connected = self.acquire(urls).await;
        let mut out = RoutePublish::default();
        for url in urls {
            if !connected.contains(url) {
                out.failed
                    .push((url.clone(), "route relay not connected".to_string()));
            }
        }
        if !connected.is_empty() {
            match tokio::time::timeout(
                ROUTE_PUBLISH_TIMEOUT,
                self.nostr.send_event_to(connected.clone(), event),
            )
            .await
            {
                Ok(Ok(output)) => {
                    out.accepted.extend(output.success);
                    out.failed.extend(output.failed);
                }
                Ok(Err(err)) => {
                    for url in &connected {
                        out.failed.push((url.clone(), err.to_string()));
                    }
                }
                Err(_) => {
                    for url in &connected {
                        out.failed
                            .push((url.clone(), "route publish timed out".to_string()));
                    }
                }
            }
        }
        self.release(&connected).await;
        out
    }

    /// One filter against our own relays (through the Marmot pool) and the
    /// lookup set (through the route pool), merged. `completed` counts both.
    pub async fn lookup(&self, main: &Client, filter: Filter) -> RouteFetch {
        let (own, lookup) = tokio::join!(
            fetch_per_relay(main, &self.own_relays, filter.clone(), ROUTE_FETCH_TIMEOUT),
            self.fetch_from(&self.config.lookup_relays, filter),
        );
        let mut seen: HashSet<EventId> = own.events.iter().map(|e| e.id).collect();
        let mut events = own.events;
        events.extend(lookup.events.into_iter().filter(|e| seen.insert(e.id)));
        RouteFetch {
            events,
            completed: own.completed + lookup.completed,
            attempted: own.attempted + lookup.attempted,
        }
    }

    // ── Peer routes ──

    fn cached_peer_routes(&self, peer: &PublicKey, now: u64) -> Option<PeerRoutes> {
        let cache = self.peer_routes.lock().unwrap();
        let entry = cache.peers.get(&peer.to_hex())?;
        let ttl = if entry.found {
            PEER_ROUTES_TTL
        } else {
            PEER_ROUTES_NEGATIVE_TTL
        };
        (now.saturating_sub(entry.fetched_at) < ttl.as_secs()).then(|| entry.routes.clone())
    }

    fn remember_peer_routes(&self, peer: &PublicKey, routes: &PeerRoutes, now: u64) {
        let mut cache = self.peer_routes.lock().unwrap();
        cache.version = PEER_ROUTES_VERSION;
        cache.peers.insert(
            peer.to_hex(),
            CachedPeerRoutes {
                routes: routes.clone(),
                fetched_at: now,
                found: !routes.is_empty(),
            },
        );
        while cache.peers.len() > PEER_ROUTES_CACHE_CAP {
            let oldest = cache
                .peers
                .iter()
                .min_by_key(|(_, e)| e.fetched_at)
                .map(|(k, _)| k.clone());
            match oldest {
                Some(key) => {
                    cache.peers.remove(&key);
                }
                None => break,
            }
        }
        store_json(self.peer_routes_path.as_deref(), &*cache);
    }

    /// Forget a cached peer, so the next resolve re-reads the relays. Used
    /// when a fetch that trusted the cache came back empty.
    pub fn forget_peer_routes(&self, peer: &PublicKey) {
        let mut cache = self.peer_routes.lock().unwrap();
        if cache.peers.remove(&peer.to_hex()).is_some() {
            store_json(self.peer_routes_path.as_deref(), &*cache);
        }
    }

    /// The peer's relay lists: cache, else own relays plus the lookup set.
    /// Never fails — a peer with no lists (or no relay answering) resolves
    /// to empty routes, and callers fall back to the Marmot pool.
    pub async fn resolve_peer_routes(&self, main: &Client, peer: PublicKey) -> PeerRoutes {
        let now = now_secs();
        if let Some(cached) = self.cached_peer_routes(&peer, now) {
            return cached;
        }
        let filter = Filter::new().author(peer).kinds([
            Kind::RelayList,
            Kind::InboxRelays,
            LEGACY_KEY_PACKAGE_RELAYS_KIND,
        ]);
        let (own, lookup) = tokio::join!(
            fetch_per_relay(main, &self.own_relays, filter.clone(), ROUTE_FETCH_TIMEOUT),
            self.fetch_from(&self.config.lookup_relays, filter),
        );
        let routes = PeerRoutes::from_events(own.events.iter().chain(lookup.events.iter()), &peer);
        tracing::debug!(
            peer = %peer.to_hex(),
            write = routes.write.len(),
            read = routes.read.len(),
            inbox = routes.inbox.len(),
            own_completed = own.completed,
            lookup_completed = lookup.completed,
            "peer routes resolved"
        );
        // Only cache a miss when somebody actually answered; a dead network
        // must not pin "no lists" for the negative TTL.
        if !routes.is_empty() || own.completed + lookup.completed > 0 {
            self.remember_peer_routes(&peer, &routes, now);
        }
        routes
    }

    // ── Our records ──

    /// Look our records up, decide per kind, publish or adopt, and remember.
    /// `main` is the Marmot pool (our own relays); the lookup set and the
    /// indexers go through the route pool. See the module docs for the
    /// decision table.
    pub async fn distribute_account_records(
        &self,
        identity: &Identity,
        main: &Client,
        force: bool,
    ) -> DistributionReport {
        let now = now_secs();
        let mut report = DistributionReport::default();
        if !force && self.distributed_recently(now) {
            report.skipped_fresh = true;
            return report;
        }
        if self.own_relays.is_empty() {
            report.lookup_failed = true;
            return report;
        }
        let me = identity.public_key();
        let filter = Filter::new().author(me).kinds(RECORD_KINDS);
        let (own, lookup) = tokio::join!(
            fetch_per_relay(main, &self.own_relays, filter.clone(), ROUTE_FETCH_TIMEOUT),
            self.fetch_from(&self.config.lookup_relays, filter),
        );
        // "Nobody answered" is unknown, not absent. With a lookup set
        // configured, an answer from our own relays alone is not enough: an
        // imported account's lists typically live on the indexers only.
        let lookup_ok = if self.config.lookup_relays.is_empty() {
            own.completed > 0
        } else {
            lookup.completed > 0
        };
        if !lookup_ok {
            tracing::warn!(
                own_completed = own.completed,
                lookup_completed = lookup.completed,
                lookup_relays = self.config.lookup_relays.len(),
                "relay records: lookup reached no relay; publishing nothing"
            );
            report.lookup_failed = true;
            return report;
        }
        let mut newest: HashMap<Kind, Event> = HashMap::new();
        for event in own.events.into_iter().chain(lookup.events) {
            if event.pubkey != me || !RECORD_KINDS.contains(&event.kind) {
                continue;
            }
            let replace = newest
                .get(&event.kind)
                .is_none_or(|cur| (event.created_at, event.id) > (cur.created_at, cur.id));
            if replace {
                newest.insert(event.kind, event);
            }
        }

        let mut states: BTreeMap<u16, RecordState> = BTreeMap::new();
        for kind in RECORD_KINDS {
            let existing = newest.remove(&kind);
            let outcome = if kind == Kind::Metadata {
                // Not ours to invent: the profile publish path creates it.
                // Whatever exists is spread so lookups find it everywhere.
                match existing {
                    Some(event) => {
                        let accepted = self.spread(main, &event).await;
                        states.insert(
                            kind.as_u16(),
                            RecordState {
                                event_id: event.id.to_hex(),
                                created_at: event.created_at.as_secs(),
                                distributed_at: now,
                                adopted: false,
                                relays: Vec::new(),
                            },
                        );
                        RecordOutcome::Rebroadcast { accepted }
                    }
                    None => RecordOutcome::Absent,
                }
            } else {
                let action = match plan_record(existing, &self.own_relays, || {
                    default_record(identity, kind, &self.own_relays)
                }) {
                    Ok(action) => action,
                    Err(err) => {
                        tracing::warn!(%err, kind = kind.as_u16(), "relay record build failed");
                        continue;
                    }
                };
                match action {
                    RecordAction::Publish(event) => {
                        let accepted = self.spread(main, &event).await;
                        if accepted > 0 {
                            states.insert(
                                kind.as_u16(),
                                RecordState {
                                    event_id: event.id.to_hex(),
                                    created_at: event.created_at.as_secs(),
                                    distributed_at: now,
                                    adopted: false,
                                    relays: list_relays(&event),
                                },
                            );
                        }
                        RecordOutcome::Published { accepted }
                    }
                    RecordAction::Rebroadcast(event) => {
                        let accepted = self.spread(main, &event).await;
                        states.insert(
                            kind.as_u16(),
                            RecordState {
                                event_id: event.id.to_hex(),
                                created_at: event.created_at.as_secs(),
                                distributed_at: now,
                                adopted: false,
                                relays: list_relays(&event),
                            },
                        );
                        RecordOutcome::Rebroadcast { accepted }
                    }
                    RecordAction::Adopt(event) => {
                        let relays = list_relays(&event);
                        tracing::info!(
                            kind = kind.as_u16(),
                            relays = relays.len(),
                            "relay record from another client adopted, not replaced"
                        );
                        states.insert(
                            kind.as_u16(),
                            RecordState {
                                event_id: event.id.to_hex(),
                                created_at: event.created_at.as_secs(),
                                distributed_at: now,
                                adopted: true,
                                relays: relays.clone(),
                            },
                        );
                        RecordOutcome::Adopted {
                            relays: relays.len(),
                        }
                    }
                }
            };
            report.actions.insert(kind.as_u16(), outcome);
        }
        {
            let mut records = self.records.lock().unwrap();
            records.version = RELAY_RECORDS_VERSION;
            for (kind, state) in states {
                records.records.insert(kind, state);
            }
            store_json(self.records_path.as_deref(), &*records);
        }
        report
    }

    /// Copy one signed record to our relays and to every indexer accepting
    /// its kind. Returns the number of relays that accepted it.
    async fn spread(&self, main: &Client, event: &Event) -> usize {
        let indexers = self.foreign(self.config.indexers_for(event.kind));
        let (own, routed) = tokio::join!(
            tokio::time::timeout(
                ROUTE_PUBLISH_TIMEOUT,
                main.send_event_to(self.own_relays.clone(), event),
            ),
            async {
                if indexers.is_empty() {
                    RoutePublish::default()
                } else {
                    self.publish_to(&indexers, event).await
                }
            }
        );
        let own_accepted = match own {
            Ok(Ok(output)) => output.success.len(),
            Ok(Err(err)) => {
                tracing::debug!(%err, kind = event.kind.as_u16(), "record publish to own relays failed");
                0
            }
            Err(_) => 0,
        };
        for (url, why) in &routed.failed {
            tracing::debug!(relay = %url, why, kind = event.kind.as_u16(), "indexer rejected record");
        }
        tracing::info!(
            kind = event.kind.as_u16(),
            own_accepted,
            indexers_accepted = routed.accepted.len(),
            indexers = indexers.len(),
            "record spread"
        );
        own_accepted + routed.accepted.len()
    }
}

/// One REQ per relay with a completion count. A relay counts as completed
/// only when its fetch returned before the outer deadline: nostr-sdk returns
/// `Ok(empty)` both at EOSE and when its own timeout fires (or when the relay
/// is not connected), so the inner call gets the full bound and the outer
/// wait a shorter one, and only an answer inside the shorter one is an answer.
pub(crate) async fn fetch_per_relay(
    client: &Client,
    urls: &[RelayUrl],
    filter: Filter,
    timeout: Duration,
) -> RouteFetch {
    let mut out = RouteFetch {
        attempted: urls.len(),
        ..RouteFetch::default()
    };
    if urls.is_empty() {
        return out;
    }
    let mut tasks = tokio::task::JoinSet::new();
    for url in dedupe(urls.iter().cloned()) {
        let client = client.clone();
        let filter = filter.clone();
        tasks.spawn(async move {
            let result = client
                .fetch_events_from(vec![url.clone()], filter, timeout)
                .await;
            (url, result)
        });
    }
    let outer = timeout.saturating_sub(Duration::from_millis(500));
    let deadline = tokio::time::Instant::now() + outer;
    let mut seen = HashSet::new();
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining, tasks.join_next()).await {
            Ok(Some(Ok((_url, Ok(events))))) => {
                out.completed += 1;
                for event in events {
                    if seen.insert(event.id) {
                        out.events.push(event);
                    }
                }
            }
            Ok(Some(Ok((url, Err(err))))) => {
                tracing::debug!(%err, relay = %url, "route fetch failed");
            }
            Ok(Some(Err(_))) => {}
            Ok(None) => break,
            Err(_) => break,
        }
    }
    tasks.abort_all();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url(s: &str) -> RelayUrl {
        RelayUrl::parse(s).unwrap()
    }

    fn signed(identity: &Identity, builder: EventBuilder) -> Event {
        builder
            .build(identity.public_key())
            .sign_with_keys(identity.keys())
            .unwrap()
    }

    #[test]
    fn nip65_markers_split_write_and_read_and_unmarked_is_both() {
        let me = Identity::generate();
        let list = signed(
            &me,
            EventBuilder::relay_list([
                (url("wss://w.example"), Some(RelayMetadata::Write)),
                (url("wss://r.example"), Some(RelayMetadata::Read)),
                (url("wss://both.example"), None),
            ]),
        );
        let routes = PeerRoutes::from_events([&list], &me.public_key());
        assert_eq!(
            routes.write,
            vec![url("wss://w.example"), url("wss://both.example")]
        );
        assert_eq!(
            routes.read,
            vec![url("wss://r.example"), url("wss://both.example")]
        );
        assert!(routes.inbox.is_empty());
    }

    #[test]
    fn newest_list_per_kind_wins_and_other_authors_are_ignored() {
        let me = Identity::generate();
        let stranger = Identity::generate();
        let old = signed(
            &me,
            EventBuilder::relay_list([(url("wss://old.example"), None)])
                .custom_created_at(Timestamp::from_secs(1_000)),
        );
        let new = signed(
            &me,
            EventBuilder::relay_list([(url("wss://new.example"), None)])
                .custom_created_at(Timestamp::from_secs(2_000)),
        );
        let forged = signed(
            &stranger,
            EventBuilder::relay_list([(url("wss://forged.example"), None)])
                .custom_created_at(Timestamp::from_secs(9_000)),
        );
        let routes = PeerRoutes::from_events([&old, &forged, &new], &me.public_key());
        assert_eq!(routes.write, vec![url("wss://new.example")]);
    }

    #[test]
    fn plaintext_relays_are_followed_only_on_loopback() {
        let me = Identity::generate();
        let list = signed(
            &me,
            EventBuilder::new(Kind::InboxRelays, "").tags([
                Tag::relay(url("ws://evil.example")),
                Tag::relay(url("ws://127.0.0.1:7777")),
                Tag::relay(url("wss://fine.example")),
            ]),
        );
        let routes = PeerRoutes::from_events([&list], &me.public_key());
        assert_eq!(
            routes.inbox,
            vec![url("ws://127.0.0.1:7777"), url("wss://fine.example")]
        );
    }

    #[test]
    fn sets_are_capped_and_deduplicated() {
        let me = Identity::generate();
        let mut tags: Vec<Tag> = (0..10)
            .map(|i| Tag::relay(url(&format!("wss://r{i}.example"))))
            .collect();
        tags.push(Tag::relay(url("wss://r0.example")));
        let list = signed(&me, EventBuilder::new(Kind::InboxRelays, "").tags(tags));
        let routes = PeerRoutes::from_events([&list], &me.public_key());
        assert_eq!(routes.inbox.len(), MAX_INBOX_RELAYS);
    }

    #[test]
    fn welcome_relays_prefer_inbox_then_read_set() {
        let mut routes = PeerRoutes {
            read: vec![url("wss://read.example")],
            ..PeerRoutes::default()
        };
        assert_eq!(routes.welcome_relays(), vec![url("wss://read.example")]);
        routes.inbox = vec![url("wss://inbox.example")];
        assert_eq!(routes.welcome_relays(), vec![url("wss://inbox.example")]);
    }

    #[test]
    fn group_relays_keep_ours_first_then_interleave_invitees_up_to_the_cap() {
        let own = vec![url("wss://a.example"), url("wss://b.example")];
        let alice = PeerRoutes {
            write: vec![url("wss://a1.example"), url("wss://a2.example")],
            ..PeerRoutes::default()
        };
        let bob = PeerRoutes {
            write: vec![url("wss://b1.example"), url("wss://a.example")],
            ..PeerRoutes::default()
        };
        let relays = group_relays_for(&own, &[alice, bob]);
        assert_eq!(
            relays,
            vec![
                url("wss://a.example"),
                url("wss://b.example"),
                url("wss://a1.example"),
                url("wss://b1.example"),
                url("wss://a2.example"),
            ]
        );

        let many: Vec<PeerRoutes> = (0..10)
            .map(|i| PeerRoutes {
                write: (0..4)
                    .map(|j| url(&format!("wss://p{i}r{j}.example")))
                    .collect(),
                ..PeerRoutes::default()
            })
            .collect();
        assert_eq!(group_relays_for(&own, &many).len(), MAX_GROUP_RELAYS);
    }

    #[test]
    fn plan_publishes_defaults_only_when_nothing_exists() {
        let me = Identity::generate();
        let own = vec![url("wss://ours.example")];
        let action =
            plan_record(None, &own, || default_record(&me, Kind::RelayList, &own)).unwrap();
        let RecordAction::Publish(event) = action else {
            panic!("expected a default publish");
        };
        assert_eq!(event.kind, Kind::RelayList);
        assert_eq!(list_relays(&event), own);
    }

    #[test]
    fn plan_rebroadcasts_a_list_that_names_us_and_adopts_one_that_does_not() {
        let me = Identity::generate();
        let own = vec![url("wss://ours.example")];
        let names_us = signed(
            &me,
            EventBuilder::relay_list([
                (url("wss://theirs.example"), None),
                (url("wss://ours.example"), Some(RelayMetadata::Write)),
            ]),
        );
        let id = names_us.id;
        match plan_record(Some(names_us), &own, || unreachable!()).unwrap() {
            RecordAction::Rebroadcast(event) => assert_eq!(event.id, id),
            other => panic!("expected rebroadcast, got {other:?}"),
        }

        let foreign = signed(
            &me,
            EventBuilder::relay_list([(url("wss://theirs.example"), None)]),
        );
        let id = foreign.id;
        match plan_record(Some(foreign), &own, || unreachable!()).unwrap() {
            RecordAction::Adopt(event) => assert_eq!(event.id, id),
            other => panic!("expected adopt, got {other:?}"),
        }

        // A list naming us only as a READ relay does not carry our
        // KeyPackages, so it is not "names us" for the write set.
        let read_only = signed(
            &me,
            EventBuilder::relay_list([(url("wss://ours.example"), Some(RelayMetadata::Read))]),
        );
        assert!(matches!(
            plan_record(Some(read_only), &own, || unreachable!()).unwrap(),
            RecordAction::Adopt(_)
        ));
    }

    #[test]
    fn default_inbox_puts_the_sonar_relay_first_and_stays_small() {
        let own = vec![
            url("wss://relay.damus.io"),
            url("wss://nos.lol"),
            url("wss://relay.primal.net"),
            url("wss://relay.kaleidoswap.com"),
            url("wss://nostr.relay.hedwig.sh"),
        ];
        assert_eq!(
            default_inbox_relays(&own),
            vec![
                url("wss://nostr.relay.hedwig.sh"),
                url("wss://relay.damus.io"),
                url("wss://nos.lol"),
            ]
        );
    }

    #[test]
    fn default_records_are_signed_by_us_and_never_name_indexers() {
        let me = Identity::generate();
        let own = vec![url("wss://ours.example"), url("wss://also.example")];
        for kind in [
            Kind::RelayList,
            Kind::InboxRelays,
            LEGACY_KEY_PACKAGE_RELAYS_KIND,
        ] {
            let event = default_record(&me, kind, &own).unwrap();
            assert!(event.verify().is_ok());
            assert_eq!(event.pubkey, me.public_key());
            for relay in list_relays(&event) {
                assert!(own.contains(&relay), "{kind:?} named {relay}");
            }
        }
        assert!(default_record(&me, Kind::TextNote, &own).is_err());
    }

    #[test]
    fn public_indexers_never_receive_key_packages() {
        let config = RelayRoutesConfig::public();
        assert!(config.indexers_for(Kind::Custom(30443)).is_empty());
        assert!(!config.indexers_for(Kind::RelayList).is_empty());
        assert!(
            config.indexers_for(Kind::RelayList).len()
                >= config.indexers_for(Kind::InboxRelays).len()
        );
        assert!(config.lookup_relays.len() >= 3);
        assert!(RelayRoutesConfig::disabled().is_disabled());
    }

    #[test]
    fn sidecars_round_trip_and_wipe() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("sonar.db");
        let own = vec![url("wss://ours.example")];
        let router = RelayRouter::new(RelayRoutesConfig::disabled(), own.clone(), Some(&db));
        let peer = Identity::generate().public_key();
        let routes = PeerRoutes {
            inbox: vec![url("wss://inbox.example")],
            ..PeerRoutes::default()
        };
        router.remember_peer_routes(&peer, &routes, now_secs());
        {
            let mut records = router.records.lock().unwrap();
            records.version = RELAY_RECORDS_VERSION;
            records.records.insert(
                Kind::RelayList.as_u16(),
                RecordState {
                    event_id: "ab".into(),
                    created_at: 1,
                    distributed_at: now_secs(),
                    adopted: true,
                    relays: vec![url("wss://theirs.example")],
                },
            );
            store_json(router.records_path.as_deref(), &*records);
        }
        assert!(relay_records_path_for_db(&db).exists());
        assert!(peer_routes_path_for_db(&db).exists());

        let reloaded = RelayRouter::new(RelayRoutesConfig::disabled(), own, Some(&db));
        assert_eq!(reloaded.cached_peer_routes(&peer, now_secs()), Some(routes));
        assert_eq!(
            reloaded.adopted_write_relays(),
            vec![url("wss://theirs.example")]
        );
        assert!(reloaded.distributed_recently(now_secs()));

        wipe_relay_routes_for_db(&db).unwrap();
        assert!(!relay_records_path_for_db(&db).exists());
        assert!(!peer_routes_path_for_db(&db).exists());
        wipe_relay_routes_for_db(&db).unwrap();
    }

    #[test]
    fn a_cached_miss_expires_sooner_than_a_hit() {
        let router = RelayRouter::new(RelayRoutesConfig::disabled(), Vec::new(), None);
        let peer = Identity::generate().public_key();
        let t = 1_000_000u64;
        router.remember_peer_routes(&peer, &PeerRoutes::default(), t);
        assert!(router
            .cached_peer_routes(&peer, t + PEER_ROUTES_NEGATIVE_TTL.as_secs() - 1)
            .is_some());
        assert!(router
            .cached_peer_routes(&peer, t + PEER_ROUTES_NEGATIVE_TTL.as_secs())
            .is_none());
        router.forget_peer_routes(&peer);
        assert!(router.cached_peer_routes(&peer, t).is_none());
    }

    #[test]
    fn foreign_drops_own_relays_and_unusable_urls() {
        let router = RelayRouter::new(
            RelayRoutesConfig::disabled(),
            vec![url("wss://ours.example")],
            None,
        );
        let out = router.foreign([
            url("wss://ours.example"),
            url("wss://theirs.example"),
            url("ws://plain.example"),
            url("wss://theirs.example"),
        ]);
        assert_eq!(out, vec![url("wss://theirs.example")]);
    }
}

#[cfg(test)]
mod pool_tests {
    use super::*;

    /// A route relay is used more than once per pass (looked up, then
    /// published to) and across passes. `release` must leave it in a state
    /// the next `acquire` can connect from: nostr-sdk never reconnects a
    /// relay that was `disconnect`ed (it stays `Terminated`), which is why
    /// release removes it from the pool instead.
    #[tokio::test]
    async fn a_route_relay_can_be_acquired_again_after_release() {
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await;
        let router = RelayRouter::new(
            RelayRoutesConfig::local(vec![url.clone()]),
            Vec::new(),
            None,
        );
        let filter = Filter::new().kind(Kind::Metadata).limit(1);
        for pass in 0..3 {
            let out = router
                .fetch_from(std::slice::from_ref(&url), filter.clone())
                .await;
            assert_eq!(out.completed, 1, "pass {pass} did not reach the relay");
        }
        // Released: gone from the pool, not lingering as a dead handle.
        assert!(router.nostr.relays().await.is_empty());

        // A sticky relay stays connected between uses.
        router.keep_open(std::slice::from_ref(&url));
        let out = router
            .fetch_from(std::slice::from_ref(&url), filter.clone())
            .await;
        assert_eq!(out.completed, 1);
        let status = router
            .nostr
            .relay(url.clone())
            .await
            .expect("kept")
            .status();
        assert_eq!(status, RelayStatus::Connected);
        let out = router.fetch_from(std::slice::from_ref(&url), filter).await;
        assert_eq!(out.completed, 1);
    }
}
