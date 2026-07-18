//! Encrypted durable journal for outgoing content that does not have an MLS
//! group yet.
//!
//! The normal relay outbox can persist only after Marmot has encrypted a local
//! message for an existing group. Hosts still need somewhere safe to put a
//! user send while a direct/group route is being created. This journal stores
//! that small, bounded pre-route window encrypted with a key derived from the
//! SQLCipher database key. Hosts own route interpretation and remove an entry
//! only after the normal core send has accepted it into local storage.

use std::collections::HashMap;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::{Error, Result};

pub(crate) const PRE_ROUTE_OUTBOX_FILE_SUFFIX: &str = ".sonar-pre-route-outbox";
pub(crate) const GROUP_OPERATION_ROUTE_KIND: &str = "group-operation";
const FILE_MAGIC: &[u8; 8] = b"SNPROBX1";
const FILE_AAD: &[u8] = b"sonar-pre-route-outbox-v1";
const HKDF_SALT: &[u8] = b"sonar-pre-route-outbox-salt-v1";
const HKDF_INFO: &[u8] = b"sonar-pre-route-outbox-key-v1";
const NONCE_LEN: usize = 12;
const MAX_ENTRIES: usize = 500;
const MAX_ENTRIES_PER_ROUTE: usize = 100;
const MAX_FIELD_BYTES: usize = 16 * 1024;
const MAX_CONTENT_BYTES: usize = 64 * 1024;
const MAX_PLAINTEXT_BYTES: usize = 8 * 1024 * 1024;
const MAX_PENDING_GROUP_CREATIONS: usize = 32;
const MAX_WELCOMES_PER_GROUP: usize = 500;
const MAX_WELCOME_EVENT_BYTES: usize = 512 * 1024;
const MAX_PENDING_GROUP_RECOVERY_BYTES: usize = 4 * 1024 * 1024;

static SHARED_OUTBOXES: OnceLock<Mutex<HashMap<PathBuf, Weak<Mutex<PreRouteOutbox>>>>> =
    OnceLock::new();

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PreRouteMessage {
    pub id: String,
    pub route_kind: String,
    pub route_id: String,
    /// Opaque, host-defined JSON. The encrypted journal never interprets it.
    pub route_context: String,
    pub content: String,
    pub created_at_secs: u64,
}

/// Replay material for an idempotent group operation whose signed Welcomes may
/// not all have reached a relay yet. Every ready Welcome is already
/// gift-wrapped, so the journal contains no plaintext group content and
/// retrying the same signed events is relay-idempotent by event id.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(crate) struct PendingGroupCreation {
    /// The hashed operation marker stored in the group description.
    pub operation_description: String,
    /// Absent until MDK has created the group and every Welcome is wrapped.
    /// This intent-only checkpoint proves that a group found with this marker
    /// crashed before publication began and is therefore safe to recreate.
    pub group_id_hex: Option<String>,
    pub welcome_event_jsons: Vec<String>,
    /// Durable cancellation intent. Written before local MLS deletion so a
    /// restart finishes cleanup instead of replaying a cancelled operation.
    #[serde(default)]
    pub cancelled: bool,
}

#[derive(Debug, Deserialize, Serialize)]
struct PreRouteStateDisk {
    version: u32,
    entries: Vec<PreRouteMessage>,
    #[serde(default)]
    pending_group_creations: Vec<PendingGroupCreation>,
}

#[derive(Debug)]
pub(crate) struct PreRouteOutbox {
    path: Option<PathBuf>,
    key: Option<[u8; 32]>,
    entries: Vec<PreRouteMessage>,
    pending_group_creations: Vec<PendingGroupCreation>,
}

impl PreRouteOutbox {
    pub fn open(path: Option<PathBuf>, db_key: Option<[u8; 32]>) -> Result<Self> {
        let key = db_key.map(derive_key).transpose()?;
        let state = match (&path, &key) {
            (Some(path), Some(key)) if path.exists() => decrypt_state(path, key)?,
            _ => PreRouteStateDisk {
                version: 1,
                entries: Vec::new(),
                pending_group_creations: Vec::new(),
            },
        };
        Ok(Self {
            path,
            key,
            entries: state.entries,
            pending_group_creations: state.pending_group_creations,
        })
    }

    pub fn messages(&self) -> Vec<PreRouteMessage> {
        self.entries.clone()
    }

