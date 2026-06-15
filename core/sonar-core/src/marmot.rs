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

use mdk_core::prelude::*;
use mdk_memory_storage::MdkMemoryStorage;
use mdk_sqlite_storage::{EncryptionConfig, MdkSqliteStorage};
use nostr::prelude::*;

use crate::identity::Identity;
use crate::{Error, Result};

/// Kind used for the inner chat rumor inside a 445 (matches White Noise / the
/// MDK examples: NIP-C7-style chat message).
pub const CHAT_RUMOR_KIND: u16 = 9;

/// Marmot KeyPackage event kind (MIP-00). nostr 0.44 has no named constant
/// for the modern addressable kind (Kind::MlsKeyPackage is the legacy 443).
pub const KEY_PACKAGE_KIND: u16 = 30443;

/// Result of creating a group: the group plus the welcome rumors that must be
/// gift-wrapped and delivered to each invited member.
pub struct GroupCreation {
    pub group: group_types::Group,
    /// `(member pubkey, kind-444 rumor)` pairs, one per invited member.
    pub welcomes: Vec<(PublicKey, UnsignedEvent)>,
}

/// A decrypted application message, mapped to a small FFI-friendly shape.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatMessage {
    pub id: EventId,
    pub group_id: GroupId,
    pub sender: PublicKey,
    pub content: String,
    pub created_at: Timestamp,
    /// True when `sender` is the local identity.
    pub mine: bool,
}

/// What came out of processing an incoming event.
#[derive(Debug)]
pub enum Incoming {
    /// A decrypted chat message (already persisted in MDK storage).
    Message(ChatMessage),
    /// A group-membership/welcome change was applied; no chat content.
    GroupUpdated(GroupId),
    /// The event was valid but produced nothing actionable (duplicates,
    /// proposals pending, unprocessable epochs, ...).
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
    pub fn persistent(identity: Identity, db_path: impl AsRef<Path>, key: [u8; 32]) -> Result<Self> {
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
                    .map_err(|e2| Error::Storage(format!(
                        "recreate after unusable DB failed: {e2} (original: {detail})"
                    )))?;
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
    /// Removes `db_path` plus the SQLite `-wal`, `-shm`, and `-journal` sidecars;
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
    /// NOTE: per MDK rules the creator's commit is merged immediately here —
    /// acceptable for M1 because the caller publishes the welcomes right after;
    /// once we have real delivery-failure handling this moves to
    /// "merge after publish confirmed".
    pub fn create_group(
        &self,
        name: &str,
        member_key_packages: Vec<Event>,
        relays: Vec<RelayUrl>,
    ) -> Result<GroupCreation> {
        let mut admins: Vec<PublicKey> = member_key_packages.iter().map(|e| e.pubkey).collect();
        admins.push(self.identity.public_key());
        let member_pubkeys: Vec<PublicKey> =
            member_key_packages.iter().map(|e| e.pubkey).collect();

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
        dispatch!(&self.storage, |mdk| mdk
            .merge_pending_commit(&result.group.mls_group_id))?;

        let welcomes = member_pubkeys
            .into_iter()
            .zip(result.welcome_rumors)
            .collect();
        Ok(GroupCreation {
            group: result.group,
            welcomes,
        })
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
        let event = dispatch!(&self.storage, |mdk| mdk.create_message(group_id, rumor, None))?;
        Ok(event)
    }

    /// Process any incoming Marmot-relevant event:
    /// - kind 1059 gift wrap → unwrap; if it holds a kind-444 welcome,
    ///   process and auto-accept it (M1 policy; invite UX comes with the shells).
    /// - kind 445 group message → decrypt/apply.
    pub async fn process_incoming(&self, event: &Event) -> Result<Incoming> {
        match event.kind {
            Kind::GiftWrap => {
                let unwrapped =
                    UnwrappedGift::from_gift_wrap(self.identity.keys(), event).await?;
                if unwrapped.rumor.kind != Kind::MlsWelcome {
                    return Ok(Incoming::None);
                }
                let welcome =
                    dispatch!(&self.storage, |mdk| mdk.process_welcome(&event.id, &unwrapped.rumor))?;
                dispatch!(&self.storage, |mdk| mdk.accept_welcome(&welcome))?;
                Ok(Incoming::GroupUpdated(welcome.mls_group_id))
            }
            Kind::MlsGroupMessage => match dispatch!(&self.storage, |mdk| mdk.process_message(event))? {
                MessageProcessingResult::ApplicationMessage(msg) => {
                    Ok(Incoming::Message(self.to_chat_message(msg)))
                }
                MessageProcessingResult::Commit { mls_group_id }
                | MessageProcessingResult::PendingProposal { mls_group_id } => {
                    Ok(Incoming::GroupUpdated(mls_group_id))
                }
                MessageProcessingResult::Proposal(update) => {
                    // Auto-committed proposal (e.g. a member leaving): the
                    // caller must publish `evolution_event`; surfacing it is
                    // M1-deferred — log and report the group as updated.
                    tracing::warn!(
                        group = ?update.mls_group_id,
                        "auto-committed proposal; evolution event publication not yet wired"
                    );
                    Ok(Incoming::GroupUpdated(update.mls_group_id))
                }
                _ => Ok(Incoming::None),
            },
            _ => Ok(Incoming::None),
        }
    }

    /// All groups this identity belongs to.
    pub fn groups(&self) -> Result<Vec<group_types::Group>> {
        Ok(dispatch!(&self.storage, |mdk| mdk.get_groups())?)
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

    /// Members of a group.
    pub fn members(&self, group_id: &GroupId) -> Result<Vec<PublicKey>> {
        Ok(dispatch!(&self.storage, |mdk| mdk.get_members(group_id))?
            .into_iter()
            .collect())
    }

    fn to_chat_message(&self, m: message_types::Message) -> ChatMessage {
        ChatMessage {
            id: m.id,
            group_id: m.mls_group_id.clone(),
            sender: m.pubkey,
            content: m.content.clone(),
            created_at: m.created_at,
            mine: m.pubkey == self.identity.public_key(),
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
    let name = base.file_name().and_then(|n| n.to_str()).unwrap_or_default();
    ["", "-wal", "-shm", "-journal"]
        .iter()
        .map(|suffix| base.with_file_name(format!("{name}{suffix}")))
        .collect()
}
