//! UniFFI surface for `sonar-core`.
//!
//! Design (2026-06-12):
//! - Proc-macro mode only (`#[uniffi::export]`), no UDL.
//! - All `SonarNode` methods are BLOCKING: the node owns a multi-thread tokio
//!   runtime and `block_on`s the async `SonarClient` internally. Swift callers
//!   dispatch onto a background queue/Task; the Swift call surface stays
//!   plain synchronous functions.
//! - GroupId crosses the boundary as lowercase hex of `GroupId::as_slice()`.

use std::sync::{Arc, Mutex};

use nostr::prelude::*;
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;
use sonar_core::noise::{NoiseHandshake, NoiseKeypair, NoiseSession};
use sonar_core::GroupId;

uniffi::setup_scaffolding!();

/// Flat error: only the rendered message crosses the FFI boundary
/// (`SonarFfiError.InvalidInput(message:)` / `.Core(message:)` in Swift).
#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum SonarFfiError {
    /// Caller passed something unparseable (bad nsec, npub, hex, relay URL).
    #[error("invalid input: {0}")]
    InvalidInput(String),
    /// Anything that went wrong inside sonar-core (relay I/O, MLS, MDK...).
    #[error("{0}")]
    Core(String),
}

impl From<sonar_core::Error> for SonarFfiError {
    fn from(err: sonar_core::Error) -> Self {
        Self::Core(err.to_string())
    }
}

type FfiResult<T> = Result<T, SonarFfiError>;

fn invalid<E: std::fmt::Display>(what: &str) -> impl FnOnce(E) -> SonarFfiError + '_ {
    move |e| SonarFfiError::InvalidInput(format!("{what}: {e}"))
}

fn parse_group_id(hex_id: &str) -> FfiResult<GroupId> {
    let bytes = hex::decode(hex_id).map_err(invalid("group id"))?;
    Ok(GroupId::from_slice(&bytes))
}

/// Parse a 64-char hex string into the 32-byte SQLCipher key.
fn parse_db_key(db_key_hex: &str) -> FfiResult<[u8; 32]> {
    let bytes = hex::decode(db_key_hex).map_err(invalid("db key hex"))?;
    bytes.try_into().map_err(|_| {
        SonarFfiError::InvalidInput("db key must be exactly 32 bytes (64 hex chars)".into())
    })
}

/// Erase the persistent Marmot database at `db_path` (and its SQLite sidecars:
/// `-wal`, `-shm`, `-journal`).
///
/// Panic-wipe entry point. Call when NO `SonarNode` holds that path open (drop
/// the node first). The Swift host should also clear the Keychain-held DB key.
/// Idempotent: a missing file is not an error.
#[uniffi::export]
pub fn wipe_marmot_database(db_path: String) -> FfiResult<()> {
    SonarClient::wipe_database(&db_path)?;
    Ok(())
}

/// A Nostr identity (secp256k1 keypair). Wraps `sonar_core::identity::Identity`.
#[derive(uniffi::Object)]
pub struct SonarIdentity {
    inner: Identity,
}

#[uniffi::export]
impl SonarIdentity {
    /// Generate a brand-new identity (default onboarding path).
    #[uniffi::constructor]
    pub fn generate() -> Arc<Self> {
        Arc::new(Self {
            inner: Identity::generate(),
        })
    }

    /// Import from an `nsec1...` bech32 string or 64-char hex secret key.
    #[uniffi::constructor]
    pub fn import(nsec: String) -> FfiResult<Arc<Self>> {
        let inner =
            Identity::import(&nsec).map_err(|e| SonarFfiError::InvalidInput(e.to_string()))?;
        Ok(Arc::new(Self { inner }))
    }

    /// `npub1...` form of the public key.
    pub fn npub(&self) -> String {
        self.inner.npub()
    }

    /// `nsec1...` secret key export (user-driven backup only).
    pub fn nsec(&self) -> String {
        self.inner.export_nsec()
    }

    /// 64-char lowercase hex public key.
    pub fn pubkey_hex(&self) -> String {
        self.inner.public_key().to_hex()
    }
}

/// FFI-friendly group summary.
#[derive(uniffi::Record)]
pub struct GroupInfo {
    /// Hex of the MLS group id (stable; use it for `send_text`/`messages`).
    pub id_hex: String,
    pub name: String,
    pub member_npubs: Vec<String>,
}

