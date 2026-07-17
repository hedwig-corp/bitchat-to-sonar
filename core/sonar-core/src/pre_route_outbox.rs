//! Encrypted durable journal for outgoing content that does not have an MLS
//! group yet.
//!
//! The normal relay outbox can persist only after Marmot has encrypted a local
//! message for an existing group. Hosts still need somewhere safe to put a
//! user send while a direct/group route is being created. This journal stores
//! that small, bounded pre-route window encrypted with a key derived from the
//! SQLCipher database key. Hosts own route interpretation and remove an entry
//! only after the normal core send has accepted it into local storage.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::{Error, Result};

pub(crate) const PRE_ROUTE_OUTBOX_FILE_SUFFIX: &str = ".sonar-pre-route-outbox";
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

#[derive(Debug, Deserialize, Serialize)]
struct PreRouteStateDisk {
    version: u32,
    entries: Vec<PreRouteMessage>,
}

#[derive(Debug)]
pub(crate) struct PreRouteOutbox {
    path: Option<PathBuf>,
    key: Option<[u8; 32]>,
    entries: Vec<PreRouteMessage>,
}

impl PreRouteOutbox {
    pub fn open(path: Option<PathBuf>, db_key: Option<[u8; 32]>) -> Result<Self> {
        let key = db_key.map(derive_key).transpose()?;
        let entries = match (&path, &key) {
            (Some(path), Some(key)) if path.exists() => decrypt_state(path, key)?.entries,
            _ => Vec::new(),
        };
        Ok(Self { path, key, entries })
    }

    pub fn messages(&self) -> Vec<PreRouteMessage> {
        self.entries.clone()
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
        if self.entries.len() >= MAX_ENTRIES {
            return Err(Error::InvalidInput("pre-route outbox is full".into()));
        }
        let route_depth = self
            .entries
            .iter()
            .filter(|entry| {
                entry.route_kind == message.route_kind && entry.route_id == message.route_id
            })
            .count();
        if route_depth >= MAX_ENTRIES_PER_ROUTE {
            return Err(Error::InvalidInput("pre-route outbox route is full".into()));
        }

        self.entries.push(message);
        if let Err(error) = self.save() {
            self.entries.pop();
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
        if let Err(error) = self.save() {
            self.entries = previous;
            return Err(error);
        }
        Ok(())
    }

    fn save(&self) -> Result<()> {
        let (Some(path), Some(key)) = (&self.path, &self.key) else {
            return Ok(());
        };
        if self.entries.is_empty() {
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
        let state = PreRouteStateDisk {
            version: 1,
            entries: self.entries.clone(),
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
        fs::rename(&tmp, path).map_err(|error| {
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
    validate_loaded_entries(&state.entries)?;
    Ok(state)
}

fn validate_loaded_entries(entries: &[PreRouteMessage]) -> Result<()> {
    use std::collections::{HashMap, HashSet};

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
    Ok(())
}

fn tmp_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-pre-route-outbox");
    path.with_file_name(format!("{file_name}.tmp"))
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
    fn wrong_key_cannot_open_journal() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("pre-route");
        let mut outbox = PreRouteOutbox::open(Some(path.clone()), Some([1u8; 32])).expect("open");
        outbox.enqueue(message("one")).expect("enqueue");
        assert!(PreRouteOutbox::open(Some(path), Some([2u8; 32])).is_err());
    }
}
