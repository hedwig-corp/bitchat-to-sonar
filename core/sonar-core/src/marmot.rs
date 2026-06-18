//! Marmot protocol engine: MLS-over-Nostr via MDK.
//!
//! This module is the synchronous, transport-free protocol layer. It produces
//! and consumes Nostr [`Event`]s but never talks to a relay — publishing and
//! subscribing belong to [`crate::client`]. Keeping this layer pure makes it
//! testable without any network and directly bindable over FFI later.
//!
//! Protocol facts (Marmot MIPs, see CLAUDE.md):
//! - KeyPackage = kind 30443 (addressable, `d` tag), signed by the user key.
//! - Welcome   = kind 444 rumor, delivered inside a NIP-59 gift wrap (1059).
//! - Group msg = kind 445, MLS ciphertext, signed by MDK with a fresh
//!   ephemeral key per event (the user key never signs a 445).
//! - Committers must call `merge_pending_commit` only after the commit/welcome
//!   has been published; see MDK docs.

use std::path::Path;

use mdk_core::encrypted_media::{EncryptedMediaUpload, MediaReference};
use mdk_core::prelude::*;
use mdk_memory_storage::MdkMemoryStorage;
use mdk_sqlite_storage::{EncryptionConfig, MdkSqliteStorage};
use mdk_storage_traits::groups::{MessageSortOrder, Pagination};
use nostr::prelude::*;
use serde::{Deserialize, Serialize};

use crate::identity::Identity;
use crate::outbox::OUTBOX_STATE_FILE_SUFFIX;
use crate::{Error, Result};

/// Kind used for the inner chat rumor inside a 445 (matches White Noise / the
/// MDK examples: NIP-C7-style chat message).
pub const CHAT_RUMOR_KIND: u16 = 9;

/// Marmot KeyPackage event kind (MIP-00). nostr 0.44 has no named constant
/// for the modern addressable kind (Kind::MlsKeyPackage is the legacy 443).
pub const KEY_PACKAGE_KIND: u16 = 30443;

/// Sidecar file suffix for Sonar's relay-sync cursor beside the MDK database.
pub(crate) const SYNC_STATE_FILE_SUFFIX: &str = ".sonar-sync.json";

/// Maximum raw MDK rows to scan while building a chat-only page. MDK stores
/// commits/proposals alongside application chat rows, so a single raw page can
/// be empty after filtering even when older chat messages exist.
const MESSAGE_PAGE_RAW_SCAN_LIMIT: usize = 10_000;

/// Result of creating a group: the group plus the welcome rumors that must be
/// gift-wrapped and delivered to each invited member.
pub struct GroupCreation {
    pub group: group_types::Group,
    /// `(member pubkey, kind-444 rumor)` pairs, one per invited member.
    pub welcomes: Vec<(PublicKey, UnsignedEvent)>,
}

/// Result of a group membership update that must be published by the caller.
#[derive(Debug)]
pub struct GroupMembershipUpdate {
    pub group_id: GroupId,
    /// Kind-445 commit/proposal event to publish to the group's relays.
    pub evolution_event: Event,
    /// `(member pubkey, kind-444 rumor)` pairs for newly invited members.
    pub welcomes: Vec<(PublicKey, UnsignedEvent)>,
    /// True when MDK staged a local commit that must be merged after publish.
    pub requires_commit_merge: bool,
}

/// Pending group invite surfaced to the native shells for accept/decline UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupInvite {
    /// Kind-444 welcome event id. Use this as the stable accept/decline handle.
    pub id: EventId,
    pub wrapper_id: EventId,
    pub group_id: GroupId,
    pub group_name: String,
    pub group_description: String,
    pub welcomer: PublicKey,
    pub member_count: u32,
    pub relays: Vec<RelayUrl>,
}

/// A reference to an encrypted media blob (Marmot MIP-04) attached to a chat
/// message — enough for the UI to render a placeholder and trigger a download.
/// The decryption material (nonce, hashes, scheme) stays inside MDK;
/// `decrypt_media_by_url` re-derives it from the message's `imeta` tag by URL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaRef {
    /// Blossom URL of the ENCRYPTED blob.
    pub url: String,
    pub mime_type: String,
    pub filename: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_ms: Option<u64>,
}