    pub fn pending_group_creation(
        &self,
        operation_description: &str,
    ) -> Option<PendingGroupCreation> {
        self.pending_group_creations
            .iter()
            .find(|entry| entry.operation_description == operation_description)
            .cloned()
    }

    /// Checkpoint all signed Welcome events before the first relay publish.
    /// If this write fails the caller can safely discard the staged MLS group,
    /// because no recipient could have observed it yet.
    pub fn save_pending_group_creation(&mut self, creation: PendingGroupCreation) -> Result<()> {
        validate_pending_group_creation(&creation)?;
        if let Some(index) = self
            .pending_group_creations
            .iter()
            .position(|entry| entry.operation_description == creation.operation_description)
        {
            if self.pending_group_creations[index] == creation {
                return Ok(());
            }
            if self.pending_group_creations[index].group_id_hex.is_none()
                && creation.group_id_hex.is_some()
            {
                let previous =
                    std::mem::replace(&mut self.pending_group_creations[index], creation);
                if let Err(error) = self.save() {
                    self.pending_group_creations[index] = previous;
                    return Err(error);
                }
                return Ok(());
            }
            return Err(Error::InvalidInput(
                "group operation already has different recovery state".into(),
            ));
        }
        if self.pending_group_creations.len() >= MAX_PENDING_GROUP_CREATIONS {
            return Err(Error::InvalidInput(
                "pending group creation recovery journal is full".into(),
            ));
        }

        self.pending_group_creations.push(creation);
        if let Err(error) = self.save() {
            self.pending_group_creations.pop();
            return Err(error);
        }
        Ok(())
    }

    pub fn complete_pending_group_creation(&mut self, operation_description: &str) -> Result<()> {
        let Some(index) = self
            .pending_group_creations
            .iter()
            .position(|entry| entry.operation_description == operation_description)
        else {
            return Ok(());
        };
        let removed = self.pending_group_creations.remove(index);
        if let Err(error) = self.save() {
            self.pending_group_creations.insert(index, removed);
            return Err(error);
        }
        Ok(())
    }

    /// Persist cancellation before deleting local MLS state. This marker stays
    /// beside the operation sentinel until final cleanup removes both in one
    /// encrypted manifest replacement.
    pub fn mark_pending_group_operation_cancelled(
        &mut self,
        operation_description: &str,
    ) -> Result<()> {
        let marker = PendingGroupCreation {
            operation_description: operation_description.to_string(),
            group_id_hex: None,
            welcome_event_jsons: Vec::new(),
            cancelled: true,
        };
        validate_pending_group_creation(&marker)?;
        if let Some(index) = self
            .pending_group_creations
            .iter()
            .position(|entry| entry.operation_description == operation_description)
        {
            if self.pending_group_creations[index].cancelled {
                return Ok(());
            }
            self.pending_group_creations[index].cancelled = true;
            if let Err(error) = self.save() {
                self.pending_group_creations[index].cancelled = false;
                return Err(error);
            }
            return Ok(());
        }
        if self.pending_group_creations.len() >= MAX_PENDING_GROUP_CREATIONS {
            return Err(Error::InvalidInput(
                "pending group creation recovery journal is full".into(),
            ));
        }
        self.pending_group_creations.push(marker);
        if let Err(error) = self.save() {
            self.pending_group_creations.pop();
            return Err(error);
        }
        Ok(())
    }

    /// Explicitly cancel a host group operation. The operation sentinel and
    /// internal Welcome checkpoint are removed in one encrypted manifest
    /// replacement so restart cannot resurrect or leak the cancelled work.
    pub fn discard_pending_group_operation(
        &mut self,
        operation_id: &str,
        operation_description: &str,
    ) -> Result<()> {
        let previous_entries = self.entries.clone();
        let previous_group_creations = self.pending_group_creations.clone();
        self.entries.retain(|entry| {
            entry.route_kind != GROUP_OPERATION_ROUTE_KIND || entry.route_id != operation_id
        });
        self.pending_group_creations
            .retain(|entry| entry.operation_description != operation_description);
        if self.entries == previous_entries
            && self.pending_group_creations == previous_group_creations
        {
            return Ok(());
        }
        if let Err(error) = self.save() {
            self.entries = previous_entries;
            self.pending_group_creations = previous_group_creations;
            return Err(error);
        }
        Ok(())
    }

