//! UniFFI surface for `sonar-core`.
//!
//! Design (2026-06-12):
//! - Proc-macro mode only (`#[uniffi::export]`), no UDL.
//! - All `SonarNode` methods are BLOCKING: the node owns a multi-thread tokio
//!   runtime and `block_on`s the async `SonarClient` internally. Swift callers
//!   dispatch onto a background queue/Task; the Swift call surface stays
//!   plain synchronous functions.
//! - GroupId crosses the boundary as lowercase hex of `GroupId::as_slice()`.

use std::path::Path;
use std::sync::{Arc, Mutex};

use nostr::prelude::*;
use sonar_core::client::SonarClient;
use sonar_core::identity::Identity;
use sonar_core::mention::{
    mentions_pubkey as core_mentions_pubkey, parse_mentions as core_parse_mentions,
    short_suffix as core_short_suffix,
};
use sonar_core::noise::{NoiseHandshake, NoiseKeypair, NoiseSession};
use sonar_core::notification::{
    classify_content as core_notification_kind, payment_amount_sats as core_payment_amount_sats,
    render_notification as core_render_notification, NotificationKind, NotificationRenderInput,
};
use sonar_core::GroupId;

uniffi::setup_scaffolding!();

// Android-only JNI shim that initializes `ndk_context` (JavaVM + app Context) so
// iroh's DNS read on `Endpoint::bind()` and cpal/oboe audio work when this `.so`
// is loaded by UniFFI's JNA bindings (no JNI_OnLoad fires under JNA).
#[cfg(target_os = "android")]
mod android_jni;

mod logging;

/// Cashu wallet + Breez→Cashu migration surface.
mod wallet;
pub use wallet::*;

/// Flat error: only the rendered message crosses the FFI boundary
/// (`SonarFfiError.InvalidInput(message:)` / `.Core(message:)` in Swift).
///
/// NOTE: flat is correct for errors travelling Rust → host, which is every use
/// below. It is NOT usable for an error a host throws back across a
/// `with_foreign` trait — see `HostWalletError` in `wallet.rs`.
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
        let _ = self
            .tx
            .lock()
            .expect("conversation change tx not poisoned")
            .send(group_id_hex);
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

/// Largest media attachment (plaintext bytes) a receiver will download.
/// Hosts must pre-check picked files against this before staging/sending;
/// the core also rejects over-cap sends so an unfetchable blob is never
/// published.
#[uniffi::export]
pub fn max_media_plaintext_bytes() -> u64 {
    sonar_core::client::MAX_MEDIA_PLAINTEXT_BYTES as u64
}

/// Aggregate plaintext ceiling for one album send (every attachment is
/// memory-resident at once during `send_media_multi`). Hosts should bound the
/// combined size of picked videos against this; the core also rejects
/// over-aggregate albums.
#[uniffi::export]
pub fn max_media_total_plaintext_bytes() -> u64 {
    sonar_core::client::MAX_MEDIA_TOTAL_PLAINTEXT_BYTES as u64
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

/// Result of uploading an encrypted account backup to Blossom.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AccountBackupUploadInfo {
    pub url: String,
    pub sha256_hex: String,
    pub size: u64,
}

fn backup_runtime() -> FfiResult<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|e| SonarFfiError::Core(format!("tokio runtime: {e}")))
}

/// Auto-backup policy snapshot for Settings / host executors.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BackupPolicyInfo {
    pub enabled: bool,
    pub dirty: bool,
    pub last_success_at: Option<u64>,
    pub last_attempt_at: Option<u64>,
    pub last_error: Option<String>,
    pub opportunistic_debounce_secs: u64,
    pub daily_interval_secs: u64,
    /// Sealed size of the last successful upload. `None` until one succeeds —
    /// hosts render a dash, never a fabricated number.
    pub last_size_bytes: Option<u64>,
    pub last_message_count: Option<u64>,
    /// "manual" | "daily" | "weekly", derived from enabled + interval.
    pub frequency: String,
}

fn policy_info(p: sonar_core::account_backup::BackupPolicy) -> BackupPolicyInfo {
    // Derive before destructuring: `from_policy` borrows, and moving
    // `last_error` out first would poison the borrow.
    let frequency = match sonar_core::account_backup::BackupFrequency::from_policy(&p) {
        sonar_core::account_backup::BackupFrequency::Manual => "manual".to_string(),
        sonar_core::account_backup::BackupFrequency::Daily => "daily".to_string(),
        sonar_core::account_backup::BackupFrequency::Weekly => "weekly".to_string(),
    };
    BackupPolicyInfo {
        enabled: p.enabled,
        dirty: p.dirty,
        last_success_at: p.last_success_at,
        last_attempt_at: p.last_attempt_at,
        last_error: p.last_error,
        opportunistic_debounce_secs: p.opportunistic_debounce_secs,
        daily_interval_secs: p.daily_interval_secs,
        last_size_bytes: p.last_size_bytes,
        last_message_count: p.last_message_count,
        frequency,
    }
}

#[uniffi::export]
pub fn get_backup_policy(db_path: String) -> BackupPolicyInfo {
    policy_info(sonar_core::account_backup::load_backup_policy(Path::new(
        &db_path,
    )))
}

#[uniffi::export]
pub fn set_backup_enabled(db_path: String, enabled: bool) -> FfiResult<()> {
    sonar_core::account_backup::set_backup_enabled(Path::new(&db_path), enabled)?;
    Ok(())
}

/// Persist on-by-default only when the policy sidecar is missing. Safe to call
/// from onboarding — never overwrites an existing opt-out or fail-closed file.
#[uniffi::export]
pub fn ensure_backup_policy_default(db_path: String) -> FfiResult<()> {
    sonar_core::account_backup::ensure_backup_policy_default(Path::new(&db_path))?;
    Ok(())
}

#[uniffi::export]
pub fn backup_is_due(db_path: String) -> bool {
    sonar_core::account_backup::backup_is_due_now(Path::new(&db_path))
}

#[uniffi::export]
pub fn mark_backup_dirty(db_path: String) {
    sonar_core::account_backup::mark_backup_dirty(Path::new(&db_path));
}

#[uniffi::export]
pub fn record_backup_success(
    db_path: String,
    size_bytes: Option<u64>,
    db_key_hex: Option<String>,
) -> FfiResult<()> {
    sonar_core::account_backup::record_backup_success(
        Path::new(&db_path),
        size_bytes,
        db_key_hex.as_deref(),
    )?;
    Ok(())
}

/// On-disk footprint of this account (DB + index + sidecars + media + stickers,
/// excluding logs) for the Settings "Storage" row.
#[uniffi::export]
pub fn account_storage_bytes(db_path: String) -> u64 {
    sonar_core::account_backup::account_storage_bytes(Path::new(&db_path))
}

/// Settings cadence: "manual" | "daily" | "weekly". Unknown values are refused
/// rather than silently defaulting — a typo must not quietly disable backups.
#[uniffi::export]
pub fn set_backup_frequency(db_path: String, frequency: String) -> FfiResult<()> {
    let parsed = match frequency.as_str() {
        "manual" => sonar_core::account_backup::BackupFrequency::Manual,
        "daily" => sonar_core::account_backup::BackupFrequency::Daily,
        "weekly" => sonar_core::account_backup::BackupFrequency::Weekly,
        other => {
            return Err(SonarFfiError::InvalidInput(format!(
                "unknown backup frequency: {other}"
            )))
        }
    };
    sonar_core::account_backup::set_backup_frequency(Path::new(&db_path), parsed)?;
    Ok(())
}

#[uniffi::export]
pub fn record_backup_failure(db_path: String, error: String) -> FfiResult<()> {
    sonar_core::account_backup::record_backup_failure(Path::new(&db_path), &error)?;
    Ok(())
}

/// Seal only (exclusive DB access). Hosts should reopen the node, then call
/// [`upload_sealed_account_backup`] so chat is not blocked on Blossom upload.
#[uniffi::export]
pub fn seal_account_backup(
    nsec: String,
    db_path: String,
    db_key_hex: String,
) -> FfiResult<Vec<u8>> {
    let identity = Identity::import(nsec.trim()).map_err(invalid("nsec"))?;
    Ok(sonar_core::account_backup::seal_account_backup_files(
        identity.keys(),
        Path::new(&db_path),
        &db_key_hex,
    )?)
}

/// Upload already-sealed ciphertext. Does **not** need a closed SonarNode.
#[uniffi::export]
pub fn upload_sealed_account_backup(
    nsec: String,
    sealed: Vec<u8>,
    blossom_server: Option<String>,
) -> FfiResult<AccountBackupUploadInfo> {
    let identity = Identity::import(nsec.trim()).map_err(invalid("nsec"))?;
    let server = blossom_server.unwrap_or_default();
    let runtime = backup_runtime()?;
    let uploaded = runtime.block_on(sonar_core::account_backup::upload_sealed_backup(
        identity.keys(),
        &server,
        sealed,
    ))?;
    Ok(AccountBackupUploadInfo {
        url: uploaded.url,
        sha256_hex: uploaded.sha256_hex,
        size: uploaded.size,
    })
}

/// Encrypt the Marmot DB at `db_path` (plus conversation index) with a key
/// derived from `nsec`, then upload to Blossom (BUD-02).
///
/// Call with **no** live `SonarNode` holding `db_path` (checkpoint/close first).
/// Empty `blossom_server` uses the default Blossom host.
/// Prefer seal → reconnect → [`upload_sealed_account_backup`] for auto-backup.
#[uniffi::export]
pub fn backup_account_to_blossom(
    nsec: String,
    db_path: String,
    db_key_hex: String,
    blossom_server: Option<String>,
) -> FfiResult<AccountBackupUploadInfo> {
    let identity = Identity::import(nsec.trim()).map_err(invalid("nsec"))?;
    let server = blossom_server.unwrap_or_default();
    let runtime = backup_runtime()?;
    let uploaded = runtime.block_on(sonar_core::account_backup::backup_account_files(
        identity.keys(),
        Path::new(&db_path),
        &db_key_hex,
        &server,
    ))?;
    Ok(AccountBackupUploadInfo {
        url: uploaded.url,
        sha256_hex: uploaded.sha256_hex,
        size: uploaded.size,
    })
}

/// One conversation inside a sealed backup, for the dry-run preview.
#[derive(uniffi::Record)]
pub struct BackupPreviewConversationInfo {
    pub name: String,
    pub latest_content: String,
    pub message_count: u64,
}

/// What restoring the latest backup would recover.
#[derive(uniffi::Record)]
pub struct AccountBackupPreviewInfo {
    pub conversations: Vec<BackupPreviewConversationInfo>,
    pub total_messages: u64,
    pub size_bytes: u64,
    pub uploaded_at_secs: u64,
}

