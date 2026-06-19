//! Relay-connected Sonar client: ties an [`Identity`] + [`MarmotEngine`] to
//! nostr relays. This is the async I/O layer; all protocol logic lives in
//! [`crate::marmot`].
//!
//! M1 scope: explicit polling via [`SonarClient::sync`] (deterministic for
//! e2e tests). Live subscriptions land with the native shells.

use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use mdk_core::prelude::*;
use nostr::prelude::*;
use nostr_blossom::prelude::*;
use nostr_sdk::{Client, RelayPoolNotification};
use serde::{Deserialize, Serialize};

use sonar_stickers::{parse_pack_event, StickerPack, StickerRef, STICKER_PACK_KIND};

use crate::conversation_index::{
    index_db_path_for_db, wipe_index_for_db, ConversationChangeListener, ConversationIndex,
    ConversationSummary,
};
use crate::identity::Identity;
use crate::invite_link::invite_link_state_path_for_db;
use crate::marmot::{
    ChatMessage, DeliveryState, GroupCreation, GroupInvite, GroupMembershipUpdate, Incoming,
    MarmotEngine, RecentMessagePage, KEY_PACKAGE_KIND, SYNC_STATE_FILE_SUFFIX,
};
use crate::outbox::{outbox_state_path_for_db, OutboxState};
use crate::sonar_descriptor::{
    descriptor_content_json, descriptor_d_tags, descriptor_tags, meta_descriptor_content_json,
    parse_descriptor_event, SonarDescriptor, SONAR_CALL_DESCRIPTOR_D_TAG, SONAR_DESCRIPTOR_KIND,
    SONAR_META_DESCRIPTOR_D_TAG,
};
use crate::{Error, Result};

/// Blossom user-server-list event kind (BUD-03): the user's preferred blob
/// servers, newest first.
const BLOSSOM_SERVER_LIST_KIND: u16 = 10063;

/// Fallback Blossom server when the user has published no kind-10063 list.
pub const DEFAULT_BLOSSOM_SERVER: &str = "https://blossom.primal.net";

/// Hard ceiling on a single downloaded media blob. The URL comes from the
/// SENDER (untrusted), so this bounds memory use against a malicious/huge blob.
/// Comfortably above any real image while well under MDK's 100 MB MIP-04 limit.
const MAX_MEDIA_DOWNLOAD_BYTES: usize = 25 * 1024 * 1024;
const MEDIA_DOWNLOAD_ATTEMPTS: usize = 3;
const MEDIA_DOWNLOAD_RETRY_DELAY: Duration = Duration::from_millis(350);
const SONAR_DIRECT_DM_DESCRIPTION: &str = "sonar.direct-dm.v1";

/// Shared HTTP client for Blossom media downloads. Built once so every blob
/// reuses keep-alive connections + the TLS session cache instead of paying a
/// fresh connect + handshake per download (the White Noise reference client
/// keeps a single static client for exactly this reason).
static HTTP_CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(60))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new())
});

/// Download raw bytes for an encrypted media blob by its full imeta URL.
///
/// Hardening (the URL is attacker-controllable — it is whatever the message
/// sender put in the imeta tag): require **https** (no SSRF to plaintext/local
/// schemes) and stream with a hard size cap (no memory-DoS from a server that
/// lies about / omits Content-Length). Integrity is still verified afterwards by
/// `decrypt_from_download` (AEAD + original-hash check).
async fn http_get(url: &str) -> Result<Vec<u8>> {
    if !url.starts_with("https://") {
        return Err(Error::Http(format!("refusing non-https media url: {url}")));
    }
    let mut resp = HTTP_CLIENT
        .get(url)
        .send()
        .await
        .map_err(|e| Error::Http(e.to_string()))?;
    if !resp.status().is_success() {
        return Err(Error::Http(format!("GET {url} -> HTTP {}", resp.status())));
    }
    if let Some(len) = resp.content_length() {
        if len as usize > MAX_MEDIA_DOWNLOAD_BYTES {
            return Err(Error::Http(format!(
                "media too large: {len} bytes (cap {MAX_MEDIA_DOWNLOAD_BYTES})"
            )));
        }
    }
    let mut out: Vec<u8> = Vec::new();
    while let Some(chunk) = resp.chunk().await.map_err(|e| Error::Http(e.to_string()))? {
        if out.len() + chunk.len() > MAX_MEDIA_DOWNLOAD_BYTES {
            return Err(Error::Http("media exceeds size cap".into()));
        }
        out.extend_from_slice(&chunk);
    }
    Ok(out)
}

/// Download public bytes from an HTTPS URL (for plaintext sticker images).
pub async fn http_get_public(url: &str) -> Result<Vec<u8>> {
    http_get(url).await
}

async fn http_get_with_retries(url: &str) -> Result<Vec<u8>> {
    for attempt in 1..=MEDIA_DOWNLOAD_ATTEMPTS {
        match http_get(url).await {
            Ok(bytes) => return Ok(bytes),
            Err(error)
                if attempt < MEDIA_DOWNLOAD_ATTEMPTS && retryable_media_http_error(&error) =>
            {
                tokio::time::sleep(MEDIA_DOWNLOAD_RETRY_DELAY).await;
            }
            Err(error) => return Err(error),
        }
    }
    unreachable!("media download retry loop always returns");
}

fn retryable_media_http_error(error: &Error) -> bool {
    let Error::Http(message) = error else {
        return false;
    };
    if message.contains("refusing non-https")
        || message.contains("media too large")
        || message.contains("media exceeds size cap")
    {
        return false;
    }
    if message.contains("HTTP 4") && !message.contains("HTTP 408") && !message.contains("HTTP 429")
    {
        return false;
    }
    true
}

const FETCH_TIMEOUT: Duration = Duration::from_secs(10);

/// Extra lookback applied ONLY to the gift-wrap (welcome) `.since` filter.
/// NIP-59 deliberately backdates a gift wrap's `created_at` (up to ~2 days, we
/// use a comfortable margin) to defeat timing analysis, so a tight watermark
/// would silently miss a just-received welcome. Mirrors White Noise's
/// `GIFTWRAP_LOOKBACK_BUFFER`.
const GIFTWRAP_LOOKBACK_SECS: u64 = 7 * 24 * 60 * 60;

/// Safety overlap subtracted from the watermark on every incremental fetch, to
/// cover clock skew and events that landed on a relay mid-sync. Already-seen
/// events are tolerated (MDK dedups on processing), so a small overlap is free.
const SYNC_OVERLAP_SECS: u64 = 5 * 60;

/// Stable subscription ids for the live Marmot tail (so re-subscribing the
/// group filter REPLACES it rather than stacking new subscriptions).
const SUB_MARMOT_WELCOMES: &str = "sonar-marmot-welcomes";
const SUB_MARMOT_GROUPS: &str = "sonar-marmot-groups";

/// Hard cap on the live Marmot event buffer. The handler pushes here while the
/// host drains via `drain_pending_marmot`; if a host has not wired draining yet
/// (e.g. a platform still on the poll path), this bounds memory — dropped live
/// events are recovered by the watermarked `sync()` safety net, so capping never
/// loses a message permanently. When full, the oldest half is dropped (amortizes
/// the shift cost vs dropping one-at-a-time).
const MARMOT_BUFFER_CAP: usize = 1024;

const SYNC_STATE_VERSION: u32 = 1;
const SYNC_STATE_PROCESSED_EVENT_CAP: usize = 20_000;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct SyncStateDisk {
    version: u32,
    watermark_secs: u64,
    processed_event_ids: Vec<String>,
}

#[derive(Debug)]
struct SyncState {
    path: Option<PathBuf>,
    watermark_secs: u64,
    processed_event_ids: HashSet<String>,
    processed_event_order: VecDeque<String>,
    dirty: bool,
}

impl SyncState {
    fn load(path: Option<PathBuf>, fallback_watermark_secs: u64, storage_empty: bool) -> Self {
        if storage_empty {
            return Self::new(path, 0, Vec::new());
        }

        let disk = path
            .as_ref()
            .and_then(|path| fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice::<SyncStateDisk>(&bytes).ok())
            .filter(|state| state.version == SYNC_STATE_VERSION);

        let (disk_watermark, processed_event_ids) = disk
            .map(|state| (state.watermark_secs, state.processed_event_ids))
            .unwrap_or((0, Vec::new()));
        let watermark_secs = conservative_watermark(disk_watermark, fallback_watermark_secs);

        Self::new(path, watermark_secs, processed_event_ids)
    }

    fn new(path: Option<PathBuf>, watermark_secs: u64, processed_event_ids: Vec<String>) -> Self {
        let mut state = Self {
            path,
            watermark_secs,
            processed_event_ids: HashSet::new(),
            processed_event_order: VecDeque::new(),
            dirty: false,
        };
        for id in processed_event_ids {
            state.mark_processed_id(id);
        }
        state.dirty = false;
        state
    }

    fn watermark_secs(&self) -> u64 {
        self.watermark_secs
    }

    fn has_processed(&self, event_id: &str) -> bool {
        self.processed_event_ids.contains(event_id)
    }

    fn mark_processed(&mut self, event_id: &EventId) {
        self.mark_processed_id(event_id.to_hex());
    }

    fn mark_processed_id(&mut self, event_id: String) {
        if !self.processed_event_ids.insert(event_id.clone()) {
            return;
        }
        self.processed_event_order.push_back(event_id);
        while self.processed_event_order.len() > SYNC_STATE_PROCESSED_EVENT_CAP {
            if let Some(oldest) = self.processed_event_order.pop_front() {
                self.processed_event_ids.remove(&oldest);
            }
        }
        self.dirty = true;
    }

    fn advance_watermark(&mut self, watermark_secs: u64) {
        if watermark_secs > self.watermark_secs {
            self.watermark_secs = watermark_secs;
            self.dirty = true;
        }
    }

    fn rewind_for_retry(&mut self, event_secs: u64) {
        if self.watermark_secs == 0 {
            return;
        }
        let retry_from = event_secs.saturating_sub(SYNC_OVERLAP_SECS);
        if retry_from < self.watermark_secs {
            self.watermark_secs = retry_from;
            self.dirty = true;
        }
    }

    fn save_if_dirty(&mut self) -> Result<()> {
        if !self.dirty {
            return Ok(());
        }
        let Some(path) = self.path.as_ref() else {
            self.dirty = false;
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| {
                Error::Storage(format!("create sync-state dir {}: {e}", parent.display()))
            })?;
        }
        let disk = SyncStateDisk {
            version: SYNC_STATE_VERSION,
            watermark_secs: self.watermark_secs,
            processed_event_ids: self.processed_event_order.iter().cloned().collect(),
        };
        let bytes = serde_json::to_vec(&disk)?;
        let tmp = sync_state_tmp_path(path);
        fs::write(&tmp, bytes)
            .map_err(|e| Error::Storage(format!("write sync state {}: {e}", tmp.display())))?;
        fs::rename(&tmp, path)
            .map_err(|e| Error::Storage(format!("replace sync state {}: {e}", path.display())))?;
        self.dirty = false;
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct MarmotProcessReport {
    processed: usize,
    retryable_failures: usize,
    oldest_retryable_secs: Option<u64>,
}

impl MarmotProcessReport {
    fn record_processed(&mut self) {
        self.processed += 1;
    }

    fn record_retryable(&mut self, event_secs: u64) {
        self.retryable_failures += 1;
        self.oldest_retryable_secs = Some(
            self.oldest_retryable_secs
                .map_or(event_secs, |oldest| oldest.min(event_secs)),
        );
    }