/// FFI-friendly decrypted chat message.
#[derive(uniffi::Record)]
pub struct MessageInfo {
    pub id_hex: String,
    pub sender_npub: String,
    pub content: String,
    pub created_at_secs: u64,
    /// True when the local identity sent it.
    pub mine: bool,
    /// Encrypted media attachments (Marmot MIP-04), empty for a plain text message.
    pub media: Vec<MediaInfo>,
}

/// FFI-friendly reference to an encrypted media attachment. `url` is the Blossom
/// URL of the CIPHERTEXT; call `fetch_media(groupId, url)` to download + decrypt.
#[derive(uniffi::Record)]
pub struct MediaInfo {
    pub url: String,
    pub mime_type: String,
    pub filename: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_ms: Option<u64>,
}

/// FFI-friendly Nostr profile (kind-0 metadata, NIP-01). A Marmot member's
/// identity is a Nostr pubkey, so this resolves their human name + avatar.
#[derive(uniffi::Record)]
pub struct ProfileInfo {
    pub name: Option<String>,
    pub display_name: Option<String>,
    pub about: Option<String>,
    pub picture: Option<String>,
    pub nip05: Option<String>,
}

/// FFI-friendly geohash channel message (public, plaintext).
#[derive(uniffi::Record)]
pub struct GeoMessageInfo {
    pub id_hex: String,
    pub sender_pubkey_hex: String,
    pub nickname: String,
    pub content: String,
    pub created_at_secs: u64,
    pub mine: bool,
}

/// A relay-connected Sonar node. Owns its own tokio runtime; every method is
/// blocking — call from a background queue in Swift, never the main thread.
#[derive(uniffi::Object)]
pub struct SonarNode {
    runtime: tokio::runtime::Runtime,
    client: SonarClient,
}

