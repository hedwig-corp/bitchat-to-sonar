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

// Android-only JNI shim that initializes `ndk_context` (JavaVM + app Context) so
// iroh's DNS read on `Endpoint::bind()` and cpal/oboe audio work when this `.so`
// is loaded by UniFFI's JNA bindings (no JNI_OnLoad fires under JNA).
#[cfg(target_os = "android")]
mod android_jni;

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

/// Forwards conversation-change notifications from core threads to the FFI
/// callback on a dedicated thread via an `mpsc` channel.  The host-provided
/// `Box<dyn ConversationChangeListener>` never leaves that single thread, so
/// no `Send + Sync` bound on the box is required — eliminating the previous
/// `unsafe impl`.
struct ChannelChangeListener {
    tx: std::sync::Mutex<std::sync::mpsc::Sender<String>>,
}

impl sonar_core::conversation_index::ConversationChangeListener for ChannelChangeListener {
    fn on_conversation_changed(&self, group_id_hex: String) {
        let _ = self.tx.lock().expect("conversation change tx not poisoned").send(group_id_hex);
    }
}

fn invalid<E: std::fmt::Display>(what: &str) -> impl FnOnce(E) -> SonarFfiError + '_ {
    move |e| SonarFfiError::InvalidInput(format!("{what}: {e}"))
}

fn parse_group_id(hex_id: &str) -> FfiResult<GroupId> {
    let bytes = hex::decode(hex_id).map_err(invalid("group id"))?;
    Ok(GroupId::from_slice(&bytes))
}

fn parse_event_id(hex_id: &str) -> FfiResult<EventId> {
    EventId::from_hex(hex_id).map_err(invalid("event id"))
}

fn parse_pubkeys(pubkeys: Vec<String>, label: &str) -> FfiResult<Vec<PublicKey>> {
    pubkeys
        .into_iter()
        .map(|pk| PublicKey::parse(&pk).map_err(invalid(label)))
        .collect()
}

/// Parse a 64-char hex string into the 32-byte SQLCipher key.
fn parse_db_key(db_key_hex: &str) -> FfiResult<[u8; 32]> {
    let bytes = hex::decode(db_key_hex).map_err(invalid("db key hex"))?;
    bytes.try_into().map_err(|_| {
        SonarFfiError::InvalidInput("db key must be exactly 32 bytes (64 hex chars)".into())
    })
}

/// Erase the persistent Marmot database at `db_path`, its SQLite sidecars
/// (`-wal`, `-shm`, `-journal`), and the conversation-index sidecar database.
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

/// FFI-friendly pending group invite summary.
#[derive(uniffi::Record)]
pub struct GroupInviteInfo {
    /// Hex of the kind-444 welcome event id. Pass to accept/decline methods.
    pub id_hex: String,
    pub wrapper_id_hex: String,
    pub group_id_hex: String,
    pub group_name: String,
    pub group_description: String,
    pub welcomer_npub: String,
    pub member_count: u32,
    pub relay_urls: Vec<String>,
}

#[derive(uniffi::Record)]
pub struct JoinRequestInfo {
    pub requester_npub: String,
    pub group_id_hex: String,
    pub received_at: u64,
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
    /// Local delivery state: received, pending, sent, or failed.
    pub delivery_state: String,
    /// Encrypted media attachments (Marmot MIP-04), empty for a plain text message.
    pub media: Vec<MediaInfo>,
    /// Sticker reference if this message is a sticker send (nil for text/media).
    pub sticker_ref: Option<StickerRefInfo>,
}

/// FFI-friendly sticker reference carried on a chat message.
#[derive(uniffi::Record)]
pub struct StickerRefInfo {
    pub pack_coordinate: String,
    pub shortcode: String,
    pub plaintext_sha256: String,
}

/// FFI-friendly single sticker inside a pack.
#[derive(uniffi::Record)]
pub struct StickerInfo {
    pub shortcode: String,
    pub url: String,
    pub sha256: String,
    pub mime: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub alt: Option<String>,
    pub emoji: Option<String>,
}

/// FFI-friendly sticker pack fetched from relays.
#[derive(uniffi::Record)]
pub struct StickerPackInfo {
    pub pack_coordinate: String,
    pub title: String,
    pub description: Option<String>,
    pub cover_url: Option<String>,
    pub stickers: Vec<StickerInfo>,
}