    pub fn enqueue(&mut self, message: PreRouteMessage) -> Result<()> {
        validate_message(&message)?;
        if let Some(existing) = self.entries.iter().find(|entry| entry.id == message.id) {
            return if existing == &message {
                Ok(())
            } else {
                Err(Error::InvalidInput(
                    "pre-route message id already exists with different content".into(),
                ))
            };
        }
        let route_entries = self
            .entries
            .iter()
            .enumerate()
            .filter(|entry| {
                entry.1.route_kind == message.route_kind && entry.1.route_id == message.route_id
            });
        let route_depth = route_entries.clone().count();
        // Hosts mirror the same per-route FIFO. Evict the oldest journal row
        // atomically with the replacement so their post-enqueue in-memory
        // eviction cannot be blocked by the durable cap first.
        let evicted = if route_depth >= MAX_ENTRIES_PER_ROUTE {
            let index = route_entries
                .map(|(index, _)| index)
                .next()
                .expect("a full route has an oldest entry");
            Some((index, self.entries.remove(index)))
        } else {
            None
        };
        if self.entries.len() >= MAX_ENTRIES {
            if let Some((index, evicted)) = evicted {
                self.entries.insert(index, evicted);
            }
            return Err(Error::InvalidInput("pre-route outbox is full".into()));
        }

        self.entries.push(message);
        if let Err(error) = self.save() {
            self.entries.pop();
            if let Some((index, evicted)) = evicted {
                self.entries.insert(index, evicted);
            }
            return Err(error);
        }
        Ok(())
    }

    pub fn remove(&mut self, id: &str) -> Result<()> {
        let Some(index) = self.entries.iter().position(|entry| entry.id == id) else {
            return Ok(());
        };
        let removed = self.entries.remove(index);
        if let Err(error) = self.save() {
            self.entries.insert(index, removed);
            return Err(error);
        }
        Ok(())
    }

    /// Checkpoint the concrete MLS group selected for an entry. Hosts call
    /// this after route creation and before handing the content to the normal
    /// send path. A restart can then replay directly into the same group
    /// instead of creating a duplicate group.
    pub fn resolve_route(&mut self, id: &str, route_id: &str) -> Result<()> {
        if route_id.trim().is_empty() || route_id.len() > MAX_FIELD_BYTES {
            return Err(Error::InvalidInput(
                "resolved pre-route group id is invalid".into(),
            ));
        }
        let Some(index) = self.entries.iter().position(|entry| entry.id == id) else {
            return Err(Error::InvalidInput(
                "pre-route message does not exist".into(),
            ));
        };
        if self.entries[index].route_kind == "marmot-group"
            && self.entries[index].route_id == route_id
        {
            return Ok(());
        }
        if self.entries[index].route_kind == "marmot-group" {
            return Err(Error::InvalidInput(
                "pre-route message is already resolved to another group".into(),
            ));
        }
        let route_depth = self
            .entries
            .iter()
            .enumerate()
            .filter(|(entry_index, entry)| {
                *entry_index != index
                    && entry.route_kind == "marmot-group"
                    && entry.route_id == route_id
            })
            .count();
        if route_depth >= MAX_ENTRIES_PER_ROUTE {
            return Err(Error::InvalidInput(
                "resolved pre-route outbox route is full".into(),
            ));
        }

        let previous_kind = std::mem::replace(
            &mut self.entries[index].route_kind,
            "marmot-group".to_string(),
        );
        let previous_id =
            std::mem::replace(&mut self.entries[index].route_id, route_id.to_string());
        if let Err(error) = self.save() {
            self.entries[index].route_kind = previous_kind;
            self.entries[index].route_id = previous_id;
            return Err(error);
        }
        Ok(())
    }

    pub fn clear(&mut self) -> Result<()> {
        let previous = std::mem::take(&mut self.entries);
        let previous_group_creations = std::mem::take(&mut self.pending_group_creations);
        if let Err(error) = self.save() {
            self.entries = previous;
            self.pending_group_creations = previous_group_creations;
            return Err(error);
        }
        Ok(())
    }