    fn absorb(&mut self, other: Self) {
        self.processed += other.processed;
        self.retryable_failures += other.retryable_failures;
        if let Some(secs) = other.oldest_retryable_secs {
            self.oldest_retryable_secs = Some(
                self.oldest_retryable_secs
                    .map_or(secs, |oldest| oldest.min(secs)),
            );
        }
    }
}

/// One received geohash channel event (ephemeral kind-20000), buffered from the
/// live subscription. Geohash channels are public ephemeral events — relays do
/// NOT store them, so we accumulate them in memory as the subscription delivers.
struct RawGeo {
    id: String,
    pubkey: PublicKey,
    nickname: String,
    content: String,
    ts: u64,
}

/// One received geohash 1:1 DM (NIP-17 over the per-geohash identity).
struct RawGeoDm {
    id: String,
    sender: PublicKey,
    content: String,
    ts: u64,
    mine: bool,
}

type GeoDmBuf = Arc<Mutex<HashMap<(String, String), Vec<RawGeoDm>>>>;

/// Live presence (kind-20001) per geohash channel: participant pubkey hex →
/// last-seen unix seconds. Presence events are ephemeral heartbeats, so we keep
/// only the most recent timestamp per participant and count those still within
/// the TTL when reporting "N here now".
type GeoPresenceBuf = Arc<Mutex<HashMap<String, HashMap<String, u64>>>>;

/// How long a presence heartbeat keeps a participant counted as "here now".
/// iOS re-broadcasts kind-20001 every 40-80s, well within this window.
const PRESENCE_TTL_SECS: u64 = 300;

/// A user's public Nostr profile (kind-0 metadata, NIP-01). Marmot identity IS
/// a Nostr pubkey (MIP-00), and MIP-00 leaves display names out of scope, so the
/// standard Nostr profile mechanism resolves a member's human-readable name and
/// avatar. All fields are optional (a peer may not have published a profile).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Profile {
    pub name: Option<String>,
    pub display_name: Option<String>,
    pub about: Option<String>,
    pub picture: Option<String>,
    pub nip05: Option<String>,
}

impl Profile {
    /// The best human-readable label: display_name, else name, else None.
    pub fn best_name(&self) -> Option<&str> {
        self.display_name
            .as_deref()
            .filter(|s| !s.trim().is_empty())
            .or_else(|| self.name.as_deref().filter(|s| !s.trim().is_empty()))
    }
}

pub struct SonarClient {
    engine: MarmotEngine,
    nostr: Client,
    relays: Vec<RelayUrl>,
    geo: Arc<Mutex<HashMap<String, Vec<RawGeo>>>>,
    geo_dm: GeoDmBuf,
    geo_presence: GeoPresenceBuf,
    geo_subscribed: Arc<Mutex<HashSet<String>>>,
    identity_secret: [u8; 32],
    /// Durable relay sync cursor plus recently processed event IDs. This keeps
    /// restart catch-up conservative: a failed event can be replayed later
    /// instead of being skipped by an advanced watermark.
    sync_state: Arc<Mutex<SyncState>>,
    /// Durable local delivery metadata for Signal-style outgoing text sends.
    /// The actual decrypted message body stays in MDK storage; this sidecar
    /// records pending/sent/failed state and the encrypted relay event to retry.
    outbox_state: Arc<Mutex<OutboxState>>,
    /// Live Marmot events (welcomes 1059→us + group 445s) pushed by the
    /// notification handler. Drained + MLS-processed on the host's serialized
    /// engine thread via `drain_pending_marmot` — the handler NEVER touches the
    /// engine, so MLS state mutation stays single-threaded (the MLS invariant).
    pending_marmot: Arc<Mutex<Vec<Event>>>,
    /// Fired whenever a live Marmot event is buffered, so `wait_for_marmot_event`
    /// wakes the host to drain in real time (push) instead of polling.
    marmot_notify: Arc<tokio::sync::Notify>,
    /// True after the real-session Marmot live tail is opened. Local group
    /// changes use this to decide whether to refresh the live kind-445 filter.
    live_marmot_enabled: Arc<Mutex<bool>>,
    /// The group-id set currently installed in the live kind-445 subscription.
    /// This prevents stacking duplicate REQs and lets deletes narrow/unsubscribe.
    marmot_group_subscriptions: Arc<Mutex<HashSet<String>>>,
    /// Startup repair queue for existing groups whose local DB has MLS/group
    /// state but no chat-message page. This covers older installs where the
    /// sync watermark could be advanced by membership/commit events before the
    /// transcript body was locally populated.
    initial_empty_transcript_backfills: Arc<Mutex<HashSet<String>>>,
    initial_backfill_scanned: Arc<AtomicBool>,
    /// Whether to join geohash-nearest relays on subscribe (real sessions); off
    /// for in-memory/test sessions so they stay network-free against a MockRelay.
    allow_geo_relays: bool,
    /// Persistent conversation-summary index (None for in-memory sessions).
    conversation_index: Option<Arc<Mutex<ConversationIndex>>>,
    /// Host-registered callback fired when a conversation summary changes.
    change_listener: Arc<Mutex<Option<Arc<dyn ConversationChangeListener>>>>,
    /// In-memory store for invite link secrets and pending join requests.
    invite_links: Arc<crate::invite_link::InviteLinkStore>,
}

impl SonarClient {
    /// Connect an identity to the given relays with a persistent, encrypted
    /// SQLCipher store at `db_path`.
    ///
    /// `db_key` is the 32-byte SQLCipher key, owned by the host (Keychain on
    /// iOS). The parent directory of `db_path` must already exist. Marmot state
    /// (groups, messages, MLS secrets) survives process restarts: reconnecting
    /// at the same path with the same key reopens the same database.
    pub async fn connect(
        identity: Identity,
        relays: Vec<RelayUrl>,
        db_path: impl AsRef<Path>,
        db_key: [u8; 32],
    ) -> Result<Self> {
        let db_path = db_path.as_ref();
        let engine = MarmotEngine::persistent(identity.clone(), db_path, db_key)?;
        let index_path = index_db_path_for_db(db_path);
        let index = match ConversationIndex::open(&index_path, db_key) {
            Ok(idx) => Some(idx),
            Err(err) => {
                tracing::warn!(%err, "conversation index open failed; continuing without");
                None
            }
        };
        let mut client = Self::with_engine(
            identity,
            relays,
            engine,
            true,
            Some(sync_state_path_for_db(db_path)),
            Some(outbox_state_path_for_db(db_path)),
            Some(invite_link_state_path_for_db(db_path)),
            index.map(|idx| Arc::new(Mutex::new(idx))),
        )
        .await?;
        client.materialize_index_if_empty();
        Ok(client)
    }

    /// Connect with a volatile in-memory store. State is lost when the client is
    /// dropped. Intended for tests and ephemeral/anonymous sessions.
    pub async fn connect_in_memory(identity: Identity, relays: Vec<RelayUrl>) -> Result<Self> {
        let engine = MarmotEngine::in_memory(identity.clone());
        Self::with_engine(identity, relays, engine, false, None, None, None, None).await
    }

    async fn with_engine(
        identity: Identity,
        relays: Vec<RelayUrl>,
        engine: MarmotEngine,
        allow_geo_relays: bool,
        sync_state_path: Option<PathBuf>,
        outbox_state_path: Option<PathBuf>,
        invite_link_state_path: Option<PathBuf>,
        conversation_index: Option<Arc<Mutex<ConversationIndex>>>,
    ) -> Result<Self> {
        let nostr = Client::new(identity.keys().clone());
        for relay in &relays {
            nostr.add_relay(relay.clone()).await?;
        }
        nostr.connect().await;

        // Background collector for geohash channel events (kind-20000, public,
        // ephemeral) and geohash 1:1 DMs (kind-1059 NIP-17 gift wraps). Both are
        // delivered live to active subscriptions; relays don't store them.
        let geo: Arc<Mutex<HashMap<String, Vec<RawGeo>>>> = Arc::new(Mutex::new(HashMap::new()));
        let geo_dm: GeoDmBuf = Arc::new(Mutex::new(HashMap::new()));
        let geo_presence: GeoPresenceBuf = Arc::new(Mutex::new(HashMap::new()));
        let geo_subscribed: Arc<Mutex<HashSet<String>>> = Arc::new(Mutex::new(HashSet::new()));
        let identity_secret = identity.keys().secret_key().to_secret_bytes();

        let pending_marmot: Arc<Mutex<Vec<Event>>> = Arc::new(Mutex::new(Vec::new()));
        let marmot_notify = Arc::new(tokio::sync::Notify::new());
        let live_marmot_enabled = Arc::new(Mutex::new(false));
        let marmot_group_subscriptions = Arc::new(Mutex::new(HashSet::new()));
        let initial_empty_transcript_backfills = Arc::new(Mutex::new(HashSet::new()));
        let initial_backfill_scanned = Arc::new(AtomicBool::new(false));

        let handler_geo = geo.clone();
        let handler_dm = geo_dm.clone();
        let handler_presence = geo_presence.clone();
        let handler_subs = geo_subscribed.clone();
        let handler_pending = pending_marmot.clone();
        let handler_notify = marmot_notify.clone();
        // Our MAIN identity pubkey hex: a kind-1059 with this `p` tag is a Marmot
        // welcome (vs a geohash DM, whose `p` is a per-geohash ephemeral key).
        let my_pubkey_hex = identity.keys().public_key().to_hex();
        let mut notifications = nostr.notifications();
        tokio::spawn(async move {
            loop {
                let notification = match notifications.recv().await {
                    Ok(n) => n,
                    // The notification stream is a BOUNDED tokio broadcast. A busy
                    // channel (e.g. a whole-country region geohash with many
                    // people broadcasting presence + messages) can make us fall
                    // behind: `Lagged` means some events were dropped — keep
                    // going, do NOT exit. The old `while let Ok` killed the
                    // collector permanently on the first lag, so Android stopped
                    // seeing ANY participants/messages while iOS (no such loop)
                    // kept working.
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                };
                let RelayPoolNotification::Event { event, .. } = notification else {
                    continue;
                };
                match event.kind.as_u16() {
                    20000 => {
                        let Some(geohash) = tag_value(&event, Alphabet::G) else {
                            continue;
                        };
                        let nickname = tag_value(&event, Alphabet::N).unwrap_or_default();
                        let id = event.id.to_hex();
                        let ts = event.created_at.as_secs();
                        // Count a message AUTHOR as an active participant too —
                        // iOS's GeohashParticipantTracker counts both message
                        // authors and presence broadcasters within the activity
                        // window, so a busy channel shows e.g. "5 here now" even
                        // if those people aren't sending presence heartbeats.
                        // Counting only presence (the old behaviour) showed "1".
                        {
                            let mut pmap = handler_presence.lock().unwrap();
                            let slot = pmap
                                .entry(geohash.clone())
                                .or_default()
                                .entry(event.pubkey.to_hex())
                                .or_insert(0);
                            if ts > *slot {
                                *slot = ts;
                            }
                        }
                        let mut map = handler_geo.lock().unwrap();
                        let bucket = map.entry(geohash).or_default();
                        if !bucket.iter().any(|r| r.id == id) {
                            bucket.push(RawGeo {
                                id,
                                pubkey: event.pubkey,
                                nickname,
                                content: event.content.clone(),
                                ts,
                            });
                        }
                    }
                    20001 => {
                        // Presence heartbeat: record the freshest timestamp per
                        // participant so "N here now" counts live participants.
                        let Some(geohash) = tag_value(&event, Alphabet::G) else {
                            continue;
                        };
                        let mut map = handler_presence.lock().unwrap();
                        let bucket = map.entry(geohash).or_default();
                        let ts = event.created_at.as_secs();
                        let slot = bucket.entry(event.pubkey.to_hex()).or_insert(0);
                        if ts > *slot {
                            *slot = ts;
                        }
                    }
                    1059 => {
                        // Gift wrap: the `p` tag names the recipient key.
                        let Some(p_hex) = tag_value(&event, Alphabet::P) else {
                            continue;
                        };
                        // Addressed to our MAIN identity → a Marmot welcome.
                        // Buffer it (do NOT touch the MLS engine here) and wake
                        // the host to drain + process it on its engine thread.
                        if p_hex == my_pubkey_hex {
                            {
                                let mut buf = handler_pending.lock().unwrap();
                                if buf.len() >= MARMOT_BUFFER_CAP {
                                    buf.drain(0..MARMOT_BUFFER_CAP / 2);
                                }
                                buf.push((*event).clone());
                            }
                            handler_notify.notify_one();
                            continue;
                        }
                        // Otherwise the `p` tag names a per-geohash recipient key:
                        // find which active channel it targets, unwrap with that
                        // key, and record the kind-14 DM.
                        let subs: Vec<String> =
                            handler_subs.lock().unwrap().iter().cloned().collect();
                        for geohash in subs {
                            let Ok(keys) =
                                crate::geohash::derive_geohash_keys(&identity_secret, &geohash)
                            else {
                                continue;
                            };
                            if keys.public_key().to_hex() != p_hex {
                                continue;
                            }
                            if let Ok(unwrapped) =
                                UnwrappedGift::from_gift_wrap(&keys, &event).await
                            {
                                if unwrapped.rumor.kind.as_u16() != 14 {
                                    break;
                                }
                                let peer_hex = unwrapped.sender.to_hex();
                                let id = unwrapped
                                    .rumor
                                    .id
                                    .map(|i| i.to_hex())
                                    .unwrap_or_else(|| event.id.to_hex());
                                let mut map = handler_dm.lock().unwrap();
                                let bucket = map.entry((geohash.clone(), peer_hex)).or_default();
                                if !bucket.iter().any(|r| r.id == id) {
                                    bucket.push(RawGeoDm {
                                        id,
                                        sender: unwrapped.sender,
                                        content: unwrapped.rumor.content.clone(),
                                        ts: unwrapped.rumor.created_at.as_secs(),
                                        mine: false,
                                    });
                                }
                            }
                            break;
                        }
                    }
                    445 => {
                        // Live MLS group message for one of our subscribed groups
                        // (the relay only sends 445s matching our `#h` filter).
                        // Buffer + wake; processing happens on the host's engine
                        // thread via drain_pending_marmot.
                        {
                            let mut buf = handler_pending.lock().unwrap();
                            if buf.len() >= MARMOT_BUFFER_CAP {
                                buf.drain(0..MARMOT_BUFFER_CAP / 2);
                            }
                            buf.push((*event).clone());
                        }
                        handler_notify.notify_one();
                    }
                    _ => {}
                }
            }
        });

        // Resume incremental sync across restarts: start the watermark at the
        // newest event already in the store (see `latest_message_secs`), so a
        // relaunch fetches only what is new instead of re-downloading the entire
        // White Noise history every time. The gift-wrap fetch still applies its
        // 7-day NIP-59 lookback on top of this.
        let resume_watermark = engine.latest_message_secs();
        let storage_empty = resume_watermark == 0
            && engine
                .groups()
                .map(|groups| groups.is_empty())
                .unwrap_or(true);
        let sync_state = Arc::new(Mutex::new(SyncState::load(
            sync_state_path,
            resume_watermark,
            storage_empty,
        )));
        let outbox_state = Arc::new(Mutex::new(OutboxState::load(outbox_state_path)));
        let client = Self {
            engine,
            nostr,
            relays,
            geo,
            geo_dm,
            geo_presence,
            geo_subscribed,
            identity_secret,
            sync_state,
            outbox_state,
            pending_marmot,
            marmot_notify,
            live_marmot_enabled,
            marmot_group_subscriptions,
            initial_empty_transcript_backfills,
            initial_backfill_scanned,
            allow_geo_relays,
            conversation_index,
            change_listener: Arc::new(Mutex::new(None)),
            invite_links: Arc::new(crate::invite_link::InviteLinkStore::load(
                invite_link_state_path,
            )),
        };
        // Open the live Marmot subscriptions for real sessions. In-memory test
        // sessions (allow_geo_relays=false) stay on the explicit `sync()` path so
        // the e2e tests remain deterministic and network-shaped.
        if allow_geo_relays {
            if let Err(err) = client.subscribe_marmot().await {
                tracing::debug!(%err, "marmot live subscribe failed (sync() still covers it)");
            }
            client.retry_outbox().await;
        }
        Ok(client)
    }