/// Dry run: report what a restore would bring back, changing nothing.
///
/// Never stages or commits, and never opens the live store — it decrypts in
/// memory and reads only the conversation index from a scratch copy that is
/// deleted before returning. Safe to call with the node open.
///
/// `db_path` is neither read nor written; its directory is the scratch parent.
/// Hosts must pass the real DB path — the process temp dir is unusable on
/// Android, so a preview scratched there fails on every device.
#[uniffi::export]
pub fn preview_account_backup(
    nsec: String,
    db_path: String,
    blossom_server: Option<String>,
) -> FfiResult<AccountBackupPreviewInfo> {
    let identity = Identity::import(nsec.trim()).map_err(invalid("nsec"))?;
    let server = blossom_server.unwrap_or_default();
    let runtime = backup_runtime()?;
    let preview = runtime.block_on(sonar_core::account_backup::preview_account_backup(
        identity.keys(),
        Path::new(&db_path),
        &server,
    ))?;
    Ok(AccountBackupPreviewInfo {
        conversations: preview
            .conversations
            .into_iter()
            .map(|c| BackupPreviewConversationInfo {
                name: c.name,
                latest_content: c.latest_content,
                message_count: c.message_count,
            })
            .collect(),
        total_messages: preview.total_messages,
        size_bytes: preview.size_bytes,
        uploaded_at_secs: preview.uploaded_at_secs,
    })
}

/// Download this identity's latest account backup from Blossom, decrypt with
/// `nsec`, and **stage** files beside `db_path`. Returns the SQLCipher
/// `db_key_hex` the host must persist, then call [`commit_account_restore`].
/// On persist failure call [`abort_account_restore`] instead.
///
/// Call with **no** live node on `db_path`. Typically after wipe / before
/// reconnect during nsec restore.
#[uniffi::export]
pub fn restore_account_from_blossom(
    nsec: String,
    db_path: String,
    blossom_server: Option<String>,
) -> FfiResult<String> {
    let identity = Identity::import(nsec.trim()).map_err(invalid("nsec"))?;
    let server = blossom_server.unwrap_or_default();
    let runtime = backup_runtime()?;
    match runtime.block_on(sonar_core::account_backup::restore_account_files(
        identity.keys(),
        Path::new(&db_path),
        &server,
    )) {
        Ok(db_key_hex) => Ok(db_key_hex),
        Err(e) if sonar_core::account_backup::is_missing_backup_error(&e) => {
            Err(SonarFfiError::InvalidInput(
                sonar_core::account_backup::ACCOUNT_BACKUP_MISSING_MARKER.into(),
            ))
        }
        Err(e) => Err(e.into()),
    }
}

/// After persisting the restored `db_key_hex`, promote staged restore files to
/// the live `db_path`.
#[uniffi::export]
pub fn commit_account_restore(db_path: String) -> FfiResult<()> {
    sonar_core::account_backup::commit_staged_account_restore(Path::new(&db_path))?;
    Ok(())
}

/// Discard staged restore files when key persistence failed.
///
/// Only safe when [`account_restore_staging_present`] is still true. If the
/// main DB was already promoted, aborting is a no-op for the live file — hosts
/// must keep the restored `db_key`.
#[uniffi::export]
pub fn abort_account_restore(db_path: String) -> FfiResult<()> {
    sonar_core::account_backup::abort_staged_account_restore(Path::new(&db_path));
    Ok(())
}

/// Boot-time recovery for interrupted stage→persist→commit. Returns `true` if
/// leftover staging was committed under `db_key_hex`.
#[uniffi::export]
pub fn reconcile_account_restore(db_path: String, db_key_hex: String) -> FfiResult<bool> {
    Ok(
        sonar_core::account_backup::reconcile_staged_account_restore(
            Path::new(&db_path),
            &db_key_hex,
        )?,
    )
}

/// True when `*.sonar-restore-staging` still exists (DB not yet promoted).
#[uniffi::export]
pub fn account_restore_staging_present(db_path: String) -> bool {
    sonar_core::account_backup::account_restore_staging_present(Path::new(&db_path))
}

/// Host helper: classify FFI error text as soft-missing backup.
#[uniffi::export]
pub fn is_missing_account_backup_error(message: String) -> bool {
    sonar_core::account_backup::message_indicates_missing_backup(&message)
}

/// Install (or re-configure) the on-device diagnostics log sink: a bounded,
/// rotating file family under `dir` fed by the core's `tracing` events
/// (relay connects, EOSE, watermark moves, decrypt failures, ...).
///
/// Call once at app start BEFORE connecting the node, with `dir` inside the
/// app's private data directory. Idempotent — calling again only switches the
/// level filter, so hosts re-invoke it when the user toggles verbose
/// diagnostics. `verbose = false` (the default profile) keeps the sink at the
/// redaction boundary: no message content, no key material, no peer npubs.
#[uniffi::export]
pub fn setup_logging(dir: String, verbose: bool) -> FfiResult<()> {
    logging::install_file_logging(&dir, verbose)
        .map_err(|e| SonarFfiError::Core(format!("setup_logging: {e}")))
}

/// True if `input` is plausibly a human-readable handle (`vincenzo` or
/// `alice@example.com`). Pure string check — no network, safe to call per
/// keystroke from search UIs to decide whether to offer a resolve action.
/// Bech32 keys/events and Lightning strings return `false` so the npub and
/// invite search paths keep priority.
#[uniffi::export]
pub fn handle_looks_valid(input: String) -> bool {
    sonar_core::handles::looks_like_handle(&input)
}

/// The default handle domain (bare nicknames resolve here, and only handles
/// on this domain are claimable). Core owns this constant — hosts must not
/// re-declare the literal, because external-vs-claim routing depends on it.
#[uniffi::export]
pub fn default_handle_domain() -> String {
    sonar_core::handles::DEFAULT_HANDLE_DOMAIN.to_owned()
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

/// Transcript-level classification of a chat message, computed once in core
/// so hosts never re-parse `content` on the UI render path. Malformed control
/// lines classify as `Text` (a parse failure never hides a message).
#[derive(uniffi::Enum)]
pub enum MessageClassInfo {
    /// Plain chat text.
    Text,
    /// `⚡PAY|1|<id>|<sats>` payment receipt — render a payment bubble.
    PayReceipt {
        payment_id: String,
        amount_sats: u64,
    },
    /// `⚡PAYDONE|…` settlement — protocol control line, hidden from the
    /// transcript (still drives ledger state).
    PayDone {
        payment_id: String,
        preimage_hex: Option<String>,
    },
    /// `☎CALL|…` signaling line — hidden from the transcript.
    CallControl,
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
    /// Precomputed content classification (pay/call control vs plain text).
    pub classification: MessageClassInfo,
    /// NIP-C7 reply pointer. `content` is the display body (nevent already stripped).
    pub reply: Option<ReplyRefInfo>,
}

/// FFI-friendly NIP-C7 quote pointer.
#[derive(uniffi::Record)]
pub struct ReplyRefInfo {
    pub parent_id_hex: String,
    pub parent_npub: Option<String>,
    pub preview: Option<String>,
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

/// One attachment for an album send (see `send_media_multi`). Raw plaintext
/// `data` plus its source filename and MIME; the core encrypts + uploads each
/// item independently before publishing the single album message.
#[derive(uniffi::Record)]
pub struct MediaUploadItem {
    pub data: Vec<u8>,
    pub filename: String,
    pub mime: String,
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

/// A handle (`vincenzo` / `alice@example.com`) resolved to its owner via
/// NIP-05. `address` is the canonical lowercased `name@domain` that resolved.
#[derive(uniffi::Record)]
pub struct ResolvedHandleInfo {
    pub address: String,
    pub npub: String,
    pub pubkey_hex: String,
}

/// Info about an incoming message discovered during drain, used by hosts to
/// fire rich local notifications (sender name + preview).
#[derive(uniffi::Record)]
pub struct DrainNotificationInfo {
    pub message_id_hex: String,
    pub sender_npub: String,
    pub group_id_hex: String,
    pub group_name: String,
    pub content_preview: String,
}

#[derive(uniffi::Enum)]
pub enum SonarNotificationKindInfo {
    Message,
    Payment,
    Call,
    Trill,
    Invite,
    Mention,
    Geohash,
    Network,
}

#[derive(uniffi::Record)]
pub struct SonarNotificationRenderInputInfo {
    pub enabled: bool,
    pub kind_hint: Option<SonarNotificationKindInfo>,
    pub conversation_title: Option<String>,
    pub sender_name: Option<String>,
    pub group_name: Option<String>,
    pub content_preview: Option<String>,
    pub unread_count: u64,
    pub show_names: bool,
    pub show_preview: bool,
    pub show_payment_amount: bool,
}

#[derive(uniffi::Record)]
pub struct SonarNotificationEnvelopeInfo {
    pub kind: SonarNotificationKindInfo,
    pub title: String,
    pub body: String,
    pub payment_sats: Option<u64>,
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
    pub reply_to_hex: Option<String>,
}

/// FFI-friendly account-level direct NIP-17 DM, decoded from a `bitchat1:`
/// embedded private-message packet.
#[derive(uniffi::Record)]
pub struct DirectDmInfo {
    pub event_id_hex: String,
    pub id_hex: String,
    pub sender_pubkey_hex: String,
    pub content: String,
    pub created_at_secs: u64,
    pub reply_to: Option<String>,
}

/// Callback interface for conversation-summary changes. The host implements
/// this to receive push notifications when a chat's summary row is updated
/// (message sent/received, group created/deleted, unread count changed).
#[uniffi::export(callback_interface)]
pub trait ConversationChangeListener: Send + Sync {
    fn on_conversation_changed(&self, group_id_hex: String);
}

/// Progress and cancellation bridge for a file-backed media download. Hosts
/// keep this object alive until the blocking `fetch_media_to_file` call exits.
#[uniffi::export(callback_interface)]
pub trait MediaDownloadListener: Send + Sync {
    fn on_progress(&self, bytes_received: u64, total_bytes: Option<u64>);
    fn is_cancelled(&self) -> bool;
}

struct FfiMediaDownloadObserver<'a> {
    listener: &'a dyn MediaDownloadListener,
}

impl sonar_core::client::MediaDownloadObserver for FfiMediaDownloadObserver<'_> {
    fn on_progress(&self, bytes_received: u64, total_bytes: Option<u64>) {
        self.listener.on_progress(bytes_received, total_bytes);
    }

    fn is_cancelled(&self) -> bool {
        self.listener.is_cancelled()
    }
}

/// Progress and cancellation bridge for a Blossom media upload. Hosts keep this
/// object alive until the blocking `send_media_*_with_progress` call exits.
#[uniffi::export(callback_interface)]
pub trait MediaUploadListener: Send + Sync {
    fn on_progress(&self, client_pending_id: String, bytes_sent: u64, total_bytes: u64);
    fn is_cancelled(&self) -> bool;
}

struct FfiMediaUploadObserver<'a> {
    listener: &'a dyn MediaUploadListener,
}