/// FFI-friendly transcript window for one recent group.
#[derive(uniffi::Record)]
pub struct RecentMessagePageInfo {
    pub group_id_hex: String,
    /// Newest message timestamp in this page, for stable chat-list ordering.
    pub latest_created_at_secs: u64,
    /// Oldest first within the bounded page.
    pub messages: Vec<MessageInfo>,
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

/// FFI-friendly Sonar app descriptor published as a NIP-78-style kind-30078
/// event. This is public capability metadata only; live call addresses are
/// exchanged inside encrypted ☎CALL signaling.
#[derive(uniffi::Record)]
pub struct SonarDescriptorInfo {
    pub schema: u32,
    pub calls: bool,
    pub media: Vec<String>,
    pub signaling: Vec<String>,
    pub transports: Vec<String>,
    pub call_identity: String,
    pub bolt12_offer: Option<String>,
    pub payment_receipts: Vec<String>,
    pub published_at_secs: u64,
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

/// Callback interface for conversation-summary changes. The host implements
/// this to receive push notifications when a chat's summary row is updated
/// (message sent/received, group created/deleted, unread count changed).
#[uniffi::export(callback_interface)]
pub trait ConversationChangeListener: Send + Sync {
    fn on_conversation_changed(&self, group_id_hex: String);
}

/// FFI-friendly conversation summary from the core-owned index.
#[derive(uniffi::Record)]
pub struct ConversationSummaryInfo {
    pub group_id_hex: String,
    pub name: String,
    pub latest_content: String,
    pub latest_sender_npub: String,
    pub latest_at_secs: u64,
    pub latest_mine: bool,
    pub message_count: u64,
    pub unread_count: u64,
}

/// A relay-connected Sonar node. Owns its own tokio runtime; every method is
/// blocking — call from a background queue in Swift, never the main thread.
#[derive(uniffi::Object)]
pub struct SonarNode {
    runtime: tokio::runtime::Runtime,
    client: SonarClient,
    /// Lazily-started P2P call engine (iroh + cpal/opus). Cloned out under a short
    /// lock so a long `call_wait_event` park never blocks `call_hangup` etc.
    #[cfg(feature = "calls-audio")]
    call: Mutex<Option<Arc<sonar_core::call::engine::CallEngine>>>,
}

#[uniffi::export]
impl SonarNode {
    /// Connect `identity` to the given relays (e.g. `wss://relay.damus.io`) with
    /// a persistent, encrypted SQLCipher store. Passing an empty relay list opens
    /// the local encrypted DB only; hosts use that for Signal-style first paint
    /// before they attach network relays in the background.
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
        Ok(Arc::new(Self {
            runtime,
            client,
            #[cfg(feature = "calls-audio")]
            call: Mutex::new(None),
        }))
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

    /// Publish this identity's public Sonar descriptor. `signaling` should list
    /// only routes this app build can actually use, in preference order.
    pub fn publish_sonar_descriptor(
        &self,
        calls_enabled: bool,
        signaling: Vec<String>,
        bolt12_offer: Option<String>,
    ) -> FfiResult<()> {
        self.runtime.block_on(self.client.publish_sonar_descriptor(
            calls_enabled,
            signaling,
            bolt12_offer,
        ))?;
        Ok(())
    }

    /// Fetch a peer's Sonar descriptor (npub or hex pubkey). `None` means the
    /// peer is not confirmed Sonar-capable through this relay set.
    pub fn fetch_sonar_descriptor(&self, npub: String) -> FfiResult<Option<SonarDescriptorInfo>> {
        let pubkey = PublicKey::parse(&npub).map_err(invalid("descriptor pubkey"))?;
        let descriptor = self
            .runtime
            .block_on(self.client.fetch_sonar_descriptor(pubkey))?;
        Ok(descriptor.map(|d| SonarDescriptorInfo {
            schema: d.schema as u32,
            calls: d.calls,
            media: d.media,
            signaling: d.signaling,
            transports: d.transports,
            call_identity: d.call_identity,
            bolt12_offer: d.bolt12_offer,
            payment_receipts: d.payment_receipts,
            published_at_secs: d.published_at_secs,
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

    /// Start a multi-member Marmot group. `members` accepts npub or hex pubkeys.
    pub fn start_group(&self, members: Vec<String>, name: String) -> FfiResult<String> {
        let members = parse_pubkeys(members, "member pubkey")?;
        let group_id = self
            .runtime
            .block_on(self.client.start_group(members, &name))?;
        Ok(hex::encode(group_id.as_slice()))
    }

    /// Add members to an existing group.
    pub fn add_group_members(&self, group_id_hex: String, members: Vec<String>) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        let members = parse_pubkeys(members, "member pubkey")?;
        self.runtime
            .block_on(self.client.add_group_members(&group_id, members))?;
        Ok(())
    }

    /// Remove members from an existing group.
    pub fn remove_group_members(
        &self,
        group_id_hex: String,
        members: Vec<String>,
    ) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        let members = parse_pubkeys(members, "member pubkey")?;
        self.runtime
            .block_on(self.client.remove_group_members(&group_id, members))?;
        Ok(())
    }

    /// Leave a group and delete its local state after the leave proposal is sent.
    pub fn leave_group(&self, group_id_hex: String) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        self.runtime.block_on(self.client.leave_group(&group_id))?;
        Ok(())
    }

    /// Pending multi-member group invites awaiting accept/decline.
    pub fn pending_group_invites(&self) -> FfiResult<Vec<GroupInviteInfo>> {
        Ok(self
            .client
            .pending_group_invites()?
            .into_iter()
            .map(|invite| GroupInviteInfo {
                id_hex: invite.id.to_hex(),
                wrapper_id_hex: invite.wrapper_id.to_hex(),
                group_id_hex: hex::encode(invite.group_id.as_slice()),
                group_name: invite.group_name,
                group_description: invite.group_description,
                welcomer_npub: invite
                    .welcomer
                    .to_bech32()
                    .expect("npub encoding cannot fail"),
                member_count: invite.member_count,
                relay_urls: invite
                    .relays
                    .into_iter()
                    .map(|relay| relay.to_string())
                    .collect(),
            })
            .collect())
    }

    /// Accept a pending group invite by welcome event id.
    pub fn accept_group_invite(&self, invite_id_hex: String) -> FfiResult<String> {
        let invite_id = parse_event_id(&invite_id_hex)?;
        let group_id = self
            .runtime
            .block_on(self.client.accept_group_invite(&invite_id))?;
        Ok(hex::encode(group_id.as_slice()))
    }

    /// Decline a pending group invite by welcome event id.
    pub fn decline_group_invite(&self, invite_id_hex: String) -> FfiResult<()> {
        let invite_id = parse_event_id(&invite_id_hex)?;
        self.client.decline_group_invite(&invite_id)?;
        Ok(())
    }

    // ── Invite links ──────────────────────────────────────────────────

    pub fn create_invite_link(
        &self,
        group_id_hex: String,
        group_name: String,
    ) -> FfiResult<String> {
        let group_id = parse_group_id(&group_id_hex)?;
        Ok(self.client.create_invite_link(&group_id, &group_name)?)
    }

    pub fn pending_join_requests(&self, group_id_hex: String) -> FfiResult<Vec<JoinRequestInfo>> {
        let group_id = parse_group_id(&group_id_hex)?;
        Ok(self
            .client
            .pending_join_requests(&group_id)
            .into_iter()
            .map(|r| JoinRequestInfo {
                requester_npub: r.requester.to_bech32().expect("npub encoding cannot fail"),
                group_id_hex: hex::encode(r.group_id.as_slice()),
                received_at: r.received_at,
            })
            .collect())
    }

    pub fn approve_join_request(
        &self,
        group_id_hex: String,
        requester_npub: String,
    ) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        let requester = PublicKey::parse(&requester_npub).map_err(invalid("requester npub"))?;
        self.runtime
            .block_on(self.client.approve_join_request(&group_id, &requester))?;
        Ok(())
    }