#[uniffi::export]
impl SonarNode {
    /// Connect `identity` to the given relays (e.g. `wss://relay.damus.io`) with
    /// a persistent, encrypted SQLCipher store.
    ///
    /// - `db_path`: absolute filesystem path for the database (the Swift host
    ///   passes e.g. `<Application Support>/sonar-marmot/marmot.sqlite`; the host
    ///   must create the parent directory, ideally Data-Protection-Complete).
    /// - `db_key_hex`: 64-char hex of the 32-byte SQLCipher key. The host owns
    ///   this key (Keychain on iOS) and passes the SAME value every launch so the
    ///   existing database reopens. Marmot groups/messages persist across restarts.
    #[uniffi::constructor]
    pub fn connect(
        identity: Arc<SonarIdentity>,
        relay_urls: Vec<String>,
        db_path: String,
        db_key_hex: String,
    ) -> FfiResult<Arc<Self>> {
        if relay_urls.is_empty() {
            return Err(SonarFfiError::InvalidInput("relay_urls is empty".into()));
        }
        if db_path.is_empty() {
            return Err(SonarFfiError::InvalidInput("db_path is empty".into()));
        }
        let db_key = parse_db_key(&db_key_hex)?;
        let relays = relay_urls
            .iter()
            .map(|u| RelayUrl::parse(u).map_err(invalid("relay url")))
            .collect::<FfiResult<Vec<_>>>()?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| SonarFfiError::Core(format!("tokio runtime: {e}")))?;
        let client = runtime.block_on(SonarClient::connect(
            identity.inner.clone(),
            relays,
            &db_path,
            db_key,
        ))?;
        Ok(Arc::new(Self { runtime, client }))
    }

    /// Publish our kind-30443 KeyPackage so others can start groups with us.
    pub fn publish_key_package(&self) -> FfiResult<()> {
        self.runtime.block_on(self.client.publish_key_package())?;
        Ok(())
    }

    /// Publish our kind-0 profile (NIP-01 metadata) so peers can show our name +
    /// avatar instead of a raw npub. `name` is used for both name + display_name.
    pub fn publish_profile(
        &self,
        name: String,
        about: Option<String>,
        picture: Option<String>,
    ) -> FfiResult<()> {
        self.runtime.block_on(self.client.publish_profile(
            &name,
            about.as_deref(),
            picture.as_deref(),
        ))?;
        Ok(())
    }

    /// Fetch a peer's kind-0 profile (npub or hex pubkey). `None` if they have
    /// not published one. Used to resolve a Marmot member's display name.
    pub fn fetch_profile(&self, npub: String) -> FfiResult<Option<ProfileInfo>> {
        let pubkey = PublicKey::parse(&npub).map_err(invalid("profile pubkey"))?;
        let profile = self.runtime.block_on(self.client.fetch_profile(pubkey))?;
        Ok(profile.map(|p| ProfileInfo {
            name: p.name,
            display_name: p.display_name,
            about: p.about,
            picture: p.picture,
            nip05: p.nip05,
        }))
    }

    /// Start a 1:1 DM group with `peer` (npub or hex pubkey). Fetches their
    /// KeyPackage from the relays and delivers the welcome. Returns the new
    /// group id as hex.
    pub fn start_dm(&self, peer: String, name: String) -> FfiResult<String> {
        let peer = PublicKey::parse(&peer).map_err(invalid("peer pubkey"))?;
        let group_id = self.runtime.block_on(self.client.start_dm(peer, &name))?;
        Ok(hex::encode(group_id.as_slice()))
    }

    /// Encrypt + publish a text message to the group.
    pub fn send_text(&self, group_id_hex: String, text: String) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        self.runtime
            .block_on(self.client.send_text(&group_id, &text))?;
        Ok(())
    }

    /// Poll the relays once: welcomes addressed to us, then group messages.
    pub fn sync_once(&self) -> FfiResult<()> {
        self.runtime.block_on(self.client.sync())?;
        Ok(())
    }

    /// All groups this identity belongs to.
    pub fn groups(&self) -> FfiResult<Vec<GroupInfo>> {
        let groups = self.client.groups()?;
        groups
            .into_iter()
            .map(|g| {
                let members = self
                    .client
                    .members(&g.mls_group_id)?
                    .into_iter()
                    .map(|pk| pk.to_bech32().expect("npub encoding cannot fail"))
                    .collect();
                Ok(GroupInfo {
                    id_hex: hex::encode(g.mls_group_id.as_slice()),
                    name: g.name,
                    member_npubs: members,
                })
            })
            .collect()
    }

    /// Decrypted message history for a group, oldest first.
    pub fn messages(&self, group_id_hex: String) -> FfiResult<Vec<MessageInfo>> {
        let group_id = parse_group_id(&group_id_hex)?;
        let mut msgs = self.client.messages(&group_id)?;
        msgs.sort_by_key(|m| m.created_at);
        Ok(msgs
            .into_iter()
            .map(|m| MessageInfo {
                id_hex: m.id.to_hex(),
                sender_npub: m.sender.to_bech32().expect("npub encoding cannot fail"),
                content: m.content,
                created_at_secs: m.created_at.as_secs(),
                mine: m.mine,
                media: m
                    .media
                    .into_iter()
                    .map(|r| MediaInfo {
                        url: r.url,
                        mime_type: r.mime_type,
                        filename: r.filename,
                        width: r.width,
                        height: r.height,
                        duration_ms: r.duration_ms,
                    })
                    .collect(),
            })
            .collect())
    }

    /// Encrypt + upload `data` to a Blossom server, then publish a media message
    /// to the group. `server_url` empty → the core default. Blocks on the upload.
    pub fn send_media(
        &self,
        group_id_hex: String,
        data: Vec<u8>,
        filename: String,
        mime: String,
        caption: String,
        server_url: String,
    ) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        self.runtime.block_on(self.client.send_media(
            &group_id,
            data,
            &filename,
            &mime,
            &caption,
            &server_url,
        ))?;
        Ok(())
    }

    /// Download + decrypt the media blob at `url` for `group_id`. Returns plaintext.
    pub fn fetch_media(&self, group_id_hex: String, url: String) -> FfiResult<Vec<u8>> {
        let group_id = parse_group_id(&group_id_hex)?;
        Ok(self
            .runtime
            .block_on(self.client.fetch_media(&group_id, &url))?)
    }

    /// The user's Blossom server list (kind-10063). Empty if unset.
    pub fn blossom_servers(&self) -> FfiResult<Vec<String>> {
        Ok(self.runtime.block_on(self.client.blossom_servers())?)
    }

    /// Publish the user's Blossom server list (kind-10063).
    pub fn publish_blossom_servers(&self, servers: Vec<String>) -> FfiResult<()> {
        self.runtime
            .block_on(self.client.publish_blossom_servers(servers))?;
        Ok(())
    }

    /// Publish a public message to a geohash channel (kind-20000 over Nostr).
    pub fn send_geohash(&self, geohash: String, text: String, nickname: String) -> FfiResult<()> {
        self.runtime
            .block_on(self.client.send_geohash(&geohash, &text, &nickname))?;
        Ok(())
    }

    /// Fetch recent messages for a geohash channel, oldest first.
    pub fn geohash_messages(&self, geohash: String, limit: u32) -> FfiResult<Vec<GeoMessageInfo>> {
        let msgs = self
            .runtime
            .block_on(self.client.fetch_geohash(&geohash, limit as usize))?;
        Ok(msgs.into_iter().map(geo_message_info).collect())
    }

    /// Broadcast a presence heartbeat (kind-20001) for a geohash channel.
    /// Call on channel open and on a ~60s heartbeat while it is active.
    pub fn send_geohash_presence(&self, geohash: String) -> FfiResult<()> {
        self.runtime
            .block_on(self.client.send_geohash_presence(&geohash))?;
        Ok(())
    }

    /// Count of participants currently "here now" in a geohash channel
    /// (distinct kind-20001 heartbeats within the presence TTL).
    pub fn geohash_presence_count(&self, geohash: String) -> FfiResult<u32> {
        Ok(self
            .runtime
            .block_on(self.client.geohash_presence_count(&geohash))?)
    }

    /// Send a 1:1 encrypted DM to a geohash channel participant (NIP-17).
    pub fn send_geo_dm(
        &self,
        geohash: String,
        recipient_hex: String,
        text: String,
    ) -> FfiResult<()> {
        self.runtime
            .block_on(self.client.send_geo_dm(&geohash, &recipient_hex, &text))?;
        Ok(())
    }

    /// The 1:1 geohash DM conversation with a participant, oldest first.
    pub fn geo_dm_messages(
        &self,
        geohash: String,
        peer_hex: String,
    ) -> FfiResult<Vec<GeoMessageInfo>> {
        let msgs = self
            .runtime
            .block_on(self.client.fetch_geo_dm(&geohash, &peer_hex))?;
        Ok(msgs.into_iter().map(geo_message_info).collect())
    }
}

