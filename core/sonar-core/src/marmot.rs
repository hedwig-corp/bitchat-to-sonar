//! Marmot protocol engine: MLS-over-Nostr via MDK 0.9 (`AccountDeviceSession`).
//!
//! This module is the transport-free protocol layer. It produces and consumes
//! Nostr [`Event`]s but never talks to a relay — publishing and subscribing belong
//! to [`crate::client`]. MDK 0.9 session methods are async; mutating engine
//! methods are therefore async. The session lock is recovered on poison.
//!
//! Protocol facts (Marmot MIPs, see CLAUDE.md):
//! - KeyPackage = kind 30443 (addressable, `d` tag), signed by the user key.
//! - Welcome   = kind 444 rumor, delivered inside a NIP-59 gift wrap (1059).
//! - Group msg = kind 445, MLS ciphertext, signed with a fresh ephemeral key.
//! - Current-profile group creation is already canonical (`FoundingGroupCreated`);
//!   `merge_pending_commit` is a no-op there. Legacy/evolution commits still
//!   require publish-then-`confirm_published`.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use cgka_engine::account_identity_proof::{
    AccountIdentityProofRequest, AccountIdentityProofSigner,
};
use cgka_engine::KeyPackageMetadata;
use cgka_session::{AccountDeviceSession, PublishWork, SessionConfig, SessionEffects};
use cgka_traits::app_components::{
    default_group_components, encode_nostr_routing_v1, AppComponentData, NostrRoutingV1,
    NOSTR_ROUTING_COMPONENT_ID,
};
use cgka_traits::app_event::{MarmotAppEvent, MARMOT_APP_EVENT_KIND_CHAT};
use cgka_traits::engine::{
    CreateGroupRequest, GroupEvent, KeyPackage, KeyPackageSource, SendIntent,
};
use cgka_traits::engine_state::PendingStateRef;
use cgka_traits::error::PeelerError;
use cgka_traits::group::Group;
use cgka_traits::group_context::GroupContextSnapshot;
use cgka_traits::ingest::{IngestOutcome, InputRejectionCategory, PeeledMessage};
use cgka_traits::peeler::{GroupMessageMetadata, TransportPeeler};
use cgka_traits::transport::{EncryptedPayload, TransportEnvelope, TransportMessage};
use cgka_traits::types::{GroupId, MemberId, MessageId};
use nostr::prelude::*;
use serde::{Deserialize, Serialize};
use storage_sqlite::SqlCipherKey;
use transport_nostr_peeler::{NostrMlsPeeler, NostrTransportEvent, KIND_MARMOT_WELCOME_RUMOR};

use sonar_stickers::{build_sticker_ref_tag, parse_sticker_ref_tag, StickerRef};

use crate::call::signaling::CallControl;
use crate::identity::Identity;
use crate::media_crypto::{self, EncryptedMediaUpload, MediaReference};
use crate::outbox::OUTBOX_STATE_FILE_SUFFIX;
use crate::reply::{ReplyRef, ReplyTo};
use crate::{Error, Result};

/// Kind used for the inner chat rumor inside a 445 (matches White Noise / the
/// MDK examples: NIP-C7-style chat message).
pub const CHAT_RUMOR_KIND: u16 = 9;

/// Marmot KeyPackage event kind (MIP-00). nostr 0.44 has no named constant
/// for the modern addressable kind (Kind::MlsKeyPackage is the legacy 443).
pub const KEY_PACKAGE_KIND: u16 = 30443;

/// Sidecar file suffix for Sonar's relay-sync cursor beside the MDK database.
pub(crate) const SYNC_STATE_FILE_SUFFIX: &str = ".sonar-sync.json";

/// Sidecar file holding this install's kind-30443 KeyPackage slot id (the `d`
/// tag). Kept beside the MDK database so it shares the database's lifetime: a
/// wipe drops the slot along with the MLS key material it addresses.
pub(crate) const KEY_PACKAGE_SLOT_FILE_SUFFIX: &str = ".sonar-keypackage-slot";

/// Host-owned chat transcript (MDK 0.9 no longer stores plaintext app events).
const TRANSCRIPT_FILE_SUFFIX: &str = ".sonar-transcript.json";
const PARKED_INVITES_FILE_SUFFIX: &str = ".sonar-parked-invites.json";
const DROPPED_GROUPS_FILE_SUFFIX: &str = ".sonar-dropped-groups.json";

/// Documented encoding of the host's 32-byte SQLCipher key for MDK 0.9.
/// MDK 0.9 applies the string via `PRAGMA key = '<passphrase>'`, not the 0.8
/// raw-key form `PRAGMA key = "x'HEX'"`.
fn sqlcipher_passphrase(key: &[u8; 32]) -> String {
    hex::encode(key)
}

/// Result of creating a group: the group plus already-wrapped welcomes that
/// the caller must publish. MDK 0.9's peeler gift-wraps welcomes; Sonar's
/// peeler uses a current-timestamp outer wrap (White Noise `since=` window).
pub struct GroupCreation {
    pub group: Group,
    /// `(member pubkey, kind-1059 gift wrap)` pairs, one per invited member.
    pub welcomes: Vec<(PublicKey, Event)>,
}

/// Result of a group membership update that must be published by the caller.
#[derive(Debug)]
pub struct GroupMembershipUpdate {
    pub group_id: GroupId,
    /// Kind-445 commit/proposal event to publish to the group's relays.
    pub evolution_event: Event,
    /// `(member pubkey, kind-1059 gift wrap)` pairs for newly invited members.
    pub welcomes: Vec<(PublicKey, Event)>,
    /// True when MDK staged a local commit that must be confirmed after publish.
    pub requires_commit_merge: bool,
}

/// Pending group invite surfaced to the native shells for accept/decline UI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupInvite {
    /// Welcome event id. Use this as the stable accept/decline handle.
    /// For MDK 0.9 parked (not-yet-ingested) welcomes this is the kind-1059
    /// wrapper id; `accept_group_invite` ingests that wrapper.
    pub id: EventId,
    pub wrapper_id: EventId,
    pub group_id: GroupId,
    pub group_name: String,
    pub group_description: String,
    pub welcomer: PublicKey,
    pub member_count: u32,
    pub relays: Vec<RelayUrl>,
    /// Original kind-1059 gift wrap JSON. Required to ingest on accept.
    /// Empty on older sidecars that only stored ids.
    #[serde(default)]
    pub wrapper_json: String,
}

/// A reference to an encrypted media blob (Marmot MIP-04) attached to a chat
/// message — enough for the UI to render a placeholder and trigger a download.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MediaRef {
    /// Blossom URL of the ENCRYPTED blob.
    pub url: String,
    pub mime_type: String,
    pub filename: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_ms: Option<u64>,
    /// SHA-256 of the plaintext. Needed to decrypt; `None` on pre-0.9 rows.
    #[serde(default)]
    pub original_hash: Option<[u8; 32]>,
    /// ChaCha20-Poly1305 nonce. Needed to decrypt; `None` on pre-0.9 rows.
    #[serde(default)]
    pub nonce: Option<[u8; 12]>,
}

/// Local delivery state for a transcript row. Network/relay work updates this
/// state by mutating Sonar-owned outbox metadata; the UI reads it with the
/// local transcript page instead of inventing app-layer optimistic rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
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
            original_hash: Some(r.original_hash),
            nonce: Some(r.nonce),
        }
    }
}

/// Transcript-level classification of a message's content, computed once when
/// the core maps a stored message so hosts never re-parse `content` on the UI
/// render path (Signal-style: classify at load, render precomputed state).
///
/// Malformed or unknown-version control lines classify as `Text` — a parse
/// failure must never hide a message from the transcript.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum MessageClassification {
    /// Plain chat text (also the fallback for malformed control lines).
    Text,
    /// `⚡PAY|1|<id>|<sats>` payment receipt — hosts render a payment bubble.
    PayReceipt {
        payment_id: String,
        amount_sats: u64,
    },
    /// `⚡PAYDONE|…` settlement — protocol control line, hidden from the
    /// transcript by hosts (still drives ledger state).
    PayDone {
        payment_id: String,
        preimage_hex: Option<String>,
    },
    /// `☎CALL|…` signaling line — hidden from the transcript by hosts.
    CallControl,
}

impl MessageClassification {
    /// Classify a message body. Cheap prefix guards keep ordinary chat text on
    /// a no-allocation fast path.
    pub fn of(content: &str) -> Self {
        let line = content.trim_start();
        if line.starts_with("⚡PAY") {
            if let Some(pay) = crate::notification::parse_pay_receipt_line(line) {
                return Self::PayReceipt {
                    payment_id: pay.payment_id,
                    amount_sats: pay.amount_sats,
                };
            }
            if let Some(done) = crate::notification::parse_pay_done_line(line) {
                return Self::PayDone {
                    payment_id: done.payment_id,
                    preimage_hex: done.preimage_hex,
                };
            }
            return Self::Text;
        }
        if line.starts_with("☎CALL") && CallControl::parse(line).is_some() {
            return Self::CallControl;
        }
        Self::Text
    }

    /// True when every host renders this message as a transcript row.
    pub fn is_transcript_visible(&self) -> bool {
        !matches!(self, Self::PayDone { .. } | Self::CallControl)
    }
}

/// A decrypted application message, mapped to a small FFI-friendly shape.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
    /// Sticker reference, if this message is a sticker send.
    pub sticker_ref: Option<StickerRef>,
    /// Content classification (pay/call control vs plain text), precomputed so
    /// hosts never parse `content` on the render path.
    pub classification: MessageClassification,
    /// NIP-C7 reply pointer. `content` is already the display body (nevent stripped).
    pub reply: Option<ReplyRef>,
}

fn compare_message_cursor_desc(a: &ChatMessage, b: &ChatMessage) -> Ordering {
    compare_message_cursor_keys_desc(a.created_at, &a.id, b.created_at, &b.id)
}

fn compare_message_cursor_keys_desc(
    a_created_at: Timestamp,
    a_id: &EventId,
    b_created_at: Timestamp,
    b_id: &EventId,
) -> Ordering {
    b_created_at.cmp(&a_created_at).then_with(|| b_id.cmp(a_id))
}

fn is_before_message_cursor(
    created_at_secs: u64,
    id: &EventId,
    before_secs: Option<u64>,
    before_id: Option<&EventId>,
) -> bool {
    let Some(cursor_secs) = before_secs else {
        return true;
    };
    created_at_secs < cursor_secs
        || (created_at_secs == cursor_secs && before_id.is_some_and(|cursor_id| id < cursor_id))
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
    /// A decrypted chat message (already persisted in the local transcript).
    Message(ChatMessage),
    /// A group-membership/welcome change was applied; no chat content.
    GroupUpdated(GroupId),
    /// A multi-member welcome was stored and is waiting for user acceptance.
    GroupInvitePending(GroupId),
    /// Processing a proposal produced an auto-commit that the caller must
    /// publish and merge before the group converges.
    GroupProposal(GroupMembershipUpdate),
    /// Processing recorded a terminal failure. The relay sync layer must mark
    /// it processed and move on.
    Failed,
    /// A join request was received for a group we administer.
    JoinRequest(crate::invite_link::JoinRequest),
    /// The event was valid but produced nothing actionable (duplicates,
    /// ignored proposals, non-Marmot gift wraps, ...).
    None,
}

/// Max 2-member welcomes auto-accepted per window before the known-sender
/// check has to vouch for the welcomer; beyond both, they surface as pending
/// invites (accept/decline UI).
pub const UNKNOWN_DM_AUTOACCEPT_MAX: usize = 5;
/// Window for [`UNKNOWN_DM_AUTOACCEPT_MAX`], in seconds.
pub const UNKNOWN_DM_AUTOACCEPT_WINDOW_SECS: u64 = 10 * 60;
/// Max ACTIVE groups shared with the SAME welcomer whose further welcomes may
/// bypass the budget.
pub const KNOWN_SENDER_GROUP_CAP: usize = 3;
/// Hard ceiling on PARKED pending invites of ANY size.
pub const PENDING_INVITE_CAP: usize = 25;
/// Ceiling on parked invites for a welcomer we already share an active group
/// with.
pub const KNOWN_SENDER_PENDING_INVITE_CAP: usize = 50;
/// Ceiling on groups INSPECTED by [`MarmotEngine::shared_active_groups_with`].
pub const SHARED_GROUP_SCAN_CAP: usize = 128;