    fn save(&self) -> Result<()> {
        let (Some(path), Some(key)) = (&self.path, &self.key) else {
            return Ok(());
        };
        if self.entries.is_empty() && self.pending_group_creations.is_empty() {
            match fs::remove_file(path) {
                Ok(()) => sync_parent(path),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(Error::Storage(format!(
                    "remove pre-route outbox {}: {error}",
                    path.display()
                ))),
            }?;
            return Ok(());
        }

        let parent = path.parent().ok_or_else(|| {
            Error::Storage("pre-route outbox path has no parent directory".into())
        })?;
        fs::create_dir_all(parent).map_err(|error| {
            Error::Storage(format!(
                "create pre-route outbox directory {}: {error}",
                parent.display()
            ))
        })?;
        validate_pending_group_recovery_bytes(&self.pending_group_creations)?;
        let state = PreRouteStateDisk {
            version: 1,
            entries: self.entries.clone(),
            pending_group_creations: self.pending_group_creations.clone(),
        };
        let plaintext = serde_json::to_vec(&state)?;
        if plaintext.len() > MAX_PLAINTEXT_BYTES {
            return Err(Error::InvalidInput(
                "pre-route outbox exceeds storage cap".into(),
            ));
        }
        let mut nonce = [0u8; NONCE_LEN];
        getrandom::getrandom(&mut nonce)
            .map_err(|error| Error::Storage(format!("generate pre-route nonce: {error}")))?;
        let cipher = ChaCha20Poly1305::new_from_slice(key)
            .map_err(|error| Error::Storage(format!("create pre-route cipher: {error}")))?;
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: &plaintext,
                    aad: FILE_AAD,
                },
            )
            .map_err(|_| Error::Storage("encrypt pre-route outbox".into()))?;

        let tmp = tmp_path(path);
        let mut options = fs::OpenOptions::new();
        options.create(true).truncate(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&tmp).map_err(|error| {
            Error::Storage(format!("open pre-route outbox {}: {error}", tmp.display()))
        })?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o600))
                .map_err(|error| {
                    Error::Storage(format!(
                        "secure pre-route outbox {}: {error}",
                        tmp.display()
                    ))
                })?;
        }
        file.write_all(FILE_MAGIC)
            .and_then(|_| file.write_all(&nonce))
            .and_then(|_| file.write_all(&ciphertext))
            .and_then(|_| file.sync_all())
            .map_err(|error| {
                Error::Storage(format!("write pre-route outbox {}: {error}", tmp.display()))
            })?;
        atomic_replace_file(&tmp, path).map_err(|error| {
            Error::Storage(format!(
                "replace pre-route outbox {}: {error}",
                path.display()
            ))
        })?;
        sync_parent(path)
    }
}

pub(crate) fn pre_route_outbox_path_for_db(db_path: &Path) -> PathBuf {
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("marmot.sqlite");
    db_path.with_file_name(format!("{file_name}{PRE_ROUTE_OUTBOX_FILE_SUFFIX}"))
}

/// Return one process-wide journal instance for a durable path. Apple and
/// Compose can briefly overlap a local-only node with its relay-connected
/// replacement; sharing the same mutex prevents two stale snapshots from
/// independently rewriting the sidecar and losing each other's entries.
pub(crate) fn shared_pre_route_outbox(
    path: Option<PathBuf>,
    db_key: Option<[u8; 32]>,
) -> Result<Arc<Mutex<PreRouteOutbox>>> {
    let Some(path) = path else {
        return Ok(Arc::new(Mutex::new(PreRouteOutbox::open(None, db_key)?)));
    };
    let registry_key = registry_key(&path);
    let expected_key = db_key.map(derive_key).transpose()?;
    let registry = SHARED_OUTBOXES.get_or_init(|| Mutex::new(HashMap::new()));
    let mut registry = registry
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    registry.retain(|_, weak| weak.strong_count() > 0);
    if let Some(shared) = registry.get(&registry_key).and_then(Weak::upgrade) {
        let uses_expected_key = shared
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .key
            == expected_key;
        if !uses_expected_key {
            return Err(Error::Storage(
                "pre-route outbox path is already open with another key".into(),
            ));
        }
        return Ok(shared);
    }

    let shared = Arc::new(Mutex::new(PreRouteOutbox::open(Some(path), db_key)?));
    registry.insert(registry_key, Arc::downgrade(&shared));
    Ok(shared)
}

fn registry_key(path: &Path) -> PathBuf {
    if let Ok(canonical) = path.canonicalize() {
        return canonical;
    }
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|current| current.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    };
    let Some(parent) = absolute.parent() else {
        return absolute;
    };
    match parent.canonicalize() {
        Ok(parent) => absolute
            .file_name()
            .map(|name| parent.join(name))
            .unwrap_or(parent),
        Err(_) => absolute,
    }
}