    pub fn identity(&self) -> &Identity {
        self.engine.identity()
    }

    /// Access the transport-free Marmot engine. Primarily for tests that exercise
    /// the media crypto path (encrypt/imeta/decrypt) without a Blossom server.
    pub fn engine(&self) -> &MarmotEngine {
        &self.engine
    }

    /// Publish our kind-30443 KeyPackage so others can start groups with us.
    pub async fn publish_key_package(&self) -> Result<()> {
        let event = self.engine.key_package_event(self.relays.clone())?;
        self.nostr.send_event(&event).await?;
        Ok(())
    }

    /// Fetch ALL of `author`'s KeyPackage events from the relays (a peer may have
    /// several under different `d` tags — e.g. multiple devices, or a stale slot
    /// from an old install). Newest first.
    pub async fn fetch_all_key_packages(&self, author: PublicKey) -> Result<Vec<Event>> {
        let filter = Filter::new()
            .kind(Kind::Custom(KEY_PACKAGE_KIND))
            .author(author);
        let mut events: Vec<Event> = self
            .nostr
            .fetch_events(filter, FETCH_TIMEOUT)
            .await?
            .into_iter()
            .collect();
        events.sort_by_key(|e| std::cmp::Reverse(e.created_at));
        Ok(events)
    }

    /// Create a 1:1 group inviting the holder of a SPECIFIC KeyPackage event and
    /// deliver the welcome. Used to invite via a chosen KeyPackage when a peer has
    /// several (the newest may be a stale slot the peer no longer holds the key
    /// material for, which the recipient rejects as "unknown key package").
    pub async fn start_dm_with_key_package(
        &self,
        key_package: Event,
        name: &str,
    ) -> Result<GroupId> {
        let creation = self.engine.create_group_with_description(
            name,
            SONAR_DIRECT_DM_DESCRIPTION,
            vec![key_package],
            self.relays.clone(),
        )?;
        self.publish_group_creation(creation).await
    }

    async fn fetch_key_packages_for_members(&self, members: Vec<PublicKey>) -> Result<Vec<Event>> {
        let mut deduped = Vec::new();
        let mut seen = HashSet::new();
        for member in members {
            if member == self.identity().public_key() {
                continue;
            }
            if seen.insert(member) {
                deduped.push(member);
            }
        }
        if deduped.is_empty() {
            return Err(Error::InvalidInput(
                "group must include at least one other member".into(),
            ));
        }

        let mut key_packages = Vec::with_capacity(deduped.len());
        for member in deduped {
            key_packages.push(self.fetch_key_package(member).await?);
        }
        Ok(key_packages)
    }

    /// Fetch the freshest KeyPackage event for `author` from the relays.
    pub async fn fetch_key_package(&self, author: PublicKey) -> Result<Event> {
        let filter = Filter::new()
            .kind(Kind::Custom(KEY_PACKAGE_KIND))
            .author(author)
            .limit(1);
        let events = self.nostr.fetch_events(filter, FETCH_TIMEOUT).await?;
        events
            .into_iter()
            .next()
            .ok_or(Error::KeyPackageNotFound(author))
    }

    /// Publish our kind-0 profile (NIP-01 metadata) so peers can resolve our
    /// display name + avatar. `name` is used for both `name` and `display_name`;
    /// `about`/`picture` are optional (a bad picture URL is dropped, not fatal).
    pub async fn publish_profile(
        &self,
        name: &str,
        about: Option<&str>,
        picture: Option<&str>,
    ) -> Result<()> {
        let mut metadata = Metadata::new().name(name).display_name(name);
        if let Some(about) = about.filter(|s| !s.is_empty()) {
            metadata = metadata.about(about);
        }
        if let Some(url) = picture
            .filter(|s| !s.is_empty())
            .and_then(|p| Url::parse(p).ok())
        {
            metadata = metadata.picture(url);
        }
        self.nostr.set_metadata(&metadata).await?;
        Ok(())
    }

    /// Fetch a peer's kind-0 profile from the relays. Returns `None` if they have
    /// not published one. Used to show a human name/avatar for a Marmot member
    /// instead of a raw npub.
    pub async fn fetch_profile(&self, author: PublicKey) -> Result<Option<Profile>> {
        let metadata = self.nostr.fetch_metadata(author, FETCH_TIMEOUT).await?;
        Ok(metadata.map(|m| Profile {
            name: m.name,
            display_name: m.display_name,
            about: m.about,
            picture: m.picture,
            nip05: m.nip05,
        }))
    }