const DM_AUTOACCEPT_FILE_SUFFIX: &str = ".dm-autoaccepts.json";
const DM_AUTOACCEPT_TMP_FILE_SUFFIX: &str = ".dm-autoaccepts.json.tmp";

struct DmAutoacceptBudget {
    admits: std::collections::VecDeque<u64>,
    sidecar: Option<PathBuf>,
}

impl DmAutoacceptBudget {
    fn in_memory() -> Self {
        Self {
            admits: std::collections::VecDeque::new(),
            sidecar: None,
        }
    }

    fn load(db_path: &Path) -> Self {
        let sidecar = dm_autoaccept_sidecar(db_path);
        let admits = match std::fs::read(&sidecar) {
            Ok(bytes) => match serde_json::from_slice::<Vec<u64>>(&bytes) {
                Ok(entries) => std::collections::VecDeque::from(entries),
                Err(e) => {
                    tracing::warn!(
                        error = %e,
                        "dm-autoaccept sidecar unparsable; treating the window as exhausted"
                    );
                    Self::exhausted_window()
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => std::collections::VecDeque::new(),
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    "dm-autoaccept sidecar unreadable; treating the window as exhausted"
                );
                Self::exhausted_window()
            }
        };
        Self {
            admits,
            sidecar: Some(sidecar),
        }
    }

    fn exhausted_window() -> std::collections::VecDeque<u64> {
        let now_secs = unix_now_secs();
        std::collections::VecDeque::from(vec![now_secs; UNKNOWN_DM_AUTOACCEPT_MAX])
    }

    fn prune(&mut self, now_secs: u64) {
        self.admits
            .retain(|t| *t <= now_secs && now_secs - *t < UNKNOWN_DM_AUTOACCEPT_WINDOW_SECS);
    }

    fn has_room(&mut self, now_secs: u64) -> bool {
        self.refresh_from_disk();
        self.prune(now_secs);
        self.admits.len() < UNKNOWN_DM_AUTOACCEPT_MAX
    }

    fn refresh_from_disk(&mut self) {
        let Some(sidecar) = &self.sidecar else { return };
        let Some(disk) = std::fs::read(sidecar)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Vec<u64>>(&bytes).ok())
        else {
            return;
        };
        if disk.is_empty() {
            return;
        }
        let mut merged = disk;
        merged.sort_unstable();
        self.admits = merged.into();
    }

    fn persist(&self) -> std::io::Result<()> {
        let Some(sidecar) = &self.sidecar else {
            return Ok(());
        };
        let admits: Vec<u64> = self.admits.iter().copied().collect();
        let bytes = serde_json::to_vec(&admits)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        let tmp = sidecar.with_extension("json.tmp");
        std::fs::write(&tmp, bytes).and_then(|()| std::fs::rename(&tmp, sidecar))
    }

    fn reserve(&mut self, now_secs: u64) -> std::io::Result<()> {
        self.refresh_from_disk();
        self.prune(now_secs);
        if self.admits.len() >= UNKNOWN_DM_AUTOACCEPT_MAX {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "dm auto-accept budget exhausted",
            ));
        }
        self.admits.push_back(now_secs);
        match self.persist() {
            Ok(()) => Ok(()),
            Err(e) => {
                self.drop_one(now_secs);
                Err(e)
            }
        }
    }

    fn release(&mut self, now_secs: u64) {
        self.drop_one(now_secs);
        if let Err(e) = self.persist() {
            tracing::warn!(
                error = %e,
                "dm-autoaccept rollback write failed; the slot stays consumed"
            );
        }
    }

    fn drop_one(&mut self, now_secs: u64) {
        if let Some(pos) = self.admits.iter().rposition(|&t| t == now_secs) {
            self.admits.remove(pos);
        }
    }
}

fn dm_autoaccept_sidecar(db_path: &Path) -> PathBuf {
    let name = db_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default();
    db_path.with_file_name(format!("{name}{DM_AUTOACCEPT_FILE_SUFFIX}"))
}

fn unix_now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

enum DmWelcomeDecision {
    AutoAccept { consume_budget: bool },
    Park,
    Drop,
}

/// Optional rumor tags our peeler adds so the receiver can park vs auto-accept
/// without ingesting. White Noise welcomes omit them; unknown size is treated
/// as a 2-member DM. Extra tags are ignored by MDK's peeler (it only requires
/// unique `e` and `relays`).
#[derive(Clone, Debug)]
struct WelcomeRumorHint {
    name: String,
    description: String,
    member_count: u32,
}

tokio::task_local! {
    static WELCOME_RUMOR_HINT: WelcomeRumorHint;
}

struct WelcomeRumorMeta {
    name: String,
    description: String,
    member_count: Option<u32>,
    group_id: Option<GroupId>,
    relays: Vec<RelayUrl>,
}

fn welcome_rumor_meta(rumor: &UnsignedEvent) -> WelcomeRumorMeta {
    let mut meta = WelcomeRumorMeta {
        name: String::new(),
        description: String::new(),
        member_count: None,
        group_id: None,
        relays: Vec::new(),
    };
    for tag in rumor.tags.iter() {
        let slice = tag.as_slice();
        let Some(name) = slice.first().map(String::as_str) else {
            continue;
        };
        match name {
            "name" => {
                if let Some(value) = slice.get(1) {
                    meta.name = value.clone();
                }
            }
            "description" => {
                if let Some(value) = slice.get(1) {
                    meta.description = value.clone();
                }
            }
            "members" | "member_count" => {
                meta.member_count = slice.get(1).and_then(|v| v.parse().ok());
            }
            "h" | "group" => {
                if let Some(hex_id) = slice.get(1) {
                    if let Ok(bytes) = hex::decode(hex_id) {
                        if !bytes.is_empty() {
                            meta.group_id = Some(GroupId::new(bytes));
                        }
                    }
                }
            }
            "relays" => {
                meta.relays = slice
                    .iter()
                    .skip(1)
                    .filter_map(|url| RelayUrl::parse(url).ok())
                    .collect();
            }
            _ => {}
        }
    }
    meta
}

fn parked_group_id_for_wrapper(wrapper: &Event, meta: &WelcomeRumorMeta) -> GroupId {
    meta.group_id
        .clone()
        .unwrap_or_else(|| GroupId::new(wrapper.id.as_bytes().to_vec()))
}

struct NostrProofSigner {
    keys: Keys,
}

impl AccountIdentityProofSigner for NostrProofSigner {
    fn sign_account_identity_proof(
        &self,
        request: &AccountIdentityProofRequest,
    ) -> std::result::Result<[u8; 64], String> {
        if self.keys.public_key().to_bytes().as_slice() != request.account_identity.as_slice() {
            return Err("request account identity does not match session key".into());
        }
        let event = request.proof_event().and_then(|event| {
            event
                .sign_with_keys(&self.keys)
                .map_err(|err| err.to_string())
        })?;
        request.signature_from_signed_event(event)
    }
}

/// Peeler that delegates MLS wrap/peel to MDK's Nostr peeler but stamps
/// welcome gift wraps with `Timestamp::now()` so White Noise `since=` fetches
/// see them. `EventBuilder::gift_wrap` randomizes `created_at` into the past.
struct SonarWelcomePeeler {
    inner: NostrMlsPeeler,
    keys: Keys,
}

impl SonarWelcomePeeler {
    fn new(keys: Keys) -> Self {
        let inner = NostrMlsPeeler::new().with_welcome_signer(keys.clone());
        Self { inner, keys }
    }

    async fn wrap_welcome_now(
        &self,
        payload: &EncryptedPayload,
        recipient: &MemberId,
        metadata: &cgka_traits::engine::WelcomeMetadata,
    ) -> Result<TransportMessage> {
        if !payload.aad.is_empty() {
            return Err(Error::Mdk(
                "Nostr welcome wrap does not currently encode payload AAD".into(),
            ));
        }
        if payload.ciphertext.is_empty() {
            return Err(Error::Mdk("welcome payload cannot be empty".into()));
        }
        if metadata.relays.is_empty() {
            return Err(Error::Mdk(
                "welcome relays tag must contain at least one relay".into(),
            ));
        }
        let recipient_pk = PublicKey::from_slice(recipient.as_slice())
            .map_err(|e| Error::Mdk(format!("recipient MemberId is not a Nostr pubkey: {e}")))?;
        let mut tags = vec![
            Tag::custom(
                TagKind::custom("e"),
                [hex::encode(metadata.key_package_event_id.as_slice())],
            ),
            Tag::custom(
                TagKind::custom("relays"),
                metadata.relays.iter().map(|relay| relay.as_str()),
            ),
        ];
        if let Ok(hint) = WELCOME_RUMOR_HINT.try_with(|hint| hint.clone()) {
            if !hint.name.is_empty() {
                tags.push(Tag::custom(TagKind::custom("name"), [hint.name]));
            }
            if !hint.description.is_empty() {
                tags.push(Tag::custom(
                    TagKind::custom("description"),
                    [hint.description],
                ));
            }
            if hint.member_count > 0 {
                tags.push(Tag::custom(
                    TagKind::custom("members"),
                    [hint.member_count.to_string()],
                ));
            }
        }
        let rumor = EventBuilder::new(
            Kind::Custom(KIND_MARMOT_WELCOME_RUMOR),
            BASE64.encode(&payload.ciphertext),
        )
        .tags(tags)
        .build(self.keys.public_key());
        let wrapped =
            gift_wrap_with_current_timestamp_async(&self.keys, &recipient_pk, rumor).await?;
        nostr_event_to_transport(&wrapped)
    }
}

#[async_trait]
impl TransportPeeler for SonarWelcomePeeler {
    async fn peel_group_message(
        &self,
        msg: &TransportMessage,
        ctx: &GroupContextSnapshot,
    ) -> std::result::Result<PeeledMessage, PeelerError> {
        self.inner.peel_group_message(msg, ctx).await
    }

    async fn peel_welcome(
        &self,
        msg: &TransportMessage,
    ) -> std::result::Result<PeeledMessage, PeelerError> {
        self.inner.peel_welcome(msg).await
    }

    async fn wrap_group_message(
        &self,
        payload: &EncryptedPayload,
        ctx: &GroupContextSnapshot,
    ) -> std::result::Result<TransportMessage, PeelerError> {
        self.inner.wrap_group_message(payload, ctx).await
    }

    async fn wrap_group_message_with_metadata(
        &self,
        payload: &EncryptedPayload,
        ctx: &GroupContextSnapshot,
        metadata: &GroupMessageMetadata,
    ) -> std::result::Result<TransportMessage, PeelerError> {
        self.inner
            .wrap_group_message_with_metadata(payload, ctx, metadata)
            .await
    }

    async fn wrap_welcome(
        &self,
        payload: &EncryptedPayload,
        recipient: &MemberId,
    ) -> std::result::Result<TransportMessage, PeelerError> {
        let _ = (payload, recipient);
        Err(PeelerError::MissingContext {
            label: "welcome_metadata".into(),
        })
    }

    async fn wrap_welcome_with_metadata(
        &self,
        payload: &EncryptedPayload,
        recipient: &MemberId,
        metadata: &cgka_traits::engine::WelcomeMetadata,
    ) -> std::result::Result<TransportMessage, PeelerError> {
        self.wrap_welcome_now(payload, recipient, metadata)
            .await
            .map_err(|e| PeelerError::WrapFailed(e.to_string()))
    }
}

