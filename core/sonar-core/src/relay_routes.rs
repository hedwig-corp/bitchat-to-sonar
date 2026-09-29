//! Relay routes: where this account's public records live (#626).
//!
//! Sonar's Marmot pool (`SonarClient::nostr`) is a fixed set of relays every
//! publish and subscription goes to. That is fine between two Sonar installs,
//! which share the set, and invisible to everyone else: a Nostr client that
//! does not happen to sit on one of those relays cannot find our profile or
//! KeyPackage. The Nostr answer is the outbox model — an account publishes
//! small relay lists saying where it writes (kind `10002`, NIP-65) and where
//! it reads gift wraps (kind `10050`, NIP-17), and spreads those lists to a
//! handful of public *indexer* relays that exist only to serve them. Marmot
//! builds on the same two lists: KeyPackages go to the `10002` write set,
//! welcomes to the `10050` inbox set (`marmot/transports/nostr.md`). The older
//! kind `10051` KeyPackage list is gone from the spec but still read by
//! archived White Noise and by Amethyst, so it is published as a
//! compatibility twin of the write set.
//!
//! `RelayRouter::distribute_account_records` looks our lists up first (own
//! relays plus the lookup set) and only then decides:
//!
//! - no lookup relay answered → publish nothing;
//! - nothing found, and fewer than [`absence_quorum`] lookup relays answered
//!   → publish nothing for that kind (a silent one may hold the user's real
//!   list);
//! - nothing found and a quorum answered → publish Sonar's default;
//! - a list that already names one of our relays → copy the *existing signed
//!   event* unchanged;
//! - a list from another client that does not name us → leave it alone and
//!   adopt it (our KeyPackage also goes to its write set).
//!
//! Kinds `10002`/`10050` are replaceable: publishing defaults over an imported
//! account's real lists would replace them network-wide, so "nobody answered"
//! and "one relay answered and had nothing" must never read as "nobody has
//! one". Existence is evidence from a single relay; absence needs a quorum.
//!
//! Finding *other* accounts through their lists (KeyPackage and profile
//! lookups on their relays, welcome routing, group relays) is deliberately not
//! here yet: its payoff is gated on the MDK upgrade that lets non-Sonar
//! Marmot clients talk to Sonar at all. It is parked on #628 / #627.
//!
//! Everything foreign goes through a **second relay pool**, never the Marmot
//! pool: nostr-sdk's pool-wide `send_event` fans out to every WRITE relay and
//! `subscribe` to every READ relay, and `send_event_to` refuses a relay that
//! lacks WRITE, so an indexer added to the main pool would receive every
//! group message and welcome we ever send. Route relays are connected on
//! demand, removed when the operation ends, and never handed to the sync path.

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
const RELAY_RECORDS_VERSION: u32 = 1;

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

/// NIP-17 SHOULD: keep the inbox list small (1–3).
pub const MAX_INBOX_RELAYS: usize = 3;
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

/// How many of the relays asked must answer before "nobody has it" is
/// believed: all but a third, and never fewer than one. Indexers are
/// redundant copies by design (they crawl the network and each other), so
/// one dead indexer must not block every account's lists forever —
/// relay.nostr.band went dark without notice — while one or two answering
/// relays out of five are not enough to call a real list absent.
pub fn absence_quorum(asked: usize) -> usize {
    (asked - asked / 3).max(1)
}