    /// Publish Sonar's public, NIP-78-style app descriptor. This is intentionally
    /// capability + route metadata only: live Iroh node addresses stay inside
    /// encrypted ☎CALL OFFER/ANSWER messages.
    pub async fn publish_sonar_descriptor(
        &self,
        calls_enabled: bool,
        signaling: Vec<String>,
        bolt12_offer: Option<String>,
    ) -> Result<()> {
        // Migration: publish the old call-only descriptor for old clients and
        // the new unified metadata descriptor for direct BOLT12 payments.
        let call_content = descriptor_content_json(calls_enabled, signaling.clone())?;
        let call_builder = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), call_content)
            .tags(descriptor_tags(SONAR_CALL_DESCRIPTOR_D_TAG));
        self.nostr.send_event_builder(call_builder).await?;

        let meta_content = meta_descriptor_content_json(calls_enabled, signaling, bolt12_offer)?;
        let meta_builder = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), meta_content)
            .tags(descriptor_tags(SONAR_META_DESCRIPTOR_D_TAG));
        self.nostr.send_event_builder(meta_builder).await?;
        Ok(())
    }

    /// Fetch a peer's freshest valid Sonar descriptor from our account relays.
    /// Returns `None` for White Noise-only peers, old Sonar clients, privacy-off
    /// clients, relay misses, or malformed descriptors.
    pub async fn fetch_sonar_descriptor(
        &self,
        author: PublicKey,
    ) -> Result<Option<SonarDescriptor>> {
        let mut events = Vec::new();
        for d_tag in descriptor_d_tags() {
            let filter = Filter::new()
                .kind(Kind::Custom(SONAR_DESCRIPTOR_KIND))
                .author(author)
                .custom_tag(SingleLetterTag::lowercase(Alphabet::D), d_tag)
                .limit(5);
            events.extend(
                self.nostr
                    .fetch_events_from(self.relays.clone(), filter, FETCH_TIMEOUT)
                    .await?
                    .into_iter(),
            );
        }
        Ok(newest_valid_sonar_descriptor(events, author))
    }

    /// Start a multi-member Marmot group: fetch each member's KeyPackage,
    /// create the MLS group, and deliver the gift-wrapped welcomes.
    pub async fn start_group(&self, members: Vec<PublicKey>, name: &str) -> Result<GroupId> {
        let key_packages = self.fetch_key_packages_for_members(members).await?;
        let creation = self
            .engine
            .create_group(name, key_packages, self.relays.clone())?;
        self.publish_group_creation(creation).await
    }

    /// Start a 1:1 DM group with `peer`: fetch their KeyPackage, create the MLS
    /// group, and deliver the gift-wrapped welcome.
    ///
    /// If a 1:1 group with `peer` already exists, returns its id instead of
    /// creating a duplicate.
    pub async fn start_dm(&self, peer: PublicKey, name: &str) -> Result<GroupId> {
        if peer == self.identity().public_key() {
            return Err(Error::InvalidInput(
                "direct message requires another member".into(),
            ));
        }
        if let Some(existing) = self.find_dm_group_with(&peer)? {
            return Ok(existing);
        }
        let key_packages = self.fetch_key_packages_for_members(vec![peer]).await?;
        let creation = self.engine.create_group_with_description(
            name,
            SONAR_DIRECT_DM_DESCRIPTION,
            key_packages,
            self.relays.clone(),
        )?;
        self.publish_group_creation(creation).await
    }

    /// Scan active groups for an existing 1:1 DM with `peer`.
    fn find_dm_group_with(&self, peer: &PublicKey) -> Result<Option<GroupId>> {
        let groups = self.engine.groups()?;
        let me = self.identity().public_key();
        for group in groups {
            let members = self.engine.members(&group.mls_group_id)?;
            if Self::is_reusable_dm_group(&group, &members, &me, peer) {
                return Ok(Some(group.mls_group_id));
            }
        }
        Ok(None)
    }

    fn is_reusable_dm_group(
        group: &group_types::Group,
        members: &[PublicKey],
        me: &PublicKey,
        peer: &PublicKey,
    ) -> bool {
        if members.len() != 2 || !members.contains(peer) || !members.contains(me) {
            return false;
        }

        group.description == SONAR_DIRECT_DM_DESCRIPTION
            || (group.description.is_empty() && group.name.is_empty())
    }

    async fn publish_group_creation(&self, creation: GroupCreation) -> Result<GroupId> {
        let group_id = creation.group.mls_group_id;
        let mut wrapped_welcomes = Vec::with_capacity(creation.welcomes.len());

        for (member, rumor) in creation.welcomes {
            match self.engine.gift_wrap_welcome(&member, rumor).await {
                Ok(wrapped) => wrapped_welcomes.push(wrapped),
                Err(err) => {
                    self.discard_unpublished_group_creation(&group_id);
                    return Err(err);
                }
            }
        }

        let mut published_welcomes = 0usize;
        for wrapped in wrapped_welcomes {
            if let Err(err) = self.publish_marmot_event(&wrapped, "group welcome").await {
                if published_welcomes == 0 {
                    self.discard_unpublished_group_creation(&group_id);
                } else {
                    tracing::debug!(
                        %err,
                        ?group_id,
                        published_welcomes,
                        "marmot group creation welcome publish partially failed; keeping pending group state"
                    );
                }
                return Err(err.into());
            }
            published_welcomes += 1;
        }

        self.engine.merge_pending_commit(&group_id)?;
        let name = self
            .engine
            .groups()
            .ok()
            .and_then(|gs| {
                gs.into_iter()
                    .find(|g| g.mls_group_id == group_id)
                    .map(|g| g.name)
            })
            .unwrap_or_default();
        self.ensure_index_for_group(&group_id, &name);
        let group_id_hex = hex::encode(group_id.as_slice());
        self.notify_conversation_changed(&group_id_hex);
        if let Err(err) = self.resubscribe_marmot_groups_if_live().await {
            tracing::debug!(%err, "marmot group live resubscribe failed after local group create");
        }
        Ok(group_id)
    }

    fn discard_unpublished_group_creation(&self, group_id: &GroupId) {
        let _ = self.engine.clear_pending_commit(group_id);
        let _ = self.engine.delete_group(group_id);
    }

    async fn publish_membership_update(&self, update: GroupMembershipUpdate) -> Result<()> {
        let group_id = update.group_id.clone();
        let requires_commit_merge = update.requires_commit_merge;
        let mut wrapped_welcomes = Vec::with_capacity(update.welcomes.len());

        for (member, rumor) in update.welcomes {
            match self.engine.gift_wrap_welcome(&member, rumor).await {
                Ok(wrapped) => wrapped_welcomes.push(wrapped),
                Err(err) => {
                    if requires_commit_merge {
                        let _ = self.engine.clear_pending_commit(&group_id);
                    }
                    return Err(err);
                }
            }
        }

        if let Err(err) = self
            .publish_marmot_event(&update.evolution_event, "membership update")
            .await
        {
            if requires_commit_merge {
                let _ = self.engine.clear_pending_commit(&group_id);
            }
            return Err(err.into());
        }

        for wrapped in wrapped_welcomes {
            if let Err(err) = self
                .publish_marmot_event(&wrapped, "membership welcome")
                .await
            {
                tracing::debug!(
                    %err,
                    ?group_id,
                    "marmot membership welcome publish failed after commit publish; keeping pending commit"
                );
                return Err(err.into());
            }
        }

        if requires_commit_merge {
            self.engine.merge_pending_commit(&group_id)?;
        }
        if let Err(err) = self.resubscribe_marmot_groups_if_live().await {
            tracing::debug!(%err, "marmot group live resubscribe failed after membership update");
        }
        Ok(())
    }

    async fn publish_marmot_event(&self, event: &Event, context: &'static str) -> Result<()> {
        let output = self.nostr.send_event(event).await?;
        require_relay_success(&output, context)
    }

    async fn ensure_relays_connected(&self, relays: &[RelayUrl]) -> Result<()> {
        for relay in relays {
            self.nostr.add_relay(relay.clone()).await?;
            self.nostr.connect_relay(relay.clone()).await?;
        }
        Ok(())
    }

    /// Add members to an existing group.
    pub async fn add_group_members(
        &self,
        group_id: &GroupId,
        members: Vec<PublicKey>,
    ) -> Result<()> {
        let key_packages = self.fetch_key_packages_for_members(members).await?;
        let update = self.engine.add_members(group_id, key_packages)?;
        self.publish_membership_update(update).await
    }

    /// Remove members from an existing group.
    pub async fn remove_group_members(
        &self,
        group_id: &GroupId,
        members: Vec<PublicKey>,
    ) -> Result<()> {
        if members.is_empty() {
            return Err(Error::InvalidInput(
                "remove_group_members requires at least one member".into(),
            ));
        }
        let update = self.engine.remove_members(group_id, &members)?;
        self.publish_membership_update(update).await
    }

    /// Notify the group that this member is leaving, then remove the group from
    /// local storage so it disappears from the chat list.
    pub async fn leave_group(&self, group_id: &GroupId) -> Result<()> {
        let leave_update = match self.engine.leave_group(group_id) {
            Ok(update) => update,
            Err(err) if err.to_string().contains("self-demote") => {
                let demote = self.engine.self_demote(group_id)?;
                self.publish_membership_update(demote).await?;
                self.engine.leave_group(group_id)?
            }
            Err(err) => return Err(err),
        };
        self.publish_membership_update(leave_update).await?;
        self.engine.delete_group(group_id)?;
        let _ = self.resubscribe_marmot_groups_if_live().await;
        Ok(())
    }

    // ── Invite links ──────────────────────────────────────────────────

    pub fn create_invite_link(&self, group_id: &GroupId, group_name: &str) -> Result<String> {
        let relay_strings: Vec<String> = self.relays.iter().map(|r| r.to_string()).collect();
        self.invite_links
            .create_link(group_id, group_name, self.engine.identity(), relay_strings)
    }

    pub fn revoke_invite_link(&self, group_id: &GroupId, secret_hash: &[u8; 32]) -> Result<()> {
        self.invite_links.revoke_link(group_id, secret_hash)
    }

    pub fn active_invite_links(
        &self,
        group_id: &GroupId,
    ) -> Vec<crate::invite_link::InviteLinkMeta> {
        self.invite_links.active_links(group_id)
    }

    pub async fn request_join_via_link(&self, token_str: &str) -> Result<()> {
        let token = crate::invite_link::decode_invite_token(token_str)?;
        let admin = PublicKey::from_slice(&token.admin_npub)
            .map_err(|e| Error::InvalidInput(e.to_string()))?;
        let group_id = GroupId::from_slice(&token.group_id);
        let invite_relays: Vec<RelayUrl> = token
            .relays
            .iter()
            .map(|url| {
                RelayUrl::parse(url)
                    .map_err(|e| Error::InvalidInput(format!("invite relay {url}: {e}")))
            })
            .collect::<Result<_>>()?;
        let publish_relays = if invite_relays.is_empty() {
            self.relays.clone()
        } else {
            invite_relays
        };

        self.ensure_relays_connected(&publish_relays).await?;
        let kp_event = self.engine.key_package_event(publish_relays.clone())?;
        let output = self
            .nostr
            .send_event_to(publish_relays.clone(), &kp_event)
            .await?;
        require_relay_success(&output, "invite key package publish")?;

        let rumor = crate::invite_link::build_join_request_rumor(
            &group_id,
            &token.invite_secret,
            &self.engine.identity().public_key(),
            Some(&kp_event.id),
        );
        let wrapped = self.engine.gift_wrap_rumor(&admin, rumor).await?;
        let output = self.nostr.send_event_to(publish_relays, &wrapped).await?;
        require_relay_success(&output, "invite join request publish")
    }

    pub fn pending_join_requests(
        &self,
        group_id: &GroupId,
    ) -> Vec<crate::invite_link::JoinRequest> {
        self.invite_links.pending_join_requests(group_id)
    }

    pub async fn approve_join_request(
        &self,
        group_id: &GroupId,
        requester: &PublicKey,
    ) -> Result<()> {
        if !self
            .invite_links
            .pending_join_requests(group_id)
            .iter()
            .any(|r| r.requester == *requester)
        {
            return Err(Error::InvalidInput("no pending join request".into()));
        }
        self.add_group_members(group_id, vec![*requester]).await?;
        self.invite_links.remove_join_request(group_id, requester)?;
        Ok(())
    }

    pub fn decline_join_request(&self, group_id: &GroupId, requester: &PublicKey) -> Result<()> {
        self.invite_links.remove_join_request(group_id, requester)
    }

    pub fn store_join_request(&self, request: crate::invite_link::JoinRequest) -> Result<bool> {
        if !self
            .invite_links
            .validate_secret(&request.group_id, &request.secret_hash)
        {
            return Ok(false);
        }
        self.invite_links.add_join_request(request)?;
        Ok(true)
    }

    /// Pending multi-member invites waiting for explicit user action.
    pub fn pending_group_invites(&self) -> Result<Vec<GroupInvite>> {
        self.engine.pending_group_invites()
    }

    /// Accept a pending group invite by welcome event id, then backfill its
    /// existing group history and widen the live subscription.
    pub async fn accept_group_invite(&self, welcome_id: &EventId) -> Result<GroupId> {
        let group_id = self.engine.accept_group_invite(welcome_id)?;
        if let Some(group) = self
            .engine
            .groups()?
            .into_iter()
            .find(|g| g.mls_group_id == group_id)
        {
            self.ensure_index_for_group(&group_id, &group.name);
            let nostr_group_id = hex::encode(group.nostr_group_id);
            if let Err(err) = self.backfill_group(&nostr_group_id).await {
                tracing::debug!(
                    %err,
                    %nostr_group_id,
                    "marmot group backfill failed after accepting invite"
                );
            }
        }
        let group_id_hex = hex::encode(group_id.as_slice());
        self.notify_conversation_changed(&group_id_hex);
        let _ = self.resubscribe_marmot_groups_if_live().await;
        Ok(group_id)
    }

    /// Decline a pending group invite by welcome event id.
    pub fn decline_group_invite(&self, welcome_id: &EventId) -> Result<()> {
        self.engine.decline_group_invite(welcome_id)
    }

    /// Encrypt and durably record a text message locally before relay publish.
    ///
    /// This is Signal-style send sequencing: the MDK local DB becomes visible
    /// first, Sonar marks the row pending in the outbox, and relay publish runs
    /// in the background. Publish success/failure only updates local delivery
    /// state; it does not gate transcript visibility.
    pub async fn send_text(&self, group_id: &GroupId, text: &str) -> Result<()> {
        let event = self.engine.create_text_message(group_id, text)?;
        let incoming = self.engine.process_incoming(&event).await?;
        let Incoming::Message(message) = incoming else {
            return Err(Error::Storage(
                "created text message did not produce a local transcript row".into(),
            ));
        };
        let group_name = self.resolve_group_name(group_id);
        self.upsert_index_for_message(&message, group_name.as_deref());
        let group_id_hex = hex::encode(group_id.as_slice());
        self.mark_local_event_processed(&event.id);
        self.mark_outbox_pending(group_id, &message, &event)?;
        self.spawn_outbox_publish(message.id.to_hex(), event);
        self.notify_conversation_changed(&group_id_hex);
        Ok(())
    }

    /// Send a sticker message to a group. Follows the same Signal-style
    /// local-first sequencing as `send_text`.
    pub async fn send_sticker(
        &self,
        group_id: &GroupId,
        sticker_ref: &StickerRef,
    ) -> Result<()> {
        let event = self.engine.create_sticker_message(group_id, sticker_ref)?;
        let incoming = self.engine.process_incoming(&event).await?;
        let Incoming::Message(message) = incoming else {
            return Err(Error::Storage(
                "created sticker message did not produce a local transcript row".into(),
            ));
        };
        let group_name = self.resolve_group_name(group_id);
        self.upsert_index_for_message(&message, group_name.as_deref());
        let group_id_hex = hex::encode(group_id.as_slice());
        self.mark_local_event_processed(&event.id);
        self.mark_outbox_pending(group_id, &message, &event)?;
        self.spawn_outbox_publish(message.id.to_hex(), event);
        self.notify_conversation_changed(&group_id_hex);
        Ok(())
    }

    /// Fetch a sticker pack from relays by its pack address coordinate.
    pub async fn fetch_sticker_pack(
        &self,
        author_pubkey_hex: &str,
        identifier: &str,
        relay_urls: &[String],
    ) -> Result<StickerPack> {
        let author = PublicKey::from_hex(author_pubkey_hex)
            .map_err(|e| Error::InvalidInput(format!("invalid pack author pubkey: {e}")))?;
        let filter = Filter::new()
            .kind(Kind::Custom(STICKER_PACK_KIND))
            .author(author)
            .custom_tag(
                SingleLetterTag::lowercase(Alphabet::D),
                identifier.to_string(),
            )
            .limit(1);

        let relays: Vec<String> = if relay_urls.is_empty() {
            self.relays.iter().map(|u| u.to_string()).collect()
        } else {
            relay_urls.to_vec()
        };
        let timeout = Duration::from_secs(10);
        let events = self
            .nostr
            .fetch_events_from(relays, filter, timeout)
            .await?;
        let event = events
            .into_iter()
            .next()
            .ok_or_else(|| Error::Http("sticker pack not found on relays".into()))?;
        parse_pack_event(&event)
            .map_err(|e| Error::Http(format!("invalid sticker pack: {e}")))
    }

    fn mark_outbox_pending(
        &self,
        group_id: &GroupId,
        message: &ChatMessage,
        event: &Event,
    ) -> Result<()> {
        self.outbox_state.lock().unwrap().mark_pending(
            hex::encode(group_id.as_slice()),
            message.id.to_hex(),
            event.id.to_hex(),
            event.as_json(),
            Timestamp::now().as_secs(),
        )
    }

    fn spawn_outbox_publish(&self, message_id_hex: String, event: Event) {
        if self.relays.is_empty() {
            return;
        }
        let nostr = self.nostr.clone();
        let outbox_state = self.outbox_state.clone();
        tokio::spawn(async move {
            let result = nostr.send_event(&event).await;
            let now_secs = Timestamp::now().as_secs();
            let mut outbox = outbox_state.lock().unwrap();
            match result {
                Ok(output) => {
                    if let Err(err) = require_relay_success(&output, "text publish") {
                        let _ = outbox.mark_failed_by_message_id(
                            &message_id_hex,
                            err.to_string(),
                            now_secs,
                        );
                    } else {
                        let _ = outbox.mark_sent_by_message_id(&message_id_hex, now_secs);
                    }
                }
                Err(err) => {
                    let _ = outbox.mark_failed_by_message_id(
                        &message_id_hex,
                        err.to_string(),
                        now_secs,
                    );
                }
            }
        });
    }

    pub async fn reload_outbox_and_retry(&self) {
        if self.relays.is_empty() {
            return;
        }
        self.outbox_state.lock().unwrap().reload_from_disk();
        self.retry_outbox().await;
    }

    async fn retry_outbox(&self) {
        if self.relays.is_empty() {
            return;
        }
        let active_group_ids = match self.engine.groups() {
            Ok(groups) => groups
                .into_iter()
                .map(|group| hex::encode(group.mls_group_id.as_slice()))
                .collect::<HashSet<_>>(),
            Err(err) => {
                tracing::debug!(%err, "failed to load active Marmot groups for outbox retry");
                return;
            }
        };
        let retryable = {
            let mut outbox = self.outbox_state.lock().unwrap();
            match outbox.retryable_events(Timestamp::now().as_secs(), &active_group_ids) {
                Ok(events) => events,
                Err(err) => {
                    tracing::debug!(%err, "failed to load retryable outbox events");
                    return;
                }
            }
        };
        for (message_id_hex, event) in retryable {
            self.spawn_outbox_publish(message_id_hex, event);
        }
    }

    fn record_delivery_for_incoming(&self, incoming: &Incoming) {
        let Incoming::Message(message) = incoming else {
            return;
        };
        if !message.mine {
            return;
        }
        if let Err(err) = self
            .outbox_state
            .lock()
            .unwrap()
            .mark_sent_by_message_id(&message.id.to_hex(), Timestamp::now().as_secs())
        {
            tracing::debug!(%err, "failed to mark outbox message sent after incoming echo");
        }
    }

    // ── Encrypted media (Marmot MIP-04 + Blossom) ─────────────────────────

    /// Send a media attachment to `group_id`: encrypt with the group key
    /// (MIP-04), upload the ciphertext to a Blossom server, then publish a
    /// kind-445 message carrying the `imeta` tag and optional `caption`. The
    /// message is only published AFTER a successful upload, so a failed upload
    /// never leaves a dangling reference. `server_url` empty →
    /// [`DEFAULT_BLOSSOM_SERVER`].
    pub async fn send_media(
        &self,
        group_id: &GroupId,
        data: Vec<u8>,
        filename: &str,
        mime: &str,
        caption: &str,
        server_url: &str,
    ) -> Result<()> {
        let upload = self.engine.encrypt_media(group_id, &data, mime, filename)?;
        let url = self
            .blossom_upload(server_url, upload.encrypted_data.clone(), &upload.mime_type)
            .await?;
        let event = self
            .engine
            .create_media_event(group_id, &upload, &url, caption)?;
        self.nostr.send_event(&event).await?;
        let incoming = self.engine.process_incoming(&event).await?;
        if let Incoming::Message(ref message) = incoming {
            let group_name = self.resolve_group_name(group_id);
            self.upsert_index_for_message(message, group_name.as_deref());
            let group_id_hex = hex::encode(group_id.as_slice());
            self.mark_local_event_processed(&event.id);
            self.notify_conversation_changed(&group_id_hex);
        }
        Ok(())
    }

    /// Download the encrypted blob at `url` and decrypt it with the group media
    /// key (resolved from the message's imeta tag). Returns plaintext bytes.
    pub async fn fetch_media(&self, group_id: &GroupId, url: &str) -> Result<Vec<u8>> {
        let ciphertext = http_get_with_retries(url).await?;
        self.engine.decrypt_media_by_url(group_id, url, &ciphertext)
    }

    /// Upload an encrypted blob to a Blossom server (BUD-02), authed with our
    /// Nostr key, returning the URL where it can be fetched.
    async fn blossom_upload(&self, server_url: &str, data: Vec<u8>, mime: &str) -> Result<String> {
        let server = if server_url.is_empty() {
            DEFAULT_BLOSSOM_SERVER
        } else {
            server_url
        };
        let base = Url::parse(server)
            .map_err(|e| Error::Blossom(format!("bad server url {server}: {e}")))?;
        let descriptor = BlossomClient::new(base)
            .upload_blob(
                data,
                Some(mime.to_string()),
                None,
                Some(self.identity().keys()),
            )
            .await
            .map_err(|e| Error::Blossom(e.to_string()))?;
        Ok(descriptor.url.to_string())
    }

    /// The user's Blossom server list (kind-10063 / BUD-03). Empty if unset.
    pub async fn blossom_servers(&self) -> Result<Vec<String>> {
        let filter = Filter::new()
            .kind(Kind::Custom(BLOSSOM_SERVER_LIST_KIND))
            .author(self.identity().public_key())
            .limit(1);
        let mut servers = Vec::new();
        for event in self.nostr.fetch_events(filter, FETCH_TIMEOUT).await? {
            for tag in event.tags.iter() {
                if tag.kind() == TagKind::Custom("server".into()) {
                    if let Some(url) = tag.content() {
                        servers.push(url.to_string());
                    }
                }
            }
        }
        Ok(servers)
    }

    /// Publish our Blossom server list (kind-10063) so peers and our other
    /// devices know where our blobs live.
    pub async fn publish_blossom_servers(&self, servers: Vec<String>) -> Result<()> {
        let tags = servers
            .into_iter()
            .map(|s| Tag::custom(TagKind::Custom("server".into()), [s]));
        let builder = EventBuilder::new(Kind::Custom(BLOSSOM_SERVER_LIST_KIND), "").tags(tags);
        self.nostr.send_event_builder(builder).await?;
        Ok(())
    }

    /// Poll the relays once for anything NEW since the last sync: gift-wrapped
    /// welcomes addressed to us (which may add groups), then kind-445 messages
    /// for every known group.
    ///
    /// A monotonic per-session watermark scopes each fetch with `.since(...)`,
    /// so a repeat poll only pulls events newer than the last one instead of
    /// re-downloading + re-processing the entire history every time (the naive
    /// version made every 5s poll a full backfill, which also starved media
    /// downloads queued behind it on the host). All group messages are fetched
    /// in ONE request batched on the `#h` tag, not one fetch per group. This is
    /// the same `last_synced_at` + batched-subscription pattern the White Noise
    /// reference client uses. Duplicate/already-processed events are tolerated.
    pub async fn sync(&self) -> Result<()> {
        // Watermark from the previous successful sync (0 on the first poll of a
        // session → an unbounded backfill, bounded only by the `#p`/`#h` scope).
        let since_secs = self.sync_watermark_secs();
        // Capture the start time as the next watermark BEFORE fetching, so any
        // event that lands mid-sync is re-covered by the overlap next poll.
        let started = Timestamp::now().as_secs();

        let mut wraps = Filter::new()
            .kind(Kind::GiftWrap)
            .pubkey(self.identity().public_key());
        if since_secs > 0 {
            // Gift wraps are backdated (NIP-59) → extra lookback so we don't
            // skip a just-received welcome whose wrapper timestamp is in the past.
            wraps = wraps.since(Timestamp::from_secs(
                since_secs.saturating_sub(GIFTWRAP_LOOKBACK_SECS),
            ));
        }
        // Scope to OUR Marmot relays, not the whole pool: `subscribe_geohash`
        // adds up to a dozen geohash-nearest relays per opened channel, none of
        // which carry our 1059/445 events — fetching from them only makes the
        // sync wait on their EOSE. The MLS group + KeyPackage relay lists are
        // built from `self.relays`, so conformant peers publish welcomes there.
        let mut process_report = MarmotProcessReport::default();
        let ids_before = self.current_group_ids()?;
        let wraps = self
            .nostr
            .fetch_events_from(self.relays.clone(), wraps, FETCH_TIMEOUT)
            .await?;
        process_report.absorb(self.process_marmot_events(wraps, "gift wrap").await);

        // A welcome processed during sync can add group(s). Backfill each new
        // group's full history once, then widen the live tail if it is enabled.
        let new_group_ids: Vec<String> = self
            .current_group_ids()?
            .into_iter()
            .filter(|id| !ids_before.contains(id))
            .collect();
        for id in &new_group_ids {
            match self.backfill_group(id).await {
                Ok(report) => process_report.absorb(report),
                Err(err) => {
                    tracing::debug!(%err, "group backfill failed during sync");
                    process_report.record_retryable(Timestamp::now().as_secs());
                }
            }
        }
        // Existing installs can have group/MLS rows locally while the chat
        // transcript page is empty. Full-backfill those groups once. The scan
        // is deferred from client construction to the first sync so it does not
        // delay local-only first paint.
        self.populate_empty_transcript_backfills_once();
        let empty_transcript_group_ids = self.take_initial_empty_transcript_backfills();
        for id in &empty_transcript_group_ids {
            match self.backfill_group(id).await {
                Ok(report) => process_report.absorb(report),
                Err(err) => {
                    tracing::debug!(%err, "empty transcript backfill failed during sync");
                    self.requeue_initial_empty_transcript_backfill(id);
                    process_report.record_retryable(Timestamp::now().as_secs());
                }
            }
        }
        if let Err(err) = self.resubscribe_marmot_groups_if_live().await {
            tracing::debug!(%err, "marmot group live resubscribe failed during sync");
        }

        // Fetch kind-445 for ALL known groups in one request (batched `#h`),
        // including any group a welcome just added above.
        let group_ids: Vec<String> = self.current_group_ids()?.into_iter().collect();
        if !group_ids.is_empty() {
            let mut filter = Filter::new()
                .kind(Kind::MlsGroupMessage)
                .custom_tags(SingleLetterTag::lowercase(Alphabet::H), group_ids);
            if since_secs > 0 {
                filter = filter.since(Timestamp::from_secs(
                    since_secs.saturating_sub(SYNC_OVERLAP_SECS),
                ));
            }
            let events = self
                .nostr
                .fetch_events_from(self.relays.clone(), filter, FETCH_TIMEOUT)
                .await?;
            process_report.absorb(self.process_marmot_events(events, "group message").await);
        }

        if process_report.retryable_failures == 0 {
            self.advance_sync_watermark(started)?;
        } else if let Some(secs) = process_report.oldest_retryable_secs {
            self.rewind_sync_watermark_for_retry(secs)?;
        } else {
            self.save_sync_state()?;
        }
        self.retry_outbox().await;
        Ok(())
    }

    /// Open the persistent LIVE Marmot subscriptions: welcomes (1059 → us) and
    /// group messages (445 on our groups' `#h`). The relay pushes new events to
    /// the notification handler → buffer → `drain_pending_marmot`. Both subs are
    /// a since-now LIVE TAIL; pre-session history stays with `sync()` (watermark)
    /// and a freshly-joined group's history is backfilled explicitly in
    /// `drain_pending_marmot` (its messages predate the watermark).
    pub async fn subscribe_marmot(&self) -> Result<()> {
        let wraps = Filter::new()
            .kind(Kind::GiftWrap)
            .pubkey(self.identity().public_key())
            .since(Timestamp::now());
        self.nostr
            .subscribe_with_id(SubscriptionId::new(SUB_MARMOT_WELCOMES), wraps, None)
            .await?;
        *self.live_marmot_enabled.lock().unwrap() = true;
        self.subscribe_group_messages().await
    }

    /// (Re)subscribe the kind-445 live tail (`since = now`) to the CURRENT group
    /// set. Re-running with the same id REPLACES the filter, so calling this
    /// after a welcome adds a group widens the live subscription. History for a
    /// newly-added group is fetched separately by `backfill_group`.
    async fn subscribe_group_messages(&self) -> Result<()> {
        let group_ids = self.current_group_ids()?;
        let sub_id = SubscriptionId::new(SUB_MARMOT_GROUPS);

        if group_ids.is_empty() {
            let had_subscription = {
                let current = self.marmot_group_subscriptions.lock().unwrap();
                !current.is_empty()
            };
            if had_subscription {
                self.nostr.unsubscribe(&sub_id).await;
                self.marmot_group_subscriptions.lock().unwrap().clear();
            }
            return Ok(());
        }

        {
            let current = self.marmot_group_subscriptions.lock().unwrap();
            if *current == group_ids {
                return Ok(());
            }
        }

        let mut group_id_list: Vec<String> = group_ids.iter().cloned().collect();
        group_id_list.sort();
        let filter = Filter::new()
            .kind(Kind::MlsGroupMessage)
            .custom_tags(SingleLetterTag::lowercase(Alphabet::H), group_id_list)
            .since(Timestamp::now());
        self.nostr.subscribe_with_id(sub_id, filter, None).await?;
        *self.marmot_group_subscriptions.lock().unwrap() = group_ids;
        Ok(())
    }

    fn current_group_ids(&self) -> Result<HashSet<String>> {
        Ok(self
            .engine
            .groups()?
            .into_iter()
            .map(|g| hex::encode(g.nostr_group_id))
            .collect())
    }

    fn empty_transcript_group_ids(engine: &MarmotEngine) -> HashSet<String> {
        let Ok(groups) = engine.groups() else {
            return HashSet::new();
        };
        groups
            .into_iter()
            .filter_map(
                |group| match engine.messages_page(&group.mls_group_id, 1, 0) {
                    Ok(page) if page.is_empty() => Some(hex::encode(group.nostr_group_id)),
                    _ => None,
                },
            )
            .collect()
    }

    fn populate_empty_transcript_backfills_once(&self) {
        if self.initial_backfill_scanned.swap(true, Ordering::Relaxed) {
            return;
        }
        let mut set = self.initial_empty_transcript_backfills.lock().unwrap();
        *set = Self::empty_transcript_group_ids(&self.engine);
    }

    fn take_initial_empty_transcript_backfills(&self) -> Vec<String> {
        self.initial_empty_transcript_backfills
            .lock()
            .unwrap()
            .drain()
            .collect()
    }

    fn requeue_initial_empty_transcript_backfill(&self, group_id_hex: &str) {
        self.initial_empty_transcript_backfills
            .lock()
            .unwrap()
            .insert(group_id_hex.to_string());
    }

    async fn resubscribe_marmot_groups_if_live(&self) -> Result<()> {
        let is_live = *self.live_marmot_enabled.lock().unwrap();
        if !is_live {
            return Ok(());
        }
        self.subscribe_group_messages().await
    }

    fn sync_watermark_secs(&self) -> u64 {
        self.sync_state.lock().unwrap().watermark_secs()
    }

    fn is_sync_event_processed(&self, event_id: &EventId) -> bool {
        self.sync_state
            .lock()
            .unwrap()
            .has_processed(&event_id.to_hex())
    }

    fn mark_sync_event_processed(&self, event_id: &EventId) {
        self.sync_state.lock().unwrap().mark_processed(event_id);
    }

    fn mark_local_event_processed(&self, event_id: &EventId) {
        self.mark_sync_event_processed(event_id);
        if let Err(err) = self.save_sync_state() {
            tracing::debug!(%err, "failed to persist locally created Marmot event marker");
        }
    }

    fn save_sync_state(&self) -> Result<()> {
        self.sync_state.lock().unwrap().save_if_dirty()
    }

    fn advance_sync_watermark(&self, watermark_secs: u64) -> Result<()> {
        {
            let mut state = self.sync_state.lock().unwrap();
            state.advance_watermark(watermark_secs);
        }
        self.save_sync_state()
    }

    fn rewind_sync_watermark_for_retry(&self, event_secs: u64) -> Result<()> {
        {
            let mut state = self.sync_state.lock().unwrap();
            state.rewind_for_retry(event_secs);
        }
        self.save_sync_state()
    }

    async fn process_marmot_events(
        &self,
        events: impl IntoIterator<Item = Event>,
        context: &'static str,
    ) -> MarmotProcessReport {
        let mut report = MarmotProcessReport::default();
        let mut changed_groups: HashSet<String> = HashSet::new();
        let group_names: HashMap<Vec<u8>, String> = self
            .engine
            .groups()
            .unwrap_or_default()
            .into_iter()
            .map(|g| (g.mls_group_id.as_slice().to_vec(), g.name))
            .collect();
        for event in sort_marmot_events(events) {
            if self.is_sync_event_processed(&event.id) {
                report.record_processed();
                continue;
            }

            match self.engine.process_incoming(&event).await {
                Ok(Incoming::Retryable) => {
                    tracing::debug!(
                        event_id = %event.id,
                        event_created_at = event.created_at.as_secs(),
                        context,
                        "marmot event needs retry; leaving sync cursor behind it"
                    );
                    report.record_retryable(event.created_at.as_secs());
                }
                Ok(Incoming::GroupProposal(update)) => {
                    match self.publish_membership_update(update).await {
                        Ok(()) => {
                            self.mark_sync_event_processed(&event.id);
                            report.record_processed();
                        }
                        Err(err) => {
                            tracing::debug!(
                                %err,
                                event_id = %event.id,
                                event_created_at = event.created_at.as_secs(),
                                context,
                                "marmot auto-commit publish failed; leaving sync cursor behind it"
                            );
                            report.record_retryable(event.created_at.as_secs());
                        }
                    }
                }
                Ok(Incoming::JoinRequest(request)) => {
                    let group_hex = hex::encode(request.group_id.as_slice());
                    if self.store_join_request(request).unwrap_or(false) {
                        changed_groups.insert(group_hex);
                    }
                    self.mark_sync_event_processed(&event.id);
                    report.record_processed();
                }
                Ok(ref incoming @ Incoming::Message(ref message)) => {
                    self.record_delivery_for_incoming(incoming);
                    let cached_name = group_names
                        .get(message.group_id.as_slice())
                        .map(|s| s.as_str());
                    self.upsert_index_for_message(message, cached_name);
                    changed_groups.insert(hex::encode(message.group_id.as_slice()));
                    self.mark_sync_event_processed(&event.id);
                    report.record_processed();
                }
                Ok(incoming) => {
                    self.record_delivery_for_incoming(&incoming);
                    self.mark_sync_event_processed(&event.id);
                    report.record_processed();
                }
                Err(err) if is_terminal_marmot_processing_error(&err) => {
                    tracing::debug!(
                        %err,
                        event_id = %event.id,
                        context,
                        "terminal marmot event failure; marking event processed"
                    );
                    self.mark_sync_event_processed(&event.id);
                    report.record_processed();
                }
                Err(err) => {
                    tracing::debug!(
                        %err,
                        event_id = %event.id,
                        event_created_at = event.created_at.as_secs(),
                        context,
                        "marmot event processing failed; leaving sync cursor behind it"
                    );
                    report.record_retryable(event.created_at.as_secs());
                }
            }
        }
        self.notify_conversations_changed(&changed_groups);
        report
    }

    /// One-off fetch of a single group's full kind-445 history (no `since`),
    /// processed through the engine. Used when a welcome adds a group whose
    /// messages predate the sync watermark, so they'd be missed by both the
    /// watermarked `sync()` and the since-now live subscription.
    async fn backfill_group(&self, group_id_hex: &str) -> Result<MarmotProcessReport> {
        let filter = Filter::new()
            .kind(Kind::MlsGroupMessage)
            .custom_tag(SingleLetterTag::lowercase(Alphabet::H), group_id_hex);
        let events = self
            .nostr
            .fetch_events_from(self.relays.clone(), filter, FETCH_TIMEOUT)
            .await?;
        Ok(self
            .process_marmot_events(events, "backfilled group message")
            .await)
    }

    /// Park until a live Marmot event is buffered (or `timeout_secs` elapses).
    /// Returns true if there is something to drain. This is the host's "wait for
    /// push" primitive — it touches NO engine state, so it is the one Marmot call
    /// the host may run OFF its serialized engine queue.
    pub async fn wait_for_marmot_event(&self, timeout_secs: u64) -> bool {
        if !self.pending_marmot.lock().unwrap().is_empty() {
            return true;
        }
        tokio::time::timeout(
            Duration::from_secs(timeout_secs.max(1)),
            self.marmot_notify.notified(),
        )
        .await
        .is_ok()
    }

    /// Process every buffered live Marmot event through the MLS engine, then
    /// widen the group subscription if a welcome just added a group. Returns true
    /// if anything was drained. MUST run on the host's serialized engine thread
    /// (it mutates MLS state); the notification handler only ever BUFFERS.
    pub async fn drain_pending_marmot(&self) -> Result<bool> {
        let mut events: Vec<Event> = {
            let mut buf = self.pending_marmot.lock().unwrap();
            if buf.is_empty() {
                return Ok(false);
            }
            std::mem::take(&mut *buf)
        };
        sort_marmot_events_in_place(&mut events);
        let ids_before = self.current_group_ids()?;
        let mut process_report = self
            .process_marmot_events(events, "live marmot event")
            .await;
        // A welcome may have joined new group(s): backfill each one's history
        // (predates the watermark + the since-now sub) and widen the live sub.
        let new_ids: Vec<String> = self
            .current_group_ids()?
            .into_iter()
            .filter(|id| !ids_before.contains(id))
            .collect();
        if !new_ids.is_empty() {
            for id in &new_ids {
                match self.backfill_group(id).await {
                    Ok(report) => process_report.absorb(report),
                    Err(err) => {
                        tracing::debug!(%err, "group backfill failed (sync will retry)");
                        process_report.record_retryable(Timestamp::now().as_secs());
                    }
                }
            }
            let _ = self.resubscribe_marmot_groups_if_live().await;
        }
        if let Some(secs) = process_report.oldest_retryable_secs {
            self.rewind_sync_watermark_for_retry(secs)?;
        } else {
            self.save_sync_state()?;
        }
        Ok(true)
    }

    pub fn groups(&self) -> Result<Vec<group_types::Group>> {
        self.engine.groups()
    }

    pub fn messages(&self, group_id: &GroupId) -> Result<Vec<ChatMessage>> {
        self.engine.messages(group_id).map(|msgs| {
            msgs.into_iter()
                .map(|m| self.with_delivery_state(m))
                .collect()
        })
    }

    pub fn messages_page(
        &self,
        group_id: &GroupId,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<ChatMessage>> {
        self.engine
            .messages_page(group_id, limit, offset)
            .map(|msgs| {
                msgs.into_iter()
                    .map(|m| self.with_delivery_state(m))
                    .collect()
            })
    }

    pub fn recent_message_pages(
        &self,
        group_limit: usize,
        page_limit: usize,
    ) -> Result<Vec<RecentMessagePage>> {
        self.engine
            .recent_message_pages(group_limit, page_limit)
            .map(|pages| {
                pages
                    .into_iter()
                    .map(|mut page| {
                        page.messages = page
                            .messages
                            .into_iter()
                            .map(|m| self.with_delivery_state(m))
                            .collect();
                        page
                    })
                    .collect()
            })
    }

    fn with_delivery_state(&self, mut message: ChatMessage) -> ChatMessage {
        if let Some(state) = self
            .outbox_state
            .lock()
            .unwrap()
            .status_for_message(&message.id.to_hex())
        {
            message.delivery_state = state;
        } else if message.mine {
            message.delivery_state = DeliveryState::Sent;
        } else {
            message.delivery_state = DeliveryState::Received;
        }
        message
    }

    pub fn members(&self, group_id: &GroupId) -> Result<Vec<PublicKey>> {
        self.engine.members(group_id)
    }

    /// Delete a single Marmot chat's local state (see
    /// [`MarmotEngine::delete_group`]) and narrow the live 445 subscription so we
    /// stop receiving its messages. Local-only; the peer is not notified.
    pub async fn delete_group(&self, group_id: &GroupId) -> Result<()> {
        let group_id_hex = hex::encode(group_id.as_slice());
        self.engine.delete_group(group_id)?;
        self.outbox_state
            .lock()
            .unwrap()
            .remove_group_entries(&group_id_hex)?;
        self.remove_index_for_group(group_id);
        self.notify_conversation_changed(&group_id_hex);
        let _ = self.resubscribe_marmot_groups_if_live().await;
        Ok(())
    }

    // ── Conversation index (Signal-style summary table) ──────────────────

    pub fn set_conversation_change_listener(
        &self,
        listener: Option<Arc<dyn ConversationChangeListener>>,
    ) {
        *self.change_listener.lock().unwrap() = listener;
    }

    pub fn conversation_summaries(&self) -> Vec<ConversationSummary> {
        let Some(ref idx) = self.conversation_index else {
            return Vec::new();
        };
        idx.lock().unwrap().summaries_ordered().unwrap_or_default()
    }

    pub fn conversation_summary(&self, group_id_hex: &str) -> Option<ConversationSummary> {
        let idx = self.conversation_index.as_ref()?;
        idx.lock().unwrap().summary(group_id_hex).ok().flatten()
    }

    pub fn mark_conversation_read(&self, group_id_hex: &str) {
        if let Some(ref idx) = self.conversation_index {
            if let Err(e) = idx.lock().unwrap().mark_read(group_id_hex) {
                tracing::warn!(%e, "index mark_read failed");
            }
            self.notify_conversation_changed(group_id_hex);
        }
    }

    pub fn messages_cursor_page(
        &self,
        group_id: &GroupId,
        before_secs: Option<u64>,
        before_id: Option<&nostr::EventId>,
        limit: usize,
    ) -> Result<Vec<ChatMessage>> {
        self.engine
            .messages_cursor_page(group_id, before_secs, before_id, limit)
            .map(|msgs| {
                msgs.into_iter()
                    .map(|m| self.with_delivery_state(m))
                    .collect()
            })
    }

    fn upsert_index_for_message(&self, message: &ChatMessage, group_name: Option<&str>) {
        let Some(ref idx) = self.conversation_index else {
            return;
        };
        let group_id_hex = hex::encode(message.group_id.as_slice());
        let name = group_name.unwrap_or("");
        if let Err(e) = idx.lock().unwrap().upsert_summary(
            &group_id_hex,
            name,
            &message.content,
            &message.sender.to_string(),
            message.created_at.as_secs(),
            message.mine,
        ) {
            tracing::warn!(%e, "index upsert failed");
        }
    }

    fn ensure_index_for_group(&self, group_id: &GroupId, name: &str) {
        let Some(ref idx) = self.conversation_index else {
            return;
        };
        let group_id_hex = hex::encode(group_id.as_slice());
        if let Err(e) = idx.lock().unwrap().ensure_group(&group_id_hex, name) {
            tracing::warn!(%e, "index ensure_group failed");
        }
    }

    fn resolve_group_name(&self, group_id: &GroupId) -> Option<String> {
        self.engine.groups().ok().and_then(|gs| {
            gs.into_iter()
                .find(|g| g.mls_group_id == *group_id)
                .map(|g| g.name)
        })
    }

    fn remove_index_for_group(&self, group_id: &GroupId) {
        let Some(ref idx) = self.conversation_index else {
            return;
        };
        let group_id_hex = hex::encode(group_id.as_slice());
        if let Err(e) = idx.lock().unwrap().remove_group(&group_id_hex) {
            tracing::warn!(%e, "index remove_group failed");
        }
    }

    fn notify_conversation_changed(&self, group_id_hex: &str) {
        if let Some(l) = self.change_listener.lock().unwrap().clone() {
            let id = group_id_hex.to_owned();
            l.on_conversation_changed(id);
        }
    }

    fn notify_conversations_changed(&self, group_ids: &HashSet<String>) {
        let listener = self.change_listener.lock().unwrap().clone();
        if let Some(l) = listener {
            for id in group_ids {
                l.on_conversation_changed(id.clone());
            }
        }
    }

    fn materialize_index_if_empty(&mut self) {
        let Some(ref idx) = self.conversation_index else {
            return;
        };
        let idx_guard = idx.lock().unwrap();
        if !idx_guard.is_empty() {
            return;
        }
        if let Err(e) = idx_guard.materialize_from(&self.engine) {
            tracing::warn!(%e, "index materialize failed");
        }
    }

    // ── Geohash public channels (kind-20000 over Nostr) ──

    /// Add + connect the Nostr relays geographically nearest [geohash] — the SAME
    /// set bitchat's `GeoRelayDirectory` uses for that geohash. Without this our
    /// channel events land on different relays than a bitchat client subscribes
    /// to, so neither side sees the other. Best-effort per relay.
    async fn ensure_geohash_relays(&self, geohash: &str) {
        if !self.allow_geo_relays {
            return; // in-memory/test session: stay network-free
        }
        // bitchat picks the 5 nearest relays from ITS relay directory. A peer's
        // directory can differ (or be a stale bundle when its fetch fails — seen
        // on bitchat-android), so its top pick may rank lower in ours. Join a
        // WIDER set (12) than bitchat's 5 so the two overlap on at least one
        // relay even when the directories don't perfectly agree.
        for url in crate::relay_directory::closest_relays_for_geohash(geohash, 12) {
            if self.nostr.add_relay(&url).await.is_ok() {
                let _ = self.nostr.connect_relay(&url).await;
            }
        }
    }

    /// Subscribe to a geohash channel so the relay delivers its live
    /// (ephemeral) messages into our buffer. Idempotent.
    pub async fn subscribe_geohash(&self, geohash: &str) -> Result<()> {
        {
            let mut subs = self.geo_subscribed.lock().unwrap();
            if !subs.insert(geohash.to_string()) {
                return Ok(());
            }
        }
        // Join the geohash's nearest relays (bitchat's set) BEFORE subscribing,
        // so the subscription covers them and our publishes reach bitchat.
        self.ensure_geohash_relays(geohash).await;
        // Public channel messages (kind-20000) tagged with this geohash.
        let channel = Filter::new()
            .kind(Kind::Custom(20000))
            .custom_tag(SingleLetterTag::lowercase(Alphabet::G), geohash);
        self.nostr.subscribe(channel, None).await?;

        // Presence heartbeats (kind-20001) tagged with this geohash.
        let presence = Filter::new()
            .kind(Kind::Custom(20001))
            .custom_tag(SingleLetterTag::lowercase(Alphabet::G), geohash);
        self.nostr.subscribe(presence, None).await?;

        // 1:1 DMs (NIP-17 gift wraps) addressed to our per-geohash key.
        let geo_pk =
            crate::geohash::derive_geohash_keys(&self.identity_secret, geohash)?.public_key();
        let dms = Filter::new().kind(Kind::GiftWrap).pubkey(geo_pk);
        self.nostr.subscribe(dms, None).await?;
        Ok(())
    }

    /// Send a 1:1 encrypted DM to a participant in a geohash channel (NIP-17
    /// gift wrap from our per-geohash key to theirs).
    pub async fn send_geo_dm(&self, geohash: &str, recipient_hex: &str, text: &str) -> Result<()> {
        self.subscribe_geohash(geohash).await?;
        let keys = crate::geohash::derive_geohash_keys(&self.identity_secret, geohash)?;
        let recipient = PublicKey::from_hex(recipient_hex)?;
        let rumor = EventBuilder::new(Kind::Custom(14), text)
            .tags([Tag::public_key(recipient)])
            .build(keys.public_key());
        let ts = rumor.created_at.as_secs();
        let gift = EventBuilder::gift_wrap(&keys, &recipient, rumor, []).await?;
        // Record locally first, then publish in the background so the UI shows
        // the message instantly (relays don't echo to the sender anyway).
        let id = gift.id.to_hex();
        {
            let mut map = self.geo_dm.lock().unwrap();
            let bucket = map
                .entry((geohash.to_string(), recipient_hex.to_string()))
                .or_default();
            bucket.push(RawGeoDm {
                id,
                sender: keys.public_key(),
                content: text.to_string(),
                ts,
                mine: true,
            });
        }
        let nostr = self.nostr.clone();
        tokio::spawn(async move {
            let _ = nostr.send_event(&gift).await;
        });
        Ok(())
    }

    /// The 1:1 geohash DM conversation with `peer_hex`, oldest first.
    pub async fn fetch_geo_dm(
        &self,
        geohash: &str,
        peer_hex: &str,
    ) -> Result<Vec<crate::geohash::GeoMessage>> {
        self.subscribe_geohash(geohash).await?;
        let map = self.geo_dm.lock().unwrap();
        let mut out: Vec<crate::geohash::GeoMessage> = map
            .get(&(geohash.to_string(), peer_hex.to_string()))
            .map(|bucket| {
                bucket
                    .iter()
                    .map(|r| crate::geohash::GeoMessage {
                        id: r.id.clone(),
                        sender_pubkey: r.sender.to_hex(),
                        nickname: String::new(),
                        content: r.content.clone(),
                        created_at: r.ts,
                        mine: r.mine,
                    })
                    .collect()
            })
            .unwrap_or_default();
        out.sort_by_key(|m| m.created_at);
        Ok(out)
    }

    /// Publish a public message to a geohash channel, signed with this
    /// identity's stable per-geohash ephemeral key, carrying the display
    /// nickname in an `n` tag.
    pub async fn send_geohash(&self, geohash: &str, text: &str, nickname: &str) -> Result<()> {
        self.subscribe_geohash(geohash).await?;
        let secret = self.identity().keys().secret_key().to_secret_bytes();
        let geo = crate::geohash::derive_geohash_keys(&secret, geohash)?;
        let tags = vec![
            Tag::custom(
                TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::G)),
                [geohash.to_string()],
            ),
            Tag::custom(
                TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::N)),
                [nickname.to_string()],
            ),
        ];
        let event = EventBuilder::new(Kind::Custom(20000), text)
            .tags(tags)
            .sign_with_keys(&geo)?;
        // Record locally + count ourselves FIRST so the UI shows the message
        // INSTANTLY, then publish in the BACKGROUND. send_event() awaits a relay
        // round-trip across EVERY connected relay (a dozen for a geohash); doing
        // that before recording made the user wait seconds for their own message
        // to appear. Relays don't echo to the sender, so the local copy is what
        // the UI renders either way.
        let id = event.id.to_hex();
        let ts = event.created_at.as_secs();
        self.geo_presence
            .lock()
            .unwrap()
            .entry(geohash.to_string())
            .or_default()
            .insert(event.pubkey.to_hex(), ts);
        {
            let mut map = self.geo.lock().unwrap();
            let bucket = map.entry(geohash.to_string()).or_default();
            if !bucket.iter().any(|r| r.id == id) {
                bucket.push(RawGeo {
                    id,
                    pubkey: event.pubkey,
                    nickname: nickname.to_string(),
                    content: text.to_string(),
                    ts,
                });
            }
        }
        let nostr = self.nostr.clone();
        tokio::spawn(async move {
            let _ = nostr.send_event(&event).await;
        });
        Ok(())
    }

    /// Broadcast a presence heartbeat (kind-20001) for a geohash channel, so
    /// other participants count this device in "N here now". Empty content, a
    /// single `g`=geohash tag, signed with the stable per-geohash ephemeral key
    /// (the same key used for messages, so presence and authorship line up).
    /// Wire-compatible with the iOS `createGeohashPresenceEvent`. Call this on
    /// channel open and re-call on a ~60s heartbeat while the channel is active.
    pub async fn send_geohash_presence(&self, geohash: &str) -> Result<()> {
        self.subscribe_geohash(geohash).await?;
        let secret = self.identity().keys().secret_key().to_secret_bytes();
        let geo = crate::geohash::derive_geohash_keys(&secret, geohash)?;
        let event = EventBuilder::new(Kind::Custom(20001), "")
            .tags([Tag::custom(
                TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::G)),
                [geohash.to_string()],
            )])
            .sign_with_keys(&geo)?;
        // Count ourselves locally first, then publish in the background — the
        // heartbeat fires for several channels each tick and must not block the
        // poll on relay round-trips.
        {
            let mut map = self.geo_presence.lock().unwrap();
            let bucket = map.entry(geohash.to_string()).or_default();
            bucket.insert(event.pubkey.to_hex(), event.created_at.as_secs());
        }
        let nostr = self.nostr.clone();
        tokio::spawn(async move {
            let _ = nostr.send_event(&event).await;
        });
        Ok(())
    }

    /// Number of participants currently "here now" in a geohash channel: the
    /// count of distinct presence heartbeats (kind-20001) seen within the TTL.
    /// Subscribes on first access. Includes this device once it has announced.
    pub async fn geohash_presence_count(&self, geohash: &str) -> Result<u32> {
        self.subscribe_geohash(geohash).await?;
        let cutoff = Timestamp::now().as_secs().saturating_sub(PRESENCE_TTL_SECS);
        let mut map = self.geo_presence.lock().unwrap();
        let count = match map.get_mut(geohash) {
            Some(bucket) => {
                // Evict stale heartbeats while we're here so the map can't grow
                // unbounded over a long session in a busy channel.
                bucket.retain(|_, &mut ts| ts >= cutoff);
                bucket.len()
            }
            None => 0,
        };
        Ok(count as u32)
    }

    /// Recent messages for a geohash channel from the live buffer, oldest
    /// first. Subscribes on first access (so a subsequent call sees messages
    /// delivered since).
    pub async fn fetch_geohash(
        &self,
        geohash: &str,
        limit: usize,
    ) -> Result<Vec<crate::geohash::GeoMessage>> {
        self.subscribe_geohash(geohash).await?;
        let secret = self.identity().keys().secret_key().to_secret_bytes();
        let my_pk = crate::geohash::derive_geohash_keys(&secret, geohash)?.public_key();
        let map = self.geo.lock().unwrap();
        let mut out: Vec<crate::geohash::GeoMessage> = map
            .get(geohash)
            .map(|bucket| {
                bucket
                    .iter()
                    .map(|r| crate::geohash::GeoMessage {
                        id: r.id.clone(),
                        sender_pubkey: r.pubkey.to_hex(),
                        nickname: r.nickname.clone(),
                        content: r.content.clone(),
                        created_at: r.ts,
                        mine: r.pubkey == my_pk,
                    })
                    .collect()
            })
            .unwrap_or_default();
        out.sort_by_key(|m| m.created_at);
        if out.len() > limit {
            out.drain(0..out.len() - limit);
        }
        Ok(out)
    }

    /// Erase a persistent database at `db_path` (and its SQLite sidecars).
    ///
    /// Free function — no live client may hold the DB open. Used by panic-wipe
    /// before the Swift host also clears the Keychain key.
    pub fn wipe_database(db_path: impl AsRef<Path>) -> Result<()> {
        let db_path = db_path.as_ref();
        let db_result = MarmotEngine::wipe(db_path);
        let index_result = wipe_index_for_db(db_path);
        db_result?;
        index_result
    }
}