async fn gift_wrap_with_current_timestamp_async(
    keys: &Keys,
    receiver: &PublicKey,
    rumor: UnsignedEvent,
) -> Result<Event> {
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

/// The Marmot engine: one per identity, owns MLS group state via MDK 0.9.
pub struct MarmotEngine {
    /// `None` while an async method owns the session across `.await`
    /// (so we never hold `std::sync::MutexGuard` across an await point).
    session: Mutex<Option<AccountDeviceSession>>,
    identity: Identity,
    dm_autoaccept_budget: Mutex<DmAutoacceptBudget>,
    db_path: Option<PathBuf>,
    key_package_slot_memo: Mutex<Option<String>>,
    pending_refs: Mutex<HashMap<GroupId, PendingStateRef>>,
    parked_invites: Mutex<HashMap<EventId, GroupInvite>>,
    dropped_groups: Mutex<HashSet<GroupId>>,
    transcript: Mutex<HashMap<GroupId, Vec<ChatMessage>>>,
    /// Keeps the temp SQLCipher file alive for [`Self::in_memory`].
    _tempdir: Option<tempfile::TempDir>,
}

/// Owns `AccountDeviceSession` across `.await` without holding a std mutex
/// guard, so engine futures stay `Send`.
struct SessionLease<'a> {
    engine: &'a MarmotEngine,
    session: Option<AccountDeviceSession>,
}

impl SessionLease<'_> {
    fn get_mut(&mut self) -> &mut AccountDeviceSession {
        self.session.as_mut().expect("session lease still held")
    }
}

impl Drop for SessionLease<'_> {
    fn drop(&mut self) {
        if let Some(session) = self.session.take() {
            self.engine.replace_session(session);
        }
    }
}

impl MarmotEngine {
    /// In-memory engine. Volatile — state is lost on drop. MDK 0.9 has no
    /// memory storage, so this is a SQLCipher file in a [`tempfile::TempDir`].
    pub fn in_memory(identity: Identity) -> Self {
        Self::open_in_memory(identity).expect("OS RNG and temp SQLCipher available")
    }

    fn in_memory_inner(identity: Identity) -> Result<Self> {
        Self::open_in_memory(identity)
    }

    fn open_in_memory(identity: Identity) -> Result<Self> {
        let tempdir = tempfile::TempDir::new()
            .map_err(|e| Error::Storage(format!("in-memory tempdir: {e}")))?;
        let db_path = tempdir.path().join("marmot.sqlite");
        let mut key = [0u8; 32];
        getrandom::getrandom(&mut key)?;
        let mut engine = Self::open_session(identity, &db_path, key, false)?;
        engine._tempdir = Some(tempdir);
        engine.db_path = None;
        engine.dm_autoaccept_budget = Mutex::new(DmAutoacceptBudget::in_memory());
        Ok(engine)
    }

    /// Persistent engine backed by an encrypted SQLCipher database at `db_path`.
    ///
    /// `key` is the 32-byte host key. It is encoded as lowercase hex and passed
    /// to MDK 0.9 as a SQLCipher passphrase (`PRAGMA key = '<hex>'`), not the
    /// 0.8 raw-key form `x'<hex>'`. Existing 0.8 databases therefore cannot be
    /// opened in place.
    ///
    /// Group hydration is deferred so chat-list first paint does not wait on
    /// every MLS group. Sends/ingest hydrate on demand.
    pub fn persistent(
        identity: Identity,
        db_path: impl AsRef<Path>,
        key: [u8; 32],
    ) -> Result<Self> {
        crate::sqlcipher_runtime::ensure_no_checkpoint_on_close()?;
        let path = db_path.as_ref();
        match Self::open_session(identity.clone(), path, key, true) {
            Ok(engine) => Ok(engine),
            Err(e) if path.exists() && is_unencrypted_sqlite(path) => {
                let detail = e.to_string();
                Self::wipe(path)?;
                let engine = Self::open_session(identity, path, key, true).map_err(|e2| {
                    Error::Storage(format!(
                        "recreate after unusable DB failed: {e2} (original: {detail})"
                    ))
                })?;
                tracing::warn!(
                    "marmot: discarded an unencrypted on-disk database and recreated it \
                     encrypted (original open error: {detail})"
                );
                Ok(engine)
            }
            Err(e) if path.exists() => Err(Error::Storage(format!(
                "MDK 0.9 cannot open this store (protocol migration required): {e}"
            ))),
            Err(e) => Err(e),
        }
    }

    fn open_session(
        identity: Identity,
        db_path: &Path,
        key: [u8; 32],
        defer_hydration: bool,
    ) -> Result<Self> {
        let keys = identity.keys().clone();
        let peeler = Box::new(SonarWelcomePeeler::new(keys.clone()));
        let sqlcipher_key = SqlCipherKey::new(sqlcipher_passphrase(&key))
            .map_err(|e| Error::Storage(e.to_string()))?;
        let mut config = SessionConfig::new(
            db_path.to_path_buf(),
            sqlcipher_key,
            identity.public_key().to_bytes().to_vec(),
            peeler,
        )
        .account_identity_proof_signer(Arc::new(NostrProofSigner { keys }))
        .supported_app_components(
            default_group_components()
                .into_iter()
                .chain(std::iter::once(NOSTR_ROUTING_COMPONENT_ID)),
        );
        if defer_hydration {
            config = config.defer_group_hydration();
        }
        let session = AccountDeviceSession::open(config)?;
        let parked = load_parked(db_path);
        let dropped = load_dropped(db_path);
        let transcript = load_transcript(db_path);
        Ok(Self {
            session: Mutex::new(Some(session)),
            identity,
            dm_autoaccept_budget: Mutex::new(DmAutoacceptBudget::load(db_path)),
            db_path: Some(db_path.to_path_buf()),
            key_package_slot_memo: Mutex::new(None),
            pending_refs: Mutex::new(HashMap::new()),
            parked_invites: Mutex::new(parked),
            dropped_groups: Mutex::new(dropped),
            transcript: Mutex::new(transcript),
            _tempdir: None,
        })
    }

    pub fn identity(&self) -> &Identity {
        &self.identity
    }

    fn take_session(&self) -> Option<AccountDeviceSession> {
        self.session
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
    }

    fn replace_session(&self, session: AccountDeviceSession) {
        let mut slot = self
            .session
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        debug_assert!(slot.is_none(), "session replaced while still borrowed");
        *slot = Some(session);
    }

