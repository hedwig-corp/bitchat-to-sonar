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

use std::cmp::Ordering;
use std::path::Path;

use mdk_core::encrypted_media::{EncryptedMediaUpload, MediaReference};
use mdk_core::key_packages::{validate_existing_d_tag, KeyPackageOptions};
use mdk_core::prelude::*;
use mdk_memory_storage::MdkMemoryStorage;
use mdk_sqlite_storage::{EncryptionConfig, MdkSqliteStorage};
use mdk_storage_traits::groups::{MessageSortOrder, Pagination};
use nostr::prelude::*;
use serde::{Deserialize, Serialize};

use sonar_stickers::{build_sticker_ref_tag, parse_sticker_ref_tag, StickerRef};

use crate::call::signaling::CallControl;
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

/// Sidecar file holding this install's kind-30443 KeyPackage slot id (the `d`
/// tag). Kept beside the MDK database so it shares the database's lifetime: a
/// wipe drops the slot along with the MLS key material it addresses.
pub(crate) const KEY_PACKAGE_SLOT_FILE_SUFFIX: &str = ".sonar-keypackage-slot";

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
        }
    }
}

/// Transcript-level classification of a message's content, computed once when
/// the core maps a stored message so hosts never re-parse `content` on the UI
/// render path (Signal-style: classify at load, render precomputed state).
///
/// Malformed or unknown-version control lines classify as `Text` — a parse
/// failure must never hide a message from the transcript.
#[derive(Debug, Clone, PartialEq, Eq)]
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
    ///
    /// `PayDone` / `CallControl` are protocol control lines that both apps hide
    /// (iOS `SonarAppStore.payMapping` → `.hidden`, Compose `ChatScreen`'s feed
    /// filter). They must therefore not count toward `unread_count`: the
    /// unread divider is placed by counting `unread_count` **visible** incoming
    /// rows back from the tail, so each invisible unread event pushes the open
    /// position one real message further into history.
    pub fn is_transcript_visible(&self) -> bool {
        !matches!(self, Self::PayDone { .. } | Self::CallControl)
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
    /// Sticker reference, if this message is a sticker send.
    pub sticker_ref: Option<StickerRef>,
    /// Content classification (pay/call control vs plain text), precomputed so
    /// hosts never parse `content` on the render path.
    pub classification: MessageClassification,
}

/// Compare render messages in the stable newest-first order used by transcript
/// cursors. Deliberately excludes MDK's local `processed_at` value: two devices
/// must page the same event set even when they received same-second events in a
/// different order.
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

/// True when a message belongs strictly after the supplied newest-first page
/// cursor. With no event id, the whole cursor second is excluded, preserving the
/// previous timestamp-only API behavior.
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
    /// A decrypted chat message (already persisted in MDK storage).
    Message(ChatMessage),
    /// A group-membership/welcome change was applied; no chat content.
    GroupUpdated(GroupId),
    /// A multi-member welcome was stored and is waiting for user acceptance.
    GroupInvitePending(GroupId),
    /// Processing a proposal produced an auto-commit that the caller must
    /// publish and merge before the group converges.
    GroupProposal(GroupMembershipUpdate),
    /// MDK recorded this event as failed and blocks reprocessing: re-delivery
    /// returns this same result forever (only MDK's internal epoch-rollback
    /// machinery can revive one). The relay sync layer must mark it processed
    /// and move on — holding the sync cursor behind it refetches the same
    /// history on every sync without ever succeeding.
    Failed,
    /// A join request was received for a group we administer.
    JoinRequest(crate::invite_link::JoinRequest),
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
    /// Serializes MLS-mutating storage operations (message/commit creation,
    /// incoming processing, group membership changes) so hosts may run sends
    /// concurrently with sync/drain instead of funneling every engine call
    /// through one serial queue. Guarded sections are synchronous — the lock
    /// is never held across an await, so a concurrent send waits for at most
    /// one in-flight mutation, never for a relay fetch.
    write_lock: std::sync::Mutex<()>,
    /// Sliding window of recent 2-member-welcome auto-accepts (#419). Anyone
    /// holding our public KeyPackage can gift-wrap us a welcome, so
    /// auto-accepts are rate limited; overflow routes to the pending
    /// accept/decline UI (or is dropped past [`PENDING_INVITE_CAP`])
    /// instead of silently writing MLS groups and chat rows without bound.
    ///
    /// Persisted to a sidecar next to the DB: the iOS NSE builds a fresh
    /// engine per push wake, so an in-memory-only window would hand every
    /// wake a fresh budget (5 × wake-rate, not 5 per window).
    dm_autoaccept_budget: std::sync::Mutex<DmAutoacceptBudget>,
    /// Where to persist this install's KeyPackage slot id (the kind-30443 `d`
    /// tag). `None` for in-memory engines, which keep the slot in
    /// [`Self::key_package_slot_memo`] for the life of the process instead.
    db_path: Option<std::path::PathBuf>,
    /// In-process cache of the slot id. Also the only storage for an in-memory
    /// engine, so tests that publish twice see one stable slot.
    key_package_slot_memo: std::sync::Mutex<Option<String>>,
}

/// Max 2-member welcomes auto-accepted per window before the known-sender
/// check has to vouch for the welcomer; beyond both, they surface as pending
/// invites (accept/decline UI).
pub const UNKNOWN_DM_AUTOACCEPT_MAX: usize = 5;
/// Window for [`UNKNOWN_DM_AUTOACCEPT_MAX`], in seconds.
pub const UNKNOWN_DM_AUTOACCEPT_WINDOW_SECS: u64 = 10 * 60;
/// Max ACTIVE groups shared with the SAME welcomer whose further welcomes may
/// bypass the budget. One admitted welcome must not buy an attacker unlimited
/// silent groups: the bypass is self-bootstrapping, since landing a single
/// welcome inside the window makes every later one from that key "known".
/// Each extra group also adds an `#h` entry to every batched kind-445 fetch.
pub const KNOWN_SENDER_GROUP_CAP: usize = 3;
/// Hard ceiling on PARKED pending invites of ANY size. Past it, a new
/// welcome is declined outright rather than parked: without this the flood
/// just moves from silent groups into an unbounded invite list pinned above
/// every real conversation on both hosts. Counting only 2-member invites
/// would leave a 3-member-group spammer an open door.
pub const PENDING_INVITE_CAP: usize = 25;
/// Ceiling on parked invites for a welcomer we already share an active group
/// with. Higher than [`PENDING_INVITE_CAP`] so a stranger flood cannot lock a
/// real contact out of inviting us, but STILL A CEILING: an attacker whose
/// first welcome was auto-accepted is "known" from then on, so an unbounded
/// exemption just moves the flood from silent groups into an unbounded invite
/// list — the exact failure [`PENDING_INVITE_CAP`] exists to prevent.
pub const KNOWN_SENDER_PENDING_INVITE_CAP: usize = 50;
/// Ceiling on groups INSPECTED by [`MarmotEngine::shared_active_groups_with`]
/// (as opposed to matched — the `limit` parameter). The attacker/unknown case
/// shares no group, so without this the scan pays one membership lookup per
/// active group under `mls_write` on every flood welcome. A contact whose only
/// shared group sits past the cap parks for manual accept instead — see the
/// method doc for the trade.
pub const SHARED_GROUP_SCAN_CAP: usize = 128;