// ── Noise XX session for the BLE mesh (the tested core crypto, on Android) ──

/// A freshly generated Noise static keypair (hex-encoded X25519).
#[derive(uniffi::Record)]
pub struct NoiseKeypairHex {
    pub private_hex: String,
    pub public_hex: String,
}

#[uniffi::export]
pub fn noise_generate_keypair() -> FfiResult<NoiseKeypairHex> {
    let kp = NoiseKeypair::generate()?;
    Ok(NoiseKeypairHex {
        private_hex: hex::encode(kp.private),
        public_hex: hex::encode(kp.public),
    })
}

enum NoisePhase {
    Handshake(NoiseHandshake),
    Session(NoiseSession),
    Spent,
}

/// A Noise XX session driver for one mesh link. Feed handshake messages until
/// `is_finished`, capture `remote_static_hex` (the peer's authenticated key →
/// bitchat fingerprint), call `into_session`, then `encrypt`/`decrypt`.
#[derive(uniffi::Object)]
pub struct SonarNoise {
    phase: Mutex<NoisePhase>,
}

#[uniffi::export]
impl SonarNoise {
    #[uniffi::constructor]
    pub fn initiator(private_hex: String) -> FfiResult<Arc<Self>> {
        let sk = hex::decode(&private_hex).map_err(invalid("noise private key"))?;
        if sk.len() != 32 {
            return Err(SonarFfiError::InvalidInput(
                "noise private key must be exactly 32 bytes (64 hex chars)".into(),
            ));
        }
        Ok(Arc::new(Self {
            phase: Mutex::new(NoisePhase::Handshake(NoiseHandshake::initiator(&sk)?)),
        }))
    }

