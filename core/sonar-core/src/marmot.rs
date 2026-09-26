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
    decode_nostr_routing_v1, default_group_components, encode_nostr_routing_v1, AppComponentData,
    NostrRoutingV1, NOSTR_ROUTING_COMPONENT_ID,
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
/// Sealed at rest — see [`crate::transcript_sidecar`].
pub(crate) const TRANSCRIPT_FILE_SUFFIX: &str = ".sonar-transcript.json";
/// Sealed rows appended since the last transcript snapshot.
pub(crate) const TRANSCRIPT_JOURNAL_FILE_SUFFIX: &str = ".sonar-transcript.log";
/// Fold the journal into a fresh snapshot past this size (~1k rows), so the
/// O(history) rewrite is amortized instead of paid per message.
const TRANSCRIPT_JOURNAL_COMPACT_BYTES: u64 = 512 * 1024;
pub(crate) const PARKED_INVITES_FILE_SUFFIX: &str = ".sonar-parked-invites.json";
pub(crate) const DROPPED_GROUPS_FILE_SUFFIX: &str = ".sonar-dropped-groups.json";
/// historical MLS group id hex → live 0.9 group id hex.
pub(crate) const HISTORICAL_FOLDS_FILE_SUFFIX: &str = ".sonar-historical-folds.json";

/// Live and recovered 1:1s stamp this on `Group.description`. A named 2-person
/// room must not share the `start_dm` path just because only one peer is known.
pub(crate) const SONAR_DIRECT_DM_DESCRIPTION: &str = "sonar.direct-dm.v1";

/// A recovered 0.8 conversation that is not a live 0.9 MLS group.
#[derive(Debug, Clone)]
pub struct HistoricalGroup {
    pub id: GroupId,
    pub name: String,
    pub members: Vec<PublicKey>,
}

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

/// Stable `Error::Media` body when a recovered 0.8 attachment cannot be
/// opened. Hosts match this string and must not offer Retry — used when
/// the 0.8 store had no `encrypted-media` exporter secret to copy.
pub const RECOVERED_08_MEDIA_UNAVAILABLE: &str =
    "this attachment is from an older Sonar and cannot be opened after the update";

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
    /// Processing recorded a terminal failure, or a Duplicate redelivery of a
    /// Failed ciphertext with no local chat row. Relay sync counts the delivery
    /// handled for the batch watermark but must not durable-dedup it: MLS
    /// rollback can later make the same event Retryable.
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