fn validate_message(message: &PreRouteMessage) -> Result<()> {
    for (name, value) in [
        ("id", &message.id),
        ("route kind", &message.route_kind),
        ("route id", &message.route_id),
        ("route context", &message.route_context),
    ] {
        if value.trim().is_empty() && name != "route context" {
            return Err(Error::InvalidInput(format!("pre-route {name} is empty")));
        }
        if value.len() > MAX_FIELD_BYTES {
            return Err(Error::InvalidInput(format!(
                "pre-route {name} is too large"
            )));
        }
    }
    if message.content.len() > MAX_CONTENT_BYTES {
        return Err(Error::InvalidInput(
            "pre-route message content is too large".into(),
        ));
    }
    Ok(())
}

fn validate_pending_group_creation(creation: &PendingGroupCreation) -> Result<()> {
    if creation.operation_description.trim().is_empty()
        || creation.operation_description.len() > MAX_FIELD_BYTES
    {
        return Err(Error::InvalidInput(
            "pending group creation operation description is invalid".into(),
        ));
    }
    match &creation.group_id_hex {
        None if creation.welcome_event_jsons.is_empty() => return Ok(()),
        Some(group_id) if !group_id.trim().is_empty() && group_id.len() <= MAX_FIELD_BYTES => {}
        _ => {
            return Err(Error::InvalidInput(
                "pending group creation checkpoint is incomplete".into(),
            ))
        }
    }
    if creation.welcome_event_jsons.is_empty()
        || creation.welcome_event_jsons.len() > MAX_WELCOMES_PER_GROUP
    {
        return Err(Error::InvalidInput(
            "pending group creation welcome count is invalid".into(),
        ));
    }
    if creation
        .welcome_event_jsons
        .iter()
        .any(|event| event.len() > MAX_WELCOME_EVENT_BYTES)
    {
        return Err(Error::InvalidInput(
            "pending group creation Welcome is too large".into(),
        ));
    }
    Ok(())
}

fn validate_pending_group_recovery_bytes(creations: &[PendingGroupCreation]) -> Result<()> {
    let mut total = 0usize;
    for event in creations
        .iter()
        .flat_map(|creation| &creation.welcome_event_jsons)
    {
        total = total.checked_add(event.len()).ok_or_else(|| {
            Error::InvalidInput("pending group creation recovery material is too large".into())
        })?;
        if total > MAX_PENDING_GROUP_RECOVERY_BYTES {
            return Err(Error::InvalidInput(
                "pending group creation recovery material is too large".into(),
            ));
        }
    }
    Ok(())
}

fn derive_key(db_key: [u8; 32]) -> Result<[u8; 32]> {
    let hkdf = Hkdf::<Sha256>::new(Some(HKDF_SALT), &db_key);
    let mut key = [0u8; 32];
    hkdf.expand(HKDF_INFO, &mut key)
        .map_err(|error| Error::Storage(format!("derive pre-route outbox key: {error}")))?;
    Ok(key)
}

fn decrypt_state(path: &Path, key: &[u8; 32]) -> Result<PreRouteStateDisk> {
    let max_file_bytes = FILE_MAGIC.len() + NONCE_LEN + MAX_PLAINTEXT_BYTES + 16;
    let file_len = fs::metadata(path)
        .map_err(|error| {
            Error::Storage(format!(
                "inspect pre-route outbox {}: {error}",
                path.display()
            ))
        })?
        .len();
    if file_len > max_file_bytes as u64 {
        return Err(Error::Storage(
            "pre-route outbox exceeds storage cap".into(),
        ));
    }
    let bytes = fs::read(path).map_err(|error| {
        Error::Storage(format!("read pre-route outbox {}: {error}", path.display()))
    })?;
    if bytes.len() < FILE_MAGIC.len() + NONCE_LEN || &bytes[..FILE_MAGIC.len()] != FILE_MAGIC {
        return Err(Error::Storage("invalid pre-route outbox header".into()));
    }
    let nonce_start = FILE_MAGIC.len();
    let ciphertext_start = nonce_start + NONCE_LEN;
    let cipher = ChaCha20Poly1305::new_from_slice(key)
        .map_err(|error| Error::Storage(format!("create pre-route cipher: {error}")))?;
    let plaintext = cipher
        .decrypt(
            Nonce::from_slice(&bytes[nonce_start..ciphertext_start]),
            Payload {
                msg: &bytes[ciphertext_start..],
                aad: FILE_AAD,
            },
        )
        .map_err(|_| Error::Storage("authenticate pre-route outbox".into()))?;
    let state: PreRouteStateDisk = serde_json::from_slice(&plaintext)?;
    if state.version != 1 {
        return Err(Error::Storage(format!(
            "unsupported pre-route outbox version {}",
            state.version
        )));
    }
    validate_loaded_state(&state)?;
    Ok(state)
}