    #[uniffi::constructor]
    pub fn responder(private_hex: String) -> FfiResult<Arc<Self>> {
        let sk = hex::decode(&private_hex).map_err(invalid("noise private key"))?;
        if sk.len() != 32 {
            return Err(SonarFfiError::InvalidInput(
                "noise private key must be exactly 32 bytes (64 hex chars)".into(),
            ));
        }
        Ok(Arc::new(Self {
            phase: Mutex::new(NoisePhase::Handshake(NoiseHandshake::responder(&sk)?)),
        }))
    }

    /// Next handshake message to send to the peer.
    pub fn write_message(&self) -> FfiResult<Vec<u8>> {
        match &mut *self.phase.lock().unwrap() {
            NoisePhase::Handshake(hs) => Ok(hs.write_message()?),
            _ => Err(SonarFfiError::Core("noise: not in handshake".into())),
        }
    }

    /// Consume a handshake message received from the peer.
    pub fn read_message(&self, msg: Vec<u8>) -> FfiResult<()> {
        match &mut *self.phase.lock().unwrap() {
            NoisePhase::Handshake(hs) => Ok(hs.read_message(&msg)?),
            _ => Err(SonarFfiError::Core("noise: not in handshake".into())),
        }
    }

    pub fn is_finished(&self) -> bool {
        match &*self.phase.lock().unwrap() {
            NoisePhase::Handshake(hs) => hs.is_finished(),
            NoisePhase::Session(_) => true,
            NoisePhase::Spent => false,
        }
    }

    /// The peer's authenticated static key (hex), available after the handshake.
    pub fn remote_static_hex(&self) -> Option<String> {
        match &*self.phase.lock().unwrap() {
            NoisePhase::Handshake(hs) => hs.remote_static().map(hex::encode),
            _ => None,
        }
    }

    /// Transition from handshake to the encrypted transport phase.
    /// NB: NOT named `finalize` — that collides with Java's `Object.finalize()`
    /// in the generated Kotlin binding (the GC then re-invokes it on a spent
    /// object and throws).
    pub fn into_session(&self) -> FfiResult<()> {
        let mut g = self.phase.lock().unwrap();
        match std::mem::replace(&mut *g, NoisePhase::Spent) {
            NoisePhase::Handshake(hs) => {
                *g = NoisePhase::Session(hs.into_session()?);
                Ok(())
            }
            other => {
                *g = other;
                Err(SonarFfiError::Core("noise: handshake not finished".into()))
            }
        }
    }

    pub fn encrypt(&self, data: Vec<u8>) -> FfiResult<Vec<u8>> {
        match &mut *self.phase.lock().unwrap() {
            NoisePhase::Session(s) => Ok(s.encrypt(&data)?),
            _ => Err(SonarFfiError::Core("noise: no session".into())),
        }
    }

    pub fn decrypt(&self, data: Vec<u8>) -> FfiResult<Vec<u8>> {
        match &mut *self.phase.lock().unwrap() {
            NoisePhase::Session(s) => Ok(s.decrypt(&data)?),
            _ => Err(SonarFfiError::Core("noise: no session".into())),
        }
    }
}

// ── bitchat mesh wire (interop with the iOS BLEService) ──
//
// Stateless helpers over `sonar_core::mesh` (the byte-exact, unit-tested wire
// stack). The Android `MeshGatt` builds/parses these to speak the real bitchat
// protocol; the Noise crypto stays in `SonarNoise`.

use sonar_core::mesh;

/// A verified identity announce decoded off the mesh.
#[derive(uniffi::Record)]
pub struct MeshAnnounceInfo {
    pub nickname: String,
    pub noise_public_key_hex: String,
    pub signing_public_key_hex: String,
    pub sender_id_hex: String,
}

/// The outer fields of a decoded mesh packet.
#[derive(uniffi::Record)]
pub struct MeshPacketInfo {
    pub packet_type: u8,
    pub ttl: u8,
    pub sender_id_hex: String,
    /// Empty when the packet has no recipient (broadcast/undirected).
    pub recipient_id_hex: String,
    pub payload: Vec<u8>,
    pub has_signature: bool,
}

/// A decoded private chat message (the inner noiseEncrypted payload).
#[derive(uniffi::Record)]
pub struct MeshPrivateMessage {
    pub message_id: String,
    pub content: String,
}