    /// Wait until the session is free, then lease it for the duration of an
    /// async MDK call. The session is returned on drop even if the caller
    /// panics after the lease is taken.
    async fn lease_session(&self) -> SessionLease<'_> {
        loop {
            if let Some(session) = self.take_session() {
                return SessionLease {
                    engine: self,
                    session: Some(session),
                };
            }
            tokio::task::yield_now().await;
        }
    }

    fn with_session<R>(&self, f: impl FnOnce(&AccountDeviceSession) -> Result<R>) -> Result<R> {
        loop {
            {
                let slot = self
                    .session
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if let Some(session) = slot.as_ref() {
                    return f(session);
                }
            }
            std::thread::yield_now();
        }
    }

    fn with_session_mut<R>(
        &self,
        f: impl FnOnce(&mut AccountDeviceSession) -> Result<R>,
    ) -> Result<R> {
        loop {
            {
                let mut slot = self
                    .session
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if let Some(session) = slot.as_mut() {
                    return f(session);
                }
            }
            std::thread::yield_now();
        }
    }

    fn dm_welcome_decision(
        &self,
        seal_sender: &PublicKey,
        welcomer: &PublicKey,
        now_secs: u64,
    ) -> DmWelcomeDecision {
        if *seal_sender != *welcomer {
            tracing::warn!(
                "welcome seal author {} != welcomer {}; parking instead of auto-accepting",
                seal_sender,
                welcomer
            );
            return self.park_or_drop_welcome(welcomer);
        }
        let has_room = self
            .dm_autoaccept_budget
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .has_room(now_secs);
        if has_room {
            return DmWelcomeDecision::AutoAccept {
                consume_budget: true,
            };
        }
        let shared = self.shared_active_groups_with(welcomer, KNOWN_SENDER_GROUP_CAP);
        if shared > 0 && shared < KNOWN_SENDER_GROUP_CAP {
            return DmWelcomeDecision::AutoAccept {
                consume_budget: false,
            };
        }
        tracing::info!(
            "unknown-sender DM welcome from {} not auto-accepted (budget exhausted)",
            welcomer
        );
        self.park_or_drop_welcome(welcomer)
    }

    fn shared_active_groups_with(&self, welcomer: &PublicKey, limit: usize) -> usize {
        let Ok(groups) = self.groups() else { return 0 };
        let mut shared = 0usize;
        for group in groups.iter().take(SHARED_GROUP_SCAN_CAP) {
            if shared >= limit {
                break;
            }
            if self
                .members(&group.id)
                .ok()
                .is_some_and(|members| members.contains(welcomer))
            {
                shared += 1;
            }
        }
        shared
    }

    fn park_or_drop_welcome(&self, welcomer: &PublicKey) -> DmWelcomeDecision {
        let known_sender = self.shared_active_groups_with(welcomer, 1) > 0;
        let cap = if known_sender {
            KNOWN_SENDER_PENDING_INVITE_CAP
        } else {
            PENDING_INVITE_CAP
        };
        let parked = self
            .parked_invites
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .len();
        if parked >= cap {
            tracing::warn!(
                welcomer = %welcomer,
                cap,
                known_sender,
                "pending-invite ceiling hit; declining a welcome without surfacing it"
            );
            DmWelcomeDecision::Drop
        } else {
            DmWelcomeDecision::Park
        }
    }

    fn reserve_dm_autoaccept(&self, now_secs: u64) -> std::io::Result<()> {
        self.dm_autoaccept_budget
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .reserve(now_secs)
    }

    fn release_dm_autoaccept(&self, now_secs: u64) {
        self.dm_autoaccept_budget
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .release(now_secs);
    }

    /// Erase the on-disk SQLCipher database at `db_path` and its sidecar files.
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

    fn key_package_slot_path(&self) -> Option<PathBuf> {
        Some(key_package_slot_path_for(self.db_path.as_ref()?))
    }

    fn load_key_package_slot(&self) -> Result<Option<String>> {
        if let Ok(memo) = self.key_package_slot_memo.lock() {
            if let Some(d) = memo.as_ref() {
                return Ok(Some(d.clone()));
            }
        }
        let Some(path) = self.key_package_slot_path() else {
            return Ok(Some(self.derived_key_package_slot()));
        };
        let raw = match std::fs::read_to_string(&path) {
            Ok(raw) => raw,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => {
                tracing::warn!(%e, "marmot: cannot read KeyPackage slot, skipping publish");
                return Err(Error::Storage(format!("read KeyPackage slot: {e}")));
            }
        };
        let d = raw.trim().to_string();
        if validate_existing_d_tag(&d).is_err() {
            tracing::warn!("marmot: stored KeyPackage slot id is malformed, minting a new slot");
            return Ok(None);
        }
        if let Ok(mut memo) = self.key_package_slot_memo.lock() {
            *memo = Some(d.clone());
        }
        Ok(Some(d))
    }

    fn derived_key_package_slot(&self) -> String {
        use nostr::hashes::{sha256::Hash as Sha256Hash, Hash as _};
        let mut input = b"sonar-keypackage-slot-v1:".to_vec();
        input.extend_from_slice(self.identity.public_key().to_hex().as_bytes());
        Sha256Hash::hash(&input).to_string()
    }

    fn store_key_package_slot(&self, d: &str) {
        if let Ok(mut memo) = self.key_package_slot_memo.lock() {
            *memo = Some(d.to_string());
        }
        let Some(path) = self.key_package_slot_path() else {
            return;
        };
        let tmp = key_package_slot_tmp_path(&path);
        if std::fs::write(&tmp, d).is_ok() {
            if std::fs::rename(&tmp, &path).is_err() {
                let _ = std::fs::remove_file(&tmp);
            }
        }
    }

    /// Build a signed kind-30443 KeyPackage event, ready to publish to `relays`.
    pub async fn key_package_event(&self, relays: Vec<RelayUrl>) -> Result<Event> {
        let _ = relays;
        let mut lease = self.lease_session().await;
        let kp = lease.get_mut().fresh_key_package().await?;
        let meta = lease.get_mut().key_package_metadata(&kp)?;
        drop(lease);
        let d_tag = match self.load_key_package_slot()? {
            Some(d) => d,
            None => meta.key_package_ref_hex.clone(),
        };
        self.store_key_package_slot(&d_tag);
        let event = key_package_to_event(&self.identity, &kp, &meta, &d_tag)?;
        Ok(event)
    }

    pub async fn create_group(
        &self,
        name: &str,
        member_key_packages: Vec<Event>,
        relays: Vec<RelayUrl>,
    ) -> Result<GroupCreation> {
        self.create_group_with_description(name, "", member_key_packages, relays)
            .await
    }

    pub(crate) async fn create_group_with_description(
        &self,
        name: &str,
        description: &str,
        member_key_packages: Vec<Event>,
        relays: Vec<RelayUrl>,
    ) -> Result<GroupCreation> {
        let relay_urls: Vec<String> = if relays.is_empty() {
            // Local-only / no-relay clients still need a wrap-valid relay list
            // in the founding Nostr routing component (0.9 peeler requires it).
            vec!["wss://relay.example.com".to_owned()]
        } else {
            relays.iter().map(|r| r.to_string()).collect()
        };
        let members = member_key_packages
            .iter()
            .map(key_package_from_event)
            .collect::<Result<Vec<_>>>()?;
        let mut nostr_group_id = [0u8; 32];
        getrandom::getrandom(&mut nostr_group_id)?;
        let routing =
            NostrRoutingV1::new(nostr_group_id, relay_urls).map_err(Error::InvalidInput)?;
        let routing_bytes = encode_nostr_routing_v1(&routing).map_err(Error::InvalidInput)?;
        let initial_admins = member_key_packages
            .iter()
            .map(|ev| MemberId::new(ev.pubkey.to_bytes().to_vec()))
            .collect();
        let req = CreateGroupRequest {
            name: name.to_owned(),
            description: description.to_owned(),
            members,
            required_features: Vec::new(),
            app_components: vec![AppComponentData {
                component_id: NOSTR_ROUTING_COMPONENT_ID,
                data: routing_bytes,
            }],
            initial_admins,
        };
        let hint = WelcomeRumorHint {
            name: name.to_owned(),
            description: description.to_owned(),
            member_count: (member_key_packages.len() + 1) as u32,
        };
        let mut lease = self.lease_session().await;
        let created = WELCOME_RUMOR_HINT
            .scope(hint, lease.get_mut().create_group(req))
            .await?;
        let group = lease.get_mut().group_record(&created.group_id)?;
        let (welcomes, pending) = publish_work_welcomes(&created.effects)?;
        drop(lease);
        if let Some(pending) = pending {
            self.pending_refs
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .insert(created.group_id.clone(), pending);
        }
        Ok(GroupCreation { group, welcomes })
    }

    pub async fn add_members(
        &self,
        group_id: &GroupId,
        member_key_packages: Vec<Event>,
    ) -> Result<GroupMembershipUpdate> {
        let key_packages = member_key_packages
            .iter()
            .map(key_package_from_event)
            .collect::<Result<Vec<_>>>()?;
        self.send_intent(
            SendIntent::Invite {
                group_id: group_id.clone(),
                key_packages,
                initial_admins: Vec::new(),
            },
            true,
        )
        .await
    }

    pub async fn remove_members(
        &self,
        group_id: &GroupId,
        members: &[PublicKey],
    ) -> Result<GroupMembershipUpdate> {
        let members = members
            .iter()
            .map(|pk| MemberId::new(pk.to_bytes().to_vec()))
            .collect();
        self.send_intent(
            SendIntent::RemoveMembers {
                group_id: group_id.clone(),
                members,
            },
            true,
        )
        .await
    }

    pub async fn self_demote(&self, group_id: &GroupId) -> Result<GroupMembershipUpdate> {
        // MDK 0.9 has no self-demote commit. Leave (MIP-03 SelfRemove) is the
        // membership-exit path; keep this method so hosts still compile.
        self.leave_group(group_id).await
    }

    pub async fn leave_group(&self, group_id: &GroupId) -> Result<GroupMembershipUpdate> {
        self.send_intent(
            SendIntent::Leave {
                group_id: group_id.clone(),
            },
            false,
        )
        .await
    }

    async fn send_intent(
        &self,
        intent: SendIntent,
        default_requires_merge: bool,
    ) -> Result<GroupMembershipUpdate> {
        let group_id = match &intent {
            SendIntent::Invite { group_id, .. }
            | SendIntent::RemoveMembers { group_id, .. }
            | SendIntent::Leave { group_id, .. }
            | SendIntent::AppMessage { group_id, .. } => group_id.clone(),
            _ => {
                return Err(Error::InvalidInput(
                    "unsupported membership send intent".into(),
                ))
            }
        };
        let invite_hint = match &intent {
            SendIntent::Invite {
                group_id,
                key_packages,
                ..
            } => {
                let extra = key_packages.len() as u32;
                let existing = self.members(group_id).map(|m| m.len() as u32).unwrap_or(0);
                let (name, description) = self
                    .with_session(|session| Ok(session.group_record(group_id).ok()))
                    .ok()
                    .flatten()
                    .map(|g| (g.name, g.description))
                    .unwrap_or_default();
                Some(WelcomeRumorHint {
                    name,
                    description,
                    member_count: existing.saturating_add(extra),
                })
            }
            _ => None,
        };
        let mut lease = self.lease_session().await;
        let _ = lease.get_mut().ensure_group_hydrated(&group_id);
        let effects = if let Some(hint) = invite_hint {
            WELCOME_RUMOR_HINT
                .scope(hint, lease.get_mut().send(intent))
                .await?
        } else {
            lease.get_mut().send(intent).await?
        };
        drop(lease);
        self.effects_to_membership_update(&group_id, effects, default_requires_merge)
    }

    fn effects_to_membership_update(
        &self,
        group_id: &GroupId,
        effects: SessionEffects,
        default_requires_merge: bool,
    ) -> Result<GroupMembershipUpdate> {
        let mut evolution_event = None;
        let mut welcomes = Vec::new();
        let mut requires_commit_merge = false;
        for work in &effects.publish {
            match work {
                PublishWork::GroupEvolution {
                    msg,
                    welcomes: w,
                    pending,
                } => {
                    evolution_event = Some(transport_to_event(msg)?);
                    welcomes = wrapped_welcomes(w)?;
                    self.store_pending(group_id.clone(), *pending);
                    requires_commit_merge = true;
                }
                PublishWork::GroupCreated {
                    welcomes: w,
                    pending,
                } => {
                    welcomes = wrapped_welcomes(w)?;
                    self.store_pending(group_id.clone(), *pending);
                    requires_commit_merge = true;
                }
                PublishWork::FoundingGroupCreated { welcomes: w } => {
                    welcomes = wrapped_welcomes(w)?;
                    requires_commit_merge = false;
                }
                PublishWork::Proposal { msg, .. } | PublishWork::AutoPublish { msg, .. } => {
                    evolution_event = Some(transport_to_event(msg)?);
                    if let PublishWork::AutoPublish { pending, .. } = work {
                        self.store_pending(group_id.clone(), *pending);
                        requires_commit_merge = true;
                    }
                }
                PublishWork::ApplicationMessage { msg, .. } => {
                    evolution_event = Some(transport_to_event(msg)?);
                }
            }
        }
        let evolution_event = evolution_event
            .ok_or_else(|| Error::Mdk("membership update produced no publishable event".into()))?;
        Ok(GroupMembershipUpdate {
            group_id: group_id.clone(),
            evolution_event,
            welcomes,
            requires_commit_merge: requires_commit_merge || default_requires_merge && false,
        })
    }

    fn store_pending(&self, group_id: GroupId, pending: PendingStateRef) {
        self.pending_refs
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(group_id, pending);
    }

    pub async fn merge_pending_commit(&self, group_id: &GroupId) -> Result<()> {
        let pending = self
            .pending_refs
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(group_id);
        let Some(pending) = pending else {
            return Ok(());
        };
        let mut lease = self.lease_session().await;
        lease.get_mut().confirm_published(pending).await?;
        Ok(())
    }

    pub async fn clear_pending_commit(&self, group_id: &GroupId) -> Result<()> {
        let pending = self
            .pending_refs
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(group_id);
        let Some(pending) = pending else {
            return Ok(());
        };
        let mut lease = self.lease_session().await;
        lease.get_mut().publish_failed(pending).await?;
        Ok(())
    }

    pub async fn gift_wrap_welcome(
        &self,
        receiver: &PublicKey,
        rumor: UnsignedEvent,
    ) -> Result<Event> {
        gift_wrap_with_current_timestamp_async(self.identity.keys(), receiver, rumor).await
    }

    pub async fn create_text_message(&self, group_id: &GroupId, text: &str) -> Result<Event> {
        self.create_text_message_with_reply(group_id, text, None)
            .await
    }

    pub async fn create_text_message_with_reply(
        &self,
        group_id: &GroupId,
        text: &str,
        reply: Option<&ReplyTo>,
    ) -> Result<Event> {
        self.create_app_event(group_id, text, Vec::new(), reply)
            .await
    }

    async fn create_app_event(
        &self,
        group_id: &GroupId,
        text: &str,
        extra_tags: Vec<Tag>,
        reply: Option<&ReplyTo>,
    ) -> Result<Event> {
        let rumor = self.kind9_rumor(text, extra_tags, reply)?;
        let payload = marmot_app_event_from_rumor(&rumor)?;
        let mut lease = self.lease_session().await;
        let _ = lease.get_mut().ensure_group_hydrated(group_id);
        let effects = lease
            .get_mut()
            .send(SendIntent::AppMessage {
                group_id: group_id.clone(),
                payload,
            })
            .await?;
        drop(lease);
        let event = event_from_app_publish(&effects)?;
        if let Some(msg) = self.chat_from_app_rumor(group_id, &rumor, &event, true) {
            self.store_chat(msg);
        }
        Ok(event)
    }

    pub async fn create_and_process_text_message(
        &self,
        group_id: &GroupId,
        text: &str,
    ) -> Result<(Event, Incoming)> {
        let event = self.create_text_message(group_id, text).await?;
        let incoming = self
            .lookup_chat(&event.id)
            .map(Incoming::Message)
            .unwrap_or(Incoming::None);
        Ok((event, incoming))
    }

    pub async fn create_and_process_text_message_with_reply(
        &self,
        group_id: &GroupId,
        text: &str,
        reply: Option<&ReplyTo>,
    ) -> Result<(Event, Incoming)> {
        let event = self
            .create_text_message_with_reply(group_id, text, reply)
            .await?;
        let incoming = overlay_reply_preview(
            self.lookup_chat(&event.id)
                .map(Incoming::Message)
                .unwrap_or(Incoming::None),
            reply,
        );
        Ok((event, incoming))
    }

    pub async fn create_sticker_message(
        &self,
        group_id: &GroupId,
        sticker_ref: &StickerRef,
    ) -> Result<Event> {
        self.create_sticker_message_with_reply(group_id, sticker_ref, None)
            .await
    }

    pub async fn create_sticker_message_with_reply(
        &self,
        group_id: &GroupId,
        sticker_ref: &StickerRef,
        reply: Option<&ReplyTo>,
    ) -> Result<Event> {
        let tag = build_sticker_ref_tag(sticker_ref);
        self.create_app_event(group_id, "", vec![tag], reply).await
    }

    pub async fn create_and_process_sticker_message(
        &self,
        group_id: &GroupId,
        sticker_ref: &StickerRef,
    ) -> Result<(Event, Incoming)> {
        let event = self.create_sticker_message(group_id, sticker_ref).await?;
        let incoming = self
            .lookup_chat(&event.id)
            .map(Incoming::Message)
            .unwrap_or(Incoming::None);
        Ok((event, incoming))
    }

    pub async fn create_and_process_sticker_message_with_reply(
        &self,
        group_id: &GroupId,
        sticker_ref: &StickerRef,
        reply: Option<&ReplyTo>,
    ) -> Result<(Event, Incoming)> {
        let event = self
            .create_sticker_message_with_reply(group_id, sticker_ref, reply)
            .await?;
        let incoming = overlay_reply_preview(
            self.lookup_chat(&event.id)
                .map(Incoming::Message)
                .unwrap_or(Incoming::None),
            reply,
        );
        Ok((event, incoming))
    }

    pub fn encrypt_media(
        &self,
        group_id: &GroupId,
        data: &[u8],
        mime: &str,
        filename: &str,
    ) -> Result<EncryptedMediaUpload> {
        let secret = self.media_exporter_secret(group_id)?;
        media_crypto::encrypt_for_upload(&secret, data, mime, filename)
    }

    fn media_exporter_secret(&self, group_id: &GroupId) -> Result<Vec<u8>> {
        self.with_session(|session| {
            let secret = session.exporter_secret(
                group_id,
                media_crypto::ENCRYPTED_MEDIA_EXPORTER_LABEL,
                32,
            )?;
            Ok((*secret).clone())
        })
    }

    pub async fn create_media_event(
        &self,
        group_id: &GroupId,
        upload: &EncryptedMediaUpload,
        url: &str,
        caption: &str,
    ) -> Result<Event> {
        self.create_media_event_multi(group_id, &[(upload, url)], caption)
            .await
    }

    pub async fn create_media_event_multi(
        &self,
        group_id: &GroupId,
        uploads: &[(&EncryptedMediaUpload, &str)],
        caption: &str,
    ) -> Result<Event> {
        self.create_media_event_multi_with_reply(group_id, uploads, caption, None)
            .await
    }

    pub async fn create_media_event_multi_with_reply(
        &self,
        group_id: &GroupId,
        uploads: &[(&EncryptedMediaUpload, &str)],
        caption: &str,
        reply: Option<&ReplyTo>,
    ) -> Result<Event> {
        if uploads.is_empty() {
            return Err(Error::Media("no media uploads for message".into()));
        }
        let imetas: Vec<Tag> = uploads
            .iter()
            .map(|&(upload, url)| media_crypto::create_imeta_tag(upload, url))
            .collect();
        self.create_app_event(group_id, caption, imetas, reply)
            .await
    }

    pub async fn create_and_process_media_event_multi(
        &self,
        group_id: &GroupId,
        uploads: &[(&EncryptedMediaUpload, &str)],
        caption: &str,
    ) -> Result<(Event, Incoming)> {
        let event = self
            .create_media_event_multi(group_id, uploads, caption)
            .await?;
        let incoming = self
            .lookup_chat(&event.id)
            .map(Incoming::Message)
            .unwrap_or(Incoming::None);
        Ok((event, incoming))
    }

    pub async fn create_and_process_media_event_multi_with_reply(
        &self,
        group_id: &GroupId,
        uploads: &[(&EncryptedMediaUpload, &str)],
        caption: &str,
        reply: Option<&ReplyTo>,
    ) -> Result<(Event, Incoming)> {
        let event = self
            .create_media_event_multi_with_reply(group_id, uploads, caption, reply)
            .await?;
        let incoming = overlay_reply_preview(
            self.lookup_chat(&event.id)
                .map(Incoming::Message)
                .unwrap_or(Incoming::None),
            reply,
        );
        Ok((event, incoming))
    }

    fn kind9_rumor(
        &self,
        content: &str,
        mut tags: Vec<Tag>,
        reply: Option<&ReplyTo>,
    ) -> Result<UnsignedEvent> {
        let body = if let Some(r) = reply {
            tags.push(crate::reply::quote_tag(&r.parent_id, &r.parent_pubkey));
            crate::reply::prefix_content(content, &r.parent_id, &r.parent_pubkey)?
        } else {
            content.to_string()
        };
        Ok(EventBuilder::new(Kind::Custom(CHAT_RUMOR_KIND), body)
            .tags(tags)
            .build(self.identity.public_key()))
    }

    pub fn decrypt_media_by_url(
        &self,
        group_id: &GroupId,
        url: &str,
        ciphertext: &[u8],
    ) -> Result<Vec<u8>> {
        let secret = self.media_exporter_secret(group_id)?;
        let msgs = self.messages(group_id)?;
        for m in msgs {
            for media in &m.media {
                if media.url != url {
                    continue;
                }
                if let (Some(original_hash), Some(nonce)) = (media.original_hash, media.nonce) {
                    let reference = MediaReference {
                        url: media.url.clone(),
                        original_hash,
                        mime_type: media.mime_type.clone(),
                        filename: media.filename.clone(),
                        dimensions: match (media.width, media.height) {
                            (Some(w), Some(h)) => Some((w, h)),
                            _ => None,
                        },
                        duration_ms: media.duration_ms,
                        waveform: None,
                        scheme_version: media_crypto::DEFAULT_SCHEME_VERSION.to_owned(),
                        nonce,
                    };
                    return media_crypto::decrypt_from_download(&secret, ciphertext, &reference);
                }
            }
            for tag in rumor_imeta_from_media(&m) {
                if let Ok(r) = media_crypto::parse_imeta_tag(&tag) {
                    if r.url == url {
                        return media_crypto::decrypt_from_download(&secret, ciphertext, &r);
                    }
                }
            }
        }
        Err(Error::Media(format!("no media reference for url {url}")))
    }

    fn parse_media_refs(&self, tags: &Tags) -> Vec<MediaRef> {
        tags.iter()
            .filter(|t| t.kind() == TagKind::Custom("imeta".into()))
            .filter_map(|t| media_crypto::parse_imeta_tag(t).ok())
            .map(|r| MediaRef::from(&r))
            .collect()
    }

    pub async fn process_incoming(&self, event: &Event) -> Result<Incoming> {
        match event.kind {
            Kind::GiftWrap => {
                let unwrapped = UnwrappedGift::from_gift_wrap(self.identity.keys(), event).await?;
                if unwrapped.rumor.kind == Kind::Custom(crate::invite_link::JOIN_REQUEST_RUMOR_KIND)
                {
                    return self.handle_join_request_rumor(&unwrapped.sender, &unwrapped.rumor);
                }
                if unwrapped.rumor.kind != Kind::MlsWelcome
                    && unwrapped.rumor.kind != Kind::Custom(KIND_MARMOT_WELCOME_RUMOR)
                {
                    return Ok(Incoming::None);
                }
                self.handle_welcome_gift_wrap(event, &unwrapped).await
            }
            Kind::MlsGroupMessage => self.ingest_event(event, None).await,
            _ => Ok(Incoming::None),
        }
    }

    /// Decide park/drop/auto-accept from the unwrapped rumor *before* MDK
    /// `ingest()`, which auto-joins. Parked invites keep the original wrapper
    /// so [`Self::accept_group_invite`] can ingest it later.
    async fn handle_welcome_gift_wrap(
        &self,
        wrapper: &Event,
        unwrapped: &UnwrappedGift,
    ) -> Result<Incoming> {
        if let Some(existing) = self.parked_for_wrapper(&wrapper.id) {
            return Ok(Incoming::GroupInvitePending(existing.group_id));
        }
        let welcomer = unwrapped.sender;
        let meta = welcome_rumor_meta(&unwrapped.rumor);
        // Unknown size (White Noise / no `members` tag) is treated as a
        // 2-member DM so the auto-accept budget and flood caps still apply.
        let member_count = meta.member_count.unwrap_or(2);
        let now_secs = unix_now_secs();
        let decision = if member_count <= 2 {
            self.dm_welcome_decision(&unwrapped.sender, &welcomer, now_secs)
        } else {
            self.park_or_drop_welcome(&welcomer)
        };
        match decision {
            DmWelcomeDecision::Drop => Ok(Incoming::None),
            DmWelcomeDecision::Park => {
                let invite = self.parked_invite_from_wrapper(wrapper, unwrapped, &meta);
                let group_id = invite.group_id.clone();
                self.park_invite(invite);
                Ok(Incoming::GroupInvitePending(group_id))
            }
            DmWelcomeDecision::AutoAccept { consume_budget } => {
                let reserved = !consume_budget
                    || match self.reserve_dm_autoaccept(now_secs) {
                        Ok(()) => true,
                        Err(e) => {
                            tracing::warn!(
                                error = %e,
                                welcomer = %welcomer,
                                "cannot persist the DM auto-accept budget; parking this welcome"
                            );
                            false
                        }
                    };
                if !reserved {
                    let invite = self.parked_invite_from_wrapper(wrapper, unwrapped, &meta);
                    let group_id = invite.group_id.clone();
                    self.park_invite(invite);
                    return Ok(Incoming::GroupInvitePending(group_id));
                }
                match self.ingest_event(wrapper, Some(unwrapped.sender)).await {
                    Ok(Incoming::GroupUpdated(id)) => Ok(Incoming::GroupUpdated(id)),
                    Ok(incoming) => {
                        // Duplicate re-delivery of an already-joined welcome
                        // must not refund the slot.
                        if consume_budget && matches!(incoming, Incoming::Failed) {
                            self.release_dm_autoaccept(now_secs);
                        }
                        Ok(incoming)
                    }
                    Err(e) => {
                        if consume_budget {
                            self.release_dm_autoaccept(now_secs);
                        }
                        Err(e)
                    }
                }
            }
        }
    }

    fn parked_invite_from_wrapper(
        &self,
        wrapper: &Event,
        unwrapped: &UnwrappedGift,
        meta: &WelcomeRumorMeta,
    ) -> GroupInvite {
        let group_id = parked_group_id_for_wrapper(wrapper, meta);
        GroupInvite {
            id: wrapper.id,
            wrapper_id: wrapper.id,
            group_id,
            group_name: meta.name.clone(),
            group_description: meta.description.clone(),
            welcomer: unwrapped.sender,
            member_count: meta.member_count.unwrap_or(2),
            relays: meta.relays.clone(),
            wrapper_json: wrapper.as_json(),
        }
    }

    fn parked_for_wrapper(&self, wrapper_id: &EventId) -> Option<GroupInvite> {
        self.parked_invites
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(wrapper_id)
            .cloned()
    }

    async fn ingest_event(
        &self,
        event: &Event,
        _seal_sender: Option<PublicKey>,
    ) -> Result<Incoming> {
        let msg = match nostr_event_to_transport(event) {
            Ok(msg) => msg,
            Err(_) => return Ok(Incoming::None),
        };
        let mut lease = self.lease_session().await;
        let ingested = lease.get_mut().ingest(msg).await?;
        let outcome = ingested.outcome;
        let mut effects = ingested.effects;
        let drained = lease.get_mut().drain();
        effects.events.extend(drained.events);
        effects.publish.extend(drained.publish);
        drop(lease);

        match outcome {
            IngestOutcome::Ignored {
                category: InputRejectionCategory::OwnEcho | InputRejectionCategory::Duplicate,
            } => {
                if let Some(msg) = self.lookup_chat(&event.id) {
                    return Ok(Incoming::Message(msg));
                }
                return Ok(Incoming::None);
            }
            IngestOutcome::Ignored { .. } => return Ok(Incoming::None),
            IngestOutcome::Rejected { .. } | IngestOutcome::Stale { .. } => {
                return Ok(Incoming::Failed)
            }
            IngestOutcome::LocalState { .. } => return Ok(Incoming::None),
            _ => {}
        }

        if let Some(update) = self.try_membership_from_effects(&effects)? {
            return Ok(Incoming::GroupProposal(update));
        }

        let mut last = Incoming::None;
        for ev in effects.events {
            match ev {
                GroupEvent::MessageReceived {
                    group_id,
                    message_id,
                    sender,
                    payload,
                    ..
                } => {
                    // Persist kind-9 chat rows only. `chat_from_payload` already
                    // returns None for other Marmot app-event kinds.
                    if let Some(msg) =
                        self.chat_from_payload(&group_id, &message_id, &sender, &payload)
                    {
                        self.store_chat(msg.clone());
                        last = Incoming::Message(msg);
                    }
                }
                GroupEvent::GroupJoined { group_id, .. } => {
                    last = if self.is_dropped(&group_id) {
                        Incoming::None
                    } else {
                        Incoming::GroupUpdated(group_id)
                    };
                }
                GroupEvent::GroupCreated { group_id }
                | GroupEvent::EpochChanged { group_id, .. }
                | GroupEvent::GroupStateChanged { group_id, .. } => {
                    last = Incoming::GroupUpdated(group_id);
                }
                _ => {}
            }
        }
        Ok(last)
    }

    fn try_membership_from_effects(
        &self,
        effects: &SessionEffects,
    ) -> Result<Option<GroupMembershipUpdate>> {
        let Some(work) = effects.publish.first() else {
            return Ok(None);
        };
        let group_id = match work {
            PublishWork::GroupEvolution { msg, .. }
            | PublishWork::Proposal { msg, .. }
            | PublishWork::AutoPublish { msg, .. } => transport_group_id(msg),
            _ => None,
        };
        let Some(group_id) = group_id else {
            return Ok(None);
        };
        match self.effects_to_membership_update(&group_id, effects.clone(), false) {
            Ok(update) => Ok(Some(update)),
            Err(_) => Ok(None),
        }
    }

    pub fn stored_group_count(&self) -> Result<usize> {
        self.with_session_mut(|session| {
            let mut ids = session.live_group_ids()?;
            ids.extend(session.unhydrated_group_ids());
            ids.sort_by(|a, b| a.as_slice().cmp(b.as_slice()));
            ids.dedup();
            for id in &ids {
                let _ = session.ensure_group_hydrated(id);
            }
            let dropped = self
                .dropped_groups
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            Ok(ids.iter().filter(|id| !dropped.contains(*id)).count())
        })
    }

    pub fn groups(&self) -> Result<Vec<Group>> {
        self.with_session_mut(|session| {
            let mut ids = session.live_group_ids()?;
            ids.extend(session.unhydrated_group_ids());
            ids.sort_by(|a, b| a.as_slice().cmp(b.as_slice()));
            ids.dedup();
            let parked: HashSet<GroupId> = self
                .parked_invites
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .values()
                .map(|i| i.group_id.clone())
                .collect();
            let dropped = self
                .dropped_groups
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut groups = Vec::new();
            for id in ids {
                if parked.contains(&id) || dropped.contains(&id) {
                    continue;
                }
                if session.ensure_group_hydrated(&id)? {
                    let Ok(g) = session.group_record(&id) else {
                        continue;
                    };
                    if g.removed || g.disbanded.is_some() || g.unrecoverable {
                        continue;
                    }
                    groups.push(g);
                }
            }
            Ok(groups)
        })
    }

    pub fn pending_group_invites(&self) -> Result<Vec<GroupInvite>> {
        let parked = self
            .parked_invites
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Ok(parked.values().cloned().collect())
    }

    pub async fn accept_group_invite(&self, welcome_id: &EventId) -> Result<GroupId> {
        let invite = self
            .parked_invites
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(welcome_id);
        let Some(invite) = invite else {
            return Err(Error::InvalidInput(format!(
                "unknown group invite {welcome_id}"
            )));
        };
        self.persist_parked();
        if invite.wrapper_json.is_empty() {
            self.park_invite(invite);
            return Err(Error::InvalidInput(format!(
                "parked group invite {welcome_id} is missing wrapper event"
            )));
        }
        let wrapper = match Event::from_json(&invite.wrapper_json) {
            Ok(event) => event,
            Err(e) => {
                self.park_invite(invite);
                return Err(Error::InvalidInput(format!(
                    "parked group invite {welcome_id} wrapper is not a nostr event: {e}"
                )));
            }
        };
        match self.ingest_event(&wrapper, Some(invite.welcomer)).await {
            Ok(Incoming::GroupUpdated(group_id)) => Ok(group_id),
            Ok(other) => {
                self.park_invite(invite);
                Err(Error::Mdk(format!(
                    "accepting parked welcome did not join a group: {other:?}"
                )))
            }
            Err(e) => {
                self.park_invite(invite);
                Err(e)
            }
        }
    }

    pub async fn decline_group_invite(&self, welcome_id: &EventId) -> Result<()> {
        let invite = self
            .parked_invites
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(welcome_id);
        let Some(invite) = invite else {
            return Err(Error::InvalidInput(format!(
                "unknown group invite {welcome_id}"
            )));
        };
        self.persist_parked();
        // Parked welcomes are not ingested, so there is no MDK group to leave.
        // Keep the overlay drop so a later auto-accept of the same MLS id
        // (if we ever learn it) cannot silently surface.
        self.drop_group(&invite.group_id);
        Ok(())
    }

    fn handle_join_request_rumor(
        &self,
        sender: &PublicKey,
        rumor: &UnsignedEvent,
    ) -> Result<Incoming> {
        let Ok(payload) = crate::invite_link::parse_join_request_rumor(rumor) else {
            return Ok(Incoming::None);
        };
        let Ok(group_id_bytes) = hex::decode(&payload.group_id) else {
            return Ok(Incoming::None);
        };
        let group_id = GroupId::new(group_id_bytes);

        let Ok(secret_hash_bytes) = hex::decode(&payload.invite_secret_hash) else {
            return Ok(Incoming::None);
        };
        let mut secret_hash = [0u8; 32];
        if secret_hash_bytes.len() == 32 {
            secret_hash.copy_from_slice(&secret_hash_bytes);
        } else {
            return Ok(Incoming::None);
        }

        let Ok(claimed) = PublicKey::parse(&payload.requester_npub) else {
            return Ok(Incoming::None);
        };
        if claimed != *sender {
            tracing::warn!(
                %claimed,
                %sender,
                "dropping join request: requester_npub does not match gift-wrap seal author"
            );
            return Ok(Incoming::None);
        }
        let requester = *sender;
        let kp_event_id = payload
            .key_package_event_id
            .as_deref()
            .and_then(|h| EventId::from_hex(h).ok());

        let request = crate::invite_link::JoinRequest {
            requester,
            group_id,
            secret_hash,
            key_package_event_id: kp_event_id,
            key_package_d_tag: payload
                .key_package_d_tag
                .as_deref()
                .filter(|d| !d.is_empty())
                .map(str::to_string),
            received_at: Timestamp::now().as_secs(),
        };
        Ok(Incoming::JoinRequest(request))
    }

    pub async fn gift_wrap_rumor(
        &self,
        receiver: &PublicKey,
        rumor: UnsignedEvent,
    ) -> Result<Event> {
        gift_wrap_with_current_timestamp_async(self.identity.keys(), receiver, rumor).await
    }

    pub fn messages(&self, group_id: &GroupId) -> Result<Vec<ChatMessage>> {
        let mut mapped = self.transcript_for(group_id);
        mapped.sort_by(|a, b| {
            a.created_at
                .cmp(&b.created_at)
                .then_with(|| a.id.cmp(&b.id))
        });
        hydrate_page_reply_previews(&mut mapped);
        Ok(mapped)
    }

    pub fn messages_page(
        &self,
        group_id: &GroupId,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<ChatMessage>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let mut msgs = self.messages(group_id)?;
        msgs.sort_by(compare_message_cursor_desc);
        let page: Vec<ChatMessage> = msgs.into_iter().skip(offset).take(limit).collect();
        Ok(page)
    }

    pub fn messages_cursor_page(
        &self,
        group_id: &GroupId,
        before_secs: Option<u64>,
        before_id: Option<&EventId>,
        limit: usize,
    ) -> Result<Vec<ChatMessage>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let mut candidates: Vec<ChatMessage> = self
            .transcript_for(group_id)
            .into_iter()
            .filter(|m| {
                is_before_message_cursor(m.created_at.as_secs(), &m.id, before_secs, before_id)
            })
            .collect();
        candidates.sort_unstable_by(compare_message_cursor_desc);
        candidates.truncate(limit);
        hydrate_page_reply_previews(&mut candidates);
        Ok(candidates)
    }

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
            let messages = self.messages_page(&group.id, page_limit, 0)?;
            let Some(latest_created_at) = messages.iter().map(|m| m.created_at).max() else {
                continue;
            };
            pages.push(RecentMessagePage {
                group_id: group.id,
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

    pub fn members(&self, group_id: &GroupId) -> Result<Vec<PublicKey>> {
        self.with_session(|session| {
            let members = session.members(group_id)?;
            Ok(members
                .into_iter()
                .filter_map(|m| PublicKey::from_slice(m.id.as_slice()).ok())
                .collect())
        })
    }

    pub fn latest_message_secs(&self) -> u64 {
        self.transcript
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .flatten()
            .map(|m| m.created_at.as_secs())
            .max()
            .unwrap_or(0)
    }

    pub fn latest_remote_event_secs(&self) -> u64 {
        let me = self.identity.public_key();
        self.transcript
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .flatten()
            .filter(|m| m.sender != me)
            .map(|m| m.created_at.as_secs())
            .max()
            .unwrap_or(0)
    }

    pub fn latest_remote_chat_message_secs(&self, group_id: &GroupId) -> Option<u64> {
        let me = self.identity.public_key();
        self.transcript_for(group_id)
            .into_iter()
            .filter(|m| m.sender != me)
            .map(|m| m.created_at.as_secs())
            .max()
    }

    pub async fn delete_group(&self, group_id: &GroupId) -> Result<()> {
        self.drop_group(group_id);
        self.transcript
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(group_id);
        self.persist_transcript();
        let _ = self.leave_group(group_id).await;
        Ok(())
    }

    fn store_chat(&self, msg: ChatMessage) {
        let mut transcript = self
            .transcript
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let rows = transcript.entry(msg.group_id.clone()).or_default();
        if rows.iter().any(|m| m.id == msg.id) {
            return;
        }
        rows.push(msg);
        drop(transcript);
        self.persist_transcript();
    }

    fn lookup_chat(&self, id: &EventId) -> Option<ChatMessage> {
        self.transcript
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .flatten()
            .find(|m| m.id == *id)
            .cloned()
    }

    fn transcript_for(&self, group_id: &GroupId) -> Vec<ChatMessage> {
        self.transcript
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(group_id)
            .cloned()
            .unwrap_or_default()
    }

    fn park_invite(&self, invite: GroupInvite) {
        self.parked_invites
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(invite.id, invite);
        self.persist_parked();
    }

    fn drop_group(&self, group_id: &GroupId) {
        self.dropped_groups
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(group_id.clone());
        self.persist_dropped();
    }

    fn is_dropped(&self, group_id: &GroupId) -> bool {
        self.dropped_groups
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(group_id)
    }

    fn persist_parked(&self) {
        let Some(path) = self.db_path.as_ref() else {
            return;
        };
        let parked = self
            .parked_invites
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let values: Vec<&GroupInvite> = parked.values().collect();
        let _ = atomic_write_json(&sidecar_named(path, PARKED_INVITES_FILE_SUFFIX), &values);
    }

    fn persist_dropped(&self) {
        let Some(path) = self.db_path.as_ref() else {
            return;
        };
        let dropped = self
            .dropped_groups
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let ids: Vec<String> = dropped.iter().map(|g| hex::encode(g.as_slice())).collect();
        let _ = atomic_write_json(&sidecar_named(path, DROPPED_GROUPS_FILE_SUFFIX), &ids);
    }

    fn persist_transcript(&self) {
        let Some(path) = self.db_path.as_ref() else {
            return;
        };
        let transcript = self
            .transcript
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let keyed: HashMap<String, Vec<ChatMessage>> = transcript
            .iter()
            .map(|(id, msgs)| (hex::encode(id.as_slice()), msgs.clone()))
            .collect();
        let _ = atomic_write_json(&sidecar_named(path, TRANSCRIPT_FILE_SUFFIX), &keyed);
    }

    fn chat_from_app_rumor(
        &self,
        group_id: &GroupId,
        rumor: &UnsignedEvent,
        event: &Event,
        mine: bool,
    ) -> Option<ChatMessage> {
        if rumor.kind.as_u16() != CHAT_RUMOR_KIND {
            return None;
        }
        let media = self.parse_media_refs(&rumor.tags);
        let sticker_ref = rumor
            .tags
            .iter()
            .find_map(|t| parse_sticker_ref_tag(t).ok());
        let (content, reply) =
            crate::reply::project_application_content(&rumor.content, rumor.tags.iter());
        Some(ChatMessage {
            id: event.id,
            group_id: group_id.clone(),
            sender: rumor.pubkey,
            classification: MessageClassification::of(&content),
            content,
            created_at: rumor.created_at,
            mine,
            delivery_state: if mine {
                DeliveryState::Sent
            } else {
                DeliveryState::Received
            },
            media,
            sticker_ref,
            reply,
        })
    }

    fn chat_from_payload(
        &self,
        group_id: &GroupId,
        message_id: &MessageId,
        sender: &MemberId,
        payload: &[u8],
    ) -> Option<ChatMessage> {
        let app = MarmotAppEvent::decode(payload).ok()?;
        if app.kind != MARMOT_APP_EVENT_KIND_CHAT {
            return None;
        }
        let sender_pk = PublicKey::from_slice(sender.as_slice()).ok()?;
        let id = message_id_to_event(message_id).ok()?;
        let tags: Tags = app
            .tags
            .iter()
            .filter_map(|t| Tag::parse(t.clone()).ok())
            .collect();
        let media = self.parse_media_refs(&tags);
        let sticker_ref = tags.iter().find_map(|t| parse_sticker_ref_tag(t).ok());
        let (content, reply) = crate::reply::project_application_content(&app.content, tags.iter());
        Some(ChatMessage {
            id,
            group_id: group_id.clone(),
            sender: sender_pk,
            classification: MessageClassification::of(&content),
            content,
            created_at: Timestamp::from_secs(app.created_at),
            mine: sender_pk == self.identity.public_key(),
            delivery_state: if sender_pk == self.identity.public_key() {
                DeliveryState::Sent
            } else {
                DeliveryState::Received
            },
            media,
            sticker_ref,
            reply,
        })
    }
}

fn overlay_reply_preview(incoming: Incoming, reply: Option<&ReplyTo>) -> Incoming {
    let Incoming::Message(mut message) = incoming else {
        return incoming;
    };
    if let (Some(sent), Some(parsed)) = (reply, message.reply.as_mut()) {
        if parsed.preview.is_none() {
            parsed.preview = sent.preview.clone();
        }
    }
    Incoming::Message(message)
}

fn hydrate_page_reply_previews(msgs: &mut [ChatMessage]) {
    let by_id: HashMap<EventId, String> = msgs
        .iter()
        .filter_map(|m| {
            crate::reply::parent_content_for_preview(
                &m.classification,
                m.sticker_ref.is_some(),
                !m.media.is_empty(),
                &m.content,
            )
            .map(|t| (m.id, t.to_string()))
        })
        .collect();
    for m in msgs.iter_mut() {
        let Some(reply) = m.reply.as_mut() else {
            continue;
        };
        crate::reply::hydrate_reply_preview(reply, by_id.get(&reply.parent_id).map(String::as_str));
    }
}

fn is_unencrypted_sqlite(path: &Path) -> bool {
    // SQLCipher files (0.8 raw-key or 0.9 passphrase) do not start with the
    // sqlite magic. Only a proven plaintext sqlite file is safe to wipe.
    let Ok(mut file) = std::fs::File::open(path) else {
        return false;
    };
    let mut hdr = [0u8; 16];
    matches!(
        std::io::Read::read(&mut file, &mut hdr),
        Ok(n) if n >= 16 && hdr.starts_with(b"SQLite format 3")
    )
}

pub(crate) fn key_package_slot_path_for(db: &Path) -> PathBuf {
    let name = db.file_name().and_then(|n| n.to_str()).unwrap_or_default();
    db.with_file_name(format!("{name}{KEY_PACKAGE_SLOT_FILE_SUFFIX}"))
}

pub(crate) fn key_package_slot_tmp_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default();
    path.with_file_name(format!("{name}.tmp"))
}