fn conservative_watermark(disk_watermark_secs: u64, fallback_watermark_secs: u64) -> u64 {
    match (disk_watermark_secs, fallback_watermark_secs) {
        (0, _) | (_, 0) => 0,
        (disk, fallback) => disk.min(fallback),
    }
}

fn sync_state_path_for_db(db_path: &Path) -> PathBuf {
    let name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar.db");
    db_path.with_file_name(format!("{name}{SYNC_STATE_FILE_SUFFIX}"))
}

fn sync_state_tmp_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-sync.json");
    path.with_file_name(format!("{name}.tmp"))
}

fn is_terminal_marmot_processing_error(err: &Error) -> bool {
    matches!(
        err,
        Error::Nip59(_)
            | Error::Nip44(_)
            | Error::NostrEvent(_)
            | Error::Mdk(mdk_core::Error::WelcomePreviouslyFailed(_))
    )
}

/// Read the value of a single-letter tag (e.g. `g`=geohash, `n`=nickname).
fn tag_value(event: &Event, letter: Alphabet) -> Option<String> {
    event
        .tags
        .iter()
        .find(|t| t.single_letter_tag() == Some(SingleLetterTag::lowercase(letter)))
        .and_then(|t| t.content().map(|s| s.to_string()))
}

fn sort_marmot_events(events: impl IntoIterator<Item = Event>) -> Vec<Event> {
    let mut events: Vec<Event> = events.into_iter().collect();
    sort_marmot_events_in_place(&mut events);
    events
}