/// Local delivery state for a transcript row. Network/relay work updates this
/// state by mutating Sonar-owned outbox metadata; the UI reads it with the
/// local transcript page instead of inventing app-layer optimistic rows.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryState {
    Received,
    Pending,
    Sent,
    Failed,
}

impl DeliveryState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Received => "received",
            Self::Pending => "pending",
            Self::Sent => "sent",
            Self::Failed => "failed",
        }
    }
}

impl From<&MediaReference> for MediaRef {
    fn from(r: &MediaReference) -> Self {
        let (width, height) = match r.dimensions {
            Some((w, h)) => (Some(w), Some(h)),
            None => (None, None),
        };
        Self {
            url: r.url.clone(),
            mime_type: r.mime_type.clone(),
            filename: r.filename.clone(),
            width,
            height,
            duration_ms: r.duration_ms,
        }
    }
}

/// A decrypted application message, mapped to a small FFI-friendly shape.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatMessage {
    pub id: EventId,
    pub group_id: GroupId,
    pub sender: PublicKey,
    /// Caption / text body (may be empty for a pure media message).
    pub content: String,
    pub created_at: Timestamp,
    /// True when `sender` is the local identity.
    pub mine: bool,
    pub delivery_state: DeliveryState,
    /// Encrypted media attachments (MIP-04 `imeta` tags), if any.
    pub media: Vec<MediaRef>,
}

/// Bounded transcript page for one recent group.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecentMessagePage {
    pub group_id: GroupId,
    pub latest_created_at: Timestamp,
    pub messages: Vec<ChatMessage>,
}

/// What came out of processing an incoming event.
#[derive(Debug)]
pub enum Incoming {
    /// A decrypted chat message (already persisted in MDK storage).
    Message(ChatMessage),
    /// A group-membership/welcome change was applied; no chat content.
    GroupUpdated(GroupId),
    /// A multi-member welcome was stored and is waiting for user acceptance.
    GroupInvitePending(GroupId),
    /// Processing a proposal produced an auto-commit that the caller must
    /// publish and merge before the group converges.
    GroupProposal(GroupMembershipUpdate),
    /// MDK saw the event but could not apply it yet or marked a prior attempt
    /// failed. The relay sync layer must not advance past this event.
    Retryable,
    /// The event was valid but produced nothing actionable (duplicates,
    /// ignored proposals, non-Marmot gift wraps, ...).
    None,
}

/// Storage backend for the MLS state.
///
/// MDK is generic over `Storage: MdkStorageProvider`, and the two concrete
/// providers (`MdkMemoryStorage`, `MdkSqliteStorage`) are distinct types. Rather
/// than thread that generic through `client`/`ffi`, we keep `MarmotEngine` a
/// single concrete type and dispatch over this enum (see the `dispatch!` macro).
enum Storage {
    /// Volatile, used by tests and the (historical) in-memory path. Boxed so the
    /// enum stays small despite the two providers' differing sizes.
    Memory(Box<MDK<MdkMemoryStorage>>),
    /// Encrypted SQLCipher database on disk (production persistence).
    Sqlite(Box<MDK<MdkSqliteStorage>>),
}

/// Call the same MDK method on whichever storage variant is active.
///
/// Usage: `dispatch!(self.storage, |mdk| mdk.get_groups())` — both arms must
/// type-check, which they do because the MDK API is identical across providers.
macro_rules! dispatch {
    ($storage:expr, |$mdk:ident| $body:expr) => {
        match $storage {
            Storage::Memory($mdk) => $body,
            Storage::Sqlite($mdk) => $body,
        }
    };
}

/// The Marmot engine: one per identity, owns MLS group state via MDK.
pub struct MarmotEngine {
    storage: Storage,
    identity: Identity,
}

impl MarmotEngine {
    /// In-memory engine. Volatile — state is lost on drop. Used by tests and any
    /// caller that does not need persistence.
    pub fn in_memory(identity: Identity) -> Self {
        Self {
            storage: Storage::Memory(Box::new(MDK::new(MdkMemoryStorage::default()))),
            identity,
        }
    }