fn sidecar_named(base: &Path, suffix: &str) -> PathBuf {
    let name = base
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default();
    base.with_file_name(format!("{name}{suffix}"))
}

fn sidecar_paths(base: &Path) -> Vec<PathBuf> {
    let name = base
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default();
    let mut paths: Vec<PathBuf> = [
        "",
        "-wal",
        "-shm",
        "-journal",
        SYNC_STATE_FILE_SUFFIX,
        OUTBOX_STATE_FILE_SUFFIX,
        DM_AUTOACCEPT_FILE_SUFFIX,
        DM_AUTOACCEPT_TMP_FILE_SUFFIX,
        KEY_PACKAGE_SLOT_FILE_SUFFIX,
        TRANSCRIPT_FILE_SUFFIX,
        PARKED_INVITES_FILE_SUFFIX,
        DROPPED_GROUPS_FILE_SUFFIX,
    ]
    .iter()
    .map(|suffix| base.with_file_name(format!("{name}{suffix}")))
    .collect();
    paths.push(base.with_file_name(format!("{name}{SYNC_STATE_FILE_SUFFIX}.tmp")));
    paths.push(base.with_file_name(format!("{name}{OUTBOX_STATE_FILE_SUFFIX}.tmp")));
    paths.push(base.with_file_name(format!("{name}{KEY_PACKAGE_SLOT_FILE_SUFFIX}.tmp")));
    paths
}

