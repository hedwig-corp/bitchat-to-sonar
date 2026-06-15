//! Relay-connected Sonar client: ties an [`Identity`] + [`MarmotEngine`] to
//! nostr relays. This is the async I/O layer; all protocol logic lives in
//! [`crate::marmot`].
//!
//! M1 scope: explicit polling via [`SonarClient::sync`] (deterministic for
//! e2e tests). Live subscriptions land with the native shells.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use mdk_core::prelude::*;
use nostr::prelude::*;
use nostr_sdk::{Client, RelayPoolNotification};

use crate::identity::Identity;
use crate::marmot::{ChatMessage, MarmotEngine, KEY_PACKAGE_KIND};
use crate::{Error, Result};

const FETCH_TIMEOUT: Duration = Duration::from_secs(10);

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

pub struct SonarClient {
    engine: MarmotEngine,
    nostr: Client,
    relays: Vec<RelayUrl>,
    geo: Arc<Mutex<HashMap<String, Vec<RawGeo>>>>,
    geo_dm: GeoDmBuf,
    geo_presence: GeoPresenceBuf,
    geo_subscribed: Arc<Mutex<HashSet<String>>>,
    identity_secret: [u8; 32],
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
        Self::with_engine(identity, relays, engine).await
    }

    /// Connect with a volatile in-memory store. State is lost when the client is
    /// dropped. Intended for tests and ephemeral/anonymous sessions.
    pub async fn connect_in_memory(identity: Identity, relays: Vec<RelayUrl>) -> Result<Self> {
        let engine = MarmotEngine::in_memory(identity.clone());
        Self::with_engine(identity, relays, engine).await
    }

    async fn with_engine(
        identity: Identity,
        relays: Vec<RelayUrl>,
        engine: MarmotEngine,
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
            while let Ok(notification) = notifications.recv().await {
                let RelayPoolNotification::Event { event, .. } = notification else {
                    continue;
                };
                match event.kind.as_u16() {
                    20000 => {
                        let Some(geohash) = tag_value(&event, Alphabet::G) else { continue };
                        let nickname = tag_value(&event, Alphabet::N).unwrap_or_default();
                        let id = event.id.to_hex();
                        let mut map = handler_geo.lock().unwrap();
                        let bucket = map.entry(geohash).or_default();
                        if !bucket.iter().any(|r| r.id == id) {
                            bucket.push(RawGeo {
                                id,
                                pubkey: event.pubkey,
                                nickname,
                                content: event.content.clone(),
                                ts: event.created_at.as_u64(),
                            });
                        }
                    }
                    20001 => {
                        // Presence heartbeat: record the freshest timestamp per
                        // participant so "N here now" counts live participants.
                        let Some(geohash) = tag_value(&event, Alphabet::G) else { continue };
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
                        let Some(p_hex) = tag_value(&event, Alphabet::P) else { continue };
                        let subs: Vec<String> = handler_subs.lock().unwrap().iter().cloned().collect();
                        for geohash in subs {
                            let Ok(keys) = crate::geohash::derive_geohash_keys(&identity_secret, &geohash) else { continue };
                            if keys.public_key().to_hex() != p_hex {
                                continue;
                            }
                            if let Ok(unwrapped) = UnwrappedGift::from_gift_wrap(&keys, &event).await {
                                if unwrapped.rumor.kind.as_u16() != 14 {
                                    break;
                                }
                                let peer_hex = unwrapped.sender.to_hex();
                                let id = unwrapped.rumor.id.map(|i| i.to_hex()).unwrap_or_else(|| event.id.to_hex());
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
        })
    }

    pub fn identity(&self) -> &Identity {
        self.engine.identity()
    }

    /// Publish our kind-30443 KeyPackage so others can start groups with us.
    pub async fn publish_key_package(&self) -> Result<()> {
        let event = self.engine.key_package_event(self.relays.clone())?;
        self.nostr.send_event(&event).await?;
        Ok(())
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

    /// Poll the relays once: first gift-wrapped welcomes addressed to us
    /// (which may add groups), then kind-445 messages for every known group.
    /// Duplicate/already-processed events are tolerated by design.
    pub async fn sync(&self) -> Result<()> {
        let wraps = Filter::new()
            .kind(Kind::GiftWrap)
            .pubkey(self.identity().public_key());
        for event in self.nostr.fetch_events(wraps, FETCH_TIMEOUT).await? {
            if let Err(err) = self.engine.process_incoming(&event).await {
                tracing::debug!(%err, "skipping gift wrap (likely duplicate)");
            }
        }

        for group in self.engine.groups()? {
            let filter = Filter::new()
                .kind(Kind::MlsGroupMessage)
                .custom_tag(
                    SingleLetterTag::lowercase(Alphabet::H),
                    hex::encode(group.nostr_group_id),
                );
            for event in self.nostr.fetch_events(filter, FETCH_TIMEOUT).await? {
                if let Err(err) = self.engine.process_incoming(&event).await {
                    tracing::debug!(%err, "skipping group message (likely duplicate)");
                }
            }
        }
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

    /// Subscribe to a geohash channel so the relay delivers its live
    /// (ephemeral) messages into our buffer. Idempotent.
    pub async fn subscribe_geohash(&self, geohash: &str) -> Result<()> {
        {
            let mut subs = self.geo_subscribed.lock().unwrap();
            if !subs.insert(geohash.to_string()) {
                return Ok(());
            }
        }
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
        let geo_pk = crate::geohash::derive_geohash_keys(&self.identity_secret, geohash)?.public_key();
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
        self.nostr.send_event(&gift).await?;
        // Record locally (relays don't echo to the sender).
        let id = gift.id.to_hex();
        let mut map = self.geo_dm.lock().unwrap();
        let bucket = map.entry((geohash.to_string(), recipient_hex.to_string())).or_default();
        bucket.push(RawGeoDm {
            id,
            sender: keys.public_key(),
            content: text.to_string(),
            ts,
            mine: true,
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
        self.nostr.send_event(&event).await?;
        // Relays don't echo an event back to its sender, so record our own
        // message locally (deduped by id in case a relay does echo).
        let id = event.id.to_hex();
        let mut map = self.geo.lock().unwrap();
        let bucket = map.entry(geohash.to_string()).or_default();
        if !bucket.iter().any(|r| r.id == id) {
            bucket.push(RawGeo {
                id,
                pubkey: event.pubkey,
                nickname: nickname.to_string(),
                content: text.to_string(),
                ts: event.created_at.as_u64(),
            });
        }
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
        self.nostr.send_event(&event).await?;
        // Relays don't echo to the sender; count ourselves locally so a solo
        // user still sees "1 here now".
        let mut map = self.geo_presence.lock().unwrap();
        let bucket = map.entry(geohash.to_string()).or_default();
        bucket.insert(event.pubkey.to_hex(), event.created_at.as_u64());
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