fn validate_loaded_state(state: &PreRouteStateDisk) -> Result<()> {
    use std::collections::{HashMap, HashSet};

    let entries = &state.entries;
    if entries.len() > MAX_ENTRIES {
        return Err(Error::Storage("pre-route outbox exceeds entry cap".into()));
    }
    let mut ids = HashSet::with_capacity(entries.len());
    let mut route_depths = HashMap::<(&str, &str), usize>::new();
    for entry in entries {
        validate_message(entry)?;
        if !ids.insert(entry.id.as_str()) {
            return Err(Error::Storage(
                "pre-route outbox contains duplicate message ids".into(),
            ));
        }
        let depth = route_depths
            .entry((entry.route_kind.as_str(), entry.route_id.as_str()))
            .or_default();
        *depth += 1;
        if *depth > MAX_ENTRIES_PER_ROUTE {
            return Err(Error::Storage(
                "pre-route outbox route exceeds entry cap".into(),
            ));
        }
    }
    if state.pending_group_creations.len() > MAX_PENDING_GROUP_CREATIONS {
        return Err(Error::Storage(
            "pending group creation recovery journal exceeds entry cap".into(),
        ));
    }
    let mut operations = HashSet::with_capacity(state.pending_group_creations.len());
    for creation in &state.pending_group_creations {
        validate_pending_group_creation(creation)?;
        if !operations.insert(creation.operation_description.as_str()) {
            return Err(Error::Storage(
                "pending group creation recovery journal contains duplicate operations".into(),
            ));
        }
    }
    validate_pending_group_recovery_bytes(&state.pending_group_creations)?;
    Ok(())
}

fn tmp_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-pre-route-outbox");
    path.with_file_name(format!("{file_name}.tmp"))
}

#[cfg(not(windows))]
fn atomic_replace_file(from: &Path, to: &Path) -> io::Result<()> {
    fs::rename(from, to)
}

#[cfg(windows)]
fn atomic_replace_file(from: &Path, to: &Path) -> io::Result<()> {
    use std::iter;
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let from = from
        .as_os_str()
        .encode_wide()
        .chain(iter::once(0))
        .collect::<Vec<_>>();
    let to = to
        .as_os_str()
        .encode_wide()
        .chain(iter::once(0))
        .collect::<Vec<_>>();
    let result = unsafe {
        MoveFileExW(
            from.as_ptr(),
            to.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(unix)]
fn sync_parent(path: &Path) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| Error::Storage("pre-route outbox path has no parent".into()))?;
    fs::File::open(parent)
        .and_then(|dir| dir.sync_all())
        .map_err(|error| {
            Error::Storage(format!(
                "sync pre-route outbox directory {}: {error}",
                parent.display()
            ))
        })
}