fn validate_existing_d_tag(d: &str) -> Result<()> {
    if d.len() == 64 && d.bytes().all(|b| b.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(Error::InvalidInput(
            "KeyPackage d tag must be 64 ASCII hex characters".into(),
        ))
    }
}

fn key_package_from_event(event: &Event) -> Result<KeyPackage> {
    let bytes = BASE64
        .decode(event.content.as_bytes())
        .map_err(|e| Error::InvalidInput(format!("key package content is not base64: {e}")))?;
    Ok(KeyPackage {
        bytes,
        source: Some(KeyPackageSource {
            event_id: MessageId::new(event.id.as_bytes().to_vec()),
        }),
        protocol_profile: cgka_traits::group::ProtocolProfile::Current,
    })
}

fn key_package_to_event(
    identity: &Identity,
    kp: &KeyPackage,
    meta: &KeyPackageMetadata,
    d_tag: &str,
) -> Result<Event> {
    let hex_u16 = |v: u16| format!("0x{v:04x}");
    let tags = [
        Tag::identifier(d_tag),
        Tag::custom(TagKind::custom("mls_protocol_version"), ["1.0"]),
        Tag::custom(TagKind::custom("i"), [meta.key_package_ref_hex.clone()]),
        Tag::custom(
            TagKind::custom("mls_ciphersuite"),
            [hex_u16(meta.ciphersuite)],
        ),
        Tag::custom(
            TagKind::custom("mls_extensions"),
            meta.mls_extensions.iter().copied().map(hex_u16),
        ),
        Tag::custom(
            TagKind::custom("mls_proposals"),
            meta.mls_proposals.iter().copied().map(hex_u16),
        ),
        Tag::custom(
            TagKind::custom("app_components"),
            meta.app_components.iter().copied().map(hex_u16),
        ),
    ];
    let event = EventBuilder::new(Kind::Custom(KEY_PACKAGE_KIND), BASE64.encode(&kp.bytes))
        .tags(tags)
        .build(identity.public_key())
        .sign_with_keys(identity.keys())?;
    Ok(event)
}