/// Sidecar suffix for the persisted auto-accept window (JSON `[u64]` of unix
/// seconds). Shares fate with the DB in [`MarmotEngine::wipe`].
const DM_AUTOACCEPT_FILE_SUFFIX: &str = ".dm-autoaccepts.json";
/// The tmp file of the atomic write above — wiped with everything else.
const DM_AUTOACCEPT_TMP_FILE_SUFFIX: &str = ".dm-autoaccepts.json.tmp";

/// The sliding auto-accept window, shared by every process that opens the
/// same DB path (app, NSE) via a best-effort JSON sidecar.
struct DmAutoacceptBudget {
    admits: std::collections::VecDeque<u64>,
    sidecar: Option<std::path::PathBuf>,
}

impl DmAutoacceptBudget {
    fn in_memory() -> Self {
        Self {
            admits: std::collections::VecDeque::new(),
            sidecar: None,
        }
    }

    /// A missing sidecar is a fresh install: empty window. Any OTHER read or
    /// parse failure fails CLOSED — an exhausted window — matching `reserve`'s
    /// treatment of a failed persist (#498 review round 2). `unwrap_or_default`
    /// here handed a truncated/unreadable sidecar a fresh set of silent
    /// auto-accepts, the opposite of what the limiter exists for. The window
    /// self-heals: the next successful persist rewrites the sidecar, and
    /// `prune` ages the synthetic admits out after
    /// [`UNKNOWN_DM_AUTOACCEPT_WINDOW_SECS`] — meanwhile welcomes park for
    /// manual accept rather than being dropped.
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
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                std::collections::VecDeque::new()
            }
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

    /// A full window stamped `now`, so `prune` retires it naturally.
    fn exhausted_window() -> std::collections::VecDeque<u64> {
        let now_secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        std::collections::VecDeque::from(vec![now_secs; UNKNOWN_DM_AUTOACCEPT_MAX])
    }

    fn prune(&mut self, now_secs: u64) {
        // Future-dated admits are dropped too: `saturating_sub` returns 0 for
        // them, so a device whose clock was ahead (dead battery, bad NTP)
        // would otherwise pin the window exhausted until wall-clock caught up
        // — and the persisted sidecar makes that survive reboots.
        self.admits
            .retain(|t| *t <= now_secs && now_secs - *t < UNKNOWN_DM_AUTOACCEPT_WINDOW_SECS);
    }

    /// Whether the window has room, WITHOUT consuming a slot — the slot is
    /// recorded only after `accept_welcome` succeeds, so a welcome that fails
    /// MLS processing cannot eat the budget for real first contacts.
    fn has_room(&mut self, now_secs: u64) -> bool {
        self.refresh_from_disk();
        self.prune(now_secs);
        self.admits.len() < UNKNOWN_DM_AUTOACCEPT_MAX
    }

    /// Union the on-disk window into ours before every read or write.
    ///
    /// The app and the iOS NSE each hold their own engine, and a
    /// whole-file write from a stale in-memory snapshot silently drops the
    /// other process's admits — last-writer-wins only ever WIDENS the
    /// budget, which is the defect persisting it was meant to close.
    /// Caveat: two admits in the same wall-clock second across processes
    /// dedup to one, a 1-slot loss versus today's whole-set loss.
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
        // Disk is the AUTHORITY, not a set to union with. Every writer
        // persists its whole window immediately after recording, so the file
        // is a superset of what this process last wrote; adopting it wholesale
        // picks up the other process's admits without the multiplicity problem
        // a value-dedup creates — two admits in the same wall-clock second are
        // distinct budget slots, and deduping collapses a burst into one.
        let mut merged = disk;
        merged.sort_unstable();
        self.admits = merged.into();
    }

    /// Write the whole window through tmp+rename, like the sync/outbox
    /// sidecars. A budget with no sidecar (memory storage, tests) persists
    /// trivially.
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

    /// Consume a slot and make it DURABLE before the caller acts on it.
    ///
    /// Ordering matters and used to be the other way round: recording after
    /// `accept_welcome` meant a failed sidecar write returned success with the
    /// budget unconsumed, so the next engine (the NSE opens its own) loaded a
    /// stale window and granted another five automatic accepts. The limiter
    /// disappeared exactly when the filesystem was under contention or the NSE
    /// was killed mid-write. Reserving first fails CLOSED instead.
    ///
    /// The property the old ordering protected — a welcome that fails MLS
    /// processing must not eat a real first contact's slot — is preserved by
    /// [`Self::release`] rather than by ordering.
    /// The cap is re-checked HERE, not only in [`Self::has_room`]. Those are
    /// two separate steps of `process_incoming`, and this one used to
    /// `push_back` unconditionally — so anything `refresh_from_disk` unioned in
    /// between (the iOS NSE runs its own engine against the same sidecar) was
    /// added on top of a decision taken against a smaller window, and the
    /// window could grow past the maximum. Failing here parks the welcome,
    /// which is the same fail-closed path a failed persist already takes.
    ///
    /// Residual: two processes that both refresh before either persists can
    /// still each admit one, so this bounds the overrun rather than making the
    /// window strictly atomic. Closing that needs a lock around the sidecar
    /// read-modify-write, the way `MarmotStoreLock` guards the store.
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

    /// Give a reserved slot back after the action it was reserved for failed.
    /// Best-effort by nature: if this write fails the window stays consumed,
    /// which errs toward rate-limiting a real contact rather than toward
    /// handing an attacker a free accept.
    fn release(&mut self, now_secs: u64) {
        self.drop_one(now_secs);
        if let Err(e) = self.persist() {
            tracing::warn!(
                error = %e,
                "dm-autoaccept rollback write failed; the slot stays consumed"
            );
        }
    }

    /// Remove one admit stamped `now_secs` (the most recent such entry).
    fn drop_one(&mut self, now_secs: u64) {
        if let Some(pos) = self.admits.iter().rposition(|&t| t == now_secs) {
            self.admits.remove(pos);
        }
    }
}

fn dm_autoaccept_sidecar(db_path: &Path) -> std::path::PathBuf {
    let name = db_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or_default();
    db_path.with_file_name(format!("{name}{DM_AUTOACCEPT_FILE_SUFFIX}"))
}

/// Outcome of the 2-member-welcome gate (#419).
enum DmWelcomeDecision {
    AutoAccept { consume_budget: bool },
    Park,
    Drop,
}