    /// Persistent engine backed by an encrypted SQLCipher database at `db_path`.
    ///
    /// `key` is the 32-byte SQLCipher key. The HOST owns this key (on iOS the
    /// Swift side stores it in the Keychain and passes it down) — MDK's keyring
    /// path is bypassed because OS keyrings are unreliable from a Rust static lib
    /// on iOS. The parent directory of `db_path` must already exist; the host is
    /// expected to place it in a Data-Protection-Complete directory.
    pub fn persistent(
        identity: Identity,
        db_path: impl AsRef<Path>,
        key: [u8; 32],
    ) -> Result<Self> {
        let path = db_path.as_ref();
        let storage = match MdkSqliteStorage::new_with_key(path, EncryptionConfig::new(key)) {
            Ok(storage) => storage,
            Err(e) if is_unusable_db_error(&e.to_string()) => {
                // The file on disk cannot be opened as our encrypted store: it is
                // either plaintext (created by an older build that didn't encrypt),
                // encrypted under a different/lost key, or corrupt. In every case
                // the contents are UNRECOVERABLE with the current key, and the file
                // blocks the app on every launch ("database was created without
                // encryption" / "file is not a database"). Self-heal by erasing it
                // and recreating a fresh encrypted database, so the app stays usable
                // (the keychain key is now stable, so the new DB persists). This is
                // destructive but only ever discards already-inaccessible data.
                let detail = e.to_string();
                Self::wipe(path)?;
                let storage = MdkSqliteStorage::new_with_key(path, EncryptionConfig::new(key))
                    .map_err(|e2| {
                        Error::Storage(format!(
                            "recreate after unusable DB failed: {e2} (original: {detail})"
                        ))
                    })?;
                tracing::warn!(
                    "marmot: discarded an unusable on-disk database and recreated it \
                     encrypted (original open error: {detail})"
                );
                storage
            }
            Err(e) => return Err(Error::Storage(e.to_string())),
        };
        Ok(Self {
            storage: Storage::Sqlite(Box::new(MDK::new(storage))),
            identity,
        })
    }

    pub fn identity(&self) -> &Identity {
        &self.identity
    }