impl sonar_core::client::MediaUploadObserver for FfiMediaUploadObserver<'_> {
    fn on_progress(&self, client_pending_id: &str, bytes_sent: u64, total_bytes: u64) {
        self.listener
            .on_progress(client_pending_id.to_string(), bytes_sent, total_bytes);
    }

    fn is_cancelled(&self) -> bool {
        self.listener.is_cancelled()
    }
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
    /// Monotonic per-conversation change counter — a cheap cache key: equal
    /// version ⇒ nothing about this conversation's summary/transcript changed.
    pub version: u64,
}

#[uniffi::export]
pub fn sonar_notification_classify_content(content: String) -> SonarNotificationKindInfo {
    notification_kind_info(core_notification_kind(&content))
}

#[uniffi::export]
pub fn sonar_notification_payment_sats(content: String) -> Option<u64> {
    core_payment_amount_sats(&content)
}

/// One `@mention` found in message content.
///
/// `start_utf16` / `end_utf16` are **UTF-16 code unit** offsets: they index a
/// Kotlin `String` directly and convert to a Swift `String.Index` with
/// `String.Index(utf16Offset:in:)`. Byte offsets would land in the wrong place
/// on both hosts as soon as the message contains an emoji.
#[derive(uniffi::Record)]
pub struct SonarMentionSpanInfo {
    pub start_utf16: u32,
    pub end_utf16: u32,
    /// Name as typed, without the leading `@` and without any `#abcd` suffix.
    pub name: String,
    /// Lowercased 4-hex disambiguator, when the mention carried one.
    pub suffix_hex4: Option<String>,
}

/// Extract every `@mention` in `content`.
///
/// Mentions are plain text on the wire, so this is pure parsing — it is the
/// single decoder both hosts read rather than each re-implementing the scan
/// (same rule as `MessageClassification`; see R-017 in `docs/REGRESSIONS.md`).
/// Cheap and allocation-free when the content holds no `@`, but hosts should
/// still call it at row-build time and memoize, never per rendered frame.
#[uniffi::export]
pub fn sonar_parse_mentions(content: String) -> Vec<SonarMentionSpanInfo> {
    core_parse_mentions(&content)
        .into_iter()
        .map(|span| SonarMentionSpanInfo {
            start_utf16: span.start_utf16,
            end_utf16: span.end_utf16,
            name: span.name,
            suffix_hex4: span.suffix_hex4,
        })
        .collect()
}

/// True when `content` mentions the identity holding `pubkey_hex`.
///
/// `display_name` is supplied by the host rather than read from core state:
/// the core deliberately caches no local kind-0 profile, and both hosts already
/// hold the user's current nickname. A `@name#abcd` mention matches on the
/// suffix alone and so survives a rename; a bare `@name` needs `display_name`
/// and stops resolving if the user renames after the message was sent.
#[uniffi::export]
pub fn sonar_mentions_pubkey(
    content: String,
    pubkey_hex: String,
    display_name: Option<String>,
) -> bool {
    core_mentions_pubkey(&content, &pubkey_hex, display_name.as_deref())
}

/// The `#abcd` disambiguator for a public key — its last 4 hex digits,
/// lowercased. Hosts use it to build `@name#abcd` when two group members share
/// a display name. `None` when `pubkey_hex` is not plausible hex.
#[uniffi::export]
pub fn sonar_mention_short_suffix(pubkey_hex: String) -> Option<String> {
    core_short_suffix(&pubkey_hex)
}

#[uniffi::export]
pub fn sonar_render_notification(
    input: SonarNotificationRenderInputInfo,
) -> Option<SonarNotificationEnvelopeInfo> {
    core_render_notification(notification_render_input(input)).map(notification_envelope_info)
}

/// One-way "the host is about to be suspended" latch.
///
/// Exists as its own object — rather than living only inside `SonarNode` — so
/// the host can hold one *before* a node exists. `SonarNode::connect` opens
/// SQLCipher and then awaits the relay quorum, `subscribe_marmot` and
/// `retry_outbox`; a connect still in flight when iOS suspends therefore holds
/// the store open with no node to call `interrupt_for_suspend()` on, and the
/// close queues behind it until RunningBoard kills the process with
/// 0xdead10cc (`docs/REGRESSIONS.md`, R-031). Passing a latch into `connect`
/// closes that window: the host latches it from its scene-phase suspend hook
/// and the connect drops its future at the next await point.
///
/// One-way for its lifetime: a reconnect builds a fresh node and takes a fresh
/// latch, so it never needs resetting. Non-blocking and safe from any thread.
#[derive(uniffi::Object)]
pub struct SonarSuspendLatch {
    tx: tokio::sync::watch::Sender<bool>,
}

#[uniffi::export]
impl SonarSuspendLatch {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            tx: tokio::sync::watch::Sender::new(false),
        })
    }

    /// Abort the latched work and make every later latched call fail fast.
    pub fn interrupt(&self) {
        let _ = self.tx.send_replace(true);
    }

    pub fn is_interrupted(&self) -> bool {
        *self.tx.borrow()
    }
}

/// A relay-connected Sonar node. Owns its own tokio runtime; every method is
/// blocking — call from a background queue in Swift, never the main thread.
#[derive(uniffi::Object)]
pub struct SonarNode {
    runtime: tokio::runtime::Runtime,
    client: SonarClient,
    /// One-way suspend latch (`interrupt_for_suspend`). Long-blocking relay
    /// methods select against it so an imminent iOS suspension can abort them
    /// instead of holding the SQLCipher store past the background deadline
    /// (RunningBoard 0xdead10cc). Reconnect builds a fresh node, so the latch
    /// never needs resetting. This is the SAME latch the host passed to
    /// `connect`, when it passed one — so a host that latches mid-connect and a
    /// host that latches after install use one object and one code path.
    suspend_interrupt: Arc<SonarSuspendLatch>,
    /// Lazily-started P2P call engine (iroh + cpal/opus). Cloned out under a short
    /// lock so a long `call_wait_event` park never blocks `call_hangup` etc.
    #[cfg(feature = "calls-audio")]
    call: Mutex<Option<Arc<sonar_core::call::engine::CallEngine>>>,
}

/// Stable marker at the end of every suspend-aborted error message.
///
/// `SonarFfiError` is `#[uniffi(flat_error)]`, so only the rendered message
/// crosses the FFI boundary — the Swift host tells a deliberate suspend abort
/// apart from a real relay failure by matching this substring. Changing the
/// text is a breaking change for `MarmotChatModel.isSuspendInterrupted` and
/// `SonarPushRegistration.attemptRegistration` (see `docs/REGRESSIONS.md`,
/// R-016); keep the two in sync.
pub const SUSPEND_INTERRUPT_MARKER: &str = "interrupted for suspend";

impl SonarNode {
    /// `block_on`, but racing the suspend latch: when `interrupt_for_suspend()`
    /// fires (or already fired), the future is dropped at its next await point
    /// and the call returns an error instead of parking the host queue for the
    /// remainder of an uncancellable relay wait. Only for relay-bound calls
    /// whose partial progress is already crash-safe (sync's stage→persist→
    /// commit has boot-time recovery; a dropped publish retries via outbox or
    /// re-registration) — a process suspension today aborts them at an
    /// arbitrary instant anyway, without the clean store close this enables.
    fn block_on_suspendable<T>(
        &self,
        what: &str,
        fut: impl std::future::Future<Output = Result<T, sonar_core::Error>>,
    ) -> FfiResult<T> {
        let mut interrupted = self.suspend_interrupt.tx.subscribe();
        self.runtime.block_on(async {
            tokio::select! {
                biased;
                _ = interrupted.wait_for(|suspending| *suspending) => Err(
                    SonarFfiError::Core(format!("{what} {SUSPEND_INTERRUPT_MARKER}"))
                ),
                result = fut => result.map_err(Into::into),
            }
        })
    }
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
    /// - `suspend_latch`: optional host-held [`SonarSuspendLatch`], created
    ///   BEFORE this call and registered where the host's suspend hook can reach
    ///   it. Latching it aborts the connect at its next await point instead of
    ///   leaving SQLCipher open for the rest of the relay quorum wait,
    ///   `subscribe_marmot` and `retry_outbox` — the R-031 0xdead10cc window,
    ///   which no post-hoc `interrupt_for_suspend()` can reach because the node
    ///   it lives on does not exist yet. On abort nothing is installed: the
    ///   half-built client (and its store handle) is dropped and the error
    ///   carries [`SUSPEND_INTERRUPT_MARKER`]. Pass `None` on hosts with no
    ///   suspend deadline (Android/desktop) — the node then makes its own latch.
    ///
    /// The abort is safe for the same reason `block_on_suspendable`'s is: a
    /// dropped future stops at an await point, and everything before the first
    /// one here — the SQLCipher open and MLS engine construction — either
    /// completed or never began. No MLS commit spans an await.
    #[uniffi::constructor]
    pub fn connect(
        identity: Arc<SonarIdentity>,
        relay_urls: Vec<String>,
        db_path: String,
        db_key_hex: String,
        suspend_latch: Option<Arc<SonarSuspendLatch>>,
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
        let suspend_interrupt = suspend_latch.unwrap_or_else(SonarSuspendLatch::new);
        let mut interrupted = suspend_interrupt.tx.subscribe();
        // `biased` matters: an already-latched host must never reach the
        // SQLCipher open at all. The connect future's body does not run until
        // it is first polled, so losing this race means the store was never
        // touched.
        let client = runtime.block_on(async {
            tokio::select! {
                biased;
                _ = interrupted.wait_for(|suspending| *suspending) => Err(
                    SonarFfiError::Core(format!("connect {SUSPEND_INTERRUPT_MARKER}"))
                ),
                result = SonarClient::connect(
                    identity.inner.clone(),
                    relays,
                    &db_path,
                    db_key,
                ) => result.map_err(Into::into),
            }
        })?;
        Ok(Arc::new(Self {
            runtime,
            client,
            suspend_interrupt,
            #[cfg(feature = "calls-audio")]
            call: Mutex::new(None),
        }))
    }