fn newest_valid_sonar_descriptor(
    events: impl IntoIterator<Item = Event>,
    author: PublicKey,
) -> Option<SonarDescriptor> {
    let mut descriptors: Vec<SonarDescriptor> = events
        .into_iter()
        .filter(|event| event.pubkey == author)
        .filter_map(|event| parse_descriptor_event(&event))
        .collect();
    descriptors.sort_by_key(|descriptor| std::cmp::Reverse(descriptor.published_at_secs));
    descriptors.into_iter().next()
}

fn sort_marmot_events_in_place(events: &mut [Event]) {
    events.sort_by(|a, b| {
        a.created_at
            .as_secs()
            .cmp(&b.created_at.as_secs())
            .then_with(|| a.id.to_hex().cmp(&b.id.to_hex()))
    });
}

fn require_relay_success(
    output: &nostr_sdk::pool::Output<EventId>,
    context: &'static str,
) -> Result<()> {
    if !output.success.is_empty() {
        if !output.failed.is_empty() {
            tracing::debug!(
                context,
                success_count = output.success.len(),
                failed_count = output.failed.len(),
                "nostr publish partially succeeded"
            );
        }
        return Ok(());
    }

    let failures = if output.failed.is_empty() {
        "no relay accepted the event".to_string()
    } else {
        output
            .failed
            .iter()
            .map(|(relay, reason)| format!("{relay:?}: {reason}"))
            .collect::<Vec<_>>()
            .join(", ")
    };
    Err(Error::NostrPublish(format!(
        "{context}: no relay accepted event {} ({failures})",
        output.val
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashMap, HashSet};

    fn signed_event(keys: &Keys, created_at_secs: u64, content: &str) -> Event {
        EventBuilder::new(Kind::MlsGroupMessage, content)
            .custom_created_at(Timestamp::from_secs(created_at_secs))
            .sign_with_keys(keys)
            .expect("event signs")
    }

    fn signed_descriptor_event(
        keys: &Keys,
        d_tag: &'static str,
        created_at_secs: u64,
        content: String,
    ) -> Event {
        EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), content)
            .tags(descriptor_tags(d_tag))
            .custom_created_at(Timestamp::from_secs(created_at_secs))
            .sign_with_keys(keys)
            .expect("descriptor signs")
    }

    #[test]
    fn media_http_retry_classifier_retries_transient_body_errors() {
        assert!(retryable_media_http_error(&Error::Http(
            "error decoding response body".into()
        )));
        assert!(retryable_media_http_error(&Error::Http(
            "GET https://example.test/blob -> HTTP 503 Service Unavailable".into()
        )));
    }

    #[test]
    fn media_http_retry_classifier_rejects_permanent_errors() {
        assert!(!retryable_media_http_error(&Error::Http(
            "refusing non-https media url: http://127.0.0.1/blob".into()
        )));
        assert!(!retryable_media_http_error(&Error::Http(
            "GET https://example.test/blob -> HTTP 404 Not Found".into()
        )));
        assert!(!retryable_media_http_error(&Error::Http(
            "media exceeds size cap".into()
        )));
    }

    #[test]
    fn sort_marmot_events_orders_by_created_at() {
        let keys = Keys::generate();
        let newer = signed_event(&keys, 30, "newer");
        let oldest = signed_event(&keys, 10, "oldest");
        let middle = signed_event(&keys, 20, "middle");

        let sorted = sort_marmot_events([newer, oldest, middle]);
        let contents: Vec<&str> = sorted.iter().map(|event| event.content.as_str()).collect();

        assert_eq!(contents, ["oldest", "middle", "newer"]);
    }

    #[test]
    fn newest_valid_sonar_descriptor_uses_freshest_event_across_d_tags() {
        let keys = Keys::generate();
        let stale_offer =
            "lno1qsgqmqvgm96frzdg8m0gc6nzeqffvzsqzrxqy32afmr3jn9ggl9g2s8sugfvxn4xqzqxqsq";
        let old_meta = signed_descriptor_event(
            &keys,
            SONAR_META_DESCRIPTOR_D_TAG,
            10,
            meta_descriptor_content_json(
                true,
                vec!["marmot".to_string()],
                Some(stale_offer.to_string()),
            )
            .expect("meta descriptor json"),
        );
        let new_call = signed_descriptor_event(
            &keys,
            SONAR_CALL_DESCRIPTOR_D_TAG,
            20,
            descriptor_content_json(true, vec!["marmot".to_string()])
                .expect("call descriptor json"),
        );

        let descriptor = newest_valid_sonar_descriptor([old_meta, new_call], keys.public_key())
            .expect("freshest descriptor");

        assert_eq!(descriptor.published_at_secs, 20);
        assert!(descriptor.bolt12_offer.is_none());
    }

    #[test]
    fn sync_state_uses_conservative_watermark() {
        assert_eq!(conservative_watermark(1_000, 500), 500);
        assert_eq!(conservative_watermark(500, 1_000), 500);
        assert_eq!(conservative_watermark(0, 1_000), 0);
        assert_eq!(conservative_watermark(1_000, 0), 0);
    }

    #[test]
    fn sync_state_ignores_stale_sidecar_when_storage_is_empty() {
        let temp = tempfile::tempdir().expect("tempdir");
        let path = temp.path().join("marmot.sqlite.sonar-sync.json");
        let disk = SyncStateDisk {
            version: SYNC_STATE_VERSION,
            watermark_secs: 1_000,
            processed_event_ids: vec!["abc".to_string()],
        };
        fs::write(&path, serde_json::to_vec(&disk).expect("json")).expect("write state");

        let state = SyncState::load(Some(path), 0, true);

        assert_eq!(state.watermark_secs(), 0);
        assert!(!state.has_processed("abc"));
    }

    #[test]
    fn sync_state_rewinds_for_retry_with_overlap() {
        let mut state = SyncState::new(None, 1_000, Vec::new());

        state.rewind_for_retry(900);

        assert_eq!(state.watermark_secs(), 900 - SYNC_OVERLAP_SECS);
    }

    #[test]
    fn relay_publish_requires_at_least_one_successful_relay() {
        let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
        let accepted = nostr_sdk::pool::Output {
            val: EventId::all_zeros(),
            success: HashSet::from([relay.clone()]),
            failed: HashMap::new(),
        };
        assert!(require_relay_success(&accepted, "test publish").is_ok());

        let rejected = nostr_sdk::pool::Output {
            val: EventId::all_zeros(),
            success: HashSet::new(),
            failed: HashMap::from([(relay, "blocked".to_string())]),
        };
        let err = require_relay_success(&rejected, "test publish").expect_err("must fail");
        assert!(err
            .to_string()
            .contains("test publish: no relay accepted event"));
    }
}