fn marmot_app_event_from_rumor(rumor: &UnsignedEvent) -> Result<Vec<u8>> {
    let tags = rumor.tags.iter().map(|t| t.as_slice().to_vec()).collect();
    MarmotAppEvent::new(
        rumor.pubkey.to_hex(),
        rumor.created_at.as_secs(),
        u64::from(rumor.kind.as_u16()),
        tags,
        rumor.content.clone(),
    )
    .encode()
    .map_err(|e| Error::Mdk(e.to_string()))
}

fn event_from_app_publish(effects: &SessionEffects) -> Result<Event> {
    for work in &effects.publish {
        if let PublishWork::ApplicationMessage { msg, .. } = work {
            return transport_to_event(msg);
        }
    }
    Err(Error::Mdk("send produced no application message".into()))
}

fn publish_work_welcomes(
    effects: &SessionEffects,
) -> Result<(Vec<(PublicKey, Event)>, Option<PendingStateRef>)> {
    for work in &effects.publish {
        match work {
            PublishWork::FoundingGroupCreated { welcomes } => {
                return Ok((wrapped_welcomes(welcomes)?, None));
            }
            PublishWork::GroupCreated { welcomes, pending } => {
                return Ok((wrapped_welcomes(welcomes)?, Some(*pending)));
            }
            PublishWork::GroupEvolution {
                welcomes, pending, ..
            } => {
                return Ok((wrapped_welcomes(welcomes)?, Some(*pending)));
            }
            _ => {}
        }
    }
    Ok((Vec::new(), None))
}

fn wrapped_welcomes(welcomes: &[TransportMessage]) -> Result<Vec<(PublicKey, Event)>> {
    welcomes
        .iter()
        .map(|msg| {
            let pk = match &msg.envelope {
                TransportEnvelope::Welcome { recipient } => {
                    PublicKey::from_slice(recipient.as_slice())
                        .map_err(|e| Error::Mdk(format!("welcome recipient: {e}")))?
                }
                _ => {
                    return Err(Error::Mdk(
                        "welcome transport message is not a Welcome envelope".into(),
                    ))
                }
            };
            Ok((pk, transport_to_event(msg)?))
        })
        .collect()
}

fn nostr_event_to_transport(event: &Event) -> Result<TransportMessage> {
    NostrTransportEvent::from_nostr_event(event)
        .and_then(|e| e.to_transport_message())
        .map_err(|e| Error::Mdk(e.to_string()))
}

fn transport_to_event(msg: &TransportMessage) -> Result<Event> {
    NostrTransportEvent::from_transport_message(msg)
        .and_then(|e| e.to_verified_nostr_event())
        .map_err(|e| Error::Mdk(e.to_string()))
}

fn transport_group_id(msg: &TransportMessage) -> Option<GroupId> {
    match &msg.envelope {
        TransportEnvelope::GroupMessage { transport_group_id } => {
            Some(GroupId::new(transport_group_id.clone()))
        }
        TransportEnvelope::Welcome { .. } => None,
    }
}

fn message_id_to_event(id: &MessageId) -> Result<EventId> {
    EventId::from_slice(id.as_slice()).map_err(|e| Error::Mdk(format!("message id: {e}")))
}

fn rumor_imeta_from_media(msg: &ChatMessage) -> Vec<Tag> {
    // Best-effort: MediaRef is display-only. Decrypt still needs a stored imeta;
    // create_media_event persists the rumor tags via MarmotAppEvent tags which
    // chat_from_payload re-parses on receive. Outgoing rows keep media refs only.
    let _ = msg;
    Vec::new()
}

fn atomic_write_json<T: Serialize>(path: &Path, value: &T) -> std::io::Result<()> {
    let bytes = serde_json::to_vec(value)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    let tmp = path.with_file_name(format!(
        "{}.tmp",
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("sidecar")
    ));
    std::fs::write(&tmp, bytes).and_then(|()| std::fs::rename(&tmp, path))
}

fn load_parked(db_path: &Path) -> HashMap<EventId, GroupInvite> {
    let path = sidecar_named(db_path, PARKED_INVITES_FILE_SUFFIX);
    let Ok(bytes) = std::fs::read(path) else {
        return HashMap::new();
    };
    serde_json::from_slice::<Vec<GroupInvite>>(&bytes)
        .unwrap_or_default()
        .into_iter()
        .map(|i| (i.id, i))
        .collect()
}

fn load_dropped(db_path: &Path) -> HashSet<GroupId> {
    let path = sidecar_named(db_path, DROPPED_GROUPS_FILE_SUFFIX);
    let Ok(bytes) = std::fs::read(path) else {
        return HashSet::new();
    };
    serde_json::from_slice::<Vec<String>>(&bytes)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|h| hex::decode(h).ok().map(GroupId::new))
        .collect()
}