/// A decoded public broadcast (BLE "Mesh" channel) message. The wire payload is
/// just the UTF-8 content (matching bitchat); the sender id + timestamp come from
/// the packet, and the display nickname is resolved from the sender's announce.
#[derive(uniffi::Record)]
pub struct MeshPublicMessage {
    pub content: String,
    pub sender_id_hex: String,
    pub timestamp_ms: u64,
}

fn parse_id8(hex_str: &str, what: &'static str) -> Result<[u8; 8], SonarFfiError> {
    let bytes = hex::decode(hex_str).map_err(invalid(what))?;
    if bytes.len() != 8 {
        return Err(SonarFfiError::InvalidInput(format!(
            "{what} must be 8 bytes"
        )));
    }
    let mut id = [0u8; 8];
    id.copy_from_slice(&bytes);
    Ok(id)
}

/// Ed25519 mesh signing public key (hex) for a 32-byte seed (hex).
#[uniffi::export]
pub fn mesh_signing_public_key(seed_hex: String) -> FfiResult<String> {
    let seed = hex::decode(&seed_hex).map_err(invalid("mesh seed"))?;
    if seed.len() != 32 {
        return Err(SonarFfiError::InvalidInput(
            "mesh seed must be 32 bytes".into(),
        ));
    }
    let mut s = [0u8; 32];
    s.copy_from_slice(&seed);
    Ok(hex::encode(mesh::MeshSigner::from_seed(&s).public_key()))
}

/// Build a signed identity announce as wire bytes (padded 0x01 packet).
#[uniffi::export]
pub fn mesh_build_announce(
    seed_hex: String,
    sender_id_hex: String,
    nickname: String,
    noise_public_key_hex: String,
    ttl: u8,
    timestamp_ms: u64,
) -> FfiResult<Vec<u8>> {
    let seed = hex::decode(&seed_hex).map_err(invalid("mesh seed"))?;
    if seed.len() != 32 {
        return Err(SonarFfiError::InvalidInput(
            "mesh seed must be 32 bytes".into(),
        ));
    }
    let mut s = [0u8; 32];
    s.copy_from_slice(&seed);
    let signer = mesh::MeshSigner::from_seed(&s);
    let sender = parse_id8(&sender_id_hex, "sender id")?;
    let noise_pub = hex::decode(&noise_public_key_hex).map_err(invalid("noise public key"))?;

    let announce = mesh::Announce {
        nickname,
        noise_public_key: noise_pub,
        signing_public_key: signer.public_key().to_vec(),
        direct_neighbors: None,
    };
    let mut packet = mesh::Packet::new(mesh::msg_type::ANNOUNCE, ttl, timestamp_ms, sender);
    packet.payload = announce
        .encode()
        .ok_or_else(|| SonarFfiError::Core("announce encode failed".into()))?;
    if !mesh::sign_packet(&mut packet, &signer) {
        return Err(SonarFfiError::Core("announce sign failed".into()));
    }
    packet
        .encode()
        .ok_or_else(|| SonarFfiError::Core("announce packet encode failed".into()))
}

/// Decode + verify an incoming announce packet. Returns the peer info only if
/// the Ed25519 signature checks against the signing key carried in the announce
/// (== iOS `verifyPacketSignature`). Returns None for non-announce/invalid.
#[uniffi::export]
pub fn mesh_parse_announce(packet_bytes: Vec<u8>) -> Option<MeshAnnounceInfo> {
    let packet = mesh::Packet::decode(&packet_bytes)?;
    if packet.type_ != mesh::msg_type::ANNOUNCE {
        return None;
    }
    let announce = mesh::Announce::decode(&packet.payload)?;
    if !mesh::verify_packet(&packet, &announce.signing_public_key) {
        return None;
    }
    Some(MeshAnnounceInfo {
        nickname: announce.nickname,
        noise_public_key_hex: hex::encode(&announce.noise_public_key),
        signing_public_key_hex: hex::encode(&announce.signing_public_key),
        sender_id_hex: hex::encode(packet.sender_id),
    })
}

/// Decode the outer fields of any mesh packet.
#[uniffi::export]
pub fn mesh_decode_packet(packet_bytes: Vec<u8>) -> Option<MeshPacketInfo> {
    let p = mesh::Packet::decode(&packet_bytes)?;
    Some(MeshPacketInfo {
        packet_type: p.type_,
        ttl: p.ttl,
        sender_id_hex: hex::encode(p.sender_id),
        recipient_id_hex: p.recipient_id.map(hex::encode).unwrap_or_default(),
        payload: p.payload,
        has_signature: p.signature.is_some(),
    })
}