impl MarmotEngine {
    /// In-memory engine. Volatile — state is lost on drop. Used by tests and any
    /// caller that does not need persistence.
    pub fn in_memory(identity: Identity) -> Self {
        Self {
            storage: Storage::Memory(Box::new(MDK::new(MdkMemoryStorage::default()))),
            identity,
            write_lock: std::sync::Mutex::new(()),
            dm_autoaccept_budget: std::sync::Mutex::new(DmAutoacceptBudget::in_memory()),
            db_path: None,
            key_package_slot_memo: std::sync::Mutex::new(None),
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
        // Before MDK's Connection::open: skip WAL checkpoint on sqlite3_close so
        // a suspend drop cannot hold file locks past iOS's ~30s grace
        // (0xdead10cc round 10). See sqlcipher_runtime.
        crate::sqlcipher_runtime::ensure_no_checkpoint_on_close()?;
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
            write_lock: std::sync::Mutex::new(()),
            // Persistent engine ⇒ persisted window. The iOS NSE builds a
            // fresh engine per push wake, so an in-memory budget here would
            // hand every wake a full budget (5 × wake-rate, not 5 per window).
            dm_autoaccept_budget: std::sync::Mutex::new(DmAutoacceptBudget::load(path)),
            db_path: Some(path.to_path_buf()),
            key_package_slot_memo: std::sync::Mutex::new(None),
        })
    }

    pub fn identity(&self) -> &Identity {
        &self.identity
    }

    /// Take the MLS write lock. A poisoned lock only means another thread
    /// panicked mid-call; MDK/SQLite transactions keep the store consistent,
    /// so recover the guard instead of propagating the poison.
    fn mls_write(&self) -> std::sync::MutexGuard<'_, ()> {
        self.write_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Decide what to do with a 2-member welcome (#419).
    ///
    /// Auto-accept is a spam/storage-DoS surface: our KeyPackage (kind 30443)
    /// is public, so anyone can mint a 2-member MLS group and gift-wrap us a
    /// welcome. Order of checks, cheapest first:
    ///
    /// 1. The authenticated seal author must BE the welcomer. NIP-59 already
    ///    rejects a third-party seal (`SenderMismatch`) before we get here and
    ///    MDK derives `welcomer` from the rumor author, so today this cannot
    ///    fire — it is a cheap, MDK-version-independent backstop, not a live
    ///    defense, and no test can reach it from the wire.
    /// 2. The sliding budget window (persisted sidecar). Checked FIRST so the
    ///    common under-budget path does zero storage IO — the known-sender
    ///    scan below deserializes full MLS group state per group while the
    ///    engine write lock is held, which is exactly the
    ///    long-work-under-a-lock shape the 0xdead10cc history warns about.
    ///    The slot is consumed only after `accept_welcome` succeeds.
    /// 3. Budget exhausted: a welcomer we already share an active group with
    ///    is vouched for (re-invites, key rotation, second device) — accept
    ///    without consuming budget.
    /// 4. Otherwise park as a pending invite — but only up to
    ///    [`PENDING_INVITE_CAP`] parked invites; past the cap the
    ///    welcome is declined outright, or the flood just moves into an
    ///    unbounded invite list on both hosts.
    fn dm_welcome_decision(
        &self,
        seal_sender: &PublicKey,
        welcome: &welcome_types::Welcome,
        now_secs: u64,
    ) -> DmWelcomeDecision {
        if *seal_sender != welcome.welcomer {
            tracing::warn!(
                "welcome seal author {} != welcomer {}; parking instead of auto-accepting",
                seal_sender,
                welcome.welcomer
            );
            return self.park_or_drop_welcome(welcome);
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
        let shared = self.shared_active_groups_with(&welcome.welcomer, KNOWN_SENDER_GROUP_CAP);
        if shared > 0 && shared < KNOWN_SENDER_GROUP_CAP {
            return DmWelcomeDecision::AutoAccept {
                consume_budget: false,
            };
        }
        tracing::info!(
            "unknown-sender DM welcome from {} not auto-accepted (budget exhausted)",
            welcome.welcomer
        );
        self.park_or_drop_welcome(welcome)
    }

    /// How many ACTIVE groups we already share with `welcomer`, counting no
    /// further than `limit`. Bounds the known-sender bypass (see
    /// [`KNOWN_SENDER_GROUP_CAP`]) and the parked-invite exemption.
    ///
    /// `limit` is not a nicety. This runs inside `process_incoming`, which
    /// holds the `mls_write` mutex that outgoing message creation also needs,
    /// and every group costs a membership storage lookup — so an unbounded
    /// scan lets relay welcome traffic block SENDING on an account with many
    /// conversations, against the Signal-comparable performance rule. Every
    /// caller compares against a small ceiling, so stopping there is exact,
    /// not approximate: the count is only ever used as `> 0` or `< CAP`.
    ///
    /// The match cap alone is not enough (#498 review round 2): the normal
    /// attacker case shares NO group, so `shared` never reaches `limit` and
    /// the loop would still pay one `members()` lookup per active group under
    /// `mls_write`. [`SHARED_GROUP_SCAN_CAP`] bounds the groups INSPECTED. The
    /// trade is explicit: a genuine contact whose only shared group sits past
    /// the cap reads as unknown and the welcome parks for manual accept —
    /// fail-toward-parking, never toward auto-accepting or dropping.
    fn shared_active_groups_with(&self, welcomer: &PublicKey, limit: usize) -> usize {
        let Ok(groups) = self.groups() else { return 0 };
        let mut shared = 0usize;
        for group in groups.iter().take(SHARED_GROUP_SCAN_CAP) {
            if shared >= limit {
                break;
            }
            if self
                .members(&group.mls_group_id)
                .ok()
                .is_some_and(|members| members.contains(welcomer))
            {
                shared += 1;
            }
        }
        shared
    }

    /// Park as pending unless the parked-invite ceiling is already hit.
    /// `process_welcome` has already stored the CURRENT welcome as pending,
    /// so it is excluded from the count — the cap bounds the OTHERS.
    ///
    /// Counts EVERY pending welcome, not just 2-member ones: a spammer who
    /// mints 3-member groups instead would otherwise walk straight around a
    /// DM-only ceiling, and the invite list is a single list to the user
    /// either way.
    fn park_or_drop_welcome(&self, current: &welcome_types::Welcome) -> DmWelcomeDecision {
        // Someone we already share an active group with gets a HIGHER ceiling,
        // never an unbounded one. The exemption is real — without it 25 parked
        // spam invites become a permanent invite outage for real contacts —
        // but returning Park unconditionally handed the attacker the flood back
        // through the other door: their first welcome is auto-accepted, which
        // makes them "known", and every later welcome then parked forever. The
        // group cap stopped the silent groups while the invite list grew without
        // limit, so the fix bounded one half and left the other open.
        let known_sender = self.shared_active_groups_with(&current.welcomer, 1) > 0;
        let cap = if known_sender {
            KNOWN_SENDER_PENDING_INVITE_CAP
        } else {
            PENDING_INVITE_CAP
        };
        // A failed pending-list read parks (fails open on the ceiling) rather
        // than declining: Drop destroys a possibly-real invite unrecoverably,
        // while Park keeps it user-visible and costs one row — the wrong
        // direction only if the storage error persists across a whole flood,
        // by which point welcome processing itself is failing. Logged so a
        // recurring read failure is visible (#498 review round 2).
        let parked = dispatch!(&self.storage, |mdk| mdk.get_pending_welcomes(None))
            .map(|ws| ws.iter().filter(|w| w.id != current.id).count())
            .unwrap_or_else(|e| {
                tracing::warn!(
                    error = %e,
                    "pending-welcome count unavailable; parking without the ceiling"
                );
                0
            });
        if parked >= cap {
            tracing::warn!(
                welcomer = %current.welcomer,
                member_count = current.member_count,
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

    /// Decline a flood welcome AND reclaim the rows it created.
    ///
    /// `process_welcome` has already persisted the welcome and a group row by
    /// the time we decide to drop it, and `decline_welcome` only marks them
    /// Declined/Inactive — so a ceiling that stops at declining still lets an
    /// attacker grow the database ~5KB per event, which is the storage DoS
    /// #419 is about. `delete_group` removes the group, its `welcomes` rows and
    /// its `processed_welcomes` rows (mdk-sqlite-storage does this explicitly,
    /// marmot-protocol/mdk#293), so the flood costs the victim nothing durable.
    ///
    /// Guarded, because deleting the wrong group destroys a real conversation:
    /// only a group that is NOT Active is ever deleted. A replayed wrapper for
    /// a live chat therefore cannot be turned into a deletion — the failure
    /// mode this PR already had to fix once (`stop replay deleting a live DM`).
    ///
    /// Dropping `processed_welcomes` does mean an identical replayed wrapper is
    /// processed again rather than deduped. That is the right trade: each replay
    /// is re-declined and re-deleted, so it costs CPU, not unbounded storage.
    fn decline_and_purge_welcome(&self, welcome: &welcome_types::Welcome) -> Result<()> {
        dispatch!(&self.storage, |mdk| mdk.decline_welcome(welcome))?;
        self.purge_declined_welcome_group(welcome)
    }

    /// The purge half of [`Self::decline_and_purge_welcome`], callable on its
    /// own for a RE-DELIVERED already-Declined welcome: a kill between
    /// `decline_welcome` and `delete_group` (or a transient delete error)
    /// leaves the decline committed with the flood group's rows still on disk,
    /// and the sync cursor advances past the wrapper — so re-delivery is the
    /// only retry that ever comes (#498 review round 2). Same Active guard:
    /// a manually declined welcome whose group is somehow live is never
    /// deleted.
    fn purge_declined_welcome_group(&self, welcome: &welcome_types::Welcome) -> Result<()> {
        let group_id = &welcome.mls_group_id;
        let state = dispatch!(&self.storage, |mdk| mdk.get_group(group_id))?.map(|g| g.state);
        match state {
            Some(group_types::GroupState::Active) => {
                tracing::warn!(
                    welcomer = %welcome.welcomer,
                    "declined welcome maps to an ACTIVE group; not deleting it"
                );
            }
            Some(_) => {
                dispatch!(&self.storage, |mdk| mdk.delete_group(group_id))?;
            }
            None => {}
        }
        Ok(())
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

    /// Path of the file holding this install's KeyPackage slot id.
    fn key_package_slot_path(&self) -> Option<std::path::PathBuf> {
        Some(key_package_slot_path_for(self.db_path.as_ref()?))
    }

    /// This install's stable KeyPackage slot id, or `None` if we have never
    /// published one. Memo first, then disk. A stored value that does not satisfy
    /// MIP-00's `d` tag rules is discarded rather than fed back to MDK, which
    /// would reject it and leave us unable to publish at all.
    /// `Ok(Some(d))` reuse that slot, `Ok(None)` mint a fresh one, `Err` do not
    /// publish at all this cycle.
    ///
    /// The error case matters: `key_package_event` persists whatever slot it
    /// ends up using, so silently substituting a value here would write that
    /// substitute to disk permanently. In particular it must never fall back to
    /// the identity-derived slot, which is a pure function of the npub: two
    /// installs of one identity that each hit a transient read error would then
    /// share one `(kind, pubkey, d)` coordinate and start replacing each other's
    /// KeyPackage. That is the exact failure this change exists to remove, and
    /// the iOS "container locked" case that triggers it would hit both of a
    /// user's devices. Failing the publish is safe instead: hosts republish on
    /// every relay connect and `publish_key_package_background` logs and
    /// continues, so it self-heals on the next connect.
    fn load_key_package_slot(&self) -> Result<Option<String>> {
        if let Ok(memo) = self.key_package_slot_memo.lock() {
            if let Some(d) = memo.as_ref() {
                return Ok(Some(d.clone()));
            }
        }
        let Some(path) = self.key_package_slot_path() else {
            // No database to persist beside (in-memory engine). Derive the slot
            // from the identity: with no disk, a random slot would mean a NEW
            // permanent addressable event on every process start. The headless
            // status probe runs one-shot per poll under a fixed nsec and would
            // otherwise accumulate a slot per poll forever. Safe here precisely
            // because an in-memory engine has no persistent install to collide
            // with.
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

    /// Deterministic per-identity slot id, for engines with nowhere durable to
    /// remember a random one. Stable across process restarts by construction.
    ///
    /// Only ever used when there is no database, so it cannot collide with a
    /// persistent install: it is a pure function of the npub, so two callers
    /// that used it would share one addressable coordinate.
    ///
    /// This is an addressing label, not key material: it is published in clear
    /// in the `d` tag and only ever appears alongside the npub that already
    /// identifies the event, so deriving it from the public key leaks nothing
    /// the event does not already carry.
    fn derived_key_package_slot(&self) -> String {
        use nostr::hashes::{sha256::Hash as Sha256Hash, Hash as _};
        let mut input = b"sonar-keypackage-slot-v1:".to_vec();
        input.extend_from_slice(self.identity.public_key().to_hex().as_bytes());
        Sha256Hash::hash(&input).to_string()
    }

    /// Persist the slot id so the NEXT publish replaces this addressable event
    /// instead of creating another one. Best effort: a write failure costs us a
    /// duplicate slot on the relays, never a failed publish.
    fn store_key_package_slot(&self, d: &str) {
        if let Ok(mut memo) = self.key_package_slot_memo.lock() {
            *memo = Some(d.to_string());
        }
        let Some(path) = self.key_package_slot_path() else {
            return;
        };
        // with_file_name, NOT with_extension: the slot file already contains
        // dots, so with_extension would REPLACE the last component and yield
        // `marmot.sqlite.tmp`. That name is absent from `sidecar_paths` (so a
        // crashed rename would survive a wipe) and, for a db path ending in
        // `.tmp`, would alias the database itself and truncate it. Matches the
        // `{file_name}.tmp` form every other sidecar in this crate uses.
        let tmp = key_package_slot_tmp_path(&path);
        if std::fs::write(&tmp, d).is_ok() {
            if std::fs::rename(&tmp, &path).is_err() {
                let _ = std::fs::remove_file(&tmp);
            }
        }
    }

    /// Build a signed kind-30443 KeyPackage event, ready to publish to
    /// `relays` (which are also advertised inside the event tags).
    ///
    /// The `d` tag is this install's STABLE slot id, reused across publishes.
    /// MDK mints a fresh random `d` whenever `existing_d_tag` is `None`, and
    /// hosts republish on every relay connect, so without this each launch left
    /// another addressable KeyPackage on the relays forever. That is not just
    /// litter: a peer starting a DM fetches one of them, and with several live
    /// slots (worse, several DEVICES sharing one npub) the welcome can be
    /// addressed to key material that lives in a different install's database,
    /// where it can never be decrypted. One slot per install keeps "which device
    /// gets invited" answerable.
    pub fn key_package_event(&self, relays: Vec<RelayUrl>) -> Result<Event> {
        let _mls = self.mls_write();
        let options = KeyPackageOptions {
            existing_d_tag: self.load_key_package_slot()?,
            ..Default::default()
        };
        let kp = dispatch!(&self.storage, |mdk| mdk
            .create_key_package_for_event_with_options(
                &self.identity.public_key(),
                relays.clone(),
                options.clone()
            ))?;
        self.store_key_package_slot(&kp.d_tag);
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
        self.create_group_with_description(name, "", member_key_packages, relays)
    }

    pub(crate) fn create_group_with_description(
        &self,
        name: &str,
        description: &str,
        member_key_packages: Vec<Event>,
        relays: Vec<RelayUrl>,
    ) -> Result<GroupCreation> {
        let _mls = self.mls_write();
        let mut admins: Vec<PublicKey> = member_key_packages.iter().map(|e| e.pubkey).collect();
        admins.push(self.identity.public_key());
        let member_pubkeys: Vec<PublicKey> = member_key_packages.iter().map(|e| e.pubkey).collect();

        let config = NostrGroupConfigData::new(
            name.to_owned(),
            description.to_owned(),
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
        let _mls = self.mls_write();
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
        let _mls = self.mls_write();
        let result = dispatch!(&self.storage, |mdk| mdk.remove_members(group_id, members))?;
        Ok(Self::to_membership_update(result, Vec::new(), true))
    }

    /// Create a self-demotion commit. Required before an admin leaves.
    pub fn self_demote(&self, group_id: &GroupId) -> Result<GroupMembershipUpdate> {
        let _mls = self.mls_write();
        let result = dispatch!(&self.storage, |mdk| mdk.self_demote(group_id))?;
        Ok(Self::to_membership_update(result, Vec::new(), true))
    }

    /// Create a leave proposal for the current member.
    pub fn leave_group(&self, group_id: &GroupId) -> Result<GroupMembershipUpdate> {
        let _mls = self.mls_write();
        let result = dispatch!(&self.storage, |mdk| mdk.leave_group(group_id))?;
        Ok(Self::to_membership_update(result, Vec::new(), false))
    }

    /// Merge a pending local commit after the caller has published it.
    pub fn merge_pending_commit(&self, group_id: &GroupId) -> Result<()> {
        let _mls = self.mls_write();
        Ok(dispatch!(&self.storage, |mdk| mdk.merge_pending_commit(group_id))?)
    }

    /// Roll back a pending local commit when publish fails before it reaches the
    /// relays. This keeps the group usable for a later retry.
    pub fn clear_pending_commit(&self, group_id: &GroupId) -> Result<()> {
        let _mls = self.mls_write();
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
        let _mls = self.mls_write();
        self.create_text_event_inner(group_id, text)
    }

    /// Requires the caller to hold the MLS write guard.
    fn create_text_event_inner(&self, group_id: &GroupId, text: &str) -> Result<Event> {
        let rumor = EventBuilder::new(Kind::Custom(CHAT_RUMOR_KIND), text)
            .build(self.identity.public_key());
        let event = dispatch!(&self.storage, |mdk| mdk
            .create_message(group_id, rumor, None))?;
        Ok(event)
    }

    /// Create an outgoing text message AND write its local transcript row under
    /// ONE MLS write guard. Without the shared guard, a concurrently drained
    /// commit could advance the group epoch between encryption and local
    /// processing and strand the just-sent row.
    pub fn create_and_process_text_message(
        &self,
        group_id: &GroupId,
        text: &str,
    ) -> Result<(Event, Incoming)> {
        let _mls = self.mls_write();
        let event = self.create_text_event_inner(group_id, text)?;
        let incoming = self.process_group_message(&event)?;
        Ok((event, incoming))
    }

    /// Encrypt a sticker message into a signed kind-445 event for `group_id`.
    /// The rumor carries the sticker ref tag so the receiver can resolve the
    /// sticker image from the pack's Blossom URL.
    pub fn create_sticker_message(
        &self,
        group_id: &GroupId,
        sticker_ref: &StickerRef,
    ) -> Result<Event> {
        let _mls = self.mls_write();
        self.create_sticker_event_inner(group_id, sticker_ref)
    }

    /// Requires the caller to hold the MLS write guard.
    fn create_sticker_event_inner(
        &self,
        group_id: &GroupId,
        sticker_ref: &StickerRef,
    ) -> Result<Event> {
        let tag = build_sticker_ref_tag(sticker_ref);
        let rumor = EventBuilder::new(Kind::Custom(CHAT_RUMOR_KIND), "")
            .tags([tag])
            .build(self.identity.public_key());
        let event = dispatch!(&self.storage, |mdk| mdk
            .create_message(group_id, rumor, None))?;
        Ok(event)
    }

    /// Sticker variant of [`Self::create_and_process_text_message`]: create and
    /// locally process under one MLS write guard.
    pub fn create_and_process_sticker_message(
        &self,
        group_id: &GroupId,
        sticker_ref: &StickerRef,
    ) -> Result<(Event, Incoming)> {
        let _mls = self.mls_write();
        let event = self.create_sticker_event_inner(group_id, sticker_ref)?;
        let incoming = self.process_group_message(&event)?;
        Ok((event, incoming))
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
        self.create_media_event_multi(group_id, &[(upload, url)], caption)
    }

    /// Build a signed kind-445 media message carrying MULTIPLE attachments: one
    /// kind-9 rumor with `caption` (may be empty) plus one `imeta` tag per
    /// `(upload, url)` pair, in order. All imeta ride INSIDE the encrypted rumor,
    /// so they are E2E-protected. This is the album path — a single message that
    /// renders as N images. `uploads` must be non-empty.
    pub fn create_media_event_multi(
        &self,
        group_id: &GroupId,
        uploads: &[(&EncryptedMediaUpload, &str)],
        caption: &str,
    ) -> Result<Event> {
        if uploads.is_empty() {
            return Err(Error::Media("no media uploads for message".into()));
        }
        let _mls = self.mls_write();
        self.create_media_event_multi_inner(group_id, uploads, caption)
    }

    /// Media variant of [`Self::create_and_process_text_message`]: create and
    /// locally process under one MLS write guard.
    pub fn create_and_process_media_event_multi(
        &self,
        group_id: &GroupId,
        uploads: &[(&EncryptedMediaUpload, &str)],
        caption: &str,
    ) -> Result<(Event, Incoming)> {
        if uploads.is_empty() {
            return Err(Error::Media("no media uploads for message".into()));
        }
        let _mls = self.mls_write();
        let event = self.create_media_event_multi_inner(group_id, uploads, caption)?;
        let incoming = self.process_group_message(&event)?;
        Ok((event, incoming))
    }

    /// Requires the caller to hold the MLS write guard.
    fn create_media_event_multi_inner(
        &self,
        group_id: &GroupId,
        uploads: &[(&EncryptedMediaUpload, &str)],
        caption: &str,
    ) -> Result<Event> {
        let event = dispatch!(&self.storage, |mdk| {
            // One imeta tag per attachment, in send order. A fresh media_manager
            // per item mirrors the single-item path exactly.
            let mut imetas = Vec::with_capacity(uploads.len());
            for &(upload, url) in uploads {
                let tag = mdk
                    .media_manager(group_id.clone())
                    .create_imeta_tag(upload, url);
                imetas.push(tag);
            }
            let rumor = EventBuilder::new(Kind::Custom(CHAT_RUMOR_KIND), caption)
                .tags(imetas)
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
                if unwrapped.rumor.kind == Kind::Custom(crate::invite_link::JOIN_REQUEST_RUMOR_KIND)
                {
                    return self.handle_join_request_rumor(&unwrapped.sender, &unwrapped.rumor);
                }
                if unwrapped.rumor.kind != Kind::MlsWelcome {
                    return Ok(Incoming::None);
                }
                // Taken after the gift-wrap unwrap await: the lock must never
                // span an await, only the synchronous MLS mutation below.
                let _mls = self.mls_write();
                let welcome = dispatch!(&self.storage, |mdk| mdk
                    .process_welcome(&event.id, &unwrapped.rumor))?;
                // A re-delivered wrapper returns the STORED welcome, which may
                // already be Accepted or Declined — `process_welcome` is
                // idempotent. Gating one of those can `decline_welcome` an
                // ACCEPTED welcome, which flips its group Inactive and makes a
                // live conversation vanish. Only a genuinely pending welcome
                // may be gated.
                if welcome.state != welcome_types::WelcomeState::Pending {
                    return match welcome.state {
                        welcome_types::WelcomeState::Accepted => {
                            Ok(Incoming::GroupUpdated(welcome.mls_group_id))
                        }
                        welcome_types::WelcomeState::Declined => {
                            // Re-delivery is the only retry a half-finished
                            // `decline_and_purge_welcome` ever gets: the
                            // decline committed, the kill (or a transient
                            // delete error) left the flood group's rows on
                            // disk, and the sync cursor advanced past the
                            // wrapper. Best-effort — the Active guard inside
                            // keeps a live group undeletable.
                            if let Err(e) = self.purge_declined_welcome_group(&welcome) {
                                tracing::warn!(
                                    error = %e,
                                    welcomer = %welcome.welcomer,
                                    "retry purge of a declined welcome's group failed"
                                );
                            }
                            Ok(Incoming::None)
                        }
                        _ => Ok(Incoming::None),
                    };
                }
                if welcome.member_count <= 2 {
                    let now_secs = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs())
                        .unwrap_or(0);
                    match self.dm_welcome_decision(&unwrapped.sender, &welcome, now_secs) {
                        DmWelcomeDecision::AutoAccept { consume_budget } => {
                            // Reserve the slot durably BEFORE accepting. If we
                            // cannot, fail closed: fall through to the parked
                            // path so the user still sees the invite, rather
                            // than granting an accept we cannot account for.
                            let reserved = !consume_budget
                                || match self.reserve_dm_autoaccept(now_secs) {
                                    Ok(()) => true,
                                    Err(e) => {
                                        tracing::warn!(
                                            error = %e,
                                            welcomer = %welcome.welcomer,
                                            "cannot persist the DM auto-accept budget; \
                                             parking this welcome instead of auto-accepting"
                                        );
                                        false
                                    }
                                };
                            if reserved {
                                match dispatch!(&self.storage, |mdk| mdk
                                    .accept_welcome(&welcome))
                                {
                                    Ok(()) => {
                                        return Ok(Incoming::GroupUpdated(welcome.mls_group_id))
                                    }
                                    Err(e) => {
                                        // Give the slot back: a welcome that
                                        // fails MLS processing must not eat a
                                        // real first contact's budget.
                                        if consume_budget {
                                            self.release_dm_autoaccept(now_secs);
                                        }
                                        return Err(e.into());
                                    }
                                }
                            }
                        }
                        DmWelcomeDecision::Park => {}
                        DmWelcomeDecision::Drop => {
                            // Flood ceiling: decline locally so it neither
                            // surfaces nor stays pending, then reclaim the rows
                            // it created so the flood costs no durable storage.
                            // The sender learns nothing (no network here).
                            self.decline_and_purge_welcome(&welcome)?;
                            return Ok(Incoming::None);
                        }
                    }
                }
                match welcome.state {
                    welcome_types::WelcomeState::Pending => {
                        // The parked-invite ceiling applies to every size, or
                        // a spammer just mints 3-member groups instead (#419
                        // review round 2).
                        if matches!(self.park_or_drop_welcome(&welcome), DmWelcomeDecision::Drop) {
                            self.decline_and_purge_welcome(&welcome)?;
                            return Ok(Incoming::None);
                        }
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
                let _mls = self.mls_write();
                self.process_group_message(event)
            }
            _ => Ok(Incoming::None),
        }
    }

    /// Process a kind-445 group message into the local store. Synchronous MLS
    /// mutation — requires the caller to hold the MLS write guard.
    fn process_group_message(&self, event: &Event) -> Result<Incoming> {
        match dispatch!(&self.storage, |mdk| mdk.process_message(event))? {
            MessageProcessingResult::ApplicationMessage(msg) => {
                // Only kind-9 chat rumors are chat messages. MDK also delivers
                // other application kinds (reactions/deletes from White Noise
                // peers) which `messages()` / `messages_page()` filter out of
                // the transcript — surfacing them as `Incoming::Message` would
                // index them, count them as unread and ring a notification for
                // a row no host can ever render. MDK has already persisted the
                // rumor, so future features can still read it from storage.
                if msg.kind.as_u16() != CHAT_RUMOR_KIND {
                    return Ok(Incoming::None);
                }
                Ok(Incoming::Message(self.to_chat_message(msg)))
            }
            MessageProcessingResult::Commit { mls_group_id }
            | MessageProcessingResult::PendingProposal { mls_group_id } => {
                Ok(Incoming::GroupUpdated(mls_group_id))
            }
            MessageProcessingResult::Proposal(update) => Ok(Incoming::GroupProposal(
                Self::to_membership_update(update, Vec::new(), true),
            )),
            // MDK persists a Failed processing record on the first
            // failure and short-circuits every re-delivery with the
            // same result, so these are terminal for the sync layer.
            MessageProcessingResult::Unprocessable { .. }
            | MessageProcessingResult::PreviouslyFailed => Ok(Incoming::Failed),
            _ => Ok(Incoming::None),
        }
    }

    /// All active groups this identity belongs to. Pending group invites are
    /// surfaced separately via [`Self::pending_group_invites`].
    /// Count of stored group rows in EVERY state, not just Active.
    ///
    /// Diagnostics and the #419 storage-DoS tests: `groups()` filters to
    /// Active, so it cannot see the Declined/Inactive rows a welcome flood
    /// leaves behind — which is exactly the growth that has to be bounded.
    pub fn stored_group_count(&self) -> Result<usize> {
        Ok(dispatch!(&self.storage, |mdk| mdk.get_groups())?.len())
    }

    pub fn groups(&self) -> Result<Vec<group_types::Group>> {
        Ok(dispatch!(&self.storage, |mdk| mdk.get_groups())?
            .into_iter()
            .filter(|g| g.state == group_types::GroupState::Active)
            .collect())
    }

    /// Pending multi-member welcomes waiting for user acceptance.
    pub fn pending_group_invites(&self) -> Result<Vec<GroupInvite>> {
        let welcomes = dispatch!(&self.storage, |mdk| mdk.get_pending_welcomes(None))?;
        // No member-count filter: 2-member welcomes normally auto-accept, but
        // an unknown-sender welcome past the rate limit (#419) parks here and
        // must stay visible for explicit accept/decline.
        //
        // INVARIANT (do not widen the kind-445 fetch to pending groups): the
        // 445 subscription/fetch filters are built from ACTIVE groups only, so
        // a pending group's messages are never handed to MDK — which is what
        // keeps them retrievable. MDK records a terminal Failed for a message
        // it cannot process; if pending groups' 445s were fetched before
        // accept, the opening message of every parked first contact would be
        // permanently undecryptable. Accept runs a full backfill instead.
        Ok(welcomes.into_iter().map(Self::to_group_invite).collect())
    }

    /// Accept a pending group invite by its kind-444 welcome event id.
    pub fn accept_group_invite(&self, welcome_id: &EventId) -> Result<GroupId> {
        let _mls = self.mls_write();
        let welcome = dispatch!(&self.storage, |mdk| mdk.get_welcome(welcome_id))?
            .ok_or_else(|| Error::InvalidInput(format!("unknown group invite {welcome_id}")))?;
        let group_id = welcome.mls_group_id.clone();
        dispatch!(&self.storage, |mdk| mdk.accept_welcome(&welcome))?;
        Ok(group_id)
    }

    /// Decline a pending group invite by its kind-444 welcome event id.
    pub fn decline_group_invite(&self, welcome_id: &EventId) -> Result<()> {
        let _mls = self.mls_write();
        let welcome = dispatch!(&self.storage, |mdk| mdk.get_welcome(welcome_id))?
            .ok_or_else(|| Error::InvalidInput(format!("unknown group invite {welcome_id}")))?;
        dispatch!(&self.storage, |mdk| mdk.decline_welcome(&welcome))?;
        Ok(())
    }

    // ── Invite link join requests ──────────────────────────────────────

    /// `sender` is the seal pubkey from the gift wrap, the only authenticated
    /// identity in a NIP-59 envelope. The rumor body is written by whoever holds
    /// the invite link, so `requester_npub` inside it is not evidence of who is
    /// asking. An admin approving a join request must be shown the seal author.
    fn handle_join_request_rumor(
        &self,
        sender: &PublicKey,
        rumor: &UnsignedEvent,
    ) -> Result<Incoming> {
        // Every malformed-body exit returns Ok(Incoming::None), never Err.
        // Neither Error::Json nor Error::InvalidInput is terminal per
        // `is_terminal_marmot_processing_error`, so an Err here would skip
        // `mark_sync_event_processed` and leave the event to be refetched and
        // re-fail on every sync forever. One junk rumor from a stranger is
        // enough to pin the cursor, so unparseable input must be discarded.
        let Ok(payload) = crate::invite_link::parse_join_request_rumor(rumor) else {
            return Ok(Incoming::None);
        };
        let Ok(group_id_bytes) = hex::decode(&payload.group_id) else {
            return Ok(Incoming::None);
        };
        let group_id = GroupId::from_slice(&group_id_bytes);

        let Ok(secret_hash_bytes) = hex::decode(&payload.invite_secret_hash) else {
            return Ok(Incoming::None);
        };
        let mut secret_hash = [0u8; 32];
        if secret_hash_bytes.len() == 32 {
            secret_hash.copy_from_slice(&secret_hash_bytes);
        } else {
            return Ok(Incoming::None);
        }

        // Drop the request outright when the body disagrees with the seal
        // author rather than silently rewriting it: an honest client always
        // sets its own npub, so a mismatch is a spoofing attempt, not drift.
        // `parse` (not `from_bech32`) matches how invite_link.rs decodes this
        // same field, so a hex-encoded key from a non-Sonar client compares
        // rather than erroring out.
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

    /// Gift-wrap an arbitrary rumor for a receiver (NIP-59, kind 1059).
    /// Uses `Timestamp::now()` to avoid relay `since` filter issues.
    pub async fn gift_wrap_rumor(
        &self,
        receiver: &PublicKey,
        rumor: UnsignedEvent,
    ) -> Result<Event> {
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

    /// Cursor-based transcript page: return up to `limit` chat messages strictly
    /// before `(before_secs, before_id)` in the canonical
    /// `(created_at DESC, event_id DESC)` transcript order. When the cursor is
    /// `None`, returns the newest messages (first page).
    ///
    /// MDK's created-at-first storage order uses `processed_at` as its secondary
    /// key. We therefore scan through the complete created-at second containing
    /// the page boundary and re-sort that bounded candidate set by event id. This
    /// prevents messages created in the same second from moving between pages
    /// according to local receive order.
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

        let raw_batch = limit.saturating_mul(4).clamp(32, 500);
        // Deep-history cursor pages must not walk every raw row from the
        // newest one: created_at is monotonic non-increasing in this order,
        // so binary-search the first row at/below the cursor second and scan
        // forward from there. Without this, paging near the origin of a
        // conversation with more than MESSAGE_PAGE_RAW_SCAN_LIMIT raw rows
        // between the live edge and the cursor failed outright (and every
        // top-edge attempt re-scanned thousands of rows), which surfaced as
        // stuck/laggy backscroll with no network (e.g. airplane mode).
        let mut raw_offset = match before_secs {
            Some(cursor_secs) => {
                let first = Pagination::with_sort_order(
                    Some(1),
                    Some(0),
                    MessageSortOrder::CreatedAtFirst,
                );
                let newest = dispatch!(&self.storage, |mdk| mdk.get_messages(group_id, Some(first)))?;
                match newest.first() {
                    None => 0,
                    // Everything retained is already at/below the cursor.
                    Some(m) if m.created_at.as_secs() <= cursor_secs => 0,
                    Some(_) => {
                        // lo (=0) is known to be newer than the cursor. Double
                        // hi until it reaches a row at/below the cursor second
                        // or runs past the end of storage.
                        let mut lo = 0usize;
                        let mut hi = raw_batch;
                        loop {
                            let probe = Pagination::with_sort_order(
                                Some(1),
                                Some(hi),
                                MessageSortOrder::CreatedAtFirst,
                            );
                            let row = dispatch!(&self.storage, |mdk| mdk.get_messages(group_id, Some(probe)))?;
                            match row.first() {
                                Some(m) if m.created_at.as_secs() > cursor_secs => {
                                    lo = hi;
                                    hi = hi.saturating_mul(2);
                                }
                                _ => break,
                            }
                        }
                        while lo + 1 < hi {
                            let mid = lo + (hi - lo) / 2;
                            let probe = Pagination::with_sort_order(
                                Some(1),
                                Some(mid),
                                MessageSortOrder::CreatedAtFirst,
                            );
                            let row = dispatch!(&self.storage, |mdk| mdk.get_messages(group_id, Some(probe)))?;
                            match row.first() {
                                Some(m) if m.created_at.as_secs() > cursor_secs => lo = mid,
                                _ => hi = mid,
                            }
                        }
                        hi
                    }
                }
            }
            None => 0,
        };
        let mut raw_scanned = 0usize;
        let mut candidates = Vec::with_capacity(limit);
        // Once `limit` eligible chat rows have been seen, keep scanning until
        // storage advances to an older second. That captures every possible ID
        // which can sort into the page at the boundary timestamp.
        let mut boundary_secs = None;
        let mut scan_complete = false;

        'scan: while raw_scanned < MESSAGE_PAGE_RAW_SCAN_LIMIT {
            let remaining_scan = MESSAGE_PAGE_RAW_SCAN_LIMIT - raw_scanned;
            let batch_limit = raw_batch.min(remaining_scan);
            let page = Pagination::with_sort_order(
                Some(batch_limit),
                Some(raw_offset),
                MessageSortOrder::CreatedAtFirst,
            );
            let raw_msgs = dispatch!(&self.storage, |mdk| mdk.get_messages(group_id, Some(page)))?;
            if raw_msgs.is_empty() {
                scan_complete = true;
                break;
            }

            let raw_len = raw_msgs.len();
            raw_scanned += raw_len;
            raw_offset += raw_len;
            for msg in raw_msgs {
                let msg_secs = msg.created_at.as_secs();
                if boundary_secs.is_some_and(|boundary| msg_secs < boundary) {
                    scan_complete = true;
                    break 'scan;
                }
                if msg.kind.as_u16() != CHAT_RUMOR_KIND
                    || !is_before_message_cursor(msg_secs, &msg.id, before_secs, before_id)
                {
                    continue;
                }
                candidates.push(self.to_chat_message(msg));
                if candidates.len() == limit {
                    boundary_secs = Some(msg_secs);
                }
            }

            if raw_len < batch_limit {
                scan_complete = true;
                break;
            }
        }

        // A page cannot be deterministic if the safety cap stops before the
        // requested window is complete: an unscanned event ID could sort ahead
        // of a selected one. Fail explicitly instead of returning a page whose
        // membership depends on MDK's processed-at tie ordering. This requires
        // at least 10,000 raw rows in the relevant window and is pathological.
        if !scan_complete {
            return Err(Error::Storage(format!(
                "cursor page exceeds bounded scan of {MESSAGE_PAGE_RAW_SCAN_LIMIT} rows"
            )));
        }

        candidates.sort_unstable_by(compare_message_cursor_desc);
        candidates.truncate(limit);
        Ok(candidates)
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
    /// kind — membership/commit/chat). Used to detect whether the local store is
    /// empty; restart relay catch-up uses [`Self::latest_remote_event_secs`] so
    /// later local-only rows do not hide missed peer messages. 0 if empty/on
    /// error.
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

    /// Unix-seconds timestamp of the newest recently stored event authored by
    /// another participant. Relay catch-up uses this conservative local floor
    /// so later local-only sends or status/bookkeeping rows cannot hide peer
    /// messages that arrived while this device was offline. The scan is bounded
    /// per group; if the only remote event is older than the bounded window,
    /// this returns 0 and the background sync safely widens instead of blocking
    /// startup on a full-history scan.
    pub fn latest_remote_event_secs(&self) -> u64 {
        let groups = match self.groups() {
            Ok(g) => g,
            Err(_) => return 0,
        };
        let mut newest = 0u64;
        let me = self.identity.public_key();
        for g in groups {
            let mut raw_offset = 0usize;
            let mut raw_scanned = 0usize;
            while raw_scanned < MESSAGE_PAGE_RAW_SCAN_LIMIT {
                let remaining_scan = MESSAGE_PAGE_RAW_SCAN_LIMIT - raw_scanned;
                let batch_limit = 500.min(remaining_scan);
                let page = Pagination::with_sort_order(
                    Some(batch_limit),
                    Some(raw_offset),
                    MessageSortOrder::CreatedAtFirst,
                );
                let msgs = match dispatch!(&self.storage, |mdk| {
                    mdk.get_messages(&g.mls_group_id, Some(page))
                }) {
                    Ok(m) => m,
                    Err(_) => break,
                };
                if msgs.is_empty() {
                    break;
                }

                let raw_len = msgs.len();
                raw_scanned += raw_len;
                raw_offset += raw_len;
                for m in msgs {
                    if m.pubkey == me {
                        continue;
                    }
                    let t = m.created_at.as_secs();
                    if t > newest {
                        newest = t;
                    }
                }
                if raw_len < batch_limit {
                    break;
                }
            }
        }
        newest
    }

    /// Unix-seconds timestamp of the newest recently stored chat message in
    /// `group_id` authored by another participant. Returns `None` when the
    /// bounded scan finds no local remote chat rows; callers should treat that
    /// as a conservative full-group repair floor.
    pub fn latest_remote_chat_message_secs(&self, group_id: &GroupId) -> Option<u64> {
        let me = self.identity.public_key();
        let mut raw_offset = 0usize;
        let mut raw_scanned = 0usize;
        while raw_scanned < MESSAGE_PAGE_RAW_SCAN_LIMIT {
            let remaining_scan = MESSAGE_PAGE_RAW_SCAN_LIMIT - raw_scanned;
            let batch_limit = 500.min(remaining_scan);
            let page = Pagination::with_sort_order(
                Some(batch_limit),
                Some(raw_offset),
                MessageSortOrder::CreatedAtFirst,
            );
            let msgs =
                dispatch!(&self.storage, |mdk| mdk.get_messages(group_id, Some(page))).ok()?;
            if msgs.is_empty() {
                return None;
            }

            let raw_len = msgs.len();
            raw_scanned += raw_len;
            raw_offset += raw_len;
            for m in msgs {
                if m.kind.as_u16() == CHAT_RUMOR_KIND && m.pubkey != me {
                    return Some(m.created_at.as_secs());
                }
            }
            if raw_len < batch_limit {
                return None;
            }
        }
        None
    }

    /// Delete ALL local state for a group: messages, processed-message records,
    /// MLS tree state, epoch secrets, key material, relay links, proposals, and
    /// snapshots. Local-only — no MLS proposal or Nostr event is published, so
    /// the peer is NOT notified (this is "delete this chat from my device", like
    /// deleting a conversation in Signal/iMessage). Idempotent.
    pub fn delete_group(&self, group_id: &GroupId) -> Result<()> {
        let _mls = self.mls_write();
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
        let sticker_ref = m
            .tags
            .iter()
            .find(|t| t.as_slice().first().map(|s| s.as_str()) == Some("sticker"))
            .and_then(|t| match parse_sticker_ref_tag(t) {
                Ok(r) => Some(r),
                Err(e) => {
                    tracing::debug!("invalid sticker ref tag: {e}");
                    None
                }
            });
        ChatMessage {
            id: m.id,
            group_id: m.mls_group_id.clone(),
            sender: m.pubkey,
            classification: MessageClassification::of(&m.content),
            content: m.content.clone(),
            created_at: m.created_at,
            mine: m.pubkey == self.identity.public_key(),
            delivery_state: if m.pubkey == self.identity.public_key() {
                DeliveryState::Sent
            } else {
                DeliveryState::Received
            },
            media,
            sticker_ref,
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

/// The KeyPackage slot file beside the database at `db`. Single source of truth
/// so callers outside this module cannot re-derive it slightly differently.
pub(crate) fn key_package_slot_path_for(db: &Path) -> std::path::PathBuf {
    let name = db.file_name().and_then(|n| n.to_str()).unwrap_or_default();
    db.with_file_name(format!("{name}{KEY_PACKAGE_SLOT_FILE_SUFFIX}"))
}

/// `<file>.tmp` beside `path`, the atomic-write staging name every sidecar in
/// this crate uses. Kept as a function so the writer and `sidecar_paths` cannot
/// disagree about what a wipe has to remove.
pub(crate) fn key_package_slot_tmp_path(path: &Path) -> std::path::PathBuf {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default();
    path.with_file_name(format!("{name}.tmp"))
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
        DM_AUTOACCEPT_FILE_SUFFIX,
        DM_AUTOACCEPT_TMP_FILE_SUFFIX,
        KEY_PACKAGE_SLOT_FILE_SUFFIX,
    ]
    .iter()
    .map(|suffix| base.with_file_name(format!("{name}{suffix}")))
    .collect();
    paths.push(base.with_file_name(format!("{name}{SYNC_STATE_FILE_SUFFIX}.tmp")));
    paths.push(base.with_file_name(format!("{name}{OUTBOX_STATE_FILE_SUFFIX}.tmp")));
    paths.push(base.with_file_name(format!("{name}{KEY_PACKAGE_SLOT_FILE_SUFFIX}.tmp")));
    paths
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