    /// Abort interruptible in-flight relay calls (`sync_once`, `sync_force`,
    /// `register_push_token`, descriptor/profile fetches) and make future ones
    /// fail fast with an "interrupted for suspend" error. The iOS host calls
    /// this right before closing the node for background suspension: the close
    /// queues on a serial dispatch queue BEHIND those blocking calls, and iOS
    /// only grants ~30s of background grace — an uninterrupted relay sync
    /// holds the SQLCipher store past that deadline and RunningBoard kills the
    /// process with 0xdead10cc. Non-blocking and safe from any thread. One-way
    /// for this node's lifetime; reconnect constructs a fresh node.
    ///
    /// Only reaches work running on an *installed* node. A connect still in
    /// flight has no node to call this on — the host must pass a
    /// [`SonarSuspendLatch`] to `connect` and latch that instead (R-031).
    pub fn interrupt_for_suspend(&self) {
        self.suspend_interrupt.interrupt();
    }

    /// Publish our kind-30443 KeyPackage so others can start groups with us.
    pub fn publish_key_package(&self) -> FfiResult<()> {
        self.runtime.block_on(self.client.publish_key_package())?;
        Ok(())
    }

    /// Like `publish_key_package`, but the relay send happens in the
    /// background: returns as soon as the KeyPackage event is created and
    /// persisted, without waiting for relay OK acks. For the cold-start /
    /// relay-connect republish path, where the per-relay OK wait must not
    /// delay the first message drain. Failures are logged in core and
    /// self-heal on the next relay connect (replaceable event).
    /// Suspendable: runs automatically on relay connect. A KeyPackage is a
    /// replaceable event, so an aborted publish self-heals on the next connect.
    pub fn publish_key_package_background(&self) -> FfiResult<()> {
        self.block_on_suspendable(
            "publish_key_package_background",
            self.client.publish_key_package_background(),
        )?;
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

    /// Like `publish_profile`, but the relay send happens in the background —
    /// same contract as `publish_key_package_background`.
    pub fn publish_profile_background(
        &self,
        name: String,
        about: Option<String>,
        picture: Option<String>,
    ) {
        self.runtime
            .block_on(self.client.publish_profile_background(
                &name,
                about.as_deref(),
                picture.as_deref(),
            ));
    }

    /// Fetch a peer's kind-0 profile (npub or hex pubkey). `None` if they have
    /// not published one. Used to resolve a Marmot member's display name.
    pub fn fetch_profile(&self, npub: String) -> FfiResult<Option<ProfileInfo>> {
        let pubkey = PublicKey::parse(&npub).map_err(invalid("profile pubkey"))?;
        // Suspendable: per-member profile prefetches park the iOS serial work
        // queue for FETCH_TIMEOUT each (0xdead10cc round 2 offender).
        let profile =
            self.block_on_suspendable("fetch_profile", self.client.fetch_profile(pubkey))?;
        Ok(profile.map(|p| ProfileInfo {
            name: p.name,
            display_name: p.display_name,
            about: p.about,
            picture: p.picture,
            nip05: p.nip05,
        }))
    }

    /// The claimed human-readable handle (`name@domain`), if any. Local read,
    /// safe on any thread — never touches the network.
    pub fn claimed_handle(&self) -> Option<String> {
        self.client.claimed_handle()
    }

    /// Claim (or refresh) a handle at the Sonar registrar. One claim registers
    /// both resolutions: NIP-05 (chat) always, BIP-353 (payments) when `offer`
    /// is present. Signed with the identity key, so restoring the nsec
    /// re-claims the same name. A taken handle surfaces as an error whose
    /// message starts with "handle taken:". Callers should republish the
    /// kind-0 profile afterwards so peers see the handle immediately.
    pub fn claim_handle(&self, handle: String, offer: Option<String>) -> FfiResult<String> {
        Ok(self
            .runtime
            .block_on(self.client.claim_handle(&handle, offer.as_deref()))?)
    }

    /// Resolve a handle to its owner. Bare nicknames (`vincenzo`) resolve on
    /// the default Sonar domain; full addresses (`alice@example.com`) resolve
    /// against any NIP-05 host. Bounded network work — call from a background
    /// context, never on the chat-open or startup path.
    pub fn resolve_handle(&self, input: String) -> FfiResult<ResolvedHandleInfo> {
        let resolved = self.runtime.block_on(self.client.resolve_handle(&input))?;
        Ok(ResolvedHandleInfo {
            address: resolved.address,
            npub: resolved
                .pubkey
                .to_bech32()
                .map_err(|e| SonarFfiError::Core(e.to_string()))?,
            pubkey_hex: resolved.pubkey.to_hex(),
        })
    }

    /// True if `address` (full `name@domain`) currently resolves to `npub` via
    /// NIP-05. `false` covers both "not registered" and "registered to someone
    /// else"; network failures are errors so callers can show "unverified"
    /// instead of "fake" when offline.
    pub fn verify_nip05(&self, address: String, npub: String) -> FfiResult<bool> {
        let pubkey = PublicKey::parse(&npub).map_err(invalid("nip05 pubkey"))?;
        Ok(self
            .runtime
            .block_on(self.client.verify_nip05(&address, &pubkey))?)
    }

    /// Publish this identity's public Sonar descriptor. `signaling` should list
    /// only routes this app build can actually use, in preference order.
    ///
    /// Suspendable: hosts republish this automatically when payment/call
    /// capabilities settle, and it awaits relay acks for up to two replaceable
    /// events on the same serial work queue the store close needs. Replaceable
    /// ⇒ an aborted publish self-heals on the next capability change or connect.
    pub fn publish_sonar_descriptor(
        &self,
        calls_enabled: bool,
        signaling: Vec<String>,
        bolt12_offer: Option<String>,
    ) -> FfiResult<()> {
        self.block_on_suspendable(
            "publish_sonar_descriptor",
            self.client
                .publish_sonar_descriptor(calls_enabled, signaling, bolt12_offer),
        )?;
        Ok(())
    }

    /// Fetch a peer's Sonar descriptor (npub or hex pubkey). `None` means the
    /// peer is not confirmed Sonar-capable through this relay set.
    pub fn fetch_sonar_descriptor(&self, npub: String) -> FfiResult<Option<SonarDescriptorInfo>> {
        let pubkey = PublicKey::parse(&npub).map_err(invalid("descriptor pubkey"))?;
        // Suspendable: runs two FETCH_TIMEOUT fetches per member on the iOS
        // serial work queue (0xdead10cc round 2 offender).
        let descriptor = self.block_on_suspendable(
            "fetch_sonar_descriptor",
            self.client.fetch_sonar_descriptor(pubkey),
        )?;
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

    /// Like `send_text`, attaching a NIP-C7 reply pointer.
    pub fn send_text_reply(
        &self,
        group_id_hex: String,
        text: String,
        reply_to_hex: String,
        reply_to_npub: String,
        preview: Option<String>,
    ) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        let parent_id = nostr::EventId::from_hex(&reply_to_hex)
            .map_err(|e| SonarFfiError::InvalidInput(format!("reply_to: {e}")))?;
        let parent_pk = PublicKey::parse(&reply_to_npub)
            .map_err(invalid("reply_to npub"))?;
        let reply = sonar_core::reply::ReplyTo::new(parent_id, parent_pk, preview);
        self.runtime.block_on(self.client.send_text_with_reply(
            &group_id,
            &text,
            Some(&reply),
        ))?;
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
        self.runtime
            .block_on(self.client.fetch_sticker_image(&url, &expected_sha256))
            .map_err(Into::into)
    }

    /// Return verified local bytes only when the latest locally cached pack
    /// definition authorizes the exact sticker reference. Never contacts relays
    /// or HTTP; `None` is an ordinary cache or validation miss.
    pub fn cached_sticker_image_for_ref(
        &self,
        pack_coordinate: String,
        shortcode: String,
        plaintext_sha256: String,
    ) -> FfiResult<Option<Vec<u8>>> {
        let pack = sonar_stickers::PackAddress::parse(&pack_coordinate)
            .map_err(|e| SonarFfiError::InvalidInput(format!("bad pack coordinate: {e}")))?;
        let sticker_ref = sonar_stickers::StickerRef::new(pack, shortcode, plaintext_sha256)
            .map_err(|e| SonarFfiError::InvalidInput(format!("bad sticker ref: {e}")))?;
        self.client
            .cached_sticker_image_for_ref(&sticker_ref)
            .map_err(Into::into)
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
    /// Suspendable: `interrupt_for_suspend()` aborts it so a store close never
    /// queues behind a full relay sync (0xdead10cc round 3).
    pub fn sync_once(&self) -> FfiResult<()> {
        self.block_on_suspendable("sync", self.client.sync())?;
        Ok(())
    }

    /// Like `sync_once` but bypasses the live-subscription short-circuit.
    /// Use after a foreground resume to catch events missed while backgrounded.
    /// Suspendable like `sync_once`.
    pub fn sync_force(&self) -> FfiResult<()> {
        self.block_on_suspendable("sync_force", self.client.sync_force())?;
        Ok(())
    }

    /// Freeze durable sync-watermark advances (White Noise NSE
    /// `cursorPersistence: .frozen`). Push-wake catch-up still decrypts into
    /// the store; the next durable session re-fetches any missed gap.
    pub fn set_sync_watermark_frozen(&self, frozen: bool) {
        self.client.set_sync_watermark_frozen(frozen);
    }

    /// Notification Service Extension / push-wake entry point: bounded
    /// `sync_force` under a frozen watermark, then drain notifications for
    /// local banner decoration. Partial progress still returns drained rows.
    pub fn collect_notifications_after_wake(
        &self,
        max_wait_ms: u64,
    ) -> FfiResult<Vec<DrainNotificationInfo>> {
        let wait = std::time::Duration::from_millis(max_wait_ms.max(1));
        let notifications = self
            .runtime
            .block_on(self.client.collect_notifications_after_wake(wait))?;
        Ok(notifications
            .into_iter()
            .map(|n| DrainNotificationInfo {
                message_id_hex: n.message_id_hex,
                sender_npub: n.sender_pubkey,
                group_id_hex: n.group_id_hex,
                group_name: n.group_name,
                content_preview: n.content_preview,
            })
            .collect())
    }

    /// Point-in-time JSON snapshot of relay/sync state for the Diagnostics
    /// screen and the exported debug bundle: per-relay connection status, the
    /// sync watermark, live-subscription state, and per-group catch-up floors.
    /// Contains NO message content and NO key material.
    pub fn sync_state_snapshot_json(&self) -> FfiResult<String> {
        let snapshot = self.runtime.block_on(self.client.sync_state_snapshot());
        serde_json::to_string_pretty(&snapshot).map_err(|e| SonarFfiError::Core(e.to_string()))
    }

    /// Reload the durable outbox sidecar and retry pending sends. Hosts call this
    /// after replacing a local-only node with a relay-backed node so sends created
    /// during relay connect are not stranded until app restart.
    /// Suspendable: runs automatically after relay connect and from the idle
    /// path, both on the host's serial work queue. Aborting only leaves entries
    /// in the durable outbox, which is precisely what it exists for — they
    /// republish on the next connect.
    pub fn retry_outbox(&self) -> FfiResult<()> {
        self.block_on_suspendable("retry_outbox", async {
            self.client.reload_outbox_and_retry().await;
            Ok(())
        })?;
        Ok(())
    }

    /// Prefer catch-up for the open chat. Pass the MLS group id hex (same id
    /// hosts use for send_text / messages). Empty clears. Local-first: does not
    /// block paint or send. Core maps MLS to nostr group id for the catch-up queue.
    pub fn prefer_catchup_group(&self, mls_group_id_hex: String) {
        let preferred = mls_group_id_hex.trim();
        if preferred.is_empty() {
            self.client.prefer_catchup_group(None);
        } else {
            self.client
                .prefer_catchup_group(Some(preferred.to_string()));
        }
    }

    /// Retry one failed outgoing message from the durable local outbox. The
    /// original encrypted event is republished, so retry cannot duplicate the
    /// plaintext transcript row or mutate MLS state a second time.
    pub fn retry_message(&self, message_id_hex: String) -> FfiResult<String> {
        Ok(self
            .runtime
            .block_on(self.client.retry_message(&message_id_hex))?)
    }

    /// Re-subscribe with the current watermark and group set to self-heal
    /// after relay disconnects. Hosts call this on the idle timeout path
    /// instead of `sync_once()`. It may run one bounded per-chat repair fetch,
    /// so hosts must keep it off the local-first chat-open path.
    /// Suspendable: this is the idle-timeout path, so it is the call most
    /// likely to be parked on the host's serial work queue exactly when the app
    /// backgrounds — and it can await subscription setup plus a bounded repair
    /// fetch, which is long enough to push the store close past the ~30s
    /// suspension deadline (0xdead10cc). Re-runs on the next idle tick.
    pub fn ensure_subscriptions(&self) -> FfiResult<()> {
        self.block_on_suspendable("ensure_subscriptions", self.client.ensure_subscriptions())?;
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

    /// Process buffered live Marmot events through the MLS engine. Returns
    /// notification info for each incoming message (empty vec = nothing drained).
    /// MUST run on the host's serialized engine queue.
    pub fn drain_pending_marmot(&self) -> FfiResult<Vec<DrainNotificationInfo>> {
        let notifications = self.runtime.block_on(self.client.drain_pending_marmot())?;
        Ok(notifications
            .into_iter()
            .map(|n| DrainNotificationInfo {
                message_id_hex: n.message_id_hex,
                sender_npub: n.sender_pubkey,
                group_id_hex: n.group_id_hex,
                group_name: n.group_name,
                content_preview: n.content_preview,
            })
            .collect())
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
                version: s.version,
            })
            .collect()
    }

    pub fn mark_conversation_read(&self, group_id_hex: String) {
        self.client.mark_conversation_read(&group_id_hex);
    }

    /// Stable newest-first transcript page ordered by
    /// `(created_at DESC, event_id DESC)`. The cursor is exclusive; callers
    /// should pass the final message tuple from the previous page.
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

    /// Encrypt + upload every `item`, then publish them as ONE album message
    /// (a single kind-445 event with N `imeta` tags, in order) carrying the
    /// optional `caption`. `server_url` empty → the core default. Blocks on the
    /// uploads; if ANY upload fails nothing is published. `items` must be
    /// non-empty.
    pub fn send_media_multi(
        &self,
        group_id_hex: String,
        items: Vec<MediaUploadItem>,
        caption: String,
        server_url: String,
    ) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        let uploads = items
            .into_iter()
            .map(|i| sonar_core::client::MediaUpload {
                data: i.data,
                filename: i.filename,
                mime: i.mime,
            })
            .collect();
        self.runtime.block_on(self.client.send_media_multi(
            &group_id,
            uploads,
            &caption,
            &server_url,
        ))?;
        Ok(())
    }