pub(crate) async fn gift_wrap_with_current_timestamp_async(
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
    /// Seals the transcript at rest, derived from the SQLCipher key.
    transcript_key: crate::transcript_sidecar::TranscriptKey,
    /// Held across a journal append and across a snapshot rewrite, so a
    /// compaction can never delete the journal under a row appended while it
    /// ran.
    transcript_io: Mutex<()>,
    transcript_journal_bytes: std::sync::atomic::AtomicU64,
    /// False when an unreadable transcript could not be moved aside: writing
    /// would overwrite it, so this session keeps the transcript in memory.
    transcript_writable: std::sync::atomic::AtomicBool,
    /// Groups whose last ingest left a MIP-03 `Buffered` commit. The host
    /// (and sonar-sim) must call [`Self::apply_pending_convergence`] after
    /// the quiescence window — ingest itself does not wait.
    pending_convergence: Mutex<HashSet<GroupId>>,
    /// Titles recovered from an MDK 0.8 store. Live 0.9 groups are not here.
    historical_group_names: Mutex<HashMap<GroupId, String>>,
    /// 0.8 `groups.description` / welcome `group_description`. Needed so a
    /// named joined room is not classified as a DM when only one peer is known.
    historical_group_descriptions: Mutex<HashMap<GroupId, String>>,
    /// Members recovered from a 0.8 store (`admin_pubkeys` + every message
    /// pubkey). Transcript senders are merged at read time so a chat you
    /// only ever sent into can still resume.
    historical_members: Mutex<HashMap<GroupId, Vec<PublicKey>>>,
    /// Original 0.8 welcome `member_count` so a 3+ room does not resume as a DM.
    historical_member_counts: Mutex<HashMap<GroupId, u32>>,
    /// Recovered 0.8 group id → new 0.9 group created with the same members.
    historical_folds: Mutex<HashMap<GroupId, GroupId>>,
    /// Leftover 0.8 rows still in `*.mdk08.bak` after the first-paint window.
    pending_mdk08: Mutex<Option<crate::mdk08_migrate::PendingMdk08Remainder>>,
    /// MIP-04 exporter secrets copied from the 0.8 `group_exporter_secrets`
    /// table (`encrypted-media` label). Used only to decrypt recovered blobs.
    historical_media_secrets: Mutex<HashMap<GroupId, Vec<Vec<u8>>>>,
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
    /// 0.8 raw-key form `x'<hex>'`.
    ///
    /// An existing 0.8 store is **not** wiped. Plaintext chat rows are copied
    /// into the host transcript sidecar, the 0.8 file is quarantined as
    /// `*.mdk08.bak`, and a fresh 0.9 store is created at `db_path`. MLS
    /// membership is not imported — 0.8 and 0.9 cannot decrypt each other.
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
        // Cheap one-shot: if an earlier 0.9 open already quarantined the 0.8
        // file, recover pending welcomes + labeled media secrets from the bak
        // without joining leftover chat payloads.
        if let Err(err) = crate::mdk08_migrate::backfill_metadata_from_bak(path, key) {
            tracing::warn!(error = %err, "0.8 bak metadata backfill failed");
        }
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
            Err(e) if path.exists() => Self::migrate_mdk08_or_fail(identity, path, key, e),
            Err(e) => Err(e),
        }
    }

    fn migrate_mdk08_or_fail(
        identity: Identity,
        path: &Path,
        key: [u8; 32],
        open_err: Error,
    ) -> Result<Self> {
        let extracted = match crate::mdk08_migrate::detect_and_extract_first_paint(
            path,
            key,
            identity.public_key(),
        ) {
            Ok(Some(extracted)) => extracted,
            Ok(None) => {
                return Err(Error::Storage(format!(
                    "MDK 0.9 cannot open this store (protocol migration required): {open_err}"
                )))
            }
            Err(migrate_err) => {
                return Err(Error::Storage(format!(
                    "MDK 0.8 extract failed (store left intact): {migrate_err}"
                )))
            }
        };
        crate::mdk08_migrate::write_sidecars(path, &extracted, &key)?;
        let quarantine = crate::mdk08_migrate::quarantine_store(path)?;
        match Self::open_session(identity, path, key, true) {
            Ok(engine) => {
                tracing::info!(
                    groups = extracted.messages.len(),
                    messages = extracted.messages.values().map(|m| m.len()).sum::<usize>(),
                    truncated = extracted.truncated,
                    "marmot: recovered 0.8 plaintext transcript; 0.8 store quarantined"
                );
                Ok(engine)
            }
            Err(e) => {
                let _ = quarantine.restore();
                Err(Error::Storage(format!(
                    "MDK 0.9 recreate after 0.8 extract failed; 0.8 store restored: {e}"
                )))
            }
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
        let transcript_key = crate::transcript_sidecar::TranscriptKey::derive(&key);
        let loaded = load_transcript(db_path, &transcript_key);
        let mut transcript = loaded.rows;
        let mut transcript_healed = loaded.needs_reseal;
        for id in &dropped {
            if transcript.remove(id).is_some() {
                transcript_healed = true;
            }
        }
        let historical_group_names = crate::mdk08_migrate::load_historical_group_names(db_path);
        let historical_members = crate::mdk08_migrate::load_historical_members(db_path);
        let historical_folds = load_historical_folds(db_path);
        let pending_mdk08 =
            crate::mdk08_migrate::pending_remainder(db_path, key, identity.public_key());
        let historical_media_secrets = crate::mdk08_migrate::load_historical_media_secrets(db_path);
        let engine = Self {
            session: Mutex::new(Some(session)),
            identity,
            dm_autoaccept_budget: Mutex::new(DmAutoacceptBudget::load(db_path)),
            db_path: Some(db_path.to_path_buf()),
            key_package_slot_memo: Mutex::new(None),
            pending_refs: Mutex::new(HashMap::new()),
            parked_invites: Mutex::new(parked),
            dropped_groups: Mutex::new(dropped),
            transcript: Mutex::new(transcript),
            transcript_key,
            transcript_io: Mutex::new(()),
            transcript_journal_bytes: std::sync::atomic::AtomicU64::new(loaded.journal_bytes),
            transcript_writable: std::sync::atomic::AtomicBool::new(loaded.writable),
            pending_convergence: Mutex::new(HashSet::new()),
            historical_group_names: Mutex::new(historical_group_names),
            historical_group_descriptions: Mutex::new(
                crate::mdk08_migrate::load_historical_group_descriptions(db_path),
            ),
            historical_members: Mutex::new(historical_members),
            historical_member_counts: Mutex::new(
                crate::mdk08_migrate::load_historical_member_counts(db_path),
            ),
            historical_folds: Mutex::new(historical_folds),
            pending_mdk08: Mutex::new(pending_mdk08),
            historical_media_secrets: Mutex::new(historical_media_secrets),
            _tempdir: None,
        };
        if transcript_healed {
            engine.persist_transcript();
        }
        Ok(engine)
    }

    pub fn has_pending_mdk08_remainder(&self) -> bool {
        self.pending_mdk08
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .is_some()
    }

    /// Copy leftover 0.8 chat rows from `*.mdk08.bak` into the transcript.
    /// One idle tick joins at most [`REMAINDER_MESSAGES_PER_TICK`] payloads.
    pub fn ensure_mdk08_remainder(&self) -> Result<()> {
        self.ensure_mdk08_remainder_budget(crate::mdk08_migrate::REMAINDER_MESSAGES_PER_TICK, None)
    }

    /// `messages()` must return the full recovered transcript, so drain every
    /// remainder page. Host first-paint pages and idle sync use one tick.
    pub fn drain_mdk08_remainder(&self) -> Result<()> {
        while self.has_pending_mdk08_remainder() {
            self.ensure_mdk08_remainder()?;
        }
        Ok(())
    }

    fn ensure_mdk08_remainder_budget(
        &self,
        budget: usize,
        only_group: Option<&GroupId>,
    ) -> Result<()> {
        let pending = {
            let mut slot = self
                .pending_mdk08
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            slot.take()
        };
        let Some(pending) = pending else {
            return Ok(());
        };
        let skip = {
            let transcript = self
                .transcript
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            transcript
                .values()
                .flatten()
                .map(|msg| msg.id)
                .collect::<HashSet<_>>()
        };
        let omit_groups = self.dropped_group_id_set();
        let extracted = match crate::mdk08_migrate::detect_and_extract_remainder(
            &pending.bak_path,
            pending.key,
            pending.local_pk,
            &skip,
            budget,
            only_group,
            &omit_groups,
        ) {
            Ok(Some((extracted, more))) => {
                if more {
                    let mut slot = self
                        .pending_mdk08
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    *slot = Some(pending);
                }
                extracted
            }
            Ok(None) => {
                let mut slot = self
                    .pending_mdk08
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                *slot = Some(pending);
                return Err(Error::Storage(
                    "0.8 remainder bak unreadable; leftover rows kept pending".into(),
                ));
            }
            Err(err) => {
                let mut slot = self
                    .pending_mdk08
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                *slot = Some(pending);
                return Err(err);
            }
        };
        {
            let mut transcript = self
                .transcript
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            for msgs in extracted.messages.into_values() {
                for msg in msgs {
                    if omit_groups.contains(&msg.group_id) {
                        continue;
                    }
                    let rows = transcript.entry(msg.group_id.clone()).or_default();
                    if !rows.iter().any(|existing| existing.id == msg.id) {
                        rows.push(msg);
                    }
                }
            }
        }
        self.persist_transcript();
        if !self.has_pending_mdk08_remainder() {
            if let Some(path) = self.db_path.as_ref() {
                crate::mdk08_migrate::mark_remainder_complete(path)?;
            }
        }
        Ok(())
    }

    /// Copy leftover bak rows for this conversation until `enough` or the
    /// group's remaining 0.8 rows are exhausted. Other chats stay pending.
    fn fill_mdk08_remainder_for_page(
        &self,
        group_id: &GroupId,
        enough: impl Fn(&Self) -> bool,
    ) -> Result<()> {
        if self
            .fold_family(group_id)
            .iter()
            .all(|id| self.is_dropped(id))
        {
            return Ok(());
        }
        while self.has_pending_mdk08_remainder() && !enough(self) {
            let before = self.transcript_for_family(group_id).len();
            let mut progressed = false;
            for target in self.fold_family(group_id) {
                self.ensure_mdk08_remainder_budget(
                    crate::mdk08_migrate::REMAINDER_MESSAGES_PER_TICK,
                    Some(&target),
                )?;
                if self.transcript_for_family(group_id).len() > before {
                    progressed = true;
                    break;
                }
            }
            if !progressed {
                break;
            }
        }
        Ok(())
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
        if self.shares_recovered_chat_with(welcomer) {
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

    /// A peer from a recovered (unfolded, not deleted) 0.8 conversation is
    /// not a stranger. Right after the 0.8 → 0.9 upgrade no live 0.9 group
    /// exists yet, so [`Self::shared_active_groups_with`] is 0 for every
    /// contact: the first peers to resume burned the unknown-sender budget
    /// and the rest parked as an anonymous "Group chat · invite" instead of
    /// auto-joining and folding onto their recovered row (#613 QA i3).
    fn shares_recovered_chat_with(&self, welcomer: &PublicKey) -> bool {
        let Ok(recovered) = self.historical_groups() else {
            return false;
        };
        recovered
            .iter()
            .take(SHARED_GROUP_SCAN_CAP)
            .any(|group| group.members.contains(welcomer))
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
        let known_sender = self.shared_active_groups_with(welcomer, 1) > 0
            || self.shares_recovered_chat_with(welcomer);
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
        crate::mdk08_migrate::wipe_mdk08_backups(base)
    }

    /// Group ids that have host-owned transcript rows, including history
    /// recovered from an MDK 0.8 store. These may not be live 0.9 MLS groups.
    pub fn transcript_group_ids(&self) -> Vec<GroupId> {
        let mut ids: Vec<GroupId> = self
            .transcript
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .keys()
            .cloned()
            .collect();
        ids.sort_by(|a, b| a.as_slice().cmp(b.as_slice()));
        ids
    }

    /// Title recovered from an MDK 0.8 `groups` row, if any.
    pub fn historical_group_name(&self, group_id: &GroupId) -> Option<String> {
        self.historical_group_names
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(group_id)
            .cloned()
    }

    /// Description recovered from an MDK 0.8 `groups` / welcome row, if any.
    pub fn historical_group_description(&self, group_id: &GroupId) -> Option<String> {
        self.historical_group_descriptions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(group_id)
            .cloned()
    }

    /// True when `group_id` is a live (or still-unhydrated) 0.9 MLS group.
    pub fn is_live_group(&self, group_id: &GroupId) -> Result<bool> {
        self.with_session_mut(|session| {
            if session.live_group_ids()?.iter().any(|id| id == group_id) {
                return Ok(true);
            }
            Ok(session
                .unhydrated_group_ids()
                .iter()
                .any(|id| id == group_id))
        })
    }

    /// Recovered 0.8 conversations that are not live 0.9 MLS groups.
    ///
    /// Members are unique transcript senders plus the local identity, so hosts
    /// can fold by npub the same way they fold duplicate direct DMs.
    pub fn historical_groups(&self) -> Result<Vec<HistoricalGroup>> {
        let live = self.live_group_id_set()?;
        let mut out = Vec::new();
        for id in self.recovered_group_ids() {
            if live.contains(&id) || self.is_dropped(&id) {
                continue;
            }
            // A live fold sibling may only exist as transcript until MLS lists it.
            if self.live_fold_target(&id).as_ref() == Some(&id) {
                continue;
            }
            out.push(HistoricalGroup {
                name: self.historical_group_name(&id).unwrap_or_default(),
                members: self.historical_members(&id),
                id,
            });
        }
        Ok(out)
    }

    /// Transcript ids plus named / member-only 0.8 rows (outbound-only chats).
    pub fn recovered_group_ids(&self) -> Vec<GroupId> {
        let mut ids = self.transcript_group_ids();
        ids.extend(
            self.historical_group_names
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .keys()
                .cloned(),
        );
        ids.extend(
            self.historical_members
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .keys()
                .cloned(),
        );
        ids.retain(|id| !self.is_dropped(id));
        ids.sort_by(|a, b| a.as_slice().cmp(b.as_slice()));
        ids.dedup();
        ids
    }

    /// True when `group_id` is recovered 0.8 history and not a live 0.9 group.
    pub fn is_historical_group(&self, group_id: &GroupId) -> Result<bool> {
        Ok(self
            .historical_groups()?
            .iter()
            .any(|group| group.id == *group_id))
    }

    /// True when `url` is a recovered 0.8 attachment. Those rows keep `imeta`
    /// for the transcript bubble. Download/decrypt is refused unless a stored
    /// 0.8 `encrypted-media` exporter secret was copied onto the sidecar.
    pub fn recovered_08_media_unavailable(&self, group_id: &GroupId, url: &str) -> bool {
        self.is_recovered_08_attachment(group_id, url)
            && self.historical_media_secrets_for(group_id, url).is_empty()
    }

    fn is_recovered_08_attachment(&self, group_id: &GroupId, url: &str) -> bool {
        let msgs = self.messages_for_media_url(group_id, url);
        let Ok(historical) = self.historical_groups() else {
            return false;
        };
        let historical_ids: HashSet<&GroupId> = historical.iter().map(|group| &group.id).collect();
        for msg in &msgs {
            for media in &msg.media {
                if media.url != url {
                    continue;
                }
                if historical_ids.contains(&msg.group_id) {
                    return true;
                }
                if (media.original_hash.is_none() || media.nonce.is_none())
                    && !self.is_live_group(&msg.group_id).unwrap_or(false)
                {
                    return true;
                }
            }
        }
        false
    }

    /// Recovered 0.8 groups whose transcript still names this blossom URL.
    /// Persist-folds can remount the bubble onto live before core
    /// `fold_family` exists — look the blob up by URL instead of inventing
    /// a fold (R-050).
    fn historical_ids_owning_media_url(&self, url: &str) -> Vec<GroupId> {
        let Ok(historical) = self.historical_groups() else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for group in historical {
            if self
                .transcript_for(&group.id)
                .iter()
                .any(|msg| msg.media.iter().any(|media| media.url == url))
            {
                out.push(group.id);
            }
        }
        out
    }

    fn messages_for_media_url(&self, group_id: &GroupId, url: &str) -> Vec<ChatMessage> {
        let mut msgs = self.transcript_for_family(group_id);
        let mut seen: HashSet<EventId> = msgs.iter().map(|msg| msg.id).collect();
        for hist_id in self.historical_ids_owning_media_url(url) {
            for msg in self.transcript_for(&hist_id) {
                if seen.insert(msg.id) {
                    msgs.push(msg);
                }
            }
        }
        msgs
    }

    fn historical_media_secrets_for(&self, group_id: &GroupId, url: &str) -> Vec<Vec<u8>> {
        let map = self
            .historical_media_secrets
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut ids = self.fold_family(group_id);
        for id in self.historical_ids_owning_media_url(url) {
            if !ids.iter().any(|existing| existing == &id) {
                ids.push(id);
            }
        }
        let mut out = Vec::new();
        for id in ids {
            if let Some(secrets) = map.get(&id) {
                for secret in secrets {
                    if !out.iter().any(|existing| existing == secret) {
                        out.push(secret.clone());
                    }
                }
            }
        }
        out
    }

    /// Other members of a recovered conversation (everyone except the local key).
    pub fn historical_resume_peers(&self, group_id: &GroupId) -> Vec<PublicKey> {
        let me = self.identity.public_key();
        self.historical_members(group_id)
            .into_iter()
            .filter(|pk| *pk != me)
            .collect()
    }

    /// True when this recovered chat should resume with `start_dm`.
    ///
    /// Matches live `group_is_direct`: a named 2-person room is not a DM, and
    /// a pending 0.8 room (`member_count > 2`) stays a group even if only the
    /// welcomer is known.
    pub fn historical_resume_is_direct(&self, group_id: &GroupId) -> bool {
        let peers = self.historical_resume_peers(group_id).len();
        let stored = self
            .historical_member_counts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(group_id)
            .copied();
        let members = stored.unwrap_or((peers as u32).saturating_add(1));
        if members > 2 {
            return false;
        }
        let name = self.historical_group_name(group_id).unwrap_or_default();
        let desc = self
            .historical_group_description(group_id)
            .unwrap_or_default();
        desc == SONAR_DIRECT_DM_DESCRIPTION || (desc.is_empty() && name.is_empty())
    }

    fn historical_members(&self, group_id: &GroupId) -> Vec<PublicKey> {
        let me = self.identity.public_key();
        let mut members: Vec<PublicKey> = self
            .transcript_for(group_id)
            .into_iter()
            .map(|m| m.sender)
            .collect();
        if let Some(stored) = self
            .historical_members
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(group_id)
            .cloned()
        {
            members.extend(stored);
        }
        members.push(me);
        members.sort_by(|a, b| a.to_hex().cmp(&b.to_hex()));
        members.dedup();
        members
    }

    fn live_group_id_set(&self) -> Result<HashSet<GroupId>> {
        self.with_session_mut(|session| {
            let mut ids: HashSet<GroupId> = session.live_group_ids()?.into_iter().collect();
            ids.extend(session.unhydrated_group_ids());
            Ok(ids)
        })
    }

    /// Recorded hist→live pairs (JSON sidecar). Used to backfill the
    /// conversation-index fold table after upgrade.
    pub fn historical_fold_pairs(&self) -> Vec<(GroupId, GroupId)> {
        let folds = self
            .historical_folds
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut pairs: Vec<(GroupId, GroupId)> = folds
            .iter()
            .map(|(historical, live)| (historical.clone(), live.clone()))
            .collect();
        pairs.sort_by(|a, b| a.0.as_slice().cmp(b.0.as_slice()));
        pairs
    }

    /// Live 0.9 groups that carry a recovered 0.8 fold sibling.
    pub fn live_resume_targets(&self) -> Vec<GroupId> {
        let folds = self
            .historical_folds
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut lives: Vec<GroupId> = folds.values().cloned().collect();
        lives.sort_by(|a, b| a.as_slice().cmp(b.as_slice()));
        lives.dedup();
        lives
    }

    /// Live 0.9 group that should carry sends for a recovered 0.8 row.
    pub fn live_fold_target(&self, group_id: &GroupId) -> Option<GroupId> {
        let folds = self
            .historical_folds
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(live) = folds.get(group_id) {
            return Some(live.clone());
        }
        if folds.values().any(|live| live == group_id) {
            return Some(group_id.clone());
        }
        None
    }

    /// Drop hist→live bindings (in-memory + sidecar).
    ///
    /// Tests use this to simulate a lost core fold sidecar after the host
    /// still remounts via `sonar.historicalFolds`. Production hosts must
    /// not call this — rebuild with `maybe_fold_new_group` instead.
    pub fn clear_historical_folds(&self) {
        self.historical_folds
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clear();
        self.persist_historical_folds();
    }

    /// Bind a recovered 0.8 group to the 0.9 group created with the same peers.
    pub fn record_historical_fold(&self, historical: &GroupId, live: &GroupId) {
        if historical == live {
            return;
        }
        let mut folds = self
            .historical_folds
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        folds.insert(historical.clone(), live.clone());
        drop(folds);
        self.persist_historical_folds();
    }

    /// Recovered and live ids that share one conversation after resume.
    pub fn fold_aliases(&self, group_id: &GroupId) -> Vec<GroupId> {
        self.fold_family(group_id)
    }

    fn fold_family(&self, group_id: &GroupId) -> Vec<GroupId> {
        let folds = self
            .historical_folds
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut family = vec![group_id.clone()];
        if let Some(live) = folds.get(group_id) {
            if !family.iter().any(|id| id == live) {
                family.push(live.clone());
            }
        }
        for (historical, live) in folds.iter() {
            if live == group_id && !family.iter().any(|id| id == historical) {
                family.push(historical.clone());
            }
        }
        family
    }

    fn persist_historical_folds(&self) {
        let Some(path) = self.db_path.as_ref() else {
            return;
        };
        let folds = self
            .historical_folds
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let keyed: HashMap<String, String> = folds
            .iter()
            .map(|(historical, live)| {
                (
                    hex::encode(historical.as_slice()),
                    hex::encode(live.as_slice()),
                )
            })
            .collect();
        let _ = atomic_write_json(&sidecar_named(path, HISTORICAL_FOLDS_FILE_SUFFIX), &keyed);
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
        self.create_group_with_admins(name, member_key_packages, relays, Vec::new())
            .await
    }

    /// Like [`Self::create_group`], with extra founding admins besides the
    /// creator. Production groups keep this empty so invitees can Leave;
    /// competing-commit tests pass a co-admin because Invite is admin-only.
    pub async fn create_group_with_admins(
        &self,
        name: &str,
        member_key_packages: Vec<Event>,
        relays: Vec<RelayUrl>,
        extra_admins: Vec<PublicKey>,
    ) -> Result<GroupCreation> {
        self.create_group_with_description(name, "", member_key_packages, relays, extra_admins)
            .await
    }

    pub(crate) async fn create_group_with_description(
        &self,
        name: &str,
        description: &str,
        member_key_packages: Vec<Event>,
        relays: Vec<RelayUrl>,
        extra_admins: Vec<PublicKey>,
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
        // Founder is always an admin. Extra ids bootstrap co-admins
        // (MIP-03 competing commits). Default empty: invitees can Leave.
        let initial_admins = extra_admins
            .into_iter()
            .map(|pk| MemberId::new(pk.to_bytes().to_vec()))
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
        // MDK 0.9 has no demote SendIntent. MIP-03 Leave refuses admins
        // (`EngineError::AdminCannotSelfRemove`). Calling Leave here would
        // recurse from `SonarClient::leave_group`'s recovery arm. Invitees
        // are created with empty `initial_admins` so they can Leave; the
        // founding admin cannot until MDK grows a demote commit.
        Err(Error::InvalidInput(format!(
            "MDK 0.9 has no self-demote commit for {}; leave the admin set first",
            hex::encode(group_id.as_slice())
        )))
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

    /// Apply buffered MIP-03 commits after the convergence quiescence
    /// window. Ingest leaves competing commits `Buffered`; the host must
    /// call this after the cutoff (tests sleep ~1.1s; the live client
    /// should schedule the same).
    ///
    /// MDK may replay PeelDeferred application messages in this same drain.
    /// Those `MessageReceived` events must land in the local transcript here:
    /// a later relay redelivery of the same ciphertext is a durable
    /// Duplicate keyed by content-id, which `lookup_chat` cannot find from
    /// the Nostr event id.
    fn note_pending_convergence(&self, group_id: GroupId) {
        self.pending_convergence
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(group_id);
    }

    /// Apply MIP-03 buffered commits for every group ingest parked.
    ///
    /// Call this after a relay-sync batch or, in tests/sim, after sleeping
    /// the ~1.1s quiescence window. Ingest itself must not wait on that
    /// window (Signal-comparable receive path).
    pub async fn apply_pending_convergence(&self) -> Result<()> {
        let ids: Vec<GroupId> = self
            .pending_convergence
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .cloned()
            .collect();
        for id in ids {
            if self.is_dropped(&id) {
                self.pending_convergence
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .remove(&id);
                continue;
            }
            self.advance_group_convergence(&id).await?;
        }
        Ok(())
    }

    pub async fn advance_group_convergence(&self, group_id: &GroupId) -> Result<()> {
        if self.is_dropped(group_id) {
            return Ok(());
        }
        let mut lease = self.lease_session().await;
        let _ = lease.get_mut().ensure_group_hydrated(group_id);
        let _ = lease
            .get_mut()
            .prepare_convergence_cutoff_delay_ms(group_id);
        let mut effects = lease.get_mut().advance_convergence(group_id).await?;
        let drained = lease.get_mut().drain();
        merge_session_effects(&mut effects, drained);
        drop(lease);
        let _ = self.persist_session_effects(effects)?;
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
        if self.is_recovered_08_attachment(group_id, url) {
            let secrets = self.historical_media_secrets_for(group_id, url);
            if secrets.is_empty() {
                return Err(Error::Media(RECOVERED_08_MEDIA_UNAVAILABLE.to_owned()));
            }
            let mut last_err = None;
            for secret in secrets {
                match self.decrypt_media_url_with_secret(group_id, url, ciphertext, &secret) {
                    Ok(plain) => return Ok(plain),
                    Err(err) => last_err = Some(err),
                }
            }
            return Err(
                last_err.unwrap_or_else(|| Error::Media(RECOVERED_08_MEDIA_UNAVAILABLE.to_owned()))
            );
        }
        // After resume the host may still pass the recovered id. New 0.9
        // attachments live on the fold target and must use that exporter.
        let secret_group = self
            .live_fold_target(group_id)
            .unwrap_or_else(|| group_id.clone());
        let secret = self.media_exporter_secret(&secret_group)?;
        self.decrypt_media_url_with_secret(group_id, url, ciphertext, &secret)
    }

    fn decrypt_media_url_with_secret(
        &self,
        group_id: &GroupId,
        url: &str,
        ciphertext: &[u8],
        secret: &[u8],
    ) -> Result<Vec<u8>> {
        let msgs = self.messages_for_media_url(group_id, url);
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
                    return media_crypto::decrypt_from_download(secret, ciphertext, &reference);
                }
            }
            for tag in rumor_imeta_from_media(&m) {
                if let Ok(r) = media_crypto::parse_imeta_tag(&tag) {
                    if r.url == url {
                        return media_crypto::decrypt_from_download(secret, ciphertext, &r);
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
            if self.is_dropped(&existing.group_id) {
                return Ok(Incoming::None);
            }
            return Ok(Incoming::GroupInvitePending(existing.group_id));
        }
        let welcomer = unwrapped.sender;
        let meta = welcome_rumor_meta(&unwrapped.rumor);
        let welcome_group_id = parked_group_id_for_wrapper(wrapper, &meta);
        // Leave/decline marks this MLS id dropped. A later welcome for the
        // same group must not re-park or auto-join — resume is a new 0.9
        // group folded by npub, not resurrection of the deleted row.
        if self.is_dropped(&welcome_group_id) {
            return Ok(Incoming::None);
        }
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
        merge_session_effects(&mut effects, drained);
        drop(lease);

        tracing::debug!(
            ?outcome,
            effect_events = effects.events.len(),
            "ingest_event"
        );
        match outcome {
            IngestOutcome::Ignored { category } => {
                match category {
                    InputRejectionCategory::OwnEcho | InputRejectionCategory::Duplicate => {
                        if let Some(msg) = self.lookup_chat(&event.id) {
                            return Ok(Incoming::Message(msg));
                        }
                        // MDK 0.9 collapsed 0.8 PreviouslyFailed into Duplicate
                        // (Failed/Processed/EpochInvalidated share this category).
                        // A Duplicate with no transcript row must not become
                        // Incoming::None — that path durable-dedups the event
                        // and hides a ciphertext MLS rollback can make Retryable.
                        if category == InputRejectionCategory::Duplicate {
                            return Ok(Incoming::Failed);
                        }
                        return Ok(Incoming::None);
                    }
                    _ => return Ok(Incoming::None),
                }
            }
            IngestOutcome::Rejected { .. } | IngestOutcome::Stale { .. } => {
                return Ok(Incoming::Failed)
            }
            IngestOutcome::Buffered { group_id, .. } => {
                if self.is_dropped(&group_id) {
                    return Ok(Incoming::None);
                }
                // MDK accepted the commit into durable storage but will not
                // apply it until `advance_convergence` after the MIP-03
                // quiescence window. Returning Failed here made sonar-sim
                // and relay sync treat a valid add-members commit as a
                // decrypt miss, so the roster never grew past the founding
                // batch. Schedule the group and surface GroupUpdated so the
                // host can apply it off the ingest path.
                self.note_pending_convergence(group_id.clone());
                let _ = self.persist_session_effects(effects);
                return Ok(Incoming::GroupUpdated(group_id));
            }
            IngestOutcome::TransportDeferred { .. } | IngestOutcome::ResourceRefused { .. } => {
                return Ok(Incoming::Failed)
            }
            IngestOutcome::LocalState { .. } => return Ok(Incoming::None),
            _ => {}
        }

        if let Some(update) = self.try_membership_from_effects(&effects)? {
            return Ok(Incoming::GroupProposal(update));
        }

        self.persist_session_effects(effects)
    }

    fn persist_session_effects(&self, effects: SessionEffects) -> Result<Incoming> {
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
                    // Leave/delete marks the fold family dropped. Relay replay
                    // of an old kind-445 must not rewrite the transcript or
                    // surface Incoming::Message (hosts upsert + notify from that).
                    if self.is_dropped(&group_id) {
                        continue;
                    }
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
                    last = if self.is_dropped(&group_id) {
                        Incoming::None
                    } else {
                        Incoming::GroupUpdated(group_id)
                    };
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

    /// Kind-445 `#h` tag: the 32-byte Nostr routing id, not the MLS [`GroupId`].
    ///
    /// MDK 0.9 puts a random 32-byte `nostr_group_id` in the founding
    /// `NostrRoutingV1` component. Relays and White Noise index kind-445 on
    /// that value. The host-facing MLS group id stays 16 bytes.
    pub fn nostr_h_tag_hex(&self, mls_group_id: &GroupId) -> Result<Option<String>> {
        self.with_session_mut(|session| {
            if !session.ensure_group_hydrated(mls_group_id)? {
                return Ok(None);
            }
            let Some(bytes) = session.app_component(mls_group_id, NOSTR_ROUTING_COMPONENT_ID)?
            else {
                return Ok(None);
            };
            match decode_nostr_routing_v1(&bytes) {
                Ok(routing) => Ok(Some(hex::encode(routing.nostr_group_id))),
                Err(e) => {
                    tracing::debug!(error = %e, "nostr routing component unreadable");
                    Ok(None)
                }
            }
        })
    }

    pub fn pending_group_invites(&self) -> Result<Vec<GroupInvite>> {
        let dropped = self.dropped_group_id_set();
        let parked = self
            .parked_invites
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Ok(parked
            .values()
            .filter(|invite| !dropped.contains(&invite.group_id))
            .cloned()
            .collect())
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
        if self.is_dropped(&invite.group_id) {
            return Err(Error::InvalidInput(
                "this invite belongs to a chat you already left".into(),
            ));
        }
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
        self.drain_mdk08_remainder()?;
        self.mapped_transcript(group_id)
    }

    fn mapped_transcript(&self, group_id: &GroupId) -> Result<Vec<ChatMessage>> {
        let mut mapped = self.transcript_for_family(group_id);
        mapped.sort_by(|a, b| {
            a.created_at
                .cmp(&b.created_at)
                .then_with(|| a.id.cmp(&b.id))
        });
        hydrate_page_reply_previews(self, &mut mapped);
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
        let want = offset.saturating_add(limit);
        self.fill_mdk08_remainder_for_page(group_id, |engine| {
            engine.transcript_for_family(group_id).len() >= want
        })?;
        let mut msgs = self.mapped_transcript(group_id)?;
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
        self.fill_mdk08_remainder_for_page(group_id, |engine| {
            engine
                .transcript_for_family(group_id)
                .into_iter()
                .filter(|m| {
                    is_before_message_cursor(m.created_at.as_secs(), &m.id, before_secs, before_id)
                })
                .count()
                >= limit
        })?;
        let mut candidates: Vec<ChatMessage> = self
            .transcript_for_family(group_id)
            .into_iter()
            .filter(|m| {
                is_before_message_cursor(m.created_at.as_secs(), &m.id, before_secs, before_id)
            })
            .collect();
        candidates.sort_unstable_by(compare_message_cursor_desc);
        candidates.truncate(limit);
        hydrate_page_reply_previews(self, &mut candidates);
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
        let mut seen: HashSet<GroupId> = HashSet::new();
        // Live groups first. A recovered 0.8 id that already has a 0.9 fold
        // sibling must not take a second bounded home-list slot — hosts fold
        // by npub, but this page window is the first-paint source.
        let mut ids: Vec<GroupId> = self.groups()?.into_iter().map(|g| g.id).collect();
        for hist in self.historical_groups()? {
            if let Some(live) = self.live_fold_target(&hist.id) {
                if !ids.iter().any(|id| id == &live) {
                    ids.push(live);
                }
                continue;
            }
            ids.push(hist.id);
        }
        for group_id in ids {
            if !seen.insert(group_id.clone()) {
                continue;
            }
            let messages = self.messages_page(&group_id, page_limit, 0)?;
            let Some(latest_created_at) = messages.iter().map(|m| m.created_at).max() else {
                continue;
            };
            pages.push(RecentMessagePage {
                group_id,
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
        if self.is_live_group(group_id).unwrap_or(false) {
            return self.with_session(|session| {
                let members = session.members(group_id)?;
                Ok(members
                    .into_iter()
                    .filter_map(|m| PublicKey::from_slice(m.id.as_slice()).ok())
                    .collect())
            });
        }
        Ok(self.historical_members(group_id))
    }

    /// Roster hosts should paint for this conversation.
    ///
    /// Unions live MLS members with recovered 0.8 fold-family rosters so a
    /// remounted room still lists people who have not joined the 0.9 group
    /// yet. Do **not** use this for resume / `missing_resume_peers`: that
    /// path must keep [`Self::members`] as the live session only, or leftover
    /// peers look already invited and are never added.
    pub fn display_members(&self, group_id: &GroupId) -> Result<Vec<PublicKey>> {
        let mut members = Vec::new();
        for alias in self.fold_family(group_id) {
            members.extend(self.members(&alias)?);
        }
        members.sort_by(|a, b| a.to_hex().cmp(&b.to_hex()));
        members.dedup();
        Ok(members)
    }

    /// Title hosts should paint for this conversation.
    ///
    /// Live MLS name wins (a later rename must stick). When that is blank
    /// after remount, fall back to a recovered 0.8 fold-family name so a
    /// named room does not become "Group chat". Do **not** use this for
    /// `group_is_direct` — that path must keep the live session name.
    pub fn display_name(&self, group_id: &GroupId, live_name: &str) -> String {
        let trimmed = live_name.trim();
        if !trimmed.is_empty() {
            return trimmed.to_owned();
        }
        for alias in self.fold_family(group_id) {
            if let Some(name) = self.historical_group_name(&alias) {
                let name = name.trim();
                if !name.is_empty() {
                    return name.to_owned();
                }
            }
        }
        String::new()
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

    /// Newest peer-authored chat row on this live MLS id only.
    ///
    /// Catch-up `since` must not use folded 0.8 hist. A recovered transcript
    /// can be days newer than unread 0.9 traffic from a peer who upgraded
    /// first; a family floor would skip those events past the 1h lookback.
    pub fn latest_remote_chat_message_secs(&self, group_id: &GroupId) -> Option<u64> {
        let me = self.identity.public_key();
        self.transcript_for(group_id)
            .into_iter()
            .filter(|m| m.sender != me)
            .map(|m| m.created_at.as_secs())
            .max()
    }

    /// True when this live MLS id has no locally stored chat rows.
    /// Folded 0.8 hist must not count — empty-transcript repair has to
    /// full-backfill a new 0.9 sibling that only has recovered history.
    pub fn live_chat_page_empty(&self, group_id: &GroupId) -> bool {
        self.transcript_for(group_id).is_empty()
    }

    pub async fn delete_group(&self, group_id: &GroupId) -> Result<()> {
        let leave_ids: Vec<GroupId> = self
            .fold_family(group_id)
            .into_iter()
            .filter(|id| self.is_live_group(id).unwrap_or(false))
            .collect();
        self.purge_fold_family(group_id);
        for id in leave_ids {
            let _ = self.leave_group(&id).await;
        }
        Ok(())
    }

    /// Drop local transcript + fold bindings for this conversation and every
    /// recovered sibling. A later `start_dm` with the same peer must not
    /// resurrect a chat the user already deleted.
    pub fn purge_fold_family(&self, group_id: &GroupId) {
        let family = self.fold_family(group_id);
        // Mark dropped before clearing rows so a concurrent remainder tick or
        // relay ingest cannot rewrite the transcript in the window between
        // persist_transcript and persist_dropped.
        for id in &family {
            self.drop_group(id);
        }
        {
            let mut transcript = self
                .transcript
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            for id in &family {
                transcript.remove(id);
            }
        }
        self.persist_transcript();
        {
            let mut folds = self
                .historical_folds
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            folds
                .retain(|historical, live| !family.iter().any(|id| id == historical || id == live));
        }
        self.persist_historical_folds();
        {
            let mut secrets = self
                .historical_media_secrets
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            for id in &family {
                secrets.remove(id);
            }
        }
        if let Some(path) = self.db_path.as_ref() {
            crate::mdk08_migrate::forget_historical_metadata(path, &family);
        }
        self.forget_in_memory_historical_sidecars(&family);
        {
            let mut parked = self
                .parked_invites
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let before = parked.len();
            parked.retain(|_, invite| !family.iter().any(|id| id == &invite.group_id));
            if parked.len() != before {
                drop(parked);
                self.persist_parked();
            }
        }
    }

    fn forget_in_memory_historical_sidecars(&self, family: &[GroupId]) {
        let mut names = self
            .historical_group_names
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut descriptions = self
            .historical_group_descriptions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut members = self
            .historical_members
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut counts = self
            .historical_member_counts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        for id in family {
            names.remove(id);
            descriptions.remove(id);
            members.remove(id);
            counts.remove(id);
        }
    }

    fn store_chat(&self, msg: ChatMessage) {
        if self.is_dropped(&msg.group_id) {
            return;
        }
        let _io = self
            .transcript_io
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        {
            let mut transcript = self
                .transcript
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let rows = transcript.entry(msg.group_id.clone()).or_default();
            if rows.iter().any(|m| m.id == msg.id) {
                return;
            }
            rows.push(msg.clone());
        }
        self.append_transcript_journal_locked(&msg);
    }

    /// O(1) durable write of one new row. Caller holds `transcript_io`.
    fn append_transcript_journal_locked(&self, msg: &ChatMessage) {
        use std::io::Write as _;
        use std::sync::atomic::Ordering as AtomicOrdering;
        let Some(path) = self.db_path.as_ref() else {
            return;
        };
        if !self.transcript_writable.load(AtomicOrdering::Relaxed) {
            return;
        }
        let record =
            match crate::transcript_sidecar::encode_journal_record(&self.transcript_key, msg) {
                Ok(record) => record,
                Err(err) => {
                    tracing::error!(%err, "transcript journal seal failed; rewriting the snapshot");
                    self.persist_transcript_locked();
                    return;
                }
            };
        let appended = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(sidecar_named(path, TRANSCRIPT_JOURNAL_FILE_SUFFIX))
            .and_then(|mut journal| journal.write_all(&record));
        match appended {
            Ok(()) => {
                let total = self
                    .transcript_journal_bytes
                    .fetch_add(record.len() as u64, AtomicOrdering::Relaxed)
                    + record.len() as u64;
                if total > TRANSCRIPT_JOURNAL_COMPACT_BYTES {
                    self.persist_transcript_locked();
                }
            }
            Err(err) => {
                tracing::warn!(%err, "transcript journal append failed; rewriting the snapshot");
                self.persist_transcript_locked();
            }
        }
    }

    fn lookup_chat(&self, id: &EventId) -> Option<ChatMessage> {
        self.transcript
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .flatten()
            .find(|m| m.id == *id)
            .cloned()
            .filter(|m| !self.is_dropped(&m.group_id))
    }

    fn transcript_for(&self, group_id: &GroupId) -> Vec<ChatMessage> {
        if self.is_dropped(group_id) {
            return Vec::new();
        }
        self.transcript
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(group_id)
            .cloned()
            .unwrap_or_default()
    }

    fn transcript_for_family(&self, group_id: &GroupId) -> Vec<ChatMessage> {
        let mut msgs = Vec::new();
        let mut seen = HashSet::new();
        for id in self.fold_family(group_id) {
            for msg in self.transcript_for(&id) {
                if seen.insert(msg.id) {
                    msgs.push(msg);
                }
            }
        }
        msgs
    }

    /// Test helper: append a host-owned transcript row without MLS ingest.
    #[cfg(test)]
    pub(crate) fn push_transcript_message(&self, msg: ChatMessage) {
        self.store_chat(msg);
    }

    /// Stored 0.8 `member_count` when extract copied it, else inferred
    /// from the recovered roster (peers + local).
    pub fn historical_declared_member_count(&self, group_id: &GroupId) -> u32 {
        self.historical_member_counts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(group_id)
            .copied()
            .unwrap_or_else(|| self.historical_members(group_id).len() as u32)
    }

    #[cfg(test)]
    pub(crate) fn seed_historical_metadata(
        &self,
        group_id: GroupId,
        name: &str,
        members: Vec<PublicKey>,
        member_count: u32,
    ) {
        self.historical_group_names
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(group_id.clone(), name.to_string());
        self.historical_members
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(group_id.clone(), members);
        self.historical_member_counts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(group_id, member_count);
    }

    #[cfg(test)]
    pub(crate) fn add_historical_media_secret(&self, group_id: GroupId, secret: Vec<u8>) {
        self.historical_media_secrets
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(group_id)
            .or_default()
            .push(secret);
    }

    fn park_invite(&self, invite: GroupInvite) {
        if self.is_dropped(&invite.group_id) {
            return;
        }
        self.parked_invites
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(invite.id, invite);
        self.persist_parked();
    }

    #[cfg(test)]
    pub(crate) fn park_invite_for_test(&self, invite: GroupInvite) {
        self.park_invite(invite);
    }

    fn drop_group(&self, group_id: &GroupId) {
        self.dropped_groups
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(group_id.clone());
        self.persist_dropped();
    }

    pub(crate) fn is_dropped(&self, group_id: &GroupId) -> bool {
        self.dropped_groups
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(group_id)
    }

    fn dropped_group_id_set(&self) -> HashSet<GroupId> {
        self.dropped_groups
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
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

    /// Rewrite the sealed snapshot and drop the journal it now covers.
    /// Structural changes (purge, remainder copy, heal) call this; plain new
    /// rows go through the O(1) journal in [`Self::store_chat`].
    fn persist_transcript(&self) {
        let _io = self
            .transcript_io
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.persist_transcript_locked();
    }

    /// Caller holds `transcript_io`.
    fn persist_transcript_locked(&self) {
        use std::sync::atomic::Ordering as AtomicOrdering;
        let Some(path) = self.db_path.as_ref() else {
            return;
        };
        if !self.transcript_writable.load(AtomicOrdering::Relaxed) {
            return;
        }
        let dropped = self.dropped_group_id_set();
        let sealed = {
            let transcript = self
                .transcript
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            // Borrow rows: cloning the whole transcript under the lock doubled
            // the cost and stalled concurrent page reads.
            let keyed: HashMap<String, &Vec<ChatMessage>> = transcript
                .iter()
                .filter(|(id, _)| !dropped.contains(*id))
                .map(|(id, msgs)| (hex::encode(id.as_slice()), msgs))
                .collect();
            crate::transcript_sidecar::encode_snapshot(&self.transcript_key, &keyed)
        };
        let sealed = match sealed {
            Ok(sealed) => sealed,
            Err(err) => {
                tracing::error!(%err, "transcript seal failed; snapshot not rewritten");
                return;
            }
        };
        match atomic_write_bytes(&sidecar_named(path, TRANSCRIPT_FILE_SUFFIX), &sealed) {
            Ok(()) => {
                // The snapshot now holds every journaled row. A crash before
                // this removal only replays duplicates, which load dedupes.
                let _ = std::fs::remove_file(sidecar_named(path, TRANSCRIPT_JOURNAL_FILE_SUFFIX));
                self.transcript_journal_bytes
                    .store(0, AtomicOrdering::Relaxed);
            }
            Err(err) => tracing::warn!(%err, "transcript snapshot write failed"),
        }
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

/// Fill missing quote-chip text from this page, then from any stored
/// transcript row. Persist-folds serve a short live page whose parent
/// still sits on hist; same-page hydrate left those chips empty.
/// `lookup_chat` walks every transcript — do not invent a fold (R-050).
fn hydrate_page_reply_previews(engine: &MarmotEngine, msgs: &mut [ChatMessage]) {
    let mut by_id: HashMap<EventId, String> = msgs
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
    for m in msgs.iter() {
        let Some(reply) = m.reply.as_ref() else {
            continue;
        };
        if by_id.contains_key(&reply.parent_id) {
            continue;
        }
        let Some(parent) = engine.lookup_chat(&reply.parent_id) else {
            continue;
        };
        if let Some(t) = crate::reply::parent_content_for_preview(
            &parent.classification,
            parent.sticker_ref.is_some(),
            !parent.media.is_empty(),
            &parent.content,
        ) {
            by_id.insert(reply.parent_id, t.to_string());
        }
    }
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
    // SQLite shards are not tmp+rename. Every other suffix here is written
    // atomically; a crashed rename leaves `{suffix}.tmp` with the previous
    // account's transcript, exporter secrets, folds, or invite state.
    let sqlite_shards = ["", "-wal", "-shm", "-journal"];
    let atomic_sidecars = [
        SYNC_STATE_FILE_SUFFIX,
        OUTBOX_STATE_FILE_SUFFIX,
        DM_AUTOACCEPT_FILE_SUFFIX,
        KEY_PACKAGE_SLOT_FILE_SUFFIX,
        TRANSCRIPT_FILE_SUFFIX,
        TRANSCRIPT_JOURNAL_FILE_SUFFIX,
        PARKED_INVITES_FILE_SUFFIX,
        crate::invite_link::INVITE_LINK_STATE_FILE_SUFFIX,
        DROPPED_GROUPS_FILE_SUFFIX,
        crate::mdk08_migrate::HISTORICAL_GROUPS_FILE_SUFFIX,
        crate::mdk08_migrate::HISTORICAL_DESCRIPTIONS_SUFFIX,
        crate::mdk08_migrate::HISTORICAL_MEMBERS_FILE_SUFFIX,
        crate::mdk08_migrate::HISTORICAL_MEMBER_COUNTS_SUFFIX,
        crate::mdk08_migrate::HISTORICAL_EXPORTER_SECRETS_SUFFIX,
        crate::mdk08_migrate::MDK08_MIGRATED_MARKER_SUFFIX,
        HISTORICAL_FOLDS_FILE_SUFFIX,
    ];
    let mut paths = Vec::with_capacity(sqlite_shards.len() + atomic_sidecars.len() * 2);
    for suffix in sqlite_shards {
        paths.push(base.with_file_name(format!("{name}{suffix}")));
    }
    for suffix in atomic_sidecars {
        paths.push(base.with_file_name(format!("{name}{suffix}")));
        paths.push(base.with_file_name(format!("{name}{suffix}.tmp")));
    }
    // Transcripts moved aside because they did not open still hold history.
    for suffix in [TRANSCRIPT_FILE_SUFFIX, TRANSCRIPT_JOURNAL_FILE_SUFFIX] {
        paths.extend(unreadable_transcript_names(
            &base.with_file_name(format!("{name}{suffix}")),
        ));
    }
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

fn merge_session_effects(into: &mut SessionEffects, from: SessionEffects) {
    into.events.extend(from.events);
    into.publish.extend(from.publish);
    into.queued.extend(from.queued);
    into.pending_convergence.extend(from.pending_convergence);
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

fn load_historical_folds(db_path: &Path) -> HashMap<GroupId, GroupId> {
    let path = sidecar_named(db_path, HISTORICAL_FOLDS_FILE_SUFFIX);
    let Ok(bytes) = std::fs::read(path) else {
        return HashMap::new();
    };
    serde_json::from_slice::<HashMap<String, String>>(&bytes)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(historical, live)| {
            let historical = hex::decode(historical).ok().map(GroupId::new)?;
            let live = hex::decode(live).ok().map(GroupId::new)?;
            Some((historical, live))
        })
        .collect()
}

struct LoadedTranscript {
    rows: HashMap<GroupId, Vec<ChatMessage>>,
    journal_bytes: u64,
    /// Legacy plaintext snapshot: rewrite it sealed right away.
    needs_reseal: bool,
    writable: bool,
}

/// Snapshot + journal. A snapshot that does not open or parse is moved aside
/// (never overwritten — it may be the only copy of the user's history) and
/// the session starts empty; the old `unwrap_or_default()` then persisted the
/// empty map over it on the first new message.
fn load_transcript(
    db_path: &Path,
    key: &crate::transcript_sidecar::TranscriptKey,
) -> LoadedTranscript {
    use crate::transcript_sidecar::{
        decode_journal, decode_snapshot, is_sealed_snapshot, merge_rows,
    };
    let snapshot_path = sidecar_named(db_path, TRANSCRIPT_FILE_SUFFIX);
    let journal_path = sidecar_named(db_path, TRANSCRIPT_JOURNAL_FILE_SUFFIX);
    let mut needs_reseal = false;
    let mut writable = true;
    let mut snapshot_unreadable = false;
    let mut rows = match std::fs::read(&snapshot_path) {
        Ok(bytes) => match decode_snapshot(Some(key), &bytes) {
            Ok(rows) => {
                needs_reseal = !is_sealed_snapshot(&bytes);
                rows
            }
            Err(err) => {
                tracing::error!(%err, "transcript snapshot unreadable; moving it aside");
                snapshot_unreadable = true;
                writable = preserve_unreadable_transcript(&snapshot_path);
                Default::default()
            }
        },
        Err(_) => Default::default(),
    };
    let mut journal_bytes = 0;
    match std::fs::read(&journal_path) {
        // Same key as the snapshot: keep it for recovery, do not replay it.
        Ok(_) if snapshot_unreadable => {
            writable &= preserve_unreadable_transcript(&journal_path);
        }
        Ok(bytes) => {
            let (appended, clean) = decode_journal(key, &bytes);
            if !clean {
                tracing::warn!("transcript journal ends in a torn record; kept the rows before it");
                needs_reseal = true;
            }
            merge_rows(&mut rows, appended);
            journal_bytes = bytes.len() as u64;
        }
        Err(_) => {}
    }
    LoadedTranscript {
        rows: rows
            .into_iter()
            .filter_map(|(hex_id, msgs)| hex::decode(hex_id).ok().map(|b| (GroupId::new(b), msgs)))
            .collect(),
        journal_bytes,
        needs_reseal: needs_reseal && writable,
        writable,
    }
}

/// Rename an unreadable transcript file to `<file>.unreadable[.N]`. False when
/// no free name exists, in which case the caller must not write over it.
fn preserve_unreadable_transcript(path: &Path) -> bool {
    for name in unreadable_transcript_names(path) {
        if name.exists() {
            continue;
        }
        return std::fs::rename(path, &name).is_ok();
    }
    false
}

fn unreadable_transcript_names(path: &Path) -> Vec<PathBuf> {
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("transcript");
    std::iter::once(path.with_file_name(format!("{name}.unreadable")))
        .chain((1..=8).map(|n| path.with_file_name(format!("{name}.unreadable.{n}"))))
        .collect()
}

fn atomic_write_bytes(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_file_name(format!(
        "{}.tmp",
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("sidecar")
    ));
    std::fs::write(&tmp, bytes).and_then(|()| std::fs::rename(&tmp, path))
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

#[cfg(test)]
mod historical_fold_tests {
    use super::*;
    use std::collections::{HashMap, HashSet};

    use crate::identity::Identity;

    fn chat(id: u8, group: &[u8], sender: PublicKey, body: &str, mine: bool) -> ChatMessage {
        ChatMessage {
            id: EventId::from_slice(&[id; 32]).expect("event id"),
            group_id: GroupId::new(group.to_vec()),
            sender,
            content: body.to_owned(),
            created_at: Timestamp::from_secs(1_700_000_000 + u64::from(id)),
            mine,
            delivery_state: if mine {
                DeliveryState::Sent
            } else {
                DeliveryState::Received
            },
            media: Vec::new(),
            sticker_ref: None,
            classification: MessageClassification::of(body),
            reply: None,
        }
    }

    fn chat_replying(
        id: u8,
        group: &[u8],
        sender: PublicKey,
        body: &str,
        mine: bool,
        parent: u8,
        parent_pk: PublicKey,
    ) -> ChatMessage {
        let mut msg = chat(id, group, sender, body, mine);
        msg.reply = Some(ReplyRef {
            parent_id: EventId::from_slice(&[parent; 32]).expect("event id"),
            parent_pubkey: Some(parent_pk),
            preview: None,
        });
        msg
    }

    #[test]
    fn recovered_history_survives_fold_onto_new_group() {
        let alice = Identity::generate();
        let bob = Identity::generate();
        let engine = MarmotEngine::in_memory(alice.clone());
        let historical = GroupId::new(vec![0x11; 16]);
        let live = GroupId::new(vec![0x22; 16]);
        engine.push_transcript_message(chat(
            1,
            historical.as_slice(),
            bob.public_key(),
            "old hello",
            false,
        ));
        engine.push_transcript_message(chat(
            2,
            live.as_slice(),
            alice.public_key(),
            "new hello",
            true,
        ));
        engine.record_historical_fold(&historical, &live);

        let from_old = engine.messages(&historical).expect("historical messages");
        let from_new = engine.messages(&live).expect("live messages");
        assert_eq!(from_old.len(), 2, "fold must merge both transcripts");
        assert_eq!(from_new.len(), 2, "either id must read the same family");
        assert!(from_old.iter().any(|m| m.content == "old hello"));
        assert!(from_old.iter().any(|m| m.content == "new hello"));
        assert_eq!(
            from_old.iter().map(|m| m.id).collect::<HashSet<_>>(),
            from_new.iter().map(|m| m.id).collect::<HashSet<_>>()
        );

        let recovered = engine.historical_groups().expect("historical groups");
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].id, historical);
        assert!(recovered[0].members.contains(&bob.public_key()));
        assert_eq!(
            engine.historical_resume_peers(&historical),
            vec![bob.public_key()]
        );
        assert_eq!(engine.live_fold_target(&historical).as_ref(), Some(&live));
        let from_live = engine.fold_aliases(&live);
        let from_historical = engine.fold_aliases(&historical);
        assert!(
            from_live.contains(&historical),
            "live id must name the hidden 0.8 sibling"
        );
        assert!(
            from_historical.contains(&live),
            "hidden id must name the live sibling"
        );

        let pages = engine
            .recent_message_pages(8, 8)
            .expect("home-list pages after fold");
        assert_eq!(
            pages.len(),
            1,
            "a recovered+resumed person must occupy one bounded page slot"
        );
        assert_eq!(pages[0].group_id, live);
        assert_eq!(pages[0].messages.len(), 2);
    }

    #[test]
    fn display_members_unions_folded_historical_roster() {
        let alice = Identity::generate();
        let bob = Identity::generate();
        let carol = Identity::generate();
        let engine = MarmotEngine::in_memory(alice.clone());
        let historical = GroupId::new(vec![0x11; 16]);
        let live = GroupId::new(vec![0x22; 16]);
        engine.push_transcript_message(chat(
            1,
            historical.as_slice(),
            bob.public_key(),
            "old hello",
            false,
        ));
        engine
            .historical_members
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(
                historical.clone(),
                vec![bob.public_key(), carol.public_key()],
            );
        engine.record_historical_fold(&historical, &live);

        let live_only = engine.members(&live).expect("live members stay single-id");
        assert!(
            !live_only.contains(&bob.public_key()),
            "members(live) must not union the recovered roster or late-resume skips leftover peers"
        );
        assert!(
            !live_only.contains(&carol.public_key()),
            "members(live) must not union sidecar-only leftover members"
        );
        assert_eq!(live_only, vec![alice.public_key()]);

        let display = engine
            .display_members(&live)
            .expect("display members union the fold family");
        assert!(display.contains(&alice.public_key()));
        assert!(display.contains(&bob.public_key()));
        assert!(
            display.contains(&carol.public_key()),
            "remounted room must still list people who have not joined 0.9 yet"
        );
    }

    #[test]
    fn display_name_falls_back_to_folded_historical_title() {
        let alice = Identity::generate();
        let engine = MarmotEngine::in_memory(alice);
        let historical = GroupId::new(vec![0x11; 16]);
        let live = GroupId::new(vec![0x22; 16]);
        engine
            .historical_group_names
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(historical.clone(), "standup".into());
        engine.record_historical_fold(&historical, &live);

        assert_eq!(
            engine.display_name(&live, ""),
            "standup",
            "remounted room must keep the recovered 0.8 title when MLS name is blank"
        );
        assert_eq!(
            engine.display_name(&live, "new name"),
            "new name",
            "a later live rename must win over the recovered title"
        );
    }

    #[test]
    fn delete_live_group_purges_folded_historical_history() {
        let alice = Identity::generate();
        let bob = Identity::generate();
        let engine = MarmotEngine::in_memory(alice.clone());
        let historical = GroupId::new(vec![0x11; 16]);
        let live = GroupId::new(vec![0x22; 16]);
        engine.push_transcript_message(chat(
            1,
            historical.as_slice(),
            bob.public_key(),
            "old hello",
            false,
        ));
        engine.push_transcript_message(chat(
            2,
            live.as_slice(),
            alice.public_key(),
            "new hello",
            true,
        ));
        engine.record_historical_fold(&historical, &live);
        engine.purge_fold_family(&live);

        assert!(
            engine.messages(&historical).expect("historical").is_empty(),
            "deleted conversation must not keep recovered 0.8 rows"
        );
        assert!(
            engine.messages(&live).expect("live").is_empty(),
            "deleted conversation must not keep live 0.9 rows"
        );
        assert!(
            engine
                .historical_groups()
                .expect("historical groups")
                .is_empty(),
            "dropped recovered row must not stay listable for a later resume fold"
        );
        assert!(
            engine.live_fold_target(&historical).is_none(),
            "fold binding must die with the conversation"
        );
    }

    fn on_disk(path: &Path, suffix: &str) -> Vec<u8> {
        std::fs::read(sidecar_named(path, suffix)).unwrap_or_default()
    }

    /// #613 QA P1: after the 0.9 port the transcript is the only local copy
    /// of every message, and it was written as plaintext JSON — the 0.8 store
    /// it replaced was SQLCipher. Rows must be sealed at rest, appended O(1),
    /// and read back after a reopen.
    #[test]
    fn transcript_rows_are_sealed_at_rest_and_survive_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let alice = Identity::generate();
        let bob = Identity::generate();
        let group = [0x5a; 16];
        {
            let engine = MarmotEngine::persistent(alice.clone(), &path, [9u8; 32]).unwrap();
            engine.push_transcript_message(chat(
                1,
                &group,
                bob.public_key(),
                "the vault code is 4471",
                false,
            ));
            engine.push_transcript_message(chat(
                2,
                &group,
                alice.public_key(),
                "noted, burn this",
                true,
            ));
        }
        for suffix in [TRANSCRIPT_FILE_SUFFIX, TRANSCRIPT_JOURNAL_FILE_SUFFIX] {
            let bytes = on_disk(&path, suffix);
            assert!(
                !bytes.windows(9).any(|w| w == b"vault cod")
                    && !bytes.windows(9).any(|w| w == b"burn this"),
                "{suffix} holds chat plaintext"
            );
        }
        assert!(
            !on_disk(&path, TRANSCRIPT_JOURNAL_FILE_SUFFIX).is_empty(),
            "new rows append to the journal"
        );

        let reopened = MarmotEngine::persistent(alice.clone(), &path, [9u8; 32]).unwrap();
        let rows = reopened.transcript_for(&GroupId::new(group.to_vec()));
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].content, "the vault code is 4471");

        // A structural rewrite folds the journal into a sealed snapshot.
        reopened.persist_transcript();
        assert!(on_disk(&path, TRANSCRIPT_JOURNAL_FILE_SUFFIX).is_empty());
        assert!(crate::transcript_sidecar::is_sealed_snapshot(&on_disk(
            &path,
            TRANSCRIPT_FILE_SUFFIX
        )));
        drop(reopened);
        let again = MarmotEngine::persistent(alice, &path, [9u8; 32]).unwrap();
        assert_eq!(again.transcript_for(&GroupId::new(group.to_vec())).len(), 2);
    }

    /// A snapshot written by an earlier build in plaintext is read, then
    /// resealed on open instead of staying plaintext until the next rewrite.
    #[test]
    fn a_legacy_plaintext_transcript_is_resealed_on_open() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let alice = Identity::generate();
        drop(MarmotEngine::persistent(alice.clone(), &path, [9u8; 32]).unwrap());
        let legacy: HashMap<String, Vec<ChatMessage>> = HashMap::from([(
            hex::encode([0x5b; 16]),
            vec![chat(
                3,
                &[0x5b; 16],
                alice.public_key(),
                "old plaintext row",
                true,
            )],
        )]);
        std::fs::write(
            sidecar_named(&path, TRANSCRIPT_FILE_SUFFIX),
            serde_json::to_vec(&legacy).unwrap(),
        )
        .unwrap();
        let engine = MarmotEngine::persistent(alice, &path, [9u8; 32]).unwrap();
        assert_eq!(
            engine.transcript_for(&GroupId::new(vec![0x5b; 16])).len(),
            1
        );
        assert!(crate::transcript_sidecar::is_sealed_snapshot(&on_disk(
            &path,
            TRANSCRIPT_FILE_SUFFIX
        )));
    }

    /// The old loader turned an unparseable transcript into an empty map and
    /// the next message persisted that over the file: the whole history gone.
    /// A snapshot that does not open must be moved aside, never overwritten.
    #[test]
    fn an_unreadable_transcript_is_moved_aside_not_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let alice = Identity::generate();
        let snapshot = sidecar_named(&path, TRANSCRIPT_FILE_SUFFIX);
        let aside =
            |n: &str| snapshot.with_file_name(format!("marmot.sqlite{TRANSCRIPT_FILE_SUFFIX}{n}"));
        {
            let engine = MarmotEngine::persistent(alice.clone(), &path, [9u8; 32]).unwrap();
            engine.push_transcript_message(chat(
                4,
                &[0x5c; 16],
                alice.public_key(),
                "keep me",
                true,
            ));
            engine.persist_transcript();
        }
        // Damage the sealed snapshot (bit rot, a partial restore, …).
        let mut damaged = on_disk(&path, TRANSCRIPT_FILE_SUFFIX);
        let last = damaged.len() - 1;
        damaged[last] ^= 0xff;
        std::fs::write(&snapshot, &damaged).unwrap();

        let engine = MarmotEngine::persistent(alice.clone(), &path, [9u8; 32]).unwrap();
        assert!(engine
            .transcript_for(&GroupId::new(vec![0x5c; 16]))
            .is_empty());
        engine.push_transcript_message(chat(5, &[0x5c; 16], alice.public_key(), "new row", true));
        engine.persist_transcript();
        assert_eq!(
            std::fs::read(aside(".unreadable")).expect("preserved aside"),
            damaged,
            "the unreadable transcript is kept byte for byte, not overwritten"
        );
        drop(engine);

        // A second bad snapshot gets its own name; the first stays untouched.
        std::fs::write(&snapshot, b"SNTRXv1\0 not a sealed transcript").unwrap();
        drop(MarmotEngine::persistent(alice, &path, [9u8; 32]).unwrap());
        assert!(aside(".unreadable.1").exists());
        assert_eq!(std::fs::read(aside(".unreadable")).unwrap(), damaged);
    }

    #[test]
    fn a_large_journal_is_compacted_into_the_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("marmot.sqlite");
        let alice = Identity::generate();
        let engine = MarmotEngine::persistent(alice.clone(), &path, [9u8; 32]).unwrap();
        let body = "x".repeat(4096);
        for i in 0..200u8 {
            engine.push_transcript_message(chat(i, &[0x5d; 16], alice.public_key(), &body, true));
        }
        assert!(
            (on_disk(&path, TRANSCRIPT_JOURNAL_FILE_SUFFIX).len() as u64)
                <= TRANSCRIPT_JOURNAL_COMPACT_BYTES,
            "the journal is folded into the snapshot once it passes the threshold"
        );
        drop(engine);
        let reopened = MarmotEngine::persistent(alice, &path, [9u8; 32]).unwrap();
        assert_eq!(
            reopened.transcript_for(&GroupId::new(vec![0x5d; 16])).len(),
            200
        );
    }

    /// Leave/delete marks the family dropped. A later ingest / send echo
    /// (`store_chat`) must not rewrite the transcript the user already cleared.
    #[test]
    fn store_chat_skips_dropped_groups() {
        let alice = Identity::generate();
        let bob = Identity::generate();
        let engine = MarmotEngine::in_memory(alice.clone());
        let historical = GroupId::new(vec![0x11; 16]);
        let live = GroupId::new(vec![0x22; 16]);
        engine.push_transcript_message(chat(
            1,
            historical.as_slice(),
            bob.public_key(),
            "old hello",
            false,
        ));
        engine.record_historical_fold(&historical, &live);
        engine.purge_fold_family(&live);

        engine.push_transcript_message(chat(
            3,
            historical.as_slice(),
            bob.public_key(),
            "resurrected",
            false,
        ));
        engine.push_transcript_message(chat(
            4,
            live.as_slice(),
            alice.public_key(),
            "also resurrected",
            true,
        ));

        assert!(
            engine.messages(&historical).expect("historical").is_empty(),
            "ingest after Leave must not restore recovered 0.8 rows"
        );
        assert!(
            engine.messages(&live).expect("live").is_empty(),
            "ingest after Leave must not restore live 0.9 rows"
        );
    }

    /// Crash after persist_dropped and before persist_transcript leaves leftover
    /// rows on the sidecar. The next open must omit them and heal the file so
    /// an unrelated persist cannot write the deleted chat back.
    #[test]
    fn reopen_omits_dropped_transcript_rows() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("marmot.sqlite");
        let key = [0x42u8; 32];
        let historical = GroupId::new(vec![0x11; 16]);
        let alice = Identity::generate();
        let bob = Identity::generate();
        {
            let engine = MarmotEngine::persistent(alice.clone(), &db_path, key).expect("open");
            engine.push_transcript_message(chat(
                1,
                historical.as_slice(),
                bob.public_key(),
                "old hello",
                false,
            ));
            assert_eq!(engine.messages(&historical).expect("seeded").len(), 1);
            let dropped_path = db_path.with_file_name(format!(
                "marmot.sqlite{}",
                crate::marmot::DROPPED_GROUPS_FILE_SUFFIX
            ));
            std::fs::write(
                &dropped_path,
                serde_json::to_vec(&vec![hex::encode(historical.as_slice())])
                    .expect("dropped json"),
            )
            .expect("write dropped");
        }
        let engine = MarmotEngine::persistent(alice, &db_path, key).expect("reopen");
        assert!(
            engine.messages(&historical).expect("reopen").is_empty(),
            "next connectLocal must not paint a chat already marked dropped"
        );
        let transcript_path = db_path.with_file_name(format!(
            "marmot.sqlite{}",
            crate::marmot::TRANSCRIPT_FILE_SUFFIX
        ));
        let leftover = crate::transcript_sidecar::decode_snapshot(
            Some(&crate::transcript_sidecar::TranscriptKey::derive(&key)),
            &std::fs::read(&transcript_path).expect("healed transcript"),
        )
        .expect("transcript opens");
        assert!(
            !leftover.contains_key(&hex::encode(historical.as_slice())),
            "open must heal leftover dropped rows off the transcript sidecar"
        );
    }

    fn test_invite(group_id: &GroupId, welcomer: PublicKey, seed: u8) -> GroupInvite {
        GroupInvite {
            id: EventId::from_slice(&[seed; 32]).expect("event id"),
            wrapper_id: EventId::from_slice(&[seed; 32]).expect("event id"),
            group_id: group_id.clone(),
            group_name: "standup".into(),
            group_description: String::new(),
            welcomer,
            member_count: 3,
            relays: Vec::new(),
            wrapper_json: String::new(),
        }
    }

    /// Leave/delete must drop a parked multi-member invite for that family so
    /// the next home-list fetch cannot show "Group chat · invite" again.
    #[test]
    fn purge_fold_family_clears_parked_invites() {
        let alice = Identity::generate();
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("marmot.sqlite");
        let key = [0x42u8; 32];
        let gone = GroupId::new(vec![0x33; 16]);
        let keep = GroupId::new(vec![0x44; 16]);
        let engine = MarmotEngine::persistent(alice.clone(), &db_path, key).expect("open");
        engine.park_invite_for_test(test_invite(&gone, alice.public_key(), 1));
        engine.park_invite_for_test(test_invite(&keep, alice.public_key(), 2));
        assert_eq!(engine.pending_group_invites().expect("parked").len(), 2);
        engine.purge_fold_family(&gone);
        let pending = engine.pending_group_invites().expect("after leave");
        assert_eq!(pending.len(), 1, "only the unrelated invite may stay");
        assert_eq!(pending[0].group_id, keep);
        let parked_path = db_path.with_file_name(format!(
            "marmot.sqlite{}",
            crate::marmot::PARKED_INVITES_FILE_SUFFIX
        ));
        let leftover: Vec<serde_json::Value> =
            serde_json::from_slice(&std::fs::read(&parked_path).expect("parked sidecar"))
                .expect("parked json");
        assert_eq!(
            leftover.len(),
            1,
            "leave must heal the parked-invite sidecar, not only the in-memory map"
        );
    }

    /// Decline/leave marks the MLS id dropped. A later park of the same id
    /// (relay re-delivery) must not surface the invite again.
    #[test]
    fn park_invite_skips_dropped_groups() {
        let alice = Identity::generate();
        let engine = MarmotEngine::in_memory(alice.clone());
        let gone = GroupId::new(vec![0x33; 16]);
        engine.purge_fold_family(&gone);
        engine.park_invite_for_test(test_invite(&gone, alice.public_key(), 1));
        assert!(
            engine.pending_group_invites().expect("pending").is_empty(),
            "a later welcome for a left chat must not reappear as an invite"
        );
    }

    #[test]
    fn delete_live_group_forgets_historical_name_sidecar() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("marmot.sqlite");
        let key = [0x42u8; 32];
        let historical = GroupId::new(vec![0x11; 16]);
        let live = GroupId::new(vec![0x22; 16]);
        let mut names = HashMap::new();
        names.insert(hex::encode(historical.as_slice()), "standup".to_string());
        let sidecar = db_path.with_file_name(format!(
            "marmot.sqlite{}",
            crate::mdk08_migrate::HISTORICAL_GROUPS_FILE_SUFFIX
        ));
        std::fs::write(&sidecar, serde_json::to_vec(&names).expect("names json")).expect("write");
        let alice = Identity::generate();
        let engine = MarmotEngine::persistent(alice, &db_path, key).expect("fresh 0.9 store");
        engine.record_historical_fold(&historical, &live);
        engine.purge_fold_family(&live);
        let remaining = crate::mdk08_migrate::load_historical_group_names(&db_path);
        assert!(
            remaining.is_empty(),
            "deleted recovered title must leave the sidecar so Settings preview cannot list it"
        );
        assert!(
            !engine.recovered_group_ids().contains(&historical),
            "in-memory title leftover must not keep a deleted id listable for index seed"
        );
        assert!(
            engine.historical_group_name(&historical).is_none(),
            "Leave must drop the in-memory 0.8 title, not only the sidecar"
        );
        assert!(
            engine.historical_group_description(&historical).is_none(),
            "Leave must drop the in-memory 0.8 description"
        );
        let idx = crate::conversation_index::ConversationIndex::open_in_memory().expect("index");
        idx.seed_missing_recovered(&engine)
            .expect("seed after Leave");
        assert!(
            idx.summary(&hex::encode(historical.as_slice()))
                .expect("lookup")
                .is_none(),
            "connectLocal seed must not recreate a chat the user already left"
        );
    }

    /// A backup taken after resume-chat must keep the fold. Otherwise restore
    /// splits the person into a recovered row and a live 0.9 row.
    #[test]
    fn historical_fold_survives_account_backup_restore() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("marmot.sqlite");
        let key = [0x42u8; 32];
        let alice = Identity::generate();
        let bob = Identity::generate();
        let historical = GroupId::new(vec![0x11; 16]);
        let live = GroupId::new(vec![0x22; 16]);
        {
            let engine =
                MarmotEngine::persistent(alice.clone(), &db_path, key).expect("fresh 0.9 store");
            engine.push_transcript_message(chat(
                1,
                historical.as_slice(),
                bob.public_key(),
                "old hello",
                false,
            ));
            engine.push_transcript_message(chat(
                2,
                live.as_slice(),
                alice.public_key(),
                "new hello",
                true,
            ));
            engine.record_historical_fold(&historical, &live);
            drop(engine);
        }
        let key_hex = hex::encode(key);
        let package = crate::account_backup::read_account_backup_package(&db_path, &key_hex)
            .expect("seal after resume-chat");
        assert!(
            package
                .sidecar_files
                .iter()
                .any(|(name, bytes)| name == HISTORICAL_FOLDS_FILE_SUFFIX && !bytes.is_empty()),
            "fold mapping must be inside the backup"
        );
        let restore_dir = tempfile::tempdir().expect("restore dir");
        let restore_path = restore_dir.path().join("marmot.sqlite");
        crate::account_backup::write_account_backup_package(&restore_path, &package)
            .expect("restore");
        let restored =
            MarmotEngine::persistent(alice, &restore_path, key).expect("restored store plus fold");
        assert_eq!(restored.live_fold_target(&historical).as_ref(), Some(&live));
        let from_old = restored.messages(&historical).expect("union after restore");
        assert_eq!(from_old.len(), 2);
        assert!(from_old.iter().any(|m| m.content == "old hello"));
        assert!(from_old.iter().any(|m| m.content == "new hello"));
        let pages = restored
            .recent_message_pages(8, 8)
            .expect("home list after restore");
        assert_eq!(pages.len(), 1, "restore must not split the person");
        assert_eq!(pages[0].group_id, live);
    }

    fn photo(url: &str, hash: Option<[u8; 32]>, nonce: Option<[u8; 12]>) -> MediaRef {
        MediaRef {
            url: url.to_owned(),
            mime_type: "image/jpeg".to_owned(),
            filename: "old.jpg".to_owned(),
            width: Some(100),
            height: Some(80),
            duration_ms: None,
            original_hash: hash,
            nonce,
        }
    }

    fn chat_with_media(
        id: u8,
        group: &[u8],
        sender: PublicKey,
        url: &str,
        hash: Option<[u8; 32]>,
        nonce: Option<[u8; 12]>,
    ) -> ChatMessage {
        let mut msg = chat(id, group, sender, "", false);
        msg.media = vec![photo(url, hash, nonce)];
        msg
    }

    #[test]
    fn recovered_08_media_is_unavailable_even_with_imeta() {
        let alice = Identity::generate();
        let bob = Identity::generate();
        let engine = MarmotEngine::in_memory(alice.clone());
        let historical = GroupId::new(vec![0x11; 16]);
        let live = GroupId::new(vec![0x22; 16]);
        let old_url = "https://blossom.example/old.bin";
        let new_url = "https://blossom.example/new.bin";
        engine.push_transcript_message(chat_with_media(
            1,
            historical.as_slice(),
            bob.public_key(),
            old_url,
            Some([1u8; 32]),
            Some([2u8; 12]),
        ));
        engine.push_transcript_message(chat_with_media(
            2,
            live.as_slice(),
            alice.public_key(),
            new_url,
            Some([3u8; 32]),
            Some([4u8; 12]),
        ));
        engine.record_historical_fold(&historical, &live);

        assert!(engine.recovered_08_media_unavailable(&historical, old_url));
        assert!(engine.recovered_08_media_unavailable(&live, old_url));
        assert!(!engine.recovered_08_media_unavailable(&historical, new_url));
        assert!(!engine.recovered_08_media_unavailable(&live, new_url));

        let err = engine
            .decrypt_media_by_url(&historical, old_url, b"cipher")
            .expect_err("0.8 blobs must not try the 0.9 exporter");
        assert!(
            err.to_string().contains(RECOVERED_08_MEDIA_UNAVAILABLE),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn recovered_08_media_decrypts_with_stored_exporter_secret() {
        let alice = Identity::generate();
        let bob = Identity::generate();
        let engine = MarmotEngine::in_memory(alice.clone());
        let historical = GroupId::new(vec![0x11; 16]);
        let url = "https://blossom.example/old.bin";
        let secret = vec![0xABu8; 32];
        let upload = crate::media_crypto::encrypt_for_upload(
            &secret,
            b"photo-bytes",
            "image/jpeg",
            "old.jpg",
        )
        .expect("encrypt with stored 0.8 exporter");
        engine.push_transcript_message(chat_with_media(
            1,
            historical.as_slice(),
            bob.public_key(),
            url,
            Some(upload.original_hash),
            Some(upload.nonce),
        ));
        engine.add_historical_media_secret(historical.clone(), secret);
        assert!(!engine.recovered_08_media_unavailable(&historical, url));
        let plain = engine
            .decrypt_media_by_url(&historical, url, &upload.encrypted_data)
            .expect("stored 0.8 exporter must open the blob");
        assert_eq!(plain, b"photo-bytes");
        let live = GroupId::new(vec![0x22; 16]);
        engine.record_historical_fold(&historical, &live);
        assert!(!engine.recovered_08_media_unavailable(&live, url));
        let remounted = engine
            .decrypt_media_by_url(&live, url, &upload.encrypted_data)
            .expect("remounted live id must still open the recovered blob");
        assert_eq!(remounted, b"photo-bytes");
    }

    #[test]
    fn persist_folds_live_page_hydrates_reply_preview_from_hist_parent() {
        // Host sidecar remounts the live row before record_historical_fold.
        // A live-only cursor page must still fill the quote chip from the
        // hist parent — do not invent a fold (R-050).
        let alice = Identity::generate();
        let bob = Identity::generate();
        let engine = MarmotEngine::in_memory(alice.clone());
        let historical = GroupId::new(vec![0x11; 16]);
        let live = GroupId::new(vec![0x22; 16]);
        engine.push_transcript_message(chat(
            1,
            historical.as_slice(),
            bob.public_key(),
            "old hello",
            false,
        ));
        engine.push_transcript_message(chat_replying(
            2,
            live.as_slice(),
            alice.public_key(),
            "replying",
            true,
            1,
            bob.public_key(),
        ));
        assert!(
            engine.live_fold_target(&historical).is_none(),
            "this window has no core fold"
        );
        let page = engine
            .messages_cursor_page(&live, None, None, 10)
            .expect("live page");
        let reply = page
            .iter()
            .find(|m| m.content == "replying")
            .and_then(|m| m.reply.as_ref())
            .expect("reply pointer");
        assert_eq!(
            reply.preview.as_deref(),
            Some("old hello"),
            "live page must hydrate the hist parent without a core fold"
        );
    }

    #[test]
    fn persist_folds_live_id_decrypts_recovered_08_media_without_core_fold() {
        // Host sidecar can remount the bubble onto live before
        // record_historical_fold. Looking the blob up by URL must not
        // invent a fold (R-050).
        let alice = Identity::generate();
        let bob = Identity::generate();
        let engine = MarmotEngine::in_memory(alice.clone());
        let historical = GroupId::new(vec![0x11; 16]);
        let live = GroupId::new(vec![0x22; 16]);
        let url = "https://blossom.example/old.bin";
        let secret = vec![0xABu8; 32];
        let upload = crate::media_crypto::encrypt_for_upload(
            &secret,
            b"photo-bytes",
            "image/jpeg",
            "old.jpg",
        )
        .expect("encrypt with stored 0.8 exporter");
        engine.push_transcript_message(chat_with_media(
            1,
            historical.as_slice(),
            bob.public_key(),
            url,
            Some(upload.original_hash),
            Some(upload.nonce),
        ));
        engine.add_historical_media_secret(historical.clone(), secret);
        assert!(
            engine.live_fold_target(&historical).is_none(),
            "this window has no core fold"
        );
        assert!(!engine.recovered_08_media_unavailable(&live, url));
        let remounted = engine
            .decrypt_media_by_url(&live, url, &upload.encrypted_data)
            .expect("live id must open the hist blob without a core fold");
        assert_eq!(remounted, b"photo-bytes");
        assert!(
            !engine.recovered_08_media_unavailable(&live, "https://blossom.example/unrelated.bin",)
        );
    }

    #[test]
    fn persist_folds_live_id_marks_recovered_08_media_unavailable_without_secret() {
        let alice = Identity::generate();
        let bob = Identity::generate();
        let engine = MarmotEngine::in_memory(alice.clone());
        let historical = GroupId::new(vec![0x11; 16]);
        let live = GroupId::new(vec![0x22; 16]);
        let url = "https://blossom.example/old.bin";
        engine.push_transcript_message(chat_with_media(
            1,
            historical.as_slice(),
            bob.public_key(),
            url,
            Some([1u8; 32]),
            Some([2u8; 12]),
        ));
        assert!(engine.recovered_08_media_unavailable(&historical, url));
        assert!(engine.recovered_08_media_unavailable(&live, url));
        let err = engine
            .decrypt_media_by_url(&live, url, b"cipher")
            .expect_err("live id must not try the 0.9 exporter for a hist blob");
        assert!(
            err.to_string().contains(RECOVERED_08_MEDIA_UNAVAILABLE),
            "unexpected error: {err}"
        );
    }
}