/// Build a directed packet of `packet_type` (e.g. 0x10 handshake / 0x11
/// encrypted). An empty `recipient_id_hex` makes it undirected.
#[uniffi::export]
pub fn mesh_build_packet(
    packet_type: u8,
    sender_id_hex: String,
    recipient_id_hex: String,
    ttl: u8,
    timestamp_ms: u64,
    payload: Vec<u8>,
) -> FfiResult<Vec<u8>> {
    let sender = parse_id8(&sender_id_hex, "sender id")?;
    let mut packet = mesh::Packet::new(packet_type, ttl, timestamp_ms, sender);
    if !recipient_id_hex.is_empty() {
        packet.recipient_id = Some(parse_id8(&recipient_id_hex, "recipient id")?);
    }
    packet.payload = payload;
    packet
        .encode()
        .ok_or_else(|| SonarFfiError::Core("packet encode failed".into()))
}

/// Build a packet SIGNED with the Ed25519 announce key (`seed_hex`), the same way
/// `mesh_build_announce` signs — for packet types that bitchat verifies against
/// the peer's signing key. Required for the Sonar Discovery announce (0x53):
/// iOS `handleSonarAnnounce` drops it unless `packet.signature` verifies against
/// the signing key from the peer's bitchat announce. Plain `mesh_build_packet`
/// leaves it unsigned, so the 0x53 was silently rejected (no npub exchange).
#[uniffi::export]
pub fn mesh_build_signed_packet(
    seed_hex: String,
    packet_type: u8,
    sender_id_hex: String,
    recipient_id_hex: String,
    ttl: u8,
    timestamp_ms: u64,
    payload: Vec<u8>,
) -> FfiResult<Vec<u8>> {
    let seed = hex::decode(&seed_hex).map_err(invalid("mesh seed"))?;
    if seed.len() != 32 {
        return Err(SonarFfiError::InvalidInput(
            "mesh seed must be 32 bytes".into(),
        ));
    }
    let mut s = [0u8; 32];
    s.copy_from_slice(&seed);
    let signer = mesh::MeshSigner::from_seed(&s);
    let sender = parse_id8(&sender_id_hex, "sender id")?;
    let mut packet = mesh::Packet::new(packet_type, ttl, timestamp_ms, sender);
    if !recipient_id_hex.is_empty() {
        packet.recipient_id = Some(parse_id8(&recipient_id_hex, "recipient id")?);
    }
    packet.payload = payload;
    if !mesh::sign_packet(&mut packet, &signer) {
        return Err(SonarFfiError::Core("signed packet sign failed".into()));
    }
    packet
        .encode()
        .ok_or_else(|| SonarFfiError::Core("signed packet encode failed".into()))
}

/// The inner noiseEncrypted plaintext for a private message: `[0x01][TLV]`.
#[uniffi::export]
pub fn mesh_encode_private_message(message_id: String, content: String) -> FfiResult<Vec<u8>> {
    let pm = mesh::PrivateMessage {
        message_id,
        content,
    };
    mesh::encode_private_message_plaintext(&pm)
        .ok_or_else(|| SonarFfiError::Core("private message encode failed".into()))
}

/// Parse a decrypted noiseEncrypted plaintext as a private message. Returns None
/// unless the leading type byte is privateMessage (0x01) and the TLV is valid.
#[uniffi::export]
pub fn mesh_decode_private_message(plaintext: Vec<u8>) -> Option<MeshPrivateMessage> {
    let (t, rest) = mesh::split_noise_plaintext(&plaintext)?;
    if t != mesh::noise_payload::PRIVATE_MESSAGE {
        return None;
    }
    let pm = mesh::PrivateMessage::decode(rest)?;
    Some(MeshPrivateMessage {
        message_id: pm.message_id,
        content: pm.content,
    })
}