    /// Like `send_media`, with Blossom upload progress for the host optimistic
    /// bubble identified by `client_pending_id`.
    pub fn send_media_with_progress(
        &self,
        group_id_hex: String,
        data: Vec<u8>,
        filename: String,
        mime: String,
        caption: String,
        server_url: String,
        client_pending_id: String,
        listener: Box<dyn MediaUploadListener>,
    ) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        let observer = FfiMediaUploadObserver {
            listener: listener.as_ref(),
        };
        self.runtime
            .block_on(self.client.send_media_multi_with_progress(
                &group_id,
                vec![sonar_core::client::MediaUpload {
                    data,
                    filename,
                    mime,
                }],
                &caption,
                &server_url,
                &client_pending_id,
                Some(&observer),
            ))?;
        Ok(())
    }

    /// Like `send_media_multi`, with aggregated album upload progress.
    pub fn send_media_multi_with_progress(
        &self,
        group_id_hex: String,
        items: Vec<MediaUploadItem>,
        caption: String,
        server_url: String,
        client_pending_id: String,
        listener: Box<dyn MediaUploadListener>,
    ) -> FfiResult<()> {
        let group_id = parse_group_id(&group_id_hex)?;
        let uploads = items
            .into_iter()
            .map(|i| sonar_core::client::MediaUpload {
                data: i.data,
                filename: i.filename,
                mime: i.mime,
            })
            .collect();
        let observer = FfiMediaUploadObserver {
            listener: listener.as_ref(),
        };
        self.runtime
            .block_on(self.client.send_media_multi_with_progress(
                &group_id,
                uploads,
                &caption,
                &server_url,
                &client_pending_id,
                Some(&observer),
            ))?;
        Ok(())
    }

    /// Resume durable pre-Blossom media staging left by interrupted uploads.
    /// Returns how many staged entries were attempted.
    pub fn resume_pending_media_uploads(
        &self,
        listener: Box<dyn MediaUploadListener>,
    ) -> FfiResult<u32> {
        let observer = FfiMediaUploadObserver {
            listener: listener.as_ref(),
        };
        Ok(self
            .runtime
            .block_on(self.client.resume_pending_media_uploads(Some(&observer)))?)
    }

    /// Resume durable staged media uploads without a progress listener.
    pub fn resume_pending_media_uploads_quiet(&self) -> FfiResult<u32> {
        Ok(self
            .runtime
            .block_on(self.client.resume_pending_media_uploads(None))?)
    }

    /// Latch cancel for quiet resume / in-flight Blossom work (wipe, stopPolling).
    pub fn cancel_all_media_uploads(&self) {
        self.client.cancel_all_media_uploads();
    }

    /// Download + decrypt the media blob at `url` for `group_id`. Returns plaintext.
    pub fn fetch_media(&self, group_id_hex: String, url: String) -> FfiResult<Vec<u8>> {
        let group_id = parse_group_id(&group_id_hex)?;
        Ok(self
            .runtime
            .block_on(self.client.fetch_media(&group_id, &url))?)
    }

    /// Download + decrypt directly into `destination_path`, reporting network
    /// progress and observing host cancellation throughout the blocking call.
    pub fn fetch_media_to_file(
        &self,
        group_id_hex: String,
        url: String,
        destination_path: String,
        listener: Box<dyn MediaDownloadListener>,
    ) -> FfiResult<u64> {
        let group_id = parse_group_id(&group_id_hex)?;
        let observer = FfiMediaDownloadObserver {
            listener: listener.as_ref(),
        };
        Ok(self.runtime.block_on(self.client.fetch_media_to_file(
            &group_id,
            &url,
            Path::new(&destination_path),
            &observer,
        ))?)
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

    /// Send an account-level direct NIP-17 DM to a plain bitchat peer. The
    /// content is wrapped as `bitchat1:` so iOS/stock bitchat can decode it.
    pub fn send_direct_dm(
        &self,
        recipient_hex: String,
        sender_peer_id_hex: String,
        recipient_peer_id_hex: String,
        message_id: String,
        text: String,
        reply_to: Option<String>,
    ) -> FfiResult<()> {
        self.runtime.block_on(self.client.send_direct_dm(
            &recipient_hex,
            &sender_peer_id_hex,
            &recipient_peer_id_hex,
            &message_id,
            &text,
            reply_to
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty()),
        ))?;
        Ok(())
    }

    /// Drain account-level direct NIP-17 DMs received since the last drain.
    pub fn drain_direct_dms(&self) -> Vec<DirectDmInfo> {
        self.client
            .drain_direct_dms()
            .into_iter()
            .map(direct_dm_info)
            .collect()
    }

    /// Acknowledge direct NIP-17 DMs only after the host persisted or consumed
    /// the drained records.
    pub fn acknowledge_direct_dms(&self, event_id_hexes: Vec<String>) -> FfiResult<()> {
        self.client.acknowledge_direct_dms(&event_id_hexes)?;
        Ok(())
    }

    // ── Push token registration (MIP-05) ──

    /// Encrypt a device push token to the transponder and cache/share it with
    /// peers. Sender-side wakeups publish kind-446 requests later.
    ///
    /// `platform`: `"apns"` or `"fcm"`.
    /// `token`: raw device token bytes (APNS) or UTF-8 FCM token string.
    /// `server_npub`: the transponder's npub (bech32 or hex).
    pub fn register_push_token(
        &self,
        platform: String,
        token: Vec<u8>,
        server_npub: String,
    ) -> FfiResult<()> {
        // Suspendable: a blocking registration was the second store-lock
        // holder in the 0xdead10cc round 2/3 crash logs; registration re-runs
        // on the next launch/foreground, so aborting it is always safe.
        self.block_on_suspendable(
            "register_push_token",
            self.client
                .register_push_token(&platform, &token, &server_npub),
        )?;
        Ok(())
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
        if self
            .call
            .lock()
            .expect("call engine lock not poisoned")
            .is_some()
        {
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
        let engine = self
            .call
            .lock()
            .expect("call engine lock not poisoned")
            .clone();
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
    pub reply_to: Option<String>,
}

/// A decoded mesh file transfer (`BitchatFilePacket`, type 0x22). `content` is
/// the raw file bytes (already decrypted for a private transfer).
#[derive(uniffi::Record)]
pub struct MeshFileInfo {
    pub file_name: Option<String>,
    pub file_size: Option<u64>,
    pub mime_type: Option<String>,
    pub message_id: Option<String>,
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
    if mesh::peer_id_from_noise_key(&announce.noise_public_key) != hex::encode(packet.sender_id) {
        return None;
    }
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

/// Decode a Sonar discovery/profile announce only when its Ed25519 signature
/// verifies against the signing key from that sender's verified identity
/// announce. The full wire packet is required because the signature covers the
/// packet header and payload (with TTL canonicalized to zero).
#[uniffi::export]
pub fn mesh_parse_verified_sonar_announce(
    packet_bytes: Vec<u8>,
    signing_public_key_hex: String,
) -> Option<Vec<u8>> {
    let signing_public_key = hex::decode(signing_public_key_hex).ok()?;
    if signing_public_key.len() != 32 {
        return None;
    }
    let packet = mesh::Packet::decode(&packet_bytes)?;
    if packet.type_ != mesh::msg_type::SONAR_ANNOUNCE
        || !mesh::verify_packet(&packet, &signing_public_key)
    {
        return None;
    }
    Some(packet.payload)
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

/// Build a protocol-v2 packet signed with the Ed25519 announce key. v2 uses a
/// u32 payload length and can carry source-route hops; this is required for
/// large Android file-transfer packets to match iOS' signed v2 shape.
#[uniffi::export]
pub fn mesh_build_signed_packet_v2(
    seed_hex: String,
    packet_type: u8,
    sender_id_hex: String,
    recipient_id_hex: String,
    route_id_hexes: Vec<String>,
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
    let mut packet = mesh::Packet::new_v2(packet_type, ttl, timestamp_ms, sender);
    if !recipient_id_hex.is_empty() {
        packet.recipient_id = Some(parse_id8(&recipient_id_hex, "recipient id")?);
    }
    if !route_id_hexes.is_empty() {
        let mut route = Vec::with_capacity(route_id_hexes.len());
        for hop in &route_id_hexes {
            route.push(parse_id8(hop, "route hop id")?);
        }
        packet.route = Some(route);
    }
    packet.payload = payload;
    if !mesh::sign_packet(&mut packet, &signer) {
        return Err(SonarFfiError::Core("signed v2 packet sign failed".into()));
    }
    packet
        .encode()
        .ok_or_else(|| SonarFfiError::Core("signed v2 packet encode failed".into()))
}

/// The inner noiseEncrypted plaintext for a private message: `[0x01][TLV]`.
#[uniffi::export]
pub fn mesh_encode_private_message(message_id: String, content: String) -> FfiResult<Vec<u8>> {
    mesh_encode_private_message_with_reply(message_id, content, None)
}

/// Same as [`mesh_encode_private_message`], with an optional parent id (TLV 0x04).
#[uniffi::export]
pub fn mesh_encode_private_message_with_reply(
    message_id: String,
    content: String,
    reply_to: Option<String>,
) -> FfiResult<Vec<u8>> {
    let pm = mesh::PrivateMessage {
        message_id,
        content,
        reply_to: reply_to
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
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
        reply_to: pm.reply_to,
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
    message_id: Option<String>,
    content: Vec<u8>,
) -> FfiResult<Vec<u8>> {
    mesh::file_packet::FilePacket {
        file_name,
        file_size,
        mime_type,
        message_id,
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
        message_id: p.message_id,
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
    /// Monotonic epoch for stream idle expiry (#416). Hosts never supply a
    /// clock through this wrapper, so age is measured against construction
    /// time; the exported API is unchanged.
    epoch: std::time::Instant,
}

#[uniffi::export]
impl MeshReassembler {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(mesh::fragment::Reassembler::new()),
            epoch: std::time::Instant::now(),
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
        let now_ms = self.epoch.elapsed().as_millis() as u64;
        let mut inner = self
            .inner
            .lock()
            .expect("fragment assembler lock not poisoned");
        // `Reassembler::add` only sweeps when a NEW key arrives at capacity, so
        // a table that never fills would retain idle and over-lifetime buckets
        // for as long as this object lives. `MeshEngine` gets its sweep from
        // `on_tick`; this wrapper has no tick, so it sweeps here — otherwise a
        // host driving fragments through this API alone inherits none of the
        // expiry bounds (#416). Sweeping is O(buckets) with a ≤256 cap.
        inner.sweep(now_ms);
        Ok(inner.add(sender, &frag, now_ms))
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
        reply_to_hex: m.reply_to,
    }
}

fn direct_dm_info(m: sonar_core::client::DirectDm) -> DirectDmInfo {
    DirectDmInfo {
        event_id_hex: m.event_id,
        id_hex: m.id,
        sender_pubkey_hex: m.sender_pubkey,
        content: m.content,
        created_at_secs: m.created_at,
        reply_to: m.reply_to,
    }
}

fn message_class_info(c: sonar_core::marmot::MessageClassification) -> MessageClassInfo {
    use sonar_core::marmot::MessageClassification as C;
    match c {
        C::Text => MessageClassInfo::Text,
        C::PayReceipt {
            payment_id,
            amount_sats,
        } => MessageClassInfo::PayReceipt {
            payment_id,
            amount_sats,
        },
        C::PayDone {
            payment_id,
            preimage_hex,
        } => MessageClassInfo::PayDone {
            payment_id,
            preimage_hex,
        },
        C::CallControl => MessageClassInfo::CallControl,
    }
}

fn message_info(m: sonar_core::marmot::ChatMessage) -> MessageInfo {
    MessageInfo {
        id_hex: m.id.to_hex(),
        sender_npub: m.sender.to_bech32().expect("npub encoding cannot fail"),
        classification: message_class_info(m.classification),
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
        reply: m.reply.map(|r| ReplyRefInfo {
            parent_id_hex: r.parent_id.to_hex(),
            parent_npub: r.parent_pubkey.and_then(|pk| pk.to_bech32().ok()),
            preview: r.preview,
        }),
    }
}

fn notification_kind_info(kind: NotificationKind) -> SonarNotificationKindInfo {
    match kind {
        NotificationKind::Message => SonarNotificationKindInfo::Message,
        NotificationKind::Payment => SonarNotificationKindInfo::Payment,
        NotificationKind::Call => SonarNotificationKindInfo::Call,
        NotificationKind::Trill => SonarNotificationKindInfo::Trill,
        NotificationKind::Invite => SonarNotificationKindInfo::Invite,
        NotificationKind::Mention => SonarNotificationKindInfo::Mention,
        NotificationKind::Geohash => SonarNotificationKindInfo::Geohash,
        NotificationKind::Network => SonarNotificationKindInfo::Network,
    }
}

fn notification_kind(kind: SonarNotificationKindInfo) -> NotificationKind {
    match kind {
        SonarNotificationKindInfo::Message => NotificationKind::Message,
        SonarNotificationKindInfo::Payment => NotificationKind::Payment,
        SonarNotificationKindInfo::Call => NotificationKind::Call,
        SonarNotificationKindInfo::Trill => NotificationKind::Trill,
        SonarNotificationKindInfo::Invite => NotificationKind::Invite,
        SonarNotificationKindInfo::Mention => NotificationKind::Mention,
        SonarNotificationKindInfo::Geohash => NotificationKind::Geohash,
        SonarNotificationKindInfo::Network => NotificationKind::Network,
    }
}

fn notification_render_input(input: SonarNotificationRenderInputInfo) -> NotificationRenderInput {
    NotificationRenderInput {
        enabled: input.enabled,
        kind_hint: input.kind_hint.map(notification_kind),
        conversation_title: input.conversation_title,
        sender_name: input.sender_name,
        group_name: input.group_name,
        content_preview: input.content_preview,
        unread_count: input.unread_count,
        show_names: input.show_names,
        show_preview: input.show_preview,
        show_payment_amount: input.show_payment_amount,
    }
}

fn notification_envelope_info(
    envelope: sonar_core::notification::NotificationEnvelope,
) -> SonarNotificationEnvelopeInfo {
    SonarNotificationEnvelopeInfo {
        kind: notification_kind_info(envelope.kind),
        title: envelope.title,
        body: envelope.body,
        payment_sats: envelope.payment_sats,
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

// ── BLE mesh link engine ─────────────────────────────────────────────────────
//
// The platform-neutral link state machine (announce/identity, dial policy,
// per-instance links, liveness, Noise lifecycle, fail-fast sends, relay) lives
// in `sonar_core::mesh_engine`. Platform drivers feed it radio events and
// execute the returned commands; timestamps are MONOTONIC milliseconds
// supplied by the driver (the engine reads no clocks).

use sonar_core::mesh_engine;

#[derive(uniffi::Enum)]
pub enum MeshEngineCommand {
    /// Open a GATT connection to `conn` (an opaque connection handle: Android
    /// passes the address of the scanned device, iOS a peripheral UUID).
    Dial { conn: String },
    /// Tear down the CLIENT connection (close the outbound GATT). Must not
    /// touch a server-role leg the same peer holds toward us.
    Disconnect { conn: String },
    /// Cancel the SERVER-role connection from an inbound central. Must not
    /// touch a client GATT we hold toward the same address.
    CancelServer { conn: String },
    /// Re-run service discovery on an existing client connection (a lost
    /// instance link has no other recovery while the connection lives).
    RefreshInstances { conn: String },
    /// Enable notifications on the mesh characteristic of service `instance`.
    Subscribe { conn: String, instance: i32 },
    /// Write one packet value to a client link, `after_ms` from now.
    WriteLink {
        conn: String,
        instance: i32,
        bytes: Vec<u8>,
        after_ms: i64,
    },
    /// Notify one packet value to a subscribed central, `after_ms` from now.
    NotifyConn {
        conn: String,
        bytes: Vec<u8>,
        after_ms: i64,
    },
}

#[derive(uniffi::Enum)]
pub enum MeshEngineEvent {
    PeerAnnounced {
        fingerprint: String,
        nickname: String,
        peer_id_hex: String,
        direct: bool,
    },
    SonarPayload {
        fingerprint: String,
        payload: Vec<u8>,
    },
    TextReceived {
        fingerprint: String,
        message_id: String,
        content: String,
        reply_to: Option<String>,
    },
    DeliveryReceived {
        fingerprint: String,
        message_id: String,
    },
    FileReceived {
        fingerprint: String,
        transfer_key: String,
        message_id: Option<String>,
        file_name: Option<String>,
        mime_type: Option<String>,
        content: Vec<u8>,
        timestamp_ms: i64,
    },
    BroadcastReceived {
        fingerprint: String,
        sender_id_hex: String,
        content: String,
        timestamp_ms: i64,
    },
    LinkEstablished {
        fingerprint: String,
    },
}

#[derive(uniffi::Record)]
pub struct MeshEngineOutput {
    pub commands: Vec<MeshEngineCommand>,
    pub events: Vec<MeshEngineEvent>,
}

fn engine_output(out: mesh_engine::Output) -> MeshEngineOutput {
    MeshEngineOutput {
        commands: out
            .commands
            .into_iter()
            .map(|c| match c {
                mesh_engine::Command::Dial { conn } => MeshEngineCommand::Dial { conn },
                mesh_engine::Command::Disconnect { conn } => MeshEngineCommand::Disconnect { conn },
                mesh_engine::Command::CancelServer { conn } => {
                    MeshEngineCommand::CancelServer { conn }
                }
                mesh_engine::Command::RefreshInstances { conn } => {
                    MeshEngineCommand::RefreshInstances { conn }
                }
                mesh_engine::Command::Subscribe { conn, instance } => {
                    MeshEngineCommand::Subscribe { conn, instance }
                }
                mesh_engine::Command::WriteLink {
                    conn,
                    instance,
                    bytes,
                    after_ms,
                } => MeshEngineCommand::WriteLink {
                    conn,
                    instance,
                    bytes,
                    after_ms: after_ms as i64,
                },
                mesh_engine::Command::NotifyConn {
                    conn,
                    bytes,
                    after_ms,
                } => MeshEngineCommand::NotifyConn {
                    conn,
                    bytes,
                    after_ms: after_ms as i64,
                },
            })
            .collect(),
        events: out
            .events
            .into_iter()
            .map(|e| match e {
                mesh_engine::AppEvent::PeerAnnounced {
                    fingerprint,
                    nickname,
                    peer_id_hex,
                    direct,
                } => MeshEngineEvent::PeerAnnounced {
                    fingerprint,
                    nickname,
                    peer_id_hex,
                    direct,
                },
                mesh_engine::AppEvent::SonarPayload {
                    fingerprint,
                    payload,
                } => MeshEngineEvent::SonarPayload {
                    fingerprint,
                    payload,
                },
                mesh_engine::AppEvent::TextReceived {
                    fingerprint,
                    message_id,
                    content,
                    reply_to,
                } => MeshEngineEvent::TextReceived {
                    fingerprint,
                    message_id,
                    content,
                    reply_to,
                },
                mesh_engine::AppEvent::DeliveryReceived {
                    fingerprint,
                    message_id,
                } => MeshEngineEvent::DeliveryReceived {
                    fingerprint,
                    message_id,
                },
                mesh_engine::AppEvent::FileReceived {
                    fingerprint,
                    transfer_key,
                    message_id,
                    file_name,
                    mime_type,
                    content,
                    timestamp_ms,
                } => MeshEngineEvent::FileReceived {
                    fingerprint,
                    transfer_key,
                    message_id,
                    file_name,
                    mime_type,
                    content,
                    timestamp_ms: timestamp_ms as i64,
                },
                mesh_engine::AppEvent::BroadcastReceived {
                    fingerprint,
                    sender_id_hex,
                    content,
                    timestamp_ms,
                } => MeshEngineEvent::BroadcastReceived {
                    fingerprint,
                    sender_id_hex,
                    content,
                    timestamp_ms: timestamp_ms as i64,
                },
                mesh_engine::AppEvent::LinkEstablished { fingerprint } => {
                    MeshEngineEvent::LinkEstablished { fingerprint }
                }
            })
            .collect(),
    }
}

fn ms(now_ms: i64) -> u64 {
    now_ms.max(0) as u64
}

#[derive(uniffi::Object)]
pub struct MeshLinkEngine {
    inner: Mutex<mesh_engine::Engine>,
}

impl MeshLinkEngine {
    fn lock(&self) -> std::sync::MutexGuard<'_, mesh_engine::Engine> {
        self.inner.lock().expect("mesh engine lock not poisoned")
    }
}

#[uniffi::export]
impl MeshLinkEngine {
    /// `noise_private_hex`/`noise_public_hex` are the account's static Noise
    /// keypair; `ed25519_seed_hex` the announce-signing seed.
    #[uniffi::constructor]
    pub fn new(
        noise_private_hex: String,
        noise_public_hex: String,
        ed25519_seed_hex: String,
        nickname: String,
    ) -> FfiResult<Arc<Self>> {
        let sk = hex::decode(&noise_private_hex).map_err(invalid("noise private key"))?;
        let seed = hex::decode(&ed25519_seed_hex).map_err(invalid("mesh seed"))?;
        let sk: [u8; 32] = sk.try_into().map_err(|_| {
            SonarFfiError::InvalidInput("noise private key must be 32 bytes".into())
        })?;
        let seed: [u8; 32] = seed
            .try_into()
            .map_err(|_| SonarFfiError::InvalidInput("mesh seed must be 32 bytes".into()))?;
        let engine = mesh_engine::Engine::new(sk, noise_public_hex, seed, nickname)
            .ok_or_else(|| SonarFfiError::InvalidInput("invalid noise public key".into()))?;
        Ok(Arc::new(Self {
            inner: Mutex::new(engine),
        }))
    }

    pub fn my_peer_id_hex(&self) -> String {
        self.lock().my_peer_id_hex().to_string()
    }

    pub fn should_dial_first(&self, peer_node_id: Vec<u8>) -> bool {
        self.lock().should_dial_first(&peer_node_id)
    }

    pub fn is_linked_conn(&self, conn: String) -> bool {
        self.lock().is_linked_conn(&conn)
    }

    pub fn has_link(&self, fingerprint: String) -> bool {
        self.lock().has_link(&fingerprint)
    }

    pub fn connected_count(&self) -> u32 {
        self.lock().connected_count() as u32
    }

    pub fn on_dial_request(&self, conn: String, now_ms: i64) -> MeshEngineOutput {
        engine_output(self.lock().on_dial_request(&conn, ms(now_ms)))
    }

    pub fn on_client_connected(&self, conn: String, now_ms: i64) -> MeshEngineOutput {
        engine_output(self.lock().on_client_connected(&conn, ms(now_ms)))
    }

    pub fn on_client_connect_failed(&self, conn: String) -> MeshEngineOutput {
        engine_output(self.lock().on_client_connect_failed(&conn))
    }

    pub fn on_client_disconnected(&self, conn: String) -> MeshEngineOutput {
        engine_output(self.lock().on_client_disconnected(&conn))
    }

    pub fn on_dial_deadline(&self, conn: String, now_ms: i64) -> MeshEngineOutput {
        engine_output(self.lock().on_dial_deadline(&conn, ms(now_ms)))
    }

    pub fn on_instances_discovered(
        &self,
        conn: String,
        instances: Vec<i32>,
        now_ms: i64,
    ) -> MeshEngineOutput {
        engine_output(
            self.lock()
                .on_instances_discovered(&conn, &instances, ms(now_ms)),
        )
    }

    pub fn on_subscribe_result(
        &self,
        conn: String,
        instance: i32,
        subscribed: bool,
        now_ms: i64,
    ) -> MeshEngineOutput {
        engine_output(
            self.lock()
                .on_subscribe_result(&conn, instance, subscribed, ms(now_ms)),
        )
    }

    pub fn on_client_rx(
        &self,
        conn: String,
        instance: i32,
        bytes: Vec<u8>,
        now_ms: i64,
    ) -> MeshEngineOutput {
        engine_output(
            self.lock()
                .on_client_rx(&conn, instance, &bytes, ms(now_ms)),
        )
    }

    pub fn on_server_connected(&self, conn: String, now_ms: i64) -> MeshEngineOutput {
        engine_output(self.lock().on_server_connected(&conn, ms(now_ms)))
    }

    pub fn on_server_disconnected(&self, conn: String) -> MeshEngineOutput {
        engine_output(self.lock().on_server_disconnected(&conn))
    }

    pub fn on_server_subscribed(&self, conn: String, now_ms: i64) -> MeshEngineOutput {
        engine_output(self.lock().on_server_subscribed(&conn, ms(now_ms)))
    }

    pub fn on_server_rx(&self, conn: String, bytes: Vec<u8>, now_ms: i64) -> MeshEngineOutput {
        engine_output(self.lock().on_server_rx(&conn, &bytes, ms(now_ms)))
    }

    pub fn on_tick(&self, now_ms: i64) -> MeshEngineOutput {
        engine_output(self.lock().on_tick(ms(now_ms)))
    }

    /// Sync the wall clock: wire timestamps are wall-clock ms while every
    /// deadline uses the monotonic `now_ms`. Call at start and on each tick.
    pub fn set_wall_clock(&self, now_ms: i64, wall_ms: i64) {
        self.lock().set_wall_clock(ms(now_ms), ms(wall_ms));
    }

    /// None = the peer is rejected by the known-only policy. Queues when no
    /// live route exists (flushed on the next establish).
    pub fn send_text(
        &self,
        fingerprint: String,
        message_id: String,
        text: String,
        now_ms: i64,
    ) -> Option<MeshEngineOutput> {
        self.lock()
            .send_text(&fingerprint, &message_id, &text, ms(now_ms))
            .map(engine_output)
    }

    /// Same as [`Self::send_text`], with an optional parent message id (TLV 0x04).
    pub fn send_text_with_reply(
        &self,
        fingerprint: String,
        message_id: String,
        text: String,
        reply_to: Option<String>,
        now_ms: i64,
    ) -> Option<MeshEngineOutput> {
        let reply = reply_to
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());
        self.lock()
            .send_text_with_reply(&fingerprint, &message_id, &text, reply, ms(now_ms))
            .map(engine_output)
    }

    /// None = no live route right now (never queues).
    pub fn send_text_now(
        &self,
        fingerprint: String,
        message_id: String,
        text: String,
        now_ms: i64,
    ) -> Option<MeshEngineOutput> {
        self.lock()
            .send_text_now(&fingerprint, &message_id, &text, ms(now_ms))
            .map(engine_output)
    }

    /// None = no live route / oversized (never queues).
    pub fn send_file(
        &self,
        fingerprint: String,
        message_id: String,
        content: Vec<u8>,
        file_name: String,
        mime_type: String,
        now_ms: i64,
    ) -> Option<MeshEngineOutput> {
        self.lock()
            .send_file(
                &fingerprint,
                &message_id,
                &content,
                &file_name,
                &mime_type,
                ms(now_ms),
            )
            .map(engine_output)
    }

    pub fn send_delivery_ack(
        &self,
        fingerprint: String,
        message_id: String,
        now_ms: i64,
    ) -> Option<MeshEngineOutput> {
        self.lock()
            .send_delivery_ack(&fingerprint, &message_id, ms(now_ms))
            .map(engine_output)
    }

    /// None = nothing connected.
    pub fn broadcast(&self, text: String, now_ms: i64) -> Option<MeshEngineOutput> {
        self.lock().broadcast(&text, ms(now_ms)).map(engine_output)
    }

    pub fn set_nickname(&self, nickname: String, now_ms: i64) -> MeshEngineOutput {
        engine_output(self.lock().set_nickname(&nickname, ms(now_ms)))
    }

    pub fn set_sonar_payload(&self, payload: Option<Vec<u8>>, now_ms: i64) -> MeshEngineOutput {
        engine_output(self.lock().set_sonar_payload(payload, ms(now_ms)))
    }

    pub fn set_allowlist(&self, allowed: Option<Vec<String>>) -> MeshEngineOutput {
        engine_output(self.lock().set_allowlist(allowed))
    }

    pub fn reset(&self) {
        self.lock().reset();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn local_test_node(relay_urls: Vec<String>) -> Arc<SonarNode> {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir
            .path()
            .join("marmot.sqlite")
            .to_string_lossy()
            .into_owned();
        // Leak the tempdir guard so the store outlives this helper for the
        // duration of the test process.
        std::mem::forget(dir);
        SonarNode::connect(
            SonarIdentity::generate(),
            relay_urls,
            db_path,
            "ab".repeat(32),
            None,
        )
        .expect("local node connects")
    }

    /// 0xdead10cc round 3 (TestFlight 1.12.2 build 30): the iOS store close
    /// queues on a serial dispatch queue BEHIND blocking relay FFI, so an
    /// interrupted node must fail relay calls fast instead of parking for the
    /// full relay wait. Pins the fail-fast half of the contract.
    #[test]
    fn interrupted_node_fails_sync_fast_instead_of_parking() {
        let node = local_test_node(vec![]);
        node.interrupt_for_suspend();
        let started = std::time::Instant::now();

        // Every entry point the host can have parked on its serial work queue
        // when the app backgrounds. `ensure_subscriptions` is the idle-timeout
        // path and was missed by the first cut of this fix — it awaits
        // subscription setup plus a bounded repair fetch, which is long enough
        // on its own to push the store close past the suspension deadline.
        let registration_npub = SonarIdentity::generate().npub();
        let calls: Vec<(&str, Box<dyn Fn() -> FfiResult<()> + '_>)> = vec![
            ("sync_once", Box::new(|| node.sync_once())),
            ("sync_force", Box::new(|| node.sync_force())),
            (
                "ensure_subscriptions",
                Box::new(|| node.ensure_subscriptions()),
            ),
            ("retry_outbox", Box::new(|| node.retry_outbox())),
            (
                "publish_key_package_background",
                Box::new(|| node.publish_key_package_background()),
            ),
            (
                "publish_sonar_descriptor",
                Box::new(|| node.publish_sonar_descriptor(false, vec![], None)),
            ),
            (
                "register_push_token",
                Box::new(|| {
                    node.register_push_token(
                        "apns".into(),
                        vec![0u8; 32],
                        registration_npub.clone(),
                    )
                }),
            ),
        ];

        for (name, call) in &calls {
            let err = call()
                .err()
                .unwrap_or_else(|| panic!("{name} must fail when interrupted"));
            assert!(
                err.to_string().contains(SUSPEND_INTERRUPT_MARKER),
                "{name}: unexpected error: {err}"
            );
        }
        assert!(
            started.elapsed() < std::time::Duration::from_secs(5),
            "interrupted relay calls must not park ({}s)",
            started.elapsed().as_secs()
        );
    }

    /// 0xdead10cc round 6 (TestFlight 1.12.3 build 31, R-031): the calls above
    /// also run *inside* `SonarClient::connect`, where there is no node yet to
    /// interrupt. A latch the host created BEFORE the connect must abort it —
    /// and when the latch is already set, must do so without ever opening
    /// SQLCipher, since an unopened store is one the close has nothing to wait
    /// for.
    #[test]
    fn prelatched_connect_aborts_without_opening_the_store() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir
            .path()
            .join("marmot.sqlite")
            .to_string_lossy()
            .into_owned();
        let latch = SonarSuspendLatch::new();
        latch.interrupt();
        assert!(latch.is_interrupted());

        let started = std::time::Instant::now();
        let err = SonarNode::connect(
            SonarIdentity::generate(),
            vec!["wss://relay.example".into()],
            db_path.clone(),
            "ab".repeat(32),
            Some(latch),
        )
        .err()
        .expect("a latched connect must not produce a node");
        assert!(
            err.to_string().contains(SUSPEND_INTERRUPT_MARKER),
            "unexpected error: {err}"
        );
        assert!(
            started.elapsed() < std::time::Duration::from_secs(5),
            "latched connect must not park ({}s)",
            started.elapsed().as_secs()
        );
        // The store file is the whole point: RunningBoard kills us for holding
        // an *open* protected file, so a connect that loses the race must leave
        // nothing behind for the close to release.
        assert!(
            !std::path::Path::new(&db_path).exists(),
            "latched connect must not have opened SQLCipher"
        );
    }

    /// The in-flight half of R-031: a connect that has already opened the store
    /// and is parked awaiting relays must abort when the host latches, rather
    /// than run to the end of its quorum wait. Uses an unroutable relay so the
    /// connect is genuinely parked in the network wait when the latch fires.
    #[test]
    fn latch_aborts_in_flight_connect() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir
            .path()
            .join("marmot.sqlite")
            .to_string_lossy()
            .into_owned();
        let latch = SonarSuspendLatch::new();
        let connecting = {
            let latch = latch.clone();
            std::thread::spawn(move || {
                let started = std::time::Instant::now();
                let result = SonarNode::connect(
                    SonarIdentity::generate(),
                    vec!["wss://192.0.2.1:4443".into()],
                    db_path,
                    "ab".repeat(32),
                    Some(latch),
                );
                (result, started.elapsed())
            })
        };
        std::thread::sleep(std::time::Duration::from_millis(300));
        latch.interrupt();
        let (result, elapsed) = connecting.join().expect("connect thread joins");
        let err = result
            .err()
            .expect("interrupted connect must not produce a node");
        assert!(
            err.to_string().contains(SUSPEND_INTERRUPT_MARKER),
            "unexpected error: {err}"
        );
        assert!(
            elapsed < std::time::Duration::from_secs(5),
            "in-flight connect must abort on latch ({}s)",
            elapsed.as_secs()
        );
    }

    /// Pins the in-flight half: a call already parked inside
    /// `block_on_suspendable` must return promptly when
    /// `interrupt_for_suspend()` fires — not when its relay wait would have
    /// timed out. The future never completes, so only the interrupt can end
    /// this call.
    #[test]
    fn interrupt_aborts_in_flight_suspendable_wait() {
        let node = local_test_node(vec![]);
        let parked = {
            let node = node.clone();
            std::thread::spawn(move || {
                let started = std::time::Instant::now();
                let result = node.block_on_suspendable::<()>("test_wait", std::future::pending());
                (result, started.elapsed())
            })
        };
        std::thread::sleep(std::time::Duration::from_millis(300));
        node.interrupt_for_suspend();
        let (result, elapsed) = parked.join().expect("parked thread joins");
        let err = result.expect_err("interrupted in-flight wait must fail");
        assert!(
            err.to_string().contains(SUSPEND_INTERRUPT_MARKER),
            "unexpected error: {err}"
        );
        assert!(
            elapsed < std::time::Duration::from_secs(5),
            "in-flight wait must abort on interrupt ({}s)",
            elapsed.as_secs()
        );
    }

    #[test]
    fn mesh_announce_requires_sender_derived_from_noise_key() {
        let seed_hex = "11".repeat(32);
        let noise_public_key = vec![0x22; 32];
        let valid_sender = mesh::peer_id_from_noise_key(&noise_public_key);
        let valid = mesh_build_announce(
            seed_hex.clone(),
            valid_sender,
            "alice".into(),
            hex::encode(&noise_public_key),
            7,
            123,
        )
        .expect("announce builds");
        assert!(mesh_parse_announce(valid).is_some());

        let forged = mesh_build_announce(
            seed_hex,
            "0000000000000000".into(),
            "mallory".into(),
            hex::encode(noise_public_key),
            7,
            123,
        )
        .expect("self-signed forged announce builds");
        assert!(mesh_parse_announce(forged).is_none());
    }

    #[test]
    fn verified_sonar_announce_rejects_forgery_and_accepts_relayed_ttl() {
        let seed_hex = "33".repeat(32);
        let signing_public_key = mesh_signing_public_key(seed_hex.clone()).expect("public key");
        let payload = b"npub profile".to_vec();
        let packet = mesh_build_signed_packet(
            seed_hex,
            mesh::msg_type::SONAR_ANNOUNCE,
            "0102030405060708".into(),
            String::new(),
            7,
            456,
            payload.clone(),
        )
        .expect("signed Sonar announce builds");

        assert_eq!(
            mesh_parse_verified_sonar_announce(packet.clone(), signing_public_key.clone()),
            Some(payload)
        );

        let mut relayed = packet.clone();
        relayed[2] = 6;
        assert!(mesh_parse_verified_sonar_announce(relayed, signing_public_key.clone()).is_some());

        let wrong_key = mesh_signing_public_key("44".repeat(32)).expect("other public key");
        assert!(mesh_parse_verified_sonar_announce(packet.clone(), wrong_key).is_none());

        let mut decoded = mesh::Packet::decode(&packet).expect("packet decodes");
        decoded.payload[0] ^= 0x01;
        let tampered = decoded.encode().expect("tampered packet encodes");
        assert!(mesh_parse_verified_sonar_announce(tampered, signing_public_key.clone()).is_none());

        let unsigned = mesh_build_packet(
            mesh::msg_type::SONAR_ANNOUNCE,
            "0102030405060708".into(),
            String::new(),
            7,
            456,
            b"unsigned".to_vec(),
        )
        .expect("unsigned packet builds");
        assert!(mesh_parse_verified_sonar_announce(unsigned, signing_public_key).is_none());
    }

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
                key.clone(),
                None
            ),
            Err(SonarFfiError::InvalidInput(_))
        ));
        // bad db key (wrong length)
        assert!(matches!(
            SonarNode::connect(
                id.clone(),
                vec!["wss://relay.example".into()],
                db.clone(),
                "abcd".into(),
                None
            ),
            Err(SonarFfiError::InvalidInput(_))
        ));
        // empty db path
        assert!(matches!(
            SonarNode::connect(
                id,
                vec!["wss://relay.example".into()],
                String::new(),
                key,
                None
            ),
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
        let node = SonarNode::connect(id, vec![], db.clone(), key, None).unwrap();
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
        let pack = "30031:abc123:mypack".to_string();
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