    /// Erase the on-disk SQLCipher database at `db_path` and its sidecar files.
    ///
    /// Used by panic-wipe. No engine must hold the file open when this is called.
    /// Removes `db_path`, SQLite sidecars, and Sonar sync/outbox sidecars;
    /// missing files are not an error (idempotent).
    pub fn wipe(db_path: impl AsRef<Path>) -> Result<()> {
        let base = db_path.as_ref();
        for path in sidecar_paths(base) {
            match std::fs::remove_file(&path) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(Error::Storage(format!("wipe {}: {e}", path.display()))),
            }
        }
        Ok(())
    }

    /// Build a signed kind-30443 KeyPackage event, ready to publish to
    /// `relays` (which are also advertised inside the event tags).
    pub fn key_package_event(&self, relays: Vec<RelayUrl>) -> Result<Event> {
        let kp = dispatch!(&self.storage, |mdk| mdk
            .create_key_package_for_event(&self.identity.public_key(), relays))?;
        let event = EventBuilder::new(Kind::Custom(KEY_PACKAGE_KIND), kp.content)
            .tags(kp.tags_30443)
            .build(self.identity.public_key())
            .sign_with_keys(self.identity.keys())?;
        Ok(event)
    }

    /// Create a group with the given members (their signed kind-30443 events).
    /// All members are admins for now (the 1:1 DM shape used by White Noise).
    ///
    /// Per MDK rules the creator's pending commit must be merged only after
    /// the caller has successfully delivered every Welcome. The caller may
    /// clear and discard the staged group only if delivery fails before any
    /// Welcome is published; after partial delivery, the pending state must be
    /// preserved so the creator does not orphan already-delivered invites.
    pub fn create_group(
        &self,
        name: &str,
        member_key_packages: Vec<Event>,
        relays: Vec<RelayUrl>,
    ) -> Result<GroupCreation> {
        let mut admins: Vec<PublicKey> = member_key_packages.iter().map(|e| e.pubkey).collect();
        admins.push(self.identity.public_key());
        let member_pubkeys: Vec<PublicKey> = member_key_packages.iter().map(|e| e.pubkey).collect();

        let config = NostrGroupConfigData::new(
            name.to_owned(),
            String::new(),
            None, // image_hash
            None, // image_key
            None, // image_nonce
            relays,
            admins,
            None, // disappearing_message_secs (no ephemeral messages in v1 DMs)
        );
        let result = dispatch!(&self.storage, |mdk| mdk.create_group(
            &self.identity.public_key(),
            member_key_packages,
            config,
        ))?;
        let welcomes = member_pubkeys
            .into_iter()
            .zip(result.welcome_rumors)
            .collect();
        Ok(GroupCreation {
            group: result.group,
            welcomes,
        })
    }

    /// Create an add-members commit for an existing group. The caller must
    /// publish `evolution_event`, deliver any welcomes, then merge the pending
    /// commit with [`Self::merge_pending_commit`]. If welcome delivery fails
    /// after the commit event may have reached relays, preserve the pending
    /// commit rather than rolling back local state.
    pub fn add_members(
        &self,
        group_id: &GroupId,
        member_key_packages: Vec<Event>,
    ) -> Result<GroupMembershipUpdate> {
        let member_pubkeys: Vec<PublicKey> = member_key_packages.iter().map(|e| e.pubkey).collect();
        let result = dispatch!(&self.storage, |mdk| mdk
            .add_members(group_id, &member_key_packages))?;
        Ok(Self::to_membership_update(result, member_pubkeys, true))
    }

    /// Create a remove-members commit for an existing group.
    pub fn remove_members(
        &self,
        group_id: &GroupId,
        members: &[PublicKey],
    ) -> Result<GroupMembershipUpdate> {
        let result = dispatch!(&self.storage, |mdk| mdk.remove_members(group_id, members))?;
        Ok(Self::to_membership_update(result, Vec::new(), true))
    }

    /// Create a self-demotion commit. Required before an admin leaves.
    pub fn self_demote(&self, group_id: &GroupId) -> Result<GroupMembershipUpdate> {
        let result = dispatch!(&self.storage, |mdk| mdk.self_demote(group_id))?;
        Ok(Self::to_membership_update(result, Vec::new(), true))
    }

    /// Create a leave proposal for the current member.
    pub fn leave_group(&self, group_id: &GroupId) -> Result<GroupMembershipUpdate> {
        let result = dispatch!(&self.storage, |mdk| mdk.leave_group(group_id))?;
        Ok(Self::to_membership_update(result, Vec::new(), false))
    }

    /// Merge a pending local commit after the caller has published it.
    pub fn merge_pending_commit(&self, group_id: &GroupId) -> Result<()> {
        Ok(dispatch!(&self.storage, |mdk| mdk.merge_pending_commit(group_id))?)
    }

    /// Roll back a pending local commit when publish fails before it reaches the
    /// relays. This keeps the group usable for a later retry.
    pub fn clear_pending_commit(&self, group_id: &GroupId) -> Result<()> {
        Ok(dispatch!(&self.storage, |mdk| mdk.clear_pending_commit(group_id))?)
    }

    /// Gift-wrap a kind-444 welcome rumor for `receiver` (NIP-59, kind 1059).
    pub async fn gift_wrap_welcome(
        &self,
        receiver: &PublicKey,
        rumor: UnsignedEvent,
    ) -> Result<Event> {
        // Build the NIP-59 gift wrap manually so the OUTER (kind-1059) event uses a
        // CURRENT timestamp instead of NIP-59's randomized up-to-2-days-in-the-past
        // tweak. White Noise subscribes for incoming welcomes with
        // `since = last_synced_at - 10s`, so a far-past gift-wrap timestamp falls
        // outside its window and the welcome is NEVER fetched — Sonar->White Noise
        // group invites silently failed. A recent timestamp keeps them in the window.
        // (We don't filter by `since`, which is why White Noise->Sonar worked.)
        let keys = self.identity.keys();
        let seal: Event = EventBuilder::seal(keys, receiver, rumor)
            .await?
            .sign(keys)
            .await?;
        let ephemeral = Keys::generate();
        let content = nip44::encrypt(
            ephemeral.secret_key(),
            receiver,
            seal.as_json(),
            nip44::Version::default(),
        )?;
        let wrapped = EventBuilder::new(Kind::GiftWrap, content)
            .tags([Tag::public_key(*receiver)])
            .custom_created_at(Timestamp::now())
            .sign_with_keys(&ephemeral)?;
        Ok(wrapped)
    }

    /// Encrypt a text message into a signed kind-445 event for `group_id`.
    /// The returned event is signed by an MDK-generated ephemeral key and is
    /// already recorded as "ours" in storage once processed back.
    pub fn create_text_message(&self, group_id: &GroupId, text: &str) -> Result<Event> {
        let rumor = EventBuilder::new(Kind::Custom(CHAT_RUMOR_KIND), text)
            .build(self.identity.public_key());
        let event = dispatch!(&self.storage, |mdk| mdk
            .create_message(group_id, rumor, None))?;
        Ok(event)
    }

    // ── Encrypted media (Marmot MIP-04) ───────────────────────────────────
    //
    // MDK does the crypto (key from the group exporter secret) and the `imeta`
    // tag; the caller ([`crate::client`]) does the Blossom upload/download. This
    // engine layer stays transport-free.

    /// Encrypt `data` for `group_id` into a ciphertext + metadata blob ready to
    /// upload to a Blossom server. Pure crypto, no I/O. `mime` like `image/jpeg`.
    pub fn encrypt_media(
        &self,
        group_id: &GroupId,
        data: &[u8],
        mime: &str,
        filename: &str,
    ) -> Result<EncryptedMediaUpload> {
        dispatch!(&self.storage, |mdk| mdk
            .media_manager(group_id.clone())
            .encrypt_for_upload(data, mime, filename)
            .map_err(|e| Error::Media(e.to_string())))
    }

    /// Build a signed kind-445 media message: a kind-9 rumor carrying `caption`
    /// (may be empty) plus the `imeta` tag pointing at the uploaded ciphertext
    /// `url`. The imeta rides INSIDE the encrypted rumor, so it is E2E-protected.
    pub fn create_media_event(
        &self,
        group_id: &GroupId,
        upload: &EncryptedMediaUpload,
        url: &str,
        caption: &str,
    ) -> Result<Event> {
        let event = dispatch!(&self.storage, |mdk| {
            let imeta = mdk
                .media_manager(group_id.clone())
                .create_imeta_tag(upload, url);
            let rumor = EventBuilder::new(Kind::Custom(CHAT_RUMOR_KIND), caption)
                .tags([imeta])
                .build(self.identity.public_key());
            mdk.create_message(group_id, rumor, None)
        })?;
        Ok(event)
    }

    /// Find the `MediaReference` for `url` among `group_id`'s stored messages and
    /// decrypt the downloaded `ciphertext` with it. Verifies the original hash.
    pub fn decrypt_media_by_url(
        &self,
        group_id: &GroupId,
        url: &str,
        ciphertext: &[u8],
    ) -> Result<Vec<u8>> {
        dispatch!(&self.storage, |mdk| {
            let mgr = mdk.media_manager(group_id.clone());
            for m in mdk.get_messages(group_id, None)? {
                for tag in m.tags.iter() {
                    if tag.kind() == TagKind::Custom("imeta".into()) {
                        if let Ok(r) = mgr.parse_imeta_tag(tag) {
                            if r.url == url {
                                return mgr
                                    .decrypt_from_download(ciphertext, &r)
                                    .map_err(|e| Error::Media(e.to_string()));
                            }
                        }
                    }
                }
            }
            Err(Error::Media(format!("no media reference for url {url}")))
        })
    }

    /// Parse the `imeta` tags on a message into display-ready [`MediaRef`]s.
    fn parse_media_refs(&self, group_id: &GroupId, tags: &Tags) -> Vec<MediaRef> {
        dispatch!(&self.storage, |mdk| {
            let mgr = mdk.media_manager(group_id.clone());
            tags.iter()
                .filter(|t| t.kind() == TagKind::Custom("imeta".into()))
                .filter_map(|t| mgr.parse_imeta_tag(t).ok())
                .map(|r| MediaRef::from(&r))
                .collect()
        })
    }

    /// Process any incoming Marmot-relevant event:
    /// - kind 1059 gift wrap → unwrap; if it holds a kind-444 welcome, direct
    ///   1:1 welcomes are auto-accepted for compatibility and group welcomes are
    ///   stored pending for explicit accept/decline UI.
    /// - kind 445 group message → decrypt/apply.
    pub async fn process_incoming(&self, event: &Event) -> Result<Incoming> {
        match event.kind {
            Kind::GiftWrap => {
                let unwrapped = UnwrappedGift::from_gift_wrap(self.identity.keys(), event).await?;
                if unwrapped.rumor.kind != Kind::MlsWelcome {
                    return Ok(Incoming::None);
                }
                let welcome = dispatch!(&self.storage, |mdk| mdk
                    .process_welcome(&event.id, &unwrapped.rumor))?;
                if welcome.member_count <= 2 {
                    dispatch!(&self.storage, |mdk| mdk.accept_welcome(&welcome))?;
                    return Ok(Incoming::GroupUpdated(welcome.mls_group_id));
                }
                match welcome.state {
                    welcome_types::WelcomeState::Pending => {
                        Ok(Incoming::GroupInvitePending(welcome.mls_group_id))
                    }
                    welcome_types::WelcomeState::Accepted => {
                        Ok(Incoming::GroupUpdated(welcome.mls_group_id))
                    }
                    welcome_types::WelcomeState::Declined
                    | welcome_types::WelcomeState::Ignored => Ok(Incoming::None),
                }
            }
            Kind::MlsGroupMessage => {
                match dispatch!(&self.storage, |mdk| mdk.process_message(event))? {
                    MessageProcessingResult::ApplicationMessage(msg) => {
                        Ok(Incoming::Message(self.to_chat_message(msg)))
                    }
                    MessageProcessingResult::Commit { mls_group_id }
                    | MessageProcessingResult::PendingProposal { mls_group_id } => {
                        Ok(Incoming::GroupUpdated(mls_group_id))
                    }
                    MessageProcessingResult::Proposal(update) => Ok(Incoming::GroupProposal(
                        Self::to_membership_update(update, Vec::new(), true),
                    )),
                    MessageProcessingResult::Unprocessable { .. }
                    | MessageProcessingResult::PreviouslyFailed => Ok(Incoming::Retryable),
                    _ => Ok(Incoming::None),
                }
            }
            _ => Ok(Incoming::None),
        }
    }

    /// All active groups this identity belongs to. Pending group invites are
    /// surfaced separately via [`Self::pending_group_invites`].
    pub fn groups(&self) -> Result<Vec<group_types::Group>> {
        Ok(dispatch!(&self.storage, |mdk| mdk.get_groups())?
            .into_iter()
            .filter(|g| g.state == group_types::GroupState::Active)
            .collect())
    }

    /// Pending multi-member welcomes waiting for user acceptance.
    pub fn pending_group_invites(&self) -> Result<Vec<GroupInvite>> {
        let welcomes = dispatch!(&self.storage, |mdk| mdk.get_pending_welcomes(None))?;
        Ok(welcomes
            .into_iter()
            .filter(|w| w.member_count > 2)
            .map(Self::to_group_invite)
            .collect())
    }

    /// Accept a pending group invite by its kind-444 welcome event id.
    pub fn accept_group_invite(&self, welcome_id: &EventId) -> Result<GroupId> {
        let welcome = dispatch!(&self.storage, |mdk| mdk.get_welcome(welcome_id))?
            .ok_or_else(|| Error::InvalidInput(format!("unknown group invite {welcome_id}")))?;
        let group_id = welcome.mls_group_id.clone();
        dispatch!(&self.storage, |mdk| mdk.accept_welcome(&welcome))?;
        Ok(group_id)
    }

    /// Decline a pending group invite by its kind-444 welcome event id.
    pub fn decline_group_invite(&self, welcome_id: &EventId) -> Result<()> {
        let welcome = dispatch!(&self.storage, |mdk| mdk.get_welcome(welcome_id))?
            .ok_or_else(|| Error::InvalidInput(format!("unknown group invite {welcome_id}")))?;
        dispatch!(&self.storage, |mdk| mdk.decline_welcome(&welcome))?;
        Ok(())
    }

    /// Decrypted message history for a group (storage-backed).
    pub fn messages(&self, group_id: &GroupId) -> Result<Vec<ChatMessage>> {
        let msgs = dispatch!(&self.storage, |mdk| mdk.get_messages(group_id, None))?;
        Ok(msgs
            .into_iter()
            // Only surface real chat messages (kind-9). MDK's store ALSO keeps
            // non-chat entries (group-membership / commit / proposal / reaction
            // kinds) which carry no chat text — without this filter they render
            // as empty message bubbles in the UI.
            .filter(|m| m.kind.as_u16() == CHAT_RUMOR_KIND)
            .map(|m| self.to_chat_message(m))
            .collect())
    }

    /// Bounded decrypted chat-message window for a group, newest window first
    /// before caller-side display sorting. Offset counts chat messages, not raw
    /// MDK storage rows, because MDK stores commits/proposals beside kind-9
    /// application messages.
    pub fn messages_page(
        &self,
        group_id: &GroupId,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<ChatMessage>> {
        if limit == 0 {
            return Ok(Vec::new());
        }

        let raw_batch = limit.saturating_mul(4).clamp(32, 500);
        let mut raw_offset = 0usize;
        let mut raw_scanned = 0usize;
        let mut chat_skipped = 0usize;
        let mut page_messages = Vec::with_capacity(limit);

        while page_messages.len() < limit && raw_scanned < MESSAGE_PAGE_RAW_SCAN_LIMIT {
            let remaining_scan = MESSAGE_PAGE_RAW_SCAN_LIMIT - raw_scanned;
            let batch_limit = raw_batch.min(remaining_scan);
            let page = Pagination::with_sort_order(
                Some(batch_limit),
                Some(raw_offset),
                MessageSortOrder::CreatedAtFirst,
            );
            let raw_msgs = dispatch!(&self.storage, |mdk| mdk.get_messages(group_id, Some(page)))?;
            if raw_msgs.is_empty() {
                break;
            }

            let raw_len = raw_msgs.len();
            raw_scanned += raw_len;
            raw_offset += raw_len;
            for msg in raw_msgs {
                if msg.kind.as_u16() != CHAT_RUMOR_KIND {
                    continue;
                }
                if chat_skipped < offset {
                    chat_skipped += 1;
                    continue;
                }
                page_messages.push(self.to_chat_message(msg));
                if page_messages.len() >= limit {
                    break;
                }
            }

            if raw_len < batch_limit {
                break;
            }
        }

        Ok(page_messages)
    }

    /// Latest local transcript windows for the most recent groups. This is the
    /// Signal-style chat-list hydration path: rank conversations by local DB
    /// recency, return only a small window for the newest groups, and leave
    /// relay sync completely out of first paint.
    pub fn recent_message_pages(
        &self,
        group_limit: usize,
        page_limit: usize,
    ) -> Result<Vec<RecentMessagePage>> {
        if group_limit == 0 || page_limit == 0 {
            return Ok(Vec::new());
        }

        let mut pages = Vec::new();
        for group in self.groups()? {
            let messages = self.messages_page(&group.mls_group_id, page_limit, 0)?;
            let Some(latest_created_at) = messages.iter().map(|m| m.created_at).max() else {
                continue;
            };
            pages.push(RecentMessagePage {
                group_id: group.mls_group_id,
                latest_created_at,
                messages,
            });
        }

        pages.sort_by(|a, b| {
            b.latest_created_at
                .cmp(&a.latest_created_at)
                .then_with(|| a.group_id.as_slice().cmp(b.group_id.as_slice()))
        });
        pages.truncate(group_limit);
        Ok(pages)
    }

    /// Members of a group.
    pub fn members(&self, group_id: &GroupId) -> Result<Vec<PublicKey>> {
        Ok(dispatch!(&self.storage, |mdk| mdk.get_members(group_id))?
            .into_iter()
            .collect())
    }

    /// Unix-seconds timestamp of the NEWEST event stored across all groups (any
    /// kind — membership/commit/chat). Used to RESUME incremental relay sync
    /// across restarts: a relaunch fetches only what arrived after this instead
    /// of re-downloading the whole history (the reference White Noise client
    /// persists a `last_synced_at` column for the same purpose; deriving it from
    /// the store keeps it ALWAYS consistent with what is actually persisted — a
    /// fresh or wiped DB has nothing → 0 → a full backfill). 0 if empty/on error.
    pub fn latest_message_secs(&self) -> u64 {
        let groups = match self.groups() {
            Ok(g) => g,
            Err(_) => return 0,
        };
        let mut newest = 0u64;
        for g in groups {
            let msgs = match dispatch!(&self.storage, |mdk| mdk.get_messages(&g.mls_group_id, None))
            {
                Ok(m) => m,
                Err(_) => continue,
            };
            for m in msgs {
                let t = m.created_at.as_secs();
                if t > newest {
                    newest = t;
                }
            }
        }
        newest
    }

    /// Delete ALL local state for a group: messages, processed-message records,
    /// MLS tree state, epoch secrets, key material, relay links, proposals, and
    /// snapshots. Local-only — no MLS proposal or Nostr event is published, so
    /// the peer is NOT notified (this is "delete this chat from my device", like
    /// deleting a conversation in Signal/iMessage). Idempotent.
    pub fn delete_group(&self, group_id: &GroupId) -> Result<()> {
        Ok(dispatch!(&self.storage, |mdk| mdk.delete_group(group_id))?)
    }

    fn to_membership_update(
        result: UpdateGroupResult,
        member_pubkeys: Vec<PublicKey>,
        requires_commit_merge: bool,
    ) -> GroupMembershipUpdate {
        let welcomes = result
            .welcome_rumors
            .unwrap_or_default()
            .into_iter()
            .zip(member_pubkeys)
            .map(|(rumor, member)| (member, rumor))
            .collect();
        GroupMembershipUpdate {
            group_id: result.mls_group_id,
            evolution_event: result.evolution_event,
            welcomes,
            requires_commit_merge,
        }
    }

    fn to_group_invite(welcome: welcome_types::Welcome) -> GroupInvite {
        GroupInvite {
            id: welcome.id,
            wrapper_id: welcome.wrapper_event_id,
            group_id: welcome.mls_group_id,
            group_name: welcome.group_name,
            group_description: welcome.group_description,
            welcomer: welcome.welcomer,
            member_count: welcome.member_count,
            relays: welcome.group_relays.into_iter().collect(),
        }
    }

    fn to_chat_message(&self, m: message_types::Message) -> ChatMessage {
        let media = self.parse_media_refs(&m.mls_group_id, &m.tags);
        ChatMessage {
            id: m.id,
            group_id: m.mls_group_id.clone(),
            sender: m.pubkey,
            content: m.content.clone(),
            created_at: m.created_at,
            mine: m.pubkey == self.identity.public_key(),
            delivery_state: if m.pubkey == self.identity.public_key() {
                DeliveryState::Sent
            } else {
                DeliveryState::Received
            },
            media,
        }
    }
}