/// NIP-01 replaceable-event order: the newer `created_at` wins, and on a tie
/// the lowest event id. Relays apply exactly this rule, so choosing any other
/// candidate would act on an event compliant relays already dropped.
pub(crate) fn supersedes(candidate: &Event, current: &Event) -> bool {
    candidate.created_at > current.created_at
        || (candidate.created_at == current.created_at && candidate.id < current.id)
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
    /// Nothing found, but not every lookup relay answered, so absence is not
    /// established and no default was published. Retried next pass.
    Deferred {
        answered: usize,
        asked: usize,
    },
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

/// Result of [`RelayRouter::lookup`]. `answered == 0`: nothing can be
/// concluded. Below [`absence_quorum`]: what was found is real, but absence
/// is not established. At or above it: absence is established too.
#[derive(Debug, Default)]
pub struct AccountLookup {
    pub events: Vec<Event>,
    pub answered: usize,
    pub asked: usize,
}

impl AccountLookup {
    pub fn reached_any(&self) -> bool {
        self.answered > 0
    }

    pub fn absence_confirmed(&self) -> bool {
        self.answered > 0 && self.answered >= absence_quorum(self.asked)
    }
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

fn sidecar_path(db_path: &Path, suffix: &str) -> PathBuf {
    let name = db_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("sonar.db");
    db_path.with_file_name(format!("{name}{suffix}"))
}

/// Remove the sidecar (account wipe). Missing file is fine.
pub(crate) fn wipe_relay_routes_for_db(db_path: &Path) -> Result<()> {
    for path in [relay_records_path_for_db(db_path)] {
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

/// Serialize under the lock (cheap); write with `write_sidecar` after the
/// lock is dropped, so a slow disk never stalls other lookups.
fn sidecar_bytes<T: Serialize>(value: &T) -> Option<Vec<u8>> {
    match serde_json::to_vec(value) {
        Ok(b) => Some(b),
        Err(err) => {
            tracing::warn!(%err, "relay routes sidecar serialize failed");
            None
        }
    }
}

/// Atomic write (`<file>.tmp` + rename), like every other sidecar here.
fn write_sidecar(path: Option<&Path>, bytes: Option<Vec<u8>>) {
    let (Some(path), Some(bytes)) = (path, bytes) else {
        return;
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
    records: Mutex<RelayRecordsDisk>,
    /// Sidecar writers queue here so two finishing together cannot persist
    /// the older map last. The in-memory state is never behind this lock.
    sidecar_write_lock: Mutex<()>,
    /// Route relays in use by in-flight operations, so one operation's
    /// release cannot close a socket another still needs.
    in_use: Mutex<HashMap<RelayUrl, usize>>,
    /// One distribution pass at a time: the foreground and background
    /// publish paths can both start one on a first connect, and two passes
    /// that each see "nothing exists" would mint two different defaults.
    distribution_lock: tokio::sync::Mutex<()>,
}

impl RelayRouter {
    pub fn new(
        config: RelayRoutesConfig,
        own_relays: Vec<RelayUrl>,
        db_path: Option<&Path>,
    ) -> Self {
        let records_path = db_path.map(relay_records_path_for_db);
        let mut records: RelayRecordsDisk = load_json(records_path.as_deref());
        if records.version != RELAY_RECORDS_VERSION {
            records = RelayRecordsDisk::default();
        }
        // Public indexers must never be told an account lives on a loopback
        // or private-network relay: that list is useless to everyone and
        // litters a shared directory (a dev build or a test pointed at a
        // local relay with the public set would do exactly that).
        let config = if !config.indexers.is_empty()
            && config == RelayRoutesConfig::public()
            && own_relays.iter().any(|u| u.is_local_addr())
        {
            tracing::warn!("local relays configured: public relay lookups and copies disabled");
            RelayRoutesConfig::disabled()
        } else {
            config
        };
        let config = RelayRoutesConfig {
            lookup_relays: dedupe(config.lookup_relays),
            indexers: config.indexers,
        };
        Self {
            nostr: Client::default(),
            config,
            own_relays: dedupe(own_relays),
            records_path,
            records: Mutex::new(records),
            sidecar_write_lock: Mutex::new(()),
            in_use: Mutex::new(HashMap::new()),
            distribution_lock: tokio::sync::Mutex::new(()),
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

    /// Fresh only when every list kind was distributed inside the interval.
    /// A pass that got the profile out but deferred the lists (a lookup
    /// relay was silent) must run again on the next connect.
    fn distributed_recently(&self, now: u64) -> bool {
        let records = self.records.lock().unwrap();
        [
            Kind::RelayList,
            Kind::InboxRelays,
            LEGACY_KEY_PACKAGE_RELAYS_KIND,
        ]
        .iter()
        .all(|kind| {
            records.records.get(&kind.as_u16()).is_some_and(|r| {
                now.saturating_sub(r.distributed_at) < DISTRIBUTION_MIN_INTERVAL.as_secs()
            })
        })
    }

    // ── Route pool plumbing ──

    /// Add (if needed) and connect `urls`, returning the ones connected
    /// within `ROUTE_CONNECT_TIMEOUT`. Each connected relay is marked in use
    /// until `release` is called with it.
    async fn acquire(&self, urls: &[RelayUrl]) -> Vec<RelayUrl> {
        let urls = dedupe(urls.iter().cloned());
        // Reserve before connecting: a concurrent operation's release must
        // not remove a relay this one is still waiting on.
        {
            let mut in_use = self.in_use.lock().unwrap();
            for url in &urls {
                *in_use.entry(url.clone()).or_insert(0) += 1;
            }
        }
        let mut handles = Vec::with_capacity(urls.len());
        let mut lost = Vec::new();
        for url in urls {
            if let Err(err) = self.nostr.add_relay(url.clone()).await {
                tracing::debug!(%err, relay = %url, "route relay add failed");
                lost.push(url);
                continue;
            }
            match self.nostr.relay(url.clone()).await {
                Ok(handle) => {
                    if handle.status() != RelayStatus::Connected {
                        handle.connect();
                    }
                    handles.push((url, handle));
                }
                Err(err) => {
                    tracing::debug!(%err, relay = %url, "route relay handle missing");
                    lost.push(url);
                }
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
        let mut connected = Vec::new();
        for (url, ok) in futures_util::future::join_all(waits).await {
            if ok {
                connected.push(url);
            } else {
                tracing::debug!(relay = %url, "route relay not connected in time");
                lost.push(url);
            }
        }
        if !lost.is_empty() {
            self.release(&lost).await;
        }
        connected
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
            urls.iter()
                .filter(|url| {
                    let zero = {
                        let count = in_use.entry((*url).clone()).or_insert(0);
                        *count = count.saturating_sub(1);
                        *count == 0
                    };
                    if zero {
                        // No entry outlives its last user: the map stays the
                        // size of the relays in flight, not of every relay
                        // ever touched.
                        in_use.remove(*url);
                    }
                    zero
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
        // One send per relay, each with its own bound: a relay that accepts
        // the socket and never answers must not take the others' OKs with it.
        let sends = connected.iter().map(|url| {
            let nostr = self.nostr.clone();
            let url = url.clone();
            async move {
                let result = tokio::time::timeout(
                    ROUTE_PUBLISH_TIMEOUT,
                    nostr.send_event_to([url.clone()], event),
                )
                .await;
                (url, result)
            }
        });
        for (url, result) in futures_util::future::join_all(sends).await {
            match result {
                Ok(Ok(output)) if output.success.contains(&url) => out.accepted.push(url),
                Ok(Ok(output)) => {
                    let why = output
                        .failed
                        .get(&url)
                        .cloned()
                        .unwrap_or_else(|| "relay rejected event".to_string());
                    out.failed.push((url, why));
                }
                Ok(Err(err)) => out.failed.push((url, err.to_string())),
                Err(_) => out
                    .failed
                    .push((url, "route publish timed out".to_string())),
            }
        }
        self.release(&connected).await;
        out
    }

    /// Write a sidecar from a snapshot taken at this writer's turn. Writers
    /// serialize on `sidecar_write_lock`, and each serializes the *current*
    /// state under the data lock only briefly, so the last write always
    /// carries the newest map and readers never wait on the disk.
    fn persist(&self, path: Option<&Path>, snapshot: impl FnOnce() -> Option<Vec<u8>>) {
        let _turn = self.sidecar_write_lock.lock().unwrap();
        write_sidecar(path, snapshot());
    }

    /// Our own records, looked up on our relays (through the Marmot pool)
    /// and the lookup set (through the route pool), merged, with the answer
    /// count that decides what the result may prove. With a lookup set
    /// configured only its answers count: an imported account's records
    /// usually live on the indexers alone, so our relays answering "nothing"
    /// proves nothing.
    pub async fn lookup(&self, main: &Client, filter: Filter) -> AccountLookup {
        let (own, lookup) = tokio::join!(
            fetch_per_relay(main, &self.own_relays, filter.clone(), ROUTE_FETCH_TIMEOUT),
            self.fetch_from(&self.config.lookup_relays, filter),
        );
        let (answered, asked) = if self.config.lookup_relays.is_empty() {
            (own.completed, own.attempted)
        } else {
            (lookup.completed, lookup.attempted)
        };
        let mut seen: HashSet<EventId> = own.events.iter().map(|e| e.id).collect();
        let mut events = own.events;
        events.extend(lookup.events.into_iter().filter(|e| seen.insert(e.id)));
        AccountLookup {
            events,
            answered,
            asked,
        }
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
        let _pass = self.distribution_lock.lock().await;
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
        let found = self
            .lookup(main, Filter::new().author(me).kinds(RECORD_KINDS))
            .await;
        let (answered, asked) = (found.answered, found.asked);
        // "Nobody answered" is unknown, not absent.
        if !found.reached_any() {
            tracing::warn!(
                asked,
                lookup_relays = self.config.lookup_relays.len(),
                "relay records: lookup reached no relay; publishing nothing"
            );
            report.lookup_failed = true;
            return report;
        }
        // Existence is evidence from a single relay; absence is not. A
        // default would replace a real list network-wide, so "nothing
        // exists" needs a quorum of the lookup relays — a silent one may be
        // the one still holding the user's list.
        let absence_confirmed = found.absence_confirmed();
        let mut newest: HashMap<Kind, Event> = HashMap::new();
        for event in found.events {
            if event.pubkey != me || !RECORD_KINDS.contains(&event.kind) || event.verify().is_err()
            {
                continue;
            }
            if newest
                .get(&event.kind)
                .is_none_or(|cur| supersedes(&event, cur))
            {
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
                        let spread = self.spread(main, &event).await;
                        let accepted = spread.accepted();
                        if spread.stamped() {
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
                        }
                        RecordOutcome::Rebroadcast { accepted }
                    }
                    None => RecordOutcome::Absent,
                }
            } else if existing.is_none() && !absence_confirmed {
                tracing::info!(
                    kind = kind.as_u16(),
                    answered,
                    asked,
                    "relay record not found, but too few lookup relays answered; deferred"
                );
                RecordOutcome::Deferred { answered, asked }
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
                        let spread = self.spread(main, &event).await;
                        let accepted = spread.accepted();
                        if spread.stamped() {
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
                        let spread = self.spread(main, &event).await;
                        let accepted = spread.accepted();
                        // Stamped only when the copy got where it is for: a
                        // copy that reached nothing (or none of the
                        // indexers) is retried next pass, not shelved for
                        // the interval.
                        if spread.stamped() {
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
        // A lookup short of the quorum acts on what it found but stamps
        // nothing: a silent relay may hold a newer list, so the next connect
        // must look again rather than wait out the interval.
        if !absence_confirmed && !states.is_empty() {
            tracing::info!(
                answered,
                asked,
                kinds = states.len(),
                "relay records acted on but not stamped: partial lookup"
            );
            states.clear();
        }
        {
            let mut records = self.records.lock().unwrap();
            records.version = RELAY_RECORDS_VERSION;
            for (kind, state) in states {
                records.records.insert(kind, state);
            }
        }
        self.persist(self.records_path.as_deref(), || {
            sidecar_bytes(&*self.records.lock().unwrap())
        });
        report
    }

    /// Copy one signed record to our relays and to every indexer accepting
    /// its kind.
    async fn spread(&self, main: &Client, event: &Event) -> SpreadOutcome {
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
        SpreadOutcome {
            own: own_accepted,
            indexers: routed.accepted.len(),
            indexers_asked: indexers.len(),
        }
    }
}

/// Where one record copy landed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SpreadOutcome {
    pub own: usize,
    pub indexers: usize,
    pub indexers_asked: usize,
}

impl SpreadOutcome {
    pub fn accepted(&self) -> usize {
        self.own + self.indexers
    }

    /// Distributed for the purposes of the interval: on at least one of our
    /// relays, and — when any indexer takes this kind — on at least one
    /// indexer. Our relays alone do not make the account findable, which is
    /// the whole point of the copy.
    pub fn stamped(&self) -> bool {
        self.own > 0 && (self.indexers_asked == 0 || self.indexers > 0)
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

    /// NIP-65 markers decide the write set (unmarked means both); the
    /// other list kinds use plain `relay` tags. Plaintext relays are
    /// followed only on loopback.
    #[test]
    fn list_relays_reads_the_write_set_of_10002_and_relay_tags_otherwise() {
        let me = Identity::generate();
        let outbox = signed(
            &me,
            EventBuilder::relay_list([
                (url("wss://w.example"), Some(RelayMetadata::Write)),
                (url("wss://r.example"), Some(RelayMetadata::Read)),
                (url("wss://both.example"), None),
                (url("ws://plain.example"), None),
            ]),
        );
        assert_eq!(
            list_relays(&outbox),
            vec![url("wss://w.example"), url("wss://both.example")]
        );
        let inbox = signed(
            &me,
            EventBuilder::new(Kind::InboxRelays, "").tags([
                Tag::relay(url("wss://inbox.example")),
                Tag::relay(url("ws://127.0.0.1:7777")),
                Tag::relay(url("ws://evil.example")),
            ]),
        );
        assert_eq!(
            list_relays(&inbox),
            vec![url("wss://inbox.example"), url("ws://127.0.0.1:7777")]
        );
    }

    /// NIP-01 replaceable order: newest `created_at`, then the LOWEST id on
    /// a tie — the event relays keep. Two devices publishing in the same
    /// second must not make Sonar act on the one relays already dropped.
    #[test]
    fn supersedes_follows_nip01_newest_then_lowest_id() {
        let me = Identity::generate();
        let at = |secs: u64, relay: &str| {
            signed(
                &me,
                EventBuilder::relay_list([(url(relay), None)])
                    .custom_created_at(Timestamp::from_secs(secs)),
            )
        };
        let old = at(1_000, "wss://old.example");
        let new = at(2_000, "wss://new.example");
        assert!(supersedes(&new, &old));
        assert!(!supersedes(&old, &new));

        let a = at(3_000, "wss://a.example");
        let b = at(3_000, "wss://b.example");
        let (low, high) = if a.id < b.id { (a, b) } else { (b, a) };
        assert!(supersedes(&low, &high));
        assert!(!supersedes(&high, &low));
        assert!(!supersedes(&low, &low));
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
            // Fresh only with every list kind recorded (a pass that
            // deferred a kind must run again).
            for kind in [Kind::InboxRelays, LEGACY_KEY_PACKAGE_RELAYS_KIND] {
                records.records.insert(
                    kind.as_u16(),
                    RecordState {
                        event_id: "cd".into(),
                        created_at: 1,
                        distributed_at: now_secs(),
                        adopted: false,
                        relays: own.clone(),
                    },
                );
            }
            drop(records);
            router.persist(router.records_path.as_deref(), || {
                sidecar_bytes(&*router.records.lock().unwrap())
            });
        }
        assert!(relay_records_path_for_db(&db).exists());

        let reloaded = RelayRouter::new(RelayRoutesConfig::disabled(), own, Some(&db));
        assert_eq!(
            reloaded.adopted_write_relays(),
            vec![url("wss://theirs.example")]
        );
        assert!(reloaded.distributed_recently(now_secs()));
        reloaded
            .records
            .lock()
            .unwrap()
            .records
            .remove(&Kind::InboxRelays.as_u16());
        assert!(!reloaded.distributed_recently(now_secs()));

        wipe_relay_routes_for_db(&db).unwrap();
        assert!(!relay_records_path_for_db(&db).exists());
        wipe_relay_routes_for_db(&db).unwrap();
    }

    /// One dead indexer out of five must not block absence forever; one or
    /// two answers out of five must not establish it.
    #[test]
    fn absence_needs_all_but_a_third_of_the_relays_asked() {
        assert_eq!(absence_quorum(0), 1);
        assert_eq!(absence_quorum(1), 1);
        assert_eq!(absence_quorum(2), 2);
        assert_eq!(absence_quorum(3), 2);
        assert_eq!(absence_quorum(5), 4);
        assert_eq!(absence_quorum(6), 4);
        let at = |answered, asked| AccountLookup {
            events: Vec::new(),
            answered,
            asked,
        };
        assert!(!at(0, 5).absence_confirmed());
        assert!(!at(3, 5).absence_confirmed());
        assert!(at(4, 5).absence_confirmed());
        assert!(!at(1, 2).absence_confirmed());
        assert!(at(0, 5).answered == 0 && !at(0, 5).reached_any());
    }

    /// A copy counts as distributed only when it reached one of our relays
    /// and, if any indexer takes the kind, one indexer: our relays alone do
    /// not make the account findable, so that pass must be retried.
    #[test]
    fn a_record_is_stamped_only_when_an_indexer_took_it() {
        let only_own = SpreadOutcome {
            own: 3,
            indexers: 0,
            indexers_asked: 4,
        };
        assert!(!only_own.stamped());
        assert_eq!(only_own.accepted(), 3);
        assert!(SpreadOutcome {
            own: 1,
            indexers: 1,
            indexers_asked: 4
        }
        .stamped());
        assert!(!SpreadOutcome {
            own: 0,
            indexers: 4,
            indexers_asked: 4
        }
        .stamped());
        // No indexer takes the kind (or none configured): our relays suffice.
        assert!(SpreadOutcome {
            own: 1,
            indexers: 0,
            indexers_asked: 0
        }
        .stamped());
    }

    /// A dev build or test pointed at a local relay must not publish lists
    /// naming it to the shared public directory.
    #[test]
    fn public_indexers_are_dropped_when_our_relays_are_local() {
        let local = RelayRouter::new(
            RelayRoutesConfig::public(),
            vec![url("ws://127.0.0.1:7777")],
            None,
        );
        assert!(local.config().is_disabled());
        let real = RelayRouter::new(
            RelayRoutesConfig::public(),
            vec![url("wss://relay.damus.io")],
            None,
        );
        assert!(!real.config().is_disabled());
        let test_dir = RelayRouter::new(
            RelayRoutesConfig::local(vec![url("ws://127.0.0.1:8888")]),
            vec![url("ws://127.0.0.1:7777")],
            None,
        );
        assert!(
            !test_dir.config().is_disabled(),
            "an explicit local directory stays"
        );
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
        // Released: gone from the pool, not lingering as a dead handle, and
        // no zero-count bookkeeping left behind.
        assert!(router.nostr.relays().await.is_empty());
        assert!(router.in_use.lock().unwrap().is_empty());
    }

    /// Two operations on one route relay at the same time: the first to
    /// finish must not pull the socket out from under the second (the
    /// in-use count is reserved before the connect wait, not after).
    #[tokio::test]
    async fn overlapping_operations_share_a_route_relay() {
        let relay = nostr_relay_builder::MockRelay::run()
            .await
            .expect("mock relay starts");
        let url = relay.url().await;
        let router = RelayRouter::new(RelayRoutesConfig::disabled(), Vec::new(), None);
        let filter = Filter::new().kind(Kind::Metadata).limit(1);
        for _ in 0..3 {
            let (a, b) = tokio::join!(
                router.fetch_from(std::slice::from_ref(&url), filter.clone()),
                router.fetch_from(std::slice::from_ref(&url), filter.clone()),
            );
            assert_eq!((a.completed, b.completed), (1, 1));
        }
        assert!(router.nostr.relays().await.is_empty());
    }
}
