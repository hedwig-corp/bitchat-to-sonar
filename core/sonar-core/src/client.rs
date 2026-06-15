//! Relay-connected Sonar client: ties an [`Identity`] + [`MarmotEngine`] to
//! nostr relays. This is the async I/O layer; all protocol logic lives in
//! [`crate::marmot`].
//!
//! M1 scope: explicit polling via [`SonarClient::sync`] (deterministic for
//! e2e tests). Live subscriptions land with the native shells.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use mdk_core::prelude::*;
use nostr::prelude::*;
use nostr_blossom::prelude::*;
use nostr_sdk::{Client, RelayPoolNotification};

use crate::identity::Identity;
use crate::marmot::{ChatMessage, MarmotEngine, KEY_PACKAGE_KIND};
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
const SYNC_OVERLAP_SECS: u64 = 60;

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
    /// Unix-seconds watermark of the last successful [`SonarClient::sync`].
    /// Scopes each poll's `.since(...)` so we fetch only NEW welcomes/messages
    /// instead of re-downloading + re-processing all history every 5s. 0 until
    /// the first sync completes (an unbounded backfill, like White Noise's
    /// `since = None` on a fresh account).
    last_sync: Arc<Mutex<u64>>,
    /// Whether to join geohash-nearest relays on subscribe (real sessions); off
    /// for in-memory/test sessions so they stay network-free against a MockRelay.
    allow_geo_relays: bool,
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
        let engine = MarmotEngine::persistent(identity.clone(), db_path, db_key)?;
        Self::with_engine(identity, relays, engine, true).await
    }

    /// Connect with a volatile in-memory store. State is lost when the client is
    /// dropped. Intended for tests and ephemeral/anonymous sessions.
    pub async fn connect_in_memory(identity: Identity, relays: Vec<RelayUrl>) -> Result<Self> {
        let engine = MarmotEngine::in_memory(identity.clone());
        Self::with_engine(identity, relays, engine, false).await
    }

    async fn with_engine(
        identity: Identity,
        relays: Vec<RelayUrl>,
        engine: MarmotEngine,
        allow_geo_relays: bool,
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

        let handler_geo = geo.clone();
        let handler_dm = geo_dm.clone();
        let handler_presence = geo_presence.clone();
        let handler_subs = geo_subscribed.clone();
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
                        let ts = event.created_at.as_u64();
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
                        let ts = event.created_at.as_u64();
                        let slot = bucket.entry(event.pubkey.to_hex()).or_insert(0);
                        if ts > *slot {
                            *slot = ts;
                        }
                    }
                    1059 => {
                        // Gift wrap: the `p` tag names our per-geohash recipient
                        // key. Find which active channel it targets, unwrap with
                        // that key, and record the kind-14 DM.
                        let Some(p_hex) = tag_value(&event, Alphabet::P) else {
                            continue;
                        };
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
                                        ts: unwrapped.rumor.created_at.as_u64(),
                                        mine: false,
                                    });
                                }
                            }
                            break;
                        }
                    }
                    _ => {}
                }
            }
        });

        Ok(Self {
            engine,
            nostr,
            relays,
            geo,
            geo_dm,
            geo_presence,
            geo_subscribed,
            identity_secret,
            last_sync: Arc::new(Mutex::new(0)),
            allow_geo_relays,
        })
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
        let creation = self
            .engine
            .create_group(name, vec![key_package], self.relays.clone())?;
        for (member, rumor) in creation.welcomes {
            let wrapped = self.engine.gift_wrap_welcome(&member, rumor).await?;
            self.nostr.send_event(&wrapped).await?;
        }
        Ok(creation.group.mls_group_id)
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

    /// Start a DM/group with `peer`: fetch their KeyPackage, create the MLS
    /// group, and deliver the gift-wrapped welcome.
    pub async fn start_dm(&self, peer: PublicKey, name: &str) -> Result<GroupId> {
        let key_package = self.fetch_key_package(peer).await?;
        let creation = self
            .engine
            .create_group(name, vec![key_package], self.relays.clone())?;
        for (member, rumor) in creation.welcomes {
            let wrapped = self.engine.gift_wrap_welcome(&member, rumor).await?;
            self.nostr.send_event(&wrapped).await?;
        }
        Ok(creation.group.mls_group_id)
    }

    /// Encrypt, publish, and locally record a text message.
    pub async fn send_text(&self, group_id: &GroupId, text: &str) -> Result<()> {
        let event = self.engine.create_text_message(group_id, text)?;
        self.nostr.send_event(&event).await?;
        self.engine.process_incoming(&event).await?;
        Ok(())
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
        self.engine.process_incoming(&event).await?;
        Ok(())
    }

    /// Download the encrypted blob at `url` and decrypt it with the group media
    /// key (resolved from the message's imeta tag). Returns plaintext bytes.
    pub async fn fetch_media(&self, group_id: &GroupId, url: &str) -> Result<Vec<u8>> {
        let ciphertext = http_get(url).await?;
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
        let since_secs = *self.last_sync.lock().unwrap();
        // Capture the start time as the next watermark BEFORE fetching, so any
        // event that lands mid-sync is re-covered by the overlap next poll.
        let started = Timestamp::now().as_u64();

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
        for event in self.nostr.fetch_events(wraps, FETCH_TIMEOUT).await? {
            if let Err(err) = self.engine.process_incoming(&event).await {
                tracing::debug!(%err, "skipping gift wrap (likely duplicate)");
            }
        }

        // Fetch kind-445 for ALL known groups in one request (batched `#h`),
        // including any group a welcome just added above.
        let group_ids: Vec<String> = self
            .engine
            .groups()?
            .into_iter()
            .map(|g| hex::encode(g.nostr_group_id))
            .collect();
        if !group_ids.is_empty() {
            let mut filter = Filter::new()
                .kind(Kind::MlsGroupMessage)
                .custom_tags(SingleLetterTag::lowercase(Alphabet::H), group_ids);
            if since_secs > 0 {
                filter = filter.since(Timestamp::from_secs(
                    since_secs.saturating_sub(SYNC_OVERLAP_SECS),
                ));
            }
            for event in self.nostr.fetch_events(filter, FETCH_TIMEOUT).await? {
                if let Err(err) = self.engine.process_incoming(&event).await {
                    tracing::debug!(%err, "skipping group message (likely duplicate)");
                }
            }
        }

        // Advance the watermark only after a fully successful poll: a fetch
        // error returns `?` above and leaves the old watermark, so the next
        // poll re-tries the same window rather than skipping events.
        *self.last_sync.lock().unwrap() = started;
        Ok(())
    }

    pub fn groups(&self) -> Result<Vec<group_types::Group>> {
        self.engine.groups()
    }

    pub fn messages(&self, group_id: &GroupId) -> Result<Vec<ChatMessage>> {
        self.engine.messages(group_id)
    }

    pub fn members(&self, group_id: &GroupId) -> Result<Vec<PublicKey>> {
        self.engine.members(group_id)
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
        let ts = rumor.created_at.as_u64();
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
        let ts = event.created_at.as_u64();
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
            bucket.insert(event.pubkey.to_hex(), event.created_at.as_u64());
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
        let cutoff = Timestamp::now().as_u64().saturating_sub(PRESENCE_TTL_SECS);
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
        MarmotEngine::wipe(db_path)
    }
}

/// Read the value of a single-letter tag (e.g. `g`=geohash, `n`=nickname).
fn tag_value(event: &Event, letter: Alphabet) -> Option<String> {
    event
        .tags
        .iter()
        .find(|t| t.single_letter_tag() == Some(SingleLetterTag::lowercase(letter)))
        .and_then(|t| t.content().map(|s| s.to_string()))
}