/// The database file plus the SQLite sidecar files that may exist alongside it.
/// True only when an open error means the on-disk file is a PLAINTEXT SQLite
/// database being opened with an encryption key — an unambiguous, permanent
/// mismatch (an older build created the store unencrypted; the file can never
/// be opened with a key). Recreating it is the only way forward and discards
/// only already-inaccessible data.
///
/// Deliberately conservative: a WRONG/lost key on a genuinely-encrypted file
/// surfaces as "file is not a database", which is indistinguishable from a
/// transient host key-plumbing bug — we do NOT self-heal on that, so a correct
/// encrypted database is never erased because the host momentarily passed a bad
/// key. Likewise disk-full / permission / locked errors are not matched.
fn is_unusable_db_error(message: &str) -> bool {
    let m = message.to_lowercase();
    // SQLCipher when a key is set but the file has no encryption header:
    // "Cannot open unencrypted database with encryption: database was created
    //  without encryption".
    m.contains("without encryption") || m.contains("unencrypted database")
}

fn sidecar_paths(base: &Path) -> Vec<std::path::PathBuf> {
    let name = base
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default();
    let mut paths: Vec<std::path::PathBuf> = [
        "",
        "-wal",
        "-shm",
        "-journal",
        SYNC_STATE_FILE_SUFFIX,
        OUTBOX_STATE_FILE_SUFFIX,
    ]
    .iter()
    .map(|suffix| base.with_file_name(format!("{name}{suffix}")))
    .collect();
    paths.push(base.with_file_name(format!("{name}{SYNC_STATE_FILE_SUFFIX}.tmp")));
    paths.push(base.with_file_name(format!("{name}{OUTBOX_STATE_FILE_SUFFIX}.tmp")));
    paths
}