#[cfg(not(unix))]
fn sync_parent(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn message(id: &str) -> PreRouteMessage {
        PreRouteMessage {
            id: id.into(),
            route_kind: "direct-npub".into(),
            route_id: "npub1peer".into(),
            route_context: "{}".into(),
            content: "survive restart".into(),
            created_at_secs: 42,
        }
    }

    fn group_creation(operation: &str) -> PendingGroupCreation {
        PendingGroupCreation {
            operation_description: operation.into(),
            group_id_hex: Some("ab".repeat(32)),
            welcome_event_jsons: vec!["{\"id\":\"welcome\"}".into()],
            cancelled: false,
        }
    }

    #[test]
    fn encrypted_journal_survives_restart_and_removal() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("pre-route");
        let key = [7u8; 32];
        let mut outbox = PreRouteOutbox::open(Some(path.clone()), Some(key)).expect("open");
        outbox.enqueue(message("one")).expect("enqueue");

        let raw = fs::read(&path).expect("read raw");
        assert!(!String::from_utf8_lossy(&raw).contains("survive restart"));
        let mut reopened = PreRouteOutbox::open(Some(path.clone()), Some(key)).expect("reopen");
        assert_eq!(reopened.messages(), vec![message("one")]);

        reopened.remove("one").expect("remove");
        assert!(!path.exists());
    }

    #[test]
    fn encrypted_journal_replaces_existing_file_on_update() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("pre-route");
        let key = [7u8; 32];
        let mut outbox = PreRouteOutbox::open(Some(path.clone()), Some(key)).expect("open");
        outbox.enqueue(message("one")).expect("first save");
        outbox.enqueue(message("two")).expect("replacement save");
        drop(outbox);

        let reopened = PreRouteOutbox::open(Some(path), Some(key)).expect("reopen");
        assert_eq!(reopened.messages(), vec![message("one"), message("two")]);
    }

    #[test]
    fn enqueue_is_idempotent_but_rejects_id_reuse() {
        let mut outbox = PreRouteOutbox::open(None, None).expect("open");
        outbox.enqueue(message("one")).expect("enqueue");
        outbox.enqueue(message("one")).expect("idempotent enqueue");
        let mut changed = message("one");
        changed.content = "different".into();
        assert!(outbox.enqueue(changed).is_err());
        assert_eq!(outbox.messages().len(), 1);
    }

    #[test]
    fn enqueue_atomically_evicts_oldest_entry_at_route_capacity() {
        let mut outbox = PreRouteOutbox::open(None, None).expect("open");
        for index in 0..MAX_ENTRIES_PER_ROUTE {
            outbox
                .enqueue(message(&format!("message-{index}")))
                .expect("fill route");
        }

        outbox
            .enqueue(message("replacement"))
            .expect("replace oldest route entry");

        let messages = outbox.messages();
        assert_eq!(messages.len(), MAX_ENTRIES_PER_ROUTE);
        assert_eq!(messages.first().unwrap().id, "message-1");
        assert_eq!(messages.last().unwrap().id, "replacement");
        assert!(!messages.iter().any(|entry| entry.id == "message-0"));
    }

    #[test]
    fn resolved_route_survives_restart_and_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.enc");
        let key = [3u8; 32];
        let mut outbox = PreRouteOutbox::open(Some(path.clone()), Some(key)).unwrap();
        let mut pending = message("stable-id");
        pending.route_context = "context".into();
        pending.content = "hello".into();
        outbox.enqueue(pending).unwrap();
        outbox.resolve_route("stable-id", "group-123").unwrap();
        outbox.resolve_route("stable-id", "group-123").unwrap();
        drop(outbox);

        let restored = PreRouteOutbox::open(Some(path), Some(key)).unwrap();
        let entry = restored.messages().pop().unwrap();
        assert_eq!(entry.route_kind, "marmot-group");
        assert_eq!(entry.route_id, "group-123");
        assert_eq!(entry.content, "hello");
        assert_eq!(entry.route_context, "context");
    }

    #[test]
    fn resolved_route_cannot_be_changed_after_checkpoint() {
        let mut outbox = PreRouteOutbox::open(None, None).unwrap();
        outbox.enqueue(message("stable-id")).unwrap();
        outbox.resolve_route("stable-id", "group-123").unwrap();

        assert!(outbox.resolve_route("stable-id", "group-456").is_err());
        assert_eq!(outbox.messages()[0].route_id, "group-123");
    }

    #[test]
    fn pending_group_creation_recovery_survives_restart_and_clears_with_messages() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.enc");
        let key = [5u8; 32];
        let mut outbox = PreRouteOutbox::open(Some(path.clone()), Some(key)).unwrap();
        outbox
            .save_pending_group_creation(PendingGroupCreation {
                operation_description: "operation-hash".into(),
                group_id_hex: None,
                welcome_event_jsons: Vec::new(),
                cancelled: false,
            })
            .unwrap();
        outbox
            .save_pending_group_creation(group_creation("operation-hash"))
            .unwrap();
        drop(outbox);

        let mut restored = PreRouteOutbox::open(Some(path.clone()), Some(key)).unwrap();
        assert_eq!(
            restored.pending_group_creation("operation-hash"),
            Some(group_creation("operation-hash"))
        );
        restored.clear().unwrap();
        assert!(!path.exists());
    }

    #[test]
    fn pending_group_creation_rejects_aggregate_recovery_material_before_save() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.enc");
        let key = [5u8; 32];
        let mut outbox = PreRouteOutbox::open(Some(path.clone()), Some(key)).unwrap();
        let large_events = vec!["x".repeat(MAX_WELCOME_EVENT_BYTES); 5];
        let first = PendingGroupCreation {
            operation_description: "first-operation".into(),
            group_id_hex: Some("ab".repeat(32)),
            welcome_event_jsons: large_events.clone(),
            cancelled: false,
        };
        outbox.save_pending_group_creation(first.clone()).unwrap();
        let second = PendingGroupCreation {
            operation_description: "second-operation".into(),
            group_id_hex: Some("cd".repeat(32)),
            welcome_event_jsons: large_events,
            cancelled: false,
        };

        assert!(outbox.save_pending_group_creation(second).is_err());
        assert_eq!(
            outbox.pending_group_creation("first-operation"),
            Some(first)
        );
        assert_eq!(outbox.pending_group_creation("second-operation"), None);
        drop(outbox);

        let reopened = PreRouteOutbox::open(Some(path), Some(key)).unwrap();
        assert!(reopened.pending_group_creation("first-operation").is_some());
        assert_eq!(reopened.pending_group_creation("second-operation"), None);
    }

    #[test]
    fn discard_group_operation_removes_sentinel_and_recovery_together() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.enc");
        let key = [5u8; 32];
        let mut outbox = PreRouteOutbox::open(Some(path.clone()), Some(key)).unwrap();
        let mut sentinel = message("operation-sentinel");
        sentinel.route_kind = GROUP_OPERATION_ROUTE_KIND.into();
        sentinel.route_id = "pending-group-id".into();
        sentinel.content.clear();
        outbox.enqueue(sentinel).unwrap();
        outbox
            .save_pending_group_creation(PendingGroupCreation {
                operation_description: "operation-description".into(),
                group_id_hex: None,
                welcome_event_jsons: Vec::new(),
                cancelled: false,
            })
            .unwrap();

        outbox
            .discard_pending_group_operation("pending-group-id", "operation-description")
            .unwrap();
        assert!(outbox.messages().is_empty());
        assert_eq!(outbox.pending_group_creation("operation-description"), None);
        assert!(!path.exists());
    }

    #[test]
    fn group_cancellation_marker_survives_restart_until_cleanup() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.enc");
        let key = [6u8; 32];
        let mut outbox = PreRouteOutbox::open(Some(path.clone()), Some(key)).unwrap();
        outbox
            .save_pending_group_creation(group_creation("operation-description"))
            .unwrap();

        outbox
            .mark_pending_group_operation_cancelled("operation-description")
            .unwrap();
        drop(outbox);

        let restored = PreRouteOutbox::open(Some(path), Some(key)).unwrap();
        assert!(restored
            .pending_group_creation("operation-description")
            .is_some_and(|checkpoint| checkpoint.cancelled));
    }

    #[test]
    fn shared_instance_serializes_overlapping_nodes_without_lost_updates() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.enc");
        let key = [9u8; 32];
        let local_node = shared_pre_route_outbox(Some(path.clone()), Some(key)).unwrap();
        let relay_node = shared_pre_route_outbox(Some(path.clone()), Some(key)).unwrap();
        assert!(Arc::ptr_eq(&local_node, &relay_node));

        local_node
            .lock()
            .unwrap()
            .enqueue(message("local"))
            .unwrap();
        relay_node
            .lock()
            .unwrap()
            .enqueue(message("relay"))
            .unwrap();
        drop(local_node);
        drop(relay_node);

        let reopened = PreRouteOutbox::open(Some(path), Some(key)).unwrap();
        let ids: HashSet<_> = reopened
            .messages()
            .into_iter()
            .map(|message| message.id)
            .collect();
        assert_eq!(ids, HashSet::from(["local".into(), "relay".into()]));
    }

    #[test]
    fn shared_instance_rejects_an_overlapping_different_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pending.enc");
        let _open = shared_pre_route_outbox(Some(path.clone()), Some([1u8; 32])).unwrap();

        assert!(shared_pre_route_outbox(Some(path), Some([2u8; 32])).is_err());
    }

    #[test]
    fn wrong_key_cannot_open_journal() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("pre-route");
        let mut outbox = PreRouteOutbox::open(Some(path.clone()), Some([1u8; 32])).expect("open");
        outbox.enqueue(message("one")).expect("enqueue");
        assert!(PreRouteOutbox::open(Some(path), Some([2u8; 32])).is_err());
    }
}