fn load_transcript(db_path: &Path) -> HashMap<GroupId, Vec<ChatMessage>> {
    let path = sidecar_named(db_path, TRANSCRIPT_FILE_SUFFIX);
    let Ok(bytes) = std::fs::read(path) else {
        return HashMap::new();
    };
    serde_json::from_slice::<HashMap<String, Vec<ChatMessage>>>(&bytes)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(hex_id, msgs)| hex::decode(hex_id).ok().map(|b| (GroupId::new(b), msgs)))
        .collect()
}

// Silence unused helper on the in-memory Result path used by tests.
#[allow(dead_code)]
fn _in_memory_result(identity: Identity) -> Result<MarmotEngine> {
    MarmotEngine::in_memory_inner(identity)
}
#[cfg(test)]
mod dm_autoaccept_budget_tests {
    use super::{
        dm_autoaccept_sidecar, DmAutoacceptBudget, UNKNOWN_DM_AUTOACCEPT_MAX,
        UNKNOWN_DM_AUTOACCEPT_WINDOW_SECS,
    };

    /// The sliding window actually slides: admits older than the window are
    /// evicted, so the budget recovers without a restart.
    #[test]
    fn window_slides() {
        let mut b = DmAutoacceptBudget::in_memory();
        let t0 = 1_000_000;
        for i in 0..UNKNOWN_DM_AUTOACCEPT_MAX {
            assert!(b.has_room(t0 + i as u64));
            b.reserve(t0 + i as u64).expect("reserve must persist");
        }
        assert!(!b.has_room(t0 + 10), "budget exhausted inside the window");
        // One second before the first admit expires: still exhausted.
        assert!(!b.has_room(t0 + UNKNOWN_DM_AUTOACCEPT_WINDOW_SECS - 1));
        // The first admit ages out; exactly one slot frees.
        assert!(b.has_room(t0 + UNKNOWN_DM_AUTOACCEPT_WINDOW_SECS));
    }

    /// `reserve` is the authority on the cap, not `has_room`.
    ///
    /// They are two separate steps of `process_incoming`, and the iOS NSE runs
    /// its own engine against the same sidecar. A peer process filling the
    /// window between our `has_room` and our `reserve` used to be added to
    /// silently — `reserve` pushed unconditionally — so the window could grow
    /// past the maximum and hand out extra silent groups. Now it fails, and the
    /// caller parks the welcome on that error.
    #[test]
    fn reserve_refuses_once_another_process_filled_the_window() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("marmot.sqlite");
        let t0 = 3_000_000;

        // We observe room...
        let mut ours = DmAutoacceptBudget::load(&db_path);
        assert!(ours.has_room(t0), "precondition: the window starts empty");

        // ...and the "NSE" fills the window from its own process before we act.
        let mut peer = DmAutoacceptBudget::load(&db_path);
        for i in 0..UNKNOWN_DM_AUTOACCEPT_MAX {
            peer.reserve(t0 + i as u64).expect("peer reserve persists");
        }
        drop(peer);

        // Act AFTER the peer's admits: `prune` drops future-dated stamps, so
        // reserving at t0 would legitimately see a window of one.
        let now = t0 + UNKNOWN_DM_AUTOACCEPT_MAX as u64;
        assert!(
            ours.reserve(now).is_err(),
            "reserve must refuse a slot the window can no longer afford"
        );
        let mut reloaded = DmAutoacceptBudget::load(&db_path);
        assert!(
            !reloaded.has_room(now),
            "and it must not have grown the window past the maximum"
        );
    }

    /// `has_room` must not consume — the slot is recorded only after a
    /// successful accept, so failed accepts cannot eat the budget.
    #[test]
    fn has_room_does_not_consume() {
        let mut b = DmAutoacceptBudget::in_memory();
        for _ in 0..100 {
            assert!(b.has_room(5));
        }
    }

    /// The window survives process death via the sidecar — the iOS NSE mints
    /// a fresh engine per push wake, so an in-memory-only window would grant
    /// every wake a fresh budget.
    #[test]
    fn budget_persists_across_reload() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("marmot.sqlite");
        let mut b = DmAutoacceptBudget::load(&db_path);
        let t0 = 2_000_000;
        for i in 0..UNKNOWN_DM_AUTOACCEPT_MAX {
            b.reserve(t0 + i as u64).expect("reserve must persist");
        }
        assert!(!b.has_room(t0 + 10));
        drop(b);

        let mut reloaded = DmAutoacceptBudget::load(&db_path);
        assert!(
            !reloaded.has_room(t0 + 10),
            "a fresh process must inherit the exhausted window"
        );
        assert!(reloaded.has_room(t0 + UNKNOWN_DM_AUTOACCEPT_WINDOW_SECS));
        // The sidecar sits next to the DB and is listed for wipe().
        assert!(dm_autoaccept_sidecar(&db_path)
            .to_string_lossy()
            .ends_with(".dm-autoaccepts.json"));
    }

    /// Two engines on the same DB path (the app and the iOS NSE) must not
    /// clobber each other's admits. A whole-file write from a stale in-memory
    /// snapshot only ever WIDENS the budget, which is the defect persisting it
    /// was meant to close.
    #[test]
    fn a_second_process_sees_the_first_ones_admits() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("marmot.sqlite");
        let t0 = 3_000_000;

        // The "NSE" records admits while the "app" handle sits idle, holding a
        // stale (empty) window.
        let mut app = DmAutoacceptBudget::load(&db_path);
        let mut nse = DmAutoacceptBudget::load(&db_path);
        for i in 0..UNKNOWN_DM_AUTOACCEPT_MAX {
            assert!(nse.has_room(t0 + i as u64));
            nse.reserve(t0 + i as u64).expect("reserve must persist");
        }

        // The app must observe them rather than overwrite them.
        assert!(
            !app.has_room(t0 + 10),
            "a second process must inherit the first's exhausted window"
        );
        // And once the window slides, both recover.
        assert!(app.has_room(t0 + UNKNOWN_DM_AUTOACCEPT_WINDOW_SECS));
    }

    /// A corrupt sidecar fails open to an empty window (never blocks welcome
    /// processing), and the next record rewrites it.
    #[test]
    fn corrupt_sidecar_fails_open() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("marmot.sqlite");
        std::fs::write(dm_autoaccept_sidecar(&db_path), b"not json").unwrap();
        let mut b = DmAutoacceptBudget::load(&db_path);
        assert!(b.has_room(1));
        b.reserve(1).expect("reserve must persist");
        let reloaded = DmAutoacceptBudget::load(&db_path);
        assert_eq!(reloaded.admits.len(), 1);
    }
}

#[cfg(test)]
mod message_cursor_tests {
    use super::{compare_message_cursor_keys_desc, is_before_message_cursor, EventId, Timestamp};

    fn event_id(byte: u8) -> EventId {
        EventId::from_byte_array([byte; EventId::LEN])
    }

    #[test]
    fn cursor_keys_sort_by_created_at_then_event_id_descending() {
        let mut keys = [
            (Timestamp::from_secs(100), event_id(0x02)),
            (Timestamp::from_secs(99), event_id(0xff)),
            (Timestamp::from_secs(100), event_id(0xff)),
            (Timestamp::from_secs(101), event_id(0x01)),
        ];

        keys.sort_unstable_by(|(a_secs, a_id), (b_secs, b_id)| {
            compare_message_cursor_keys_desc(*a_secs, a_id, *b_secs, b_id)
        });

        assert_eq!(
            keys,
            [
                (Timestamp::from_secs(101), event_id(0x01)),
                (Timestamp::from_secs(100), event_id(0xff)),
                (Timestamp::from_secs(100), event_id(0x02)),
                (Timestamp::from_secs(99), event_id(0xff)),
            ]
        );
    }

    #[test]
    fn same_second_cursor_boundary_is_strictly_event_id_based() {
        let cursor_id = event_id(0x80);

        assert!(!is_before_message_cursor(
            101,
            &event_id(0x00),
            Some(100),
            Some(&cursor_id)
        ));
        assert!(!is_before_message_cursor(
            100,
            &event_id(0x81),
            Some(100),
            Some(&cursor_id)
        ));
        assert!(!is_before_message_cursor(
            100,
            &cursor_id,
            Some(100),
            Some(&cursor_id)
        ));
        assert!(is_before_message_cursor(
            100,
            &event_id(0x7f),
            Some(100),
            Some(&cursor_id)
        ));
        assert!(is_before_message_cursor(
            99,
            &event_id(0xff),
            Some(100),
            Some(&cursor_id)
        ));
    }

    #[test]
    fn timestamp_only_cursor_excludes_its_entire_second() {
        assert!(!is_before_message_cursor(
            100,
            &event_id(0x00),
            Some(100),
            None
        ));
        assert!(is_before_message_cursor(
            99,
            &event_id(0xff),
            Some(100),
            None
        ));
        assert!(is_before_message_cursor(101, &event_id(0x00), None, None));
    }
}

#[cfg(test)]
mod classification_tests {
    use super::MessageClassification as C;

    #[test]
    fn plain_text_and_empty_classify_as_text() {
        assert_eq!(C::of("hello"), C::Text);
        assert_eq!(C::of(""), C::Text);
        assert_eq!(C::of("⚡ not a control line"), C::Text);
    }

    #[test]
    fn pay_receipt_v1_classifies_with_fields() {
        assert_eq!(
            C::of("⚡PAY|1|abc-123|2100"),
            C::PayReceipt {
                payment_id: "abc-123".into(),
                amount_sats: 2100,
            }
        );
    }

    #[test]
    fn malformed_pay_lines_fall_back_to_text() {
        // Unknown version, zero sats, trailing field, bad id: all plain text —
        // a parse failure must never hide a message.
        assert_eq!(C::of("⚡PAY|2|abc|2100"), C::Text);
        assert_eq!(C::of("⚡PAY|1|abc|0"), C::Text);
        assert_eq!(C::of("⚡PAY|1|abc|21|extra"), C::Text);
        assert_eq!(C::of("⚡PAY|1|not hex!|21"), C::Text);
        assert_eq!(C::of("⚡PAYDONE|3|abc"), C::Text);
    }

    #[test]
    fn pay_done_v1_and_v2_classify_with_optional_preimage() {
        assert_eq!(
            C::of("⚡PAYDONE|1|abc-123"),
            C::PayDone {
                payment_id: "abc-123".into(),
                preimage_hex: None,
            }
        );
        assert_eq!(
            C::of("⚡PAYDONE|2|abc-123"),
            C::PayDone {
                payment_id: "abc-123".into(),
                preimage_hex: None,
            }
        );
        let preimage = "a".repeat(64);
        assert_eq!(
            C::of(&format!("⚡PAYDONE|2|abc-123|{preimage}")),
            C::PayDone {
                payment_id: "abc-123".into(),
                preimage_hex: Some(preimage),
            }
        );
        // Bad preimage → text, not a silently-dropped control line.
        assert_eq!(C::of("⚡PAYDONE|2|abc-123|deadbeef"), C::Text);
    }

    #[test]
    fn call_control_lines_classify_and_malformed_fall_back() {
        assert_eq!(
            C::of("☎CALL|1|END|c3a1|declined"),
            C::CallControl,
            "well-formed call control should classify"
        );
        assert_eq!(C::of("☎CALL|not-a-version|X|y"), C::Text);
        assert_eq!(C::of("☎CALLING you later"), C::Text);
    }

    #[test]
    fn only_host_rendered_classes_are_transcript_visible() {
        // Whatever the transcript hides must not be counted as unread, or the
        // unread divider lands that many real messages further back.
        assert!(C::Text.is_transcript_visible());
        assert!(C::PayReceipt {
            payment_id: "abc-123".into(),
            amount_sats: 21,
        }
        .is_transcript_visible());
        assert!(!C::CallControl.is_transcript_visible());
        assert!(!C::PayDone {
            payment_id: "abc-123".into(),
            preimage_hex: None,
        }
        .is_transcript_visible());
        // A malformed control line renders as text, so it stays countable.
        assert!(C::of("☎CALL|not-a-version|X|y").is_transcript_visible());
    }
}