/// Build a SIGNED public broadcast message packet (type 0x02, recipient
/// 0xFF*8) carrying a `BitchatMessage` payload — the BLE "Mesh" channel.
/// Wire-compatible with iOS public messages.
#[uniffi::export]
pub fn mesh_build_public_message(
    seed_hex: String,
    sender_id_hex: String,
    content: String,
    ttl: u8,
    timestamp_ms: u64,
) -> FfiResult<Vec<u8>> {
    let seed = hex::decode(&seed_hex).map_err(invalid("mesh seed"))?;
    if seed.len() != 32 {
        return Err(SonarFfiError::InvalidInput(
            "mesh seed must be 32 bytes".into(),
        ));
    }
    let mut s = [0u8; 32];
    s.copy_from_slice(&seed);
    let signer = mesh::MeshSigner::from_seed(&s);
    let sender = parse_id8(&sender_id_hex, "sender id")?;
    // bitchat public message: payload IS the raw UTF-8 content; recipientID = nil;
    // signed. Sender + timestamp live in the packet header.
    let mut packet = mesh::Packet::new(mesh::msg_type::MESSAGE, ttl, timestamp_ms, sender);
    packet.payload = content.into_bytes();
    if !mesh::sign_packet(&mut packet, &signer) {
        return Err(SonarFfiError::Core("public message sign failed".into()));
    }
    packet
        .encode()
        .ok_or_else(|| SonarFfiError::Core("public message packet encode failed".into()))
}

/// Parse an incoming type-0x02 packet as a public broadcast message — payload is
/// the raw UTF-8 content. Returns None for other types / non-UTF-8 input.
#[uniffi::export]
pub fn mesh_parse_public_message(packet_bytes: Vec<u8>) -> Option<MeshPublicMessage> {
    let packet = mesh::Packet::decode(&packet_bytes)?;
    if packet.type_ != mesh::msg_type::MESSAGE {
        return None;
    }
    let content = String::from_utf8(packet.payload).ok()?;
    Some(MeshPublicMessage {
        content,
        sender_id_hex: hex::encode(packet.sender_id),
        timestamp_ms: packet.timestamp,
    })
}

fn geo_message_info(m: sonar_core::geohash::GeoMessage) -> GeoMessageInfo {
    GeoMessageInfo {
        id_hex: m.id,
        sender_pubkey_hex: m.sender_pubkey,
        nickname: m.nickname,
        content: m.content,
        created_at_secs: m.created_at,
        mine: m.mine,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_roundtrip() {
        let id = SonarIdentity::generate();
        assert!(id.npub().starts_with("npub1"));
        assert!(id.nsec().starts_with("nsec1"));
        assert_eq!(id.pubkey_hex().len(), 64);

        let again = SonarIdentity::import(id.nsec()).unwrap();
        assert_eq!(id.pubkey_hex(), again.pubkey_hex());
        assert!(SonarIdentity::import("garbage".into()).is_err());
    }

    #[test]
    fn group_id_hex_roundtrips() {
        let gid = GroupId::from_slice(&[7u8; 32]);
        let hex_id = hex::encode(gid.as_slice());
        assert_eq!(parse_group_id(&hex_id).unwrap(), gid);
        assert!(parse_group_id("zz").is_err());
    }

    #[test]
    fn connect_rejects_bad_input() {
        let id = SonarIdentity::generate();
        let key = "00".repeat(32);
        let db = "/tmp/sonar-ffi-test-unused.sqlite".to_string();
        // empty relays
        assert!(matches!(
            SonarNode::connect(id.clone(), vec![], db.clone(), key.clone()),
            Err(SonarFfiError::InvalidInput(_))
        ));
        // bad relay url
        assert!(matches!(
            SonarNode::connect(
                id.clone(),
                vec!["not-a-url".into()],
                db.clone(),
                key.clone()
            ),
            Err(SonarFfiError::InvalidInput(_))
        ));
        // bad db key (wrong length)
        assert!(matches!(
            SonarNode::connect(
                id.clone(),
                vec!["wss://relay.example".into()],
                db.clone(),
                "abcd".into()
            ),
            Err(SonarFfiError::InvalidInput(_))
        ));
        // empty db path
        assert!(matches!(
            SonarNode::connect(id, vec!["wss://relay.example".into()], String::new(), key),
            Err(SonarFfiError::InvalidInput(_))
        ));
    }

    #[test]
    fn wipe_missing_db_is_ok() {
        // Idempotent: wiping a non-existent path succeeds.
        assert!(wipe_marmot_database("/tmp/sonar-ffi-does-not-exist.sqlite".into()).is_ok());
    }
}
