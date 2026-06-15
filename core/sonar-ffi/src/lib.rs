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
        let inner = Identity::import(&nsec).map_err(|e| SonarFfiError::InvalidInput(e.to_string()))?;
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
            })
            .collect())
    }

    /// Publish a public message to a geohash channel (kind-20000 over Nostr).
    pub fn send_geohash(&self, geohash: String, text: String, nickname: String) -> FfiResult<()> {
        self.runtime
            .block_on(self.client.send_geohash(&geohash, &text, &nickname))?;
        Ok(())
    }

    /// Fetch recent messages for a geohash channel, oldest first.
    pub fn geohash_messages(
        &self,
        geohash: String,
        limit: u32,
    ) -> FfiResult<Vec<GeoMessageInfo>> {
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
    pub fn send_geo_dm(&self, geohash: String, recipient_hex: String, text: String) -> FfiResult<()> {
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
            SonarNode::connect(id.clone(), vec!["not-a-url".into()], db.clone(), key.clone()),
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