    pub fn decline_join_request(
        &self,
        group_id_hex: String,
        requester_npub: String,
    ) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        let requester = PublicKey::parse(&requester_npub).map_err(invalid("requester npub"))?;
        self.client.decline_join_request(&group_id, &requester)?;
        Ok(())
    }

    pub fn request_join_via_link(&self, invite_token: String) -> FfiResult<()> {
        self.runtime
            .block_on(self.client.request_join_via_link(&invite_token))?;
        Ok(())
    }

    /// Encrypt + publish a text message to the group.
    pub fn send_text(&self, group_id_hex: String, text: String) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        self.runtime
            .block_on(self.client.send_text(&group_id, &text))?;
        Ok(())
    }

    /// Encrypt + publish a sticker message to the group.
    pub fn send_sticker(
        &self,
        group_id_hex: String,
        pack_coordinate: String,
        shortcode: String,
        plaintext_sha256: String,
    ) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        let pack = sonar_stickers::PackAddress::parse(&pack_coordinate)
            .map_err(|e| SonarFfiError::InvalidInput(format!("bad pack coordinate: {e}")))?;
        let sticker_ref = sonar_stickers::StickerRef::new(pack, shortcode, plaintext_sha256)
            .map_err(|e| SonarFfiError::InvalidInput(format!("bad sticker ref: {e}")))?;
        self.runtime
            .block_on(self.client.send_sticker(&group_id, &sticker_ref))?;
        Ok(())
    }

    /// Fetch a sticker pack from relays by its pack address.
    pub fn fetch_sticker_pack(
        &self,
        author_pubkey_hex: String,
        identifier: String,
        relay_urls: Vec<String>,
    ) -> FfiResult<StickerPackInfo> {
        let pack = self.runtime.block_on(self.client.fetch_sticker_pack(
            &author_pubkey_hex,
            &identifier,
            &relay_urls,
        ))?;
        Ok(sticker_pack_info(pack))
    }

    /// Download a public sticker image by its plaintext HTTPS URL and verify
    /// the bytes match the sticker ref / pack hash before returning them.
    pub fn fetch_sticker_image(&self, url: String, expected_sha256: String) -> FfiResult<Vec<u8>> {
        if !url.starts_with("https://") {
            return Err(SonarFfiError::InvalidInput(
                "sticker URL must be HTTPS".into(),
            ));
        }
        let expected_sha256 = expected_sha256.to_ascii_lowercase();
        sonar_stickers::validate_sha256_hex(&expected_sha256)
            .map_err(|e| SonarFfiError::InvalidInput(format!("bad sticker sha256: {e}")))?;
        let bytes = self
            .runtime
            .block_on(sonar_core::client::http_get_public(&url))?;
        let actual_sha256 = sonar_stickers::sha256_hex(&bytes);
        if actual_sha256 != expected_sha256 {
            return Err(SonarFfiError::InvalidInput(format!(
                "sticker image sha256 mismatch: expected {expected_sha256}, got {actual_sha256}"
            )));
        }
        Ok(bytes)
    }

    pub fn fetch_installed_packs(&self) -> FfiResult<Vec<String>> {
        let packs = self.runtime.block_on(self.client.fetch_installed_packs())?;
        Ok(packs.iter().map(|p| p.coordinate()).collect())
    }

    pub fn install_sticker_pack(&self, coordinate: String) -> FfiResult<()> {
        self.runtime
            .block_on(self.client.install_sticker_pack(&coordinate))?;
        Ok(())
    }

    pub fn uninstall_sticker_pack(&self, coordinate: String) -> FfiResult<()> {
        self.runtime
            .block_on(self.client.uninstall_sticker_pack(&coordinate))?;
        Ok(())
    }

    /// Delete a single chat's local Marmot state (messages + MLS keys). Local-
    /// only — the peer is NOT notified. Idempotent (deleting an unknown group is
    /// a no-op). Used by per-chat "delete this conversation".
    pub fn delete_group(&self, group_id_hex: String) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        self.runtime.block_on(self.client.delete_group(&group_id))?;
        Ok(())
    }

    /// Poll the relays once: welcomes addressed to us, then group messages.
    pub fn sync_once(&self) -> FfiResult<()> {
        self.runtime.block_on(self.client.sync())?;
        Ok(())
    }

    /// Reload the durable outbox sidecar and retry pending sends. Hosts call this
    /// after replacing a local-only node with a relay-backed node so sends created
    /// during relay connect are not stranded until app restart.
    pub fn retry_outbox(&self) -> FfiResult<()> {
        self.runtime.block_on(self.client.reload_outbox_and_retry());
        Ok(())
    }

    /// Block until a live Marmot event (welcome or group message) has been pushed
    /// by the relay subscriptions, or `timeout_secs` elapses. Returns true if
    /// there is something to drain. Touches NO MLS state, so the host may call it
    /// OFF its serialized engine queue (a parked "wait for push", not a poll).
    pub fn wait_for_marmot_event(&self, timeout_secs: u64) -> bool {
        self.runtime
            .block_on(self.client.wait_for_marmot_event(timeout_secs))
    }

    /// Process buffered live Marmot events through the MLS engine. Returns true if
    /// anything was drained. MUST run on the host's serialized engine queue.
    pub fn drain_pending_marmot(&self) -> FfiResult<bool> {
        Ok(self.runtime.block_on(self.client.drain_pending_marmot())?)
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
        Ok(msgs.into_iter().map(message_info).collect())
    }

    /// Bounded local chat-message window for a group, oldest first within the
    /// page. `offset` counts chat messages in newest-first order; non-chat MDK
    /// rows such as commits/proposals are skipped by the core.
    pub fn messages_page(
        &self,
        group_id_hex: String,
        limit: u32,
        offset: u32,
    ) -> FfiResult<Vec<MessageInfo>> {
        let group_id = parse_group_id(&group_id_hex)?;
        if limit == 0 {
            return Err(SonarFfiError::InvalidInput(
                "messages_page limit must be greater than zero".into(),
            ));
        }
        let mut msgs = self
            .client
            .messages_page(&group_id, limit as usize, offset as usize)?;
        msgs.sort_by_key(|m| m.created_at);
        Ok(msgs.into_iter().map(message_info).collect())
    }

    /// Bounded local transcript windows for the most recent groups, newest
    /// conversation first. Used by chat-list hydration so first paint is local
    /// DB only and does not wait on relay sync or full-history scans.
    pub fn recent_message_pages(
        &self,
        group_limit: u32,
        page_limit: u32,
    ) -> FfiResult<Vec<RecentMessagePageInfo>> {
        if group_limit == 0 || page_limit == 0 {
            return Ok(Vec::new());
        }
        self.client
            .recent_message_pages(group_limit as usize, page_limit as usize)?
            .into_iter()
            .map(|page| {
                let mut messages = page.messages;
                messages.sort_by_key(|m| m.created_at);
                Ok(RecentMessagePageInfo {
                    group_id_hex: hex::encode(page.group_id.as_slice()),
                    latest_created_at_secs: page.latest_created_at.as_secs(),
                    messages: messages.into_iter().map(message_info).collect(),
                })
            })
            .collect()
    }

    // ── Conversation index (Signal-style summary table) ──────────────────

    pub fn set_conversation_change_listener(&self, listener: Box<dyn ConversationChangeListener>) {
        let (tx, rx) = std::sync::mpsc::channel::<String>();
        std::thread::Builder::new()
            .name("sonar-change-fwd".into())
            .spawn(move || {
                while let Ok(group_id_hex) = rx.recv() {
                    listener.on_conversation_changed(group_id_hex);
                }
            })
            .expect("spawn change-listener forwarder");
        let core_listener: Arc<dyn sonar_core::conversation_index::ConversationChangeListener> =
            Arc::new(ChannelChangeListener {
                tx: std::sync::Mutex::new(tx),
            });
        self.client
            .set_conversation_change_listener(Some(core_listener));
    }

    pub fn clear_conversation_change_listener(&self) {
        self.client.set_conversation_change_listener(None);
    }

    pub fn conversation_summaries(&self) -> Vec<ConversationSummaryInfo> {
        self.client
            .conversation_summaries()
            .into_iter()
            .map(|s| ConversationSummaryInfo {
                group_id_hex: s.group_id_hex,
                name: s.name,
                latest_content: s.latest_content,
                latest_sender_npub: s.latest_sender,
                latest_at_secs: s.latest_at_secs,
                latest_mine: s.latest_mine,
                message_count: s.message_count,
                unread_count: s.unread_count,
            })
            .collect()
    }

    pub fn mark_conversation_read(&self, group_id_hex: String) {
        self.client.mark_conversation_read(&group_id_hex);
    }

    pub fn messages_cursor_page(
        &self,
        group_id_hex: String,
        before_secs: Option<u64>,
        before_id_hex: Option<String>,
        limit: u32,
    ) -> FfiResult<Vec<MessageInfo>> {
        let group_id = parse_group_id(&group_id_hex)?;
        let before_id = before_id_hex
            .as_deref()
            .map(EventId::from_hex)
            .transpose()
            .map_err(invalid("cursor event id"))?;
        let msgs = self.client.messages_cursor_page(
            &group_id,
            before_secs,
            before_id.as_ref(),
            limit as usize,
        )?;
        Ok(msgs.into_iter().map(message_info).collect())
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

// ── P2P voice calls (iroh transport + cpal/opus media) ──────────────────────
//
// The CallEngine is started lazily (`call_start`) and stored in the SonarNode.
// The engine never sends ☎CALL lines itself: the host serializes OFFER/ANSWER/
// END (built via the `call_encode_*` helpers, carrying `call_local_address`)
// over the existing Marmot/NIP-17 transports and feeds inbound control lines
// (parsed via `call_parse_control`) back in. All call methods are BLOCKING like
// the rest of SonarNode; the host polls `call_wait_event` on a dedicated thread.

/// Public call state for the host UI (mirrors `sonar_core::call::engine::CallStateKind`).
#[cfg(feature = "calls-audio")]
#[derive(uniffi::Enum)]
pub enum CallStateInfo {
    Ringing,
    Connecting,
    Connected,
    Ended,
    Failed,
    Declined,
    Busy,
    Missed,
}

#[cfg(feature = "calls-audio")]
impl From<sonar_core::call::engine::CallStateKind> for CallStateInfo {
    fn from(s: sonar_core::call::engine::CallStateKind) -> Self {
        use sonar_core::call::engine::CallStateKind as K;
        match s {
            K::Ringing => Self::Ringing,
            K::Connecting => Self::Connecting,
            K::Connected => Self::Connected,
            K::Ended => Self::Ended,
            K::Failed => Self::Failed,
            K::Declined => Self::Declined,
            K::Busy => Self::Busy,
            K::Missed => Self::Missed,
        }
    }
}

/// A call state change drained by `call_wait_event`.
#[cfg(feature = "calls-audio")]
#[derive(uniffi::Record)]
pub struct CallEventInfo {
    pub call_id: String,
    pub state: CallStateInfo,
    /// Connected duration in seconds — only meaningful for `Ended`.
    pub duration_secs: u64,
    /// Human reason for `Ended`/`Failed`/`Declined`/`Busy` (else empty).
    pub reason: String,
}

/// The answerer's verdict on an incoming offer (mirrors `signaling::AnswerKind`).
#[cfg(feature = "calls-audio")]
#[derive(uniffi::Enum)]
pub enum CallAnswerKind {
    Accept,
    Decline,
    Busy,
}

#[cfg(feature = "calls-audio")]
impl From<CallAnswerKind> for sonar_core::call::signaling::AnswerKind {
    fn from(a: CallAnswerKind) -> Self {
        use sonar_core::call::signaling::AnswerKind as A;
        match a {
            CallAnswerKind::Accept => A::Accept,
            CallAnswerKind::Decline => A::Decline,
            CallAnswerKind::Busy => A::Busy,
        }
    }
}

#[cfg(feature = "calls-audio")]
impl From<sonar_core::call::signaling::AnswerKind> for CallAnswerKind {
    fn from(a: sonar_core::call::signaling::AnswerKind) -> Self {
        use sonar_core::call::signaling::AnswerKind as A;
        match a {
            A::Accept => Self::Accept,
            A::Decline => Self::Decline,
            A::Busy => Self::Busy,
        }
    }
}

/// A parsed inbound `☎CALL` control line (the host scan loop feeds raw message
/// content to `call_parse_control` and routes the result to the call engine).
#[cfg(feature = "calls-audio")]
#[derive(uniffi::Enum)]
pub enum CallControlInfo {
    Offer {
        call_id: String,
        video: bool,
        node_addr_b64: String,
        unix_secs: u64,
    },
    Answer {
        call_id: String,
        answer: CallAnswerKind,
        node_addr_b64: String,
    },
    Cancel {
        call_id: String,
    },
    End {
        call_id: String,
        reason: String,
    },
}

#[cfg(feature = "calls-audio")]
fn media_kind(video: bool) -> sonar_core::call::signaling::CallMediaKind {
    use sonar_core::call::signaling::CallMediaKind as M;
    if video {
        M::Video
    } else {
        M::Voice
    }
}

#[cfg(feature = "calls-audio")]
#[uniffi::export]
impl SonarNode {
    /// Bind the iroh call endpoint once for this session. The iroh Ed25519 key is
    /// derived IN-CORE from this node's Nostr secret (HKDF, `call::identity`), so
    /// the host passes nothing and never reimplements the derivation; the NodeId
    /// is stable across launches. Idempotent-ish: a second call rebinds.
    pub fn call_start(&self) -> FfiResult<()> {
        // Idempotent: bind the iroh endpoint ONCE per session. A second
        // CallEngine::start binds a fresh endpoint (presets::N0 → a network
        // round-trip that can block) AND drops the active engine — which made a
        // call placed after boot's ensureCallStarted "take forever".
        if self.call.lock().expect("call engine lock not poisoned").is_some() {
            return Ok(());
        }
        let nostr_secret = self.client.identity().keys().secret_key().to_secret_bytes();
        let iroh_secret = sonar_core::call::identity::derive_iroh_secret(&nostr_secret);
        let engine = self
            .runtime
            .block_on(sonar_core::call::engine::CallEngine::start(iroh_secret))
            .map_err(|e| SonarFfiError::Core(format!("call start: {e}")))?;
        *self.call.lock().expect("call engine lock not poisoned") = Some(Arc::new(engine));
        Ok(())
    }

    /// Our dialable address as the `nodeAddrB64` token to embed in an OFFER/ANSWER.
    pub fn call_local_address(&self) -> FfiResult<String> {
        self.call_engine()?
            .local_addr_b64()
            .map_err(|e| SonarFfiError::Core(format!("local address: {e}")))
    }

    /// Begin an OUTGOING call (offerer). Returns immediately (Ringing); the host
    /// then sends `call_encode_offer(call_id, video, call_local_address(), now)`.
    pub fn call_place(&self, call_id: String, video: bool) -> FfiResult<()> {
        self.call_engine()?
            .place(&call_id, media_kind(video))
            .map_err(|e| SonarFfiError::Core(format!("call place: {e}")))
    }

    /// Register an inbound OFFER the host parsed (`call_parse_control`).
    pub fn call_on_incoming_offer(
        &self,
        call_id: String,
        remote_addr_b64: String,
        video: bool,
    ) -> FfiResult<()> {
        self.call_engine()?
            .on_incoming_offer(&call_id, &remote_addr_b64, media_kind(video))
            .map_err(|e| SonarFfiError::Core(format!("incoming offer: {e}")))
    }

    /// The offerer received the peer's ANSWER (host-parsed). On accept this pins
    /// the answerer + goes Connecting (awaiting their dial); decline/busy ends it.
    pub fn call_on_answer(
        &self,
        call_id: String,
        answer: CallAnswerKind,
        remote_addr_b64: String,
    ) -> FfiResult<()> {
        self.call_engine()?
            .on_answer(&call_id, answer.into(), &remote_addr_b64)
            .map_err(|e| SonarFfiError::Core(format!("on answer: {e}")))
    }

    /// The user accepted an incoming call: we are the dialer. Dials the offerer
    /// and starts media. Blocks on the QUIC connect.
    pub fn call_accept(&self, call_id: String) -> FfiResult<()> {
        let engine = self.call_engine()?;
        self.runtime
            .block_on(engine.accept(&call_id))
            .map_err(|e| SonarFfiError::Core(format!("call accept: {e}")))
    }

    /// Hang up / cancel a call: tears down media + connection, emits `Ended`.
    pub fn call_hangup(&self, call_id: String) -> FfiResult<()> {
        self.call_engine()?
            .hangup(&call_id)
            .map_err(|e| SonarFfiError::Core(format!("call hangup: {e}")))
    }

    /// Toggle local microphone capture for an active or still-connecting call.
    /// The RTP session keeps sending timed silence frames while muted.
    pub fn call_set_muted(&self, call_id: String, muted: bool) -> FfiResult<()> {
        self.call_engine()?
            .set_muted(&call_id, muted)
            .map_err(|e| SonarFfiError::Core(format!("call mute: {e}")))
    }

    /// Park up to `timeout_secs` for the next call state change. The host loops
    /// this on a dedicated thread (like `wait_for_marmot_event`); it touches no
    /// MLS state. `None` on timeout.
    ///
    /// If the engine is not bound yet (`call_start` hasn't run, or it failed),
    /// we STILL park for the timeout instead of returning instantly — otherwise
    /// the host's `while { waitEvent(20) }` loop busy-spins (on iOS that loop is
    /// MainActor-isolated → the UI freezes). Mirrors `wait_for_marmot_event`,
    /// which also blocks the timeout when there is nothing yet to wait on.
    pub fn call_wait_event(&self, timeout_secs: u64) -> Option<CallEventInfo> {
        // Snapshot the engine under a SHORT lock: bind it to a `let` so the
        // guard drops at the `;`, never held across the block_on park below
        // (so a long wait can't block `call_hangup`/`call_start`).
        let engine = self.call.lock().expect("call engine lock not poisoned").clone();
        let Some(engine) = engine else {
            // No engine: park the node's runtime for the (capped) timeout, then
            // report "nothing happened". `.max(1)` floors a 0 timeout so we can
            // never spin; capping at 30s bounds a bogus/hostile huge value.
            let secs = timeout_secs.clamp(1, 30);
            self.runtime.block_on(async move {
                tokio::time::sleep(std::time::Duration::from_secs(secs)).await;
            });
            return None;
        };
        // Engine present: `next_event` already honors the timeout internally
        // (tokio::time::timeout over an mpsc recv → None on elapse).
        let ev = self.runtime.block_on(engine.next_event(timeout_secs))?;
        Some(CallEventInfo {
            call_id: ev.call_id,
            state: ev.state.into(),
            duration_secs: ev.duration_secs,
            reason: ev.reason,
        })
    }
}

#[cfg(feature = "calls-audio")]
impl SonarNode {
    /// Clone the started engine out under a short lock (so a parked
    /// `call_wait_event` never blocks another call method).
    fn call_engine(&self) -> FfiResult<Arc<sonar_core::call::engine::CallEngine>> {
        self.call
            .lock()
            .expect("call engine lock not poisoned")
            .clone()
            .ok_or_else(|| SonarFfiError::Core("call engine not started (call_start first)".into()))
    }
}

// ── Pure ☎CALL signaling codec (no iroh; shared by both apps) ──

/// Encode an OFFER control line to send as encrypted message content.
#[cfg(feature = "calls-audio")]
#[uniffi::export]
pub fn call_encode_offer(
    call_id: String,
    video: bool,
    node_addr_b64: String,
    unix_secs: u64,
) -> String {
    sonar_core::call::signaling::CallControl::Offer {
        call_id,
        media: media_kind(video),
        node_addr_b64,
        unix_secs,
    }
    .encode()
}

/// Encode an ANSWER control line (`node_addr_b64` empty for decline/busy).
#[cfg(feature = "calls-audio")]
#[uniffi::export]
pub fn call_encode_answer(
    call_id: String,
    answer: CallAnswerKind,
    node_addr_b64: String,
) -> String {
    sonar_core::call::signaling::CallControl::Answer {
        call_id,
        answer: answer.into(),
        node_addr_b64,
    }
    .encode()
}

/// Encode a CANCEL control line (offerer retracted before answer).
#[cfg(feature = "calls-audio")]
#[uniffi::export]
pub fn call_encode_cancel(call_id: String) -> String {
    sonar_core::call::signaling::CallControl::Cancel { call_id }.encode()
}

/// Encode an END control line (either side hung up a connected call).
#[cfg(feature = "calls-audio")]
#[uniffi::export]
pub fn call_encode_end(call_id: String, reason: String) -> String {
    sonar_core::call::signaling::CallControl::End { call_id, reason }.encode()
}

/// Parse message content as a `☎CALL` control line. `None` for plain chat,
/// `⚡PAY` lines, unknown versions, and malformed lines (so they are ignored).
#[cfg(feature = "calls-audio")]
#[uniffi::export]
pub fn call_parse_control(content: String) -> Option<CallControlInfo> {
    use sonar_core::call::signaling::{CallControl, CallMediaKind};
    Some(match CallControl::parse(&content)? {
        CallControl::Offer {
            call_id,
            media,
            node_addr_b64,
            unix_secs,
        } => CallControlInfo::Offer {
            call_id,
            video: media == CallMediaKind::Video,
            node_addr_b64,
            unix_secs,
        },
        CallControl::Answer {
            call_id,
            answer,
            node_addr_b64,
        } => CallControlInfo::Answer {
            call_id,
            answer: answer.into(),
            node_addr_b64,
        },
        CallControl::Cancel { call_id } => CallControlInfo::Cancel { call_id },
        CallControl::End { call_id, reason } => CallControlInfo::End { call_id, reason },
    })
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
        match &mut *self.phase.lock().expect("noise phase lock not poisoned") {
            NoisePhase::Handshake(hs) => Ok(hs.write_message()?),
            _ => Err(SonarFfiError::Core("noise: not in handshake".into())),
        }
    }

    /// Consume a handshake message received from the peer.
    pub fn read_message(&self, msg: Vec<u8>) -> FfiResult<()> {
        match &mut *self.phase.lock().expect("noise phase lock not poisoned") {
            NoisePhase::Handshake(hs) => Ok(hs.read_message(&msg)?),
            _ => Err(SonarFfiError::Core("noise: not in handshake".into())),
        }
    }

    pub fn is_finished(&self) -> bool {
        match &*self.phase.lock().expect("noise phase lock not poisoned") {
            NoisePhase::Handshake(hs) => hs.is_finished(),
            NoisePhase::Session(_) => true,
            NoisePhase::Spent => false,
        }
    }

    /// The peer's authenticated static key (hex), available after the handshake.
    pub fn remote_static_hex(&self) -> Option<String> {
        match &*self.phase.lock().expect("noise phase lock not poisoned") {
            NoisePhase::Handshake(hs) => hs.remote_static().map(hex::encode),
            _ => None,
        }
    }

    /// Transition from handshake to the encrypted transport phase.
    /// NB: NOT named `finalize` — that collides with Java's `Object.finalize()`
    /// in the generated Kotlin binding (the GC then re-invokes it on a spent
    /// object and throws).
    pub fn into_session(&self) -> FfiResult<()> {
        let mut g = self.phase.lock().expect("noise phase lock not poisoned");
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
        match &mut *self.phase.lock().expect("noise phase lock not poisoned") {
            NoisePhase::Session(s) => Ok(s.encrypt(&data)?),
            _ => Err(SonarFfiError::Core("noise: no session".into())),
        }
    }

    pub fn decrypt(&self, data: Vec<u8>) -> FfiResult<Vec<u8>> {
        match &mut *self.phase.lock().expect("noise phase lock not poisoned") {
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

/// A decoded mesh file transfer (`BitchatFilePacket`, type 0x22). `content` is
/// the raw file bytes (already decrypted for a private transfer).
#[derive(uniffi::Record)]
pub struct MeshFileInfo {
    pub file_name: Option<String>,
    pub file_size: Option<u64>,
    pub mime_type: Option<String>,
    pub content: Vec<u8>,
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

/// Encode a sticker reference as a content string suitable for a BLE mesh
/// private message.  The wire uses ASCII Unit Separator (\x1F) delimiters so
/// the encoded string is unambiguous against regular chat text.
#[uniffi::export]
pub fn mesh_sticker_content(
    pack_coordinate: String,
    shortcode: String,
    plaintext_sha256: String,
) -> String {
    format!("\x1Fsticker\x1F{pack_coordinate}\x1F{shortcode}\x1F{plaintext_sha256}")
}

/// Try to parse a content string as a mesh-encoded sticker reference.
/// Returns `None` for regular text messages.
#[uniffi::export]
pub fn mesh_parse_sticker_content(content: String) -> Option<StickerRefInfo> {
    let parts: Vec<&str> = content.splitn(5, '\x1F').collect();
    if parts.len() >= 5 && parts[0].is_empty() && parts[1] == "sticker" {
        Some(StickerRefInfo {
            pack_coordinate: parts[2].to_string(),
            shortcode: parts[3].to_string(),
            plaintext_sha256: parts[4].to_string(),
        })
    } else {
        None
    }
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

// ── Mesh file transfer (BitchatFilePacket, type 0x22) ─────────────────────

/// Encode a `BitchatFilePacket` TLV (bitchat-compatible). The result is the
/// payload of a 0x22 packet (private = Noise-encrypt it first, then fragment).
#[uniffi::export]
pub fn mesh_encode_file_packet(
    file_name: Option<String>,
    file_size: Option<u64>,
    mime_type: Option<String>,
    content: Vec<u8>,
) -> FfiResult<Vec<u8>> {
    mesh::file_packet::FilePacket {
        file_name,
        file_size,
        mime_type,
        content,
    }
    .encode()
    .ok_or_else(|| SonarFfiError::InvalidInput("file packet exceeds protocol limits".into()))
}

/// Decode a `BitchatFilePacket` TLV (already reassembled + decrypted).
#[uniffi::export]
pub fn mesh_decode_file_packet(bytes: Vec<u8>) -> Option<MeshFileInfo> {
    let p = mesh::file_packet::FilePacket::decode(&bytes)?;
    Some(MeshFileInfo {
        file_name: p.file_name,
        file_size: p.file_size,
        mime_type: p.mime_type,
        content: p.content,
    })
}

/// Split `data` into bitchat-compatible 0x20 fragment payloads (each carries
/// `original_type`). Wrap each returned payload in a 0x20 packet to send.
#[uniffi::export]
pub fn mesh_fragment(
    data: Vec<u8>,
    fragment_id_hex: String,
    original_type: u8,
    chunk_size: u32,
) -> FfiResult<Vec<Vec<u8>>> {
    let id_bytes = hex::decode(&fragment_id_hex).map_err(invalid("fragment id"))?;
    let id: [u8; 8] = id_bytes
        .try_into()
        .map_err(|_| SonarFfiError::InvalidInput("fragment id must be 8 bytes".into()))?;
    if chunk_size == 0 {
        return Err(SonarFfiError::InvalidInput("chunk_size must be > 0".into()));
    }
    let frags = mesh::file_packet::fragment(&data, id, original_type, chunk_size as usize)
        .ok_or_else(|| {
            SonarFfiError::InvalidInput("data too large to fragment (exceeds max fragments)".into())
        })?;
    Ok(frags.iter().map(|f| f.encode_payload()).collect())
}

/// Reassembles incoming 0x20 fragment payloads into the original bytes. Keyed by
/// (sender, fragmentID); `add` returns the full bytes once the last piece lands.
#[derive(uniffi::Object)]
pub struct MeshReassembler {
    inner: Mutex<mesh::fragment::Reassembler>,
}

#[uniffi::export]
impl MeshReassembler {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(mesh::fragment::Reassembler::new()),
        })
    }

    /// Feed one 0x20 fragment payload (with the carrying packet's sender id hex).
    /// Returns the reassembled original bytes when complete, else nil.
    pub fn add(
        &self,
        sender_id_hex: String,
        fragment_payload: Vec<u8>,
    ) -> FfiResult<Option<Vec<u8>>> {
        let sender_bytes = hex::decode(&sender_id_hex).map_err(invalid("sender id"))?;
        let sender: [u8; 8] = sender_bytes
            .try_into()
            .map_err(|_| SonarFfiError::InvalidInput("sender id must be 8 bytes".into()))?;
        let frag = match mesh::fragment::Fragment::decode_payload(&fragment_payload) {
            Some(f) => f,
            None => return Ok(None),
        };
        Ok(self.inner.lock().expect("fragment assembler lock not poisoned").add(sender, &frag))
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

fn message_info(m: sonar_core::marmot::ChatMessage) -> MessageInfo {
    MessageInfo {
        id_hex: m.id.to_hex(),
        sender_npub: m.sender.to_bech32().expect("npub encoding cannot fail"),
        content: m.content,
        created_at_secs: m.created_at.as_secs(),
        mine: m.mine,
        delivery_state: m.delivery_state.as_str().to_string(),
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
        sticker_ref: m.sticker_ref.map(|s| StickerRefInfo {
            pack_coordinate: s.pack.coordinate(),
            shortcode: s.shortcode,
            plaintext_sha256: s.plaintext_sha256,
        }),
    }
}

fn sticker_pack_info(pack: sonar_stickers::StickerPack) -> StickerPackInfo {
    StickerPackInfo {
        pack_coordinate: pack.address.coordinate(),
        title: pack.title,
        description: pack.description,
        cover_url: pack.cover.as_ref().map(|c| c.url.clone()),
        stickers: pack
            .stickers
            .into_iter()
            .map(|s| StickerInfo {
                shortcode: s.shortcode,
                url: s.url,
                sha256: s.sha256,
                mime: s.mime,
                width: s.width,
                height: s.height,
                alt: s.alt,
                emoji: s.emoji,
            })
            .collect(),
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
        // Empty relays are allowed: the host can open the encrypted local DB
        // first, then attach real relays after first paint.
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

    #[cfg(feature = "calls-audio")]
    #[test]
    fn call_wait_without_engine_times_out() {
        let id = SonarIdentity::generate();
        let key = "00".repeat(32);
        let db = format!(
            "/tmp/sonar-ffi-call-wait-{}.sqlite",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let node = SonarNode::connect(id, vec![], db.clone(), key).unwrap();
        assert!(node.call_wait_event(0).is_none());
        let _ = wipe_marmot_database(db);
    }

    #[test]
    fn wipe_missing_db_is_ok() {
        // Idempotent: wiping a non-existent path succeeds.
        assert!(wipe_marmot_database("/tmp/sonar-ffi-does-not-exist.sqlite".into()).is_ok());
    }

    #[test]
    fn sticker_content_roundtrip() {
        let pack = "30030:abc123:mypack".to_string();
        let code = "wave".to_string();
        let hash = "deadbeef".to_string();
        let encoded = mesh_sticker_content(pack.clone(), code.clone(), hash.clone());
        let parsed = mesh_parse_sticker_content(encoded).expect("should parse");
        assert_eq!(parsed.pack_coordinate, pack);
        assert_eq!(parsed.shortcode, code);
        assert_eq!(parsed.plaintext_sha256, hash);
    }

    #[test]
    fn sticker_content_rejects_plain_text() {
        assert!(mesh_parse_sticker_content("hello world".into()).is_none());
        assert!(mesh_parse_sticker_content("".into()).is_none());
        assert!(mesh_parse_sticker_content("sticker:fake".into()).is_none());
    }
}
