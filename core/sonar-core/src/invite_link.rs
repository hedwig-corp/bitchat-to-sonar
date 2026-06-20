//! Group invite link: bech32 token (`sinvite1…`) for shareable group join requests.
//!
//! Each link embeds one admin's npub as the sole approver — join requests are
//! gift-wrapped to that admin only. This serializes MLS commits and avoids
//! conflicting epoch transitions when multiple admins could approve concurrently.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use nostr::prelude::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::identity::Identity;
use crate::{Error, GroupId, Result};

pub const JOIN_REQUEST_RUMOR_KIND: u16 = 4445;
pub(crate) const INVITE_LINK_STATE_FILE_SUFFIX: &str = ".sonar-invites.json";
const INVITE_LINK_STATE_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InviteToken {
    pub group_id: Vec<u8>,
    pub group_name: String,
    pub admin_npub: Vec<u8>,
    pub relays: Vec<String>,
    pub invite_secret: Vec<u8>,
    pub created_at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InviteLinkMeta {
    pub secret_hash: [u8; 32],
    pub created_at: u64,
    pub revoked: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JoinRequest {
    pub requester: PublicKey,
    pub group_id: GroupId,
    pub secret_hash: [u8; 32],
    pub key_package_event_id: Option<EventId>,
    pub received_at: u64,
}

#[derive(Clone, Debug, Default)]
struct InviteLinkState {
    links: HashMap<Vec<u8>, Vec<InviteLinkMeta>>,
    requests: HashMap<Vec<u8>, Vec<JoinRequest>>,
}

impl InviteLinkState {
    fn from_disk(disk: InviteLinkStoreDisk) -> Result<Self> {
        let mut links = HashMap::new();
        for group in disk.links {
            links.insert(
                hex_vec("invite group id", &group.group_id_hex)?,
                group.links,
            );
        }

        let mut requests: HashMap<Vec<u8>, Vec<JoinRequest>> = HashMap::new();
        for request in disk.requests {
            let group_id_bytes = hex_vec("join request group id", &request.group_id_hex)?;
            let group_id = GroupId::from_slice(&group_id_bytes);
            let key_package_event_id = request
                .key_package_event_id_hex
                .as_deref()
                .map(EventId::from_hex)
                .transpose()
                .map_err(|e| Error::InvalidInput(format!("join request event id: {e}")))?;
            let join_request = JoinRequest {
                requester: PublicKey::parse(&request.requester_npub)
                    .map_err(|e| Error::InvalidInput(format!("join request requester: {e}")))?,
                group_id,
                secret_hash: secret_hash_from_hex(&request.secret_hash_hex)?,
                key_package_event_id,
                received_at: request.received_at,
            };
            requests
                .entry(group_id_bytes)
                .or_default()
                .push(join_request);
        }

        Ok(Self { links, requests })
    }

    fn to_disk(&self) -> InviteLinkStoreDisk {
        let mut links: Vec<_> = self
            .links
            .iter()
            .map(|(group_id, links)| InviteLinkGroupDisk {
                group_id_hex: hex::encode(group_id),
                links: links.clone(),
            })
            .collect();
        links.sort_by(|a, b| a.group_id_hex.cmp(&b.group_id_hex));

        let mut requests: Vec<_> = self
            .requests
            .values()
            .flatten()
            .map(|request| JoinRequestDisk {
                requester_npub: request
                    .requester
                    .to_bech32()
                    .expect("npub encoding cannot fail"),
                group_id_hex: hex::encode(request.group_id.as_slice()),
                secret_hash_hex: hex::encode(request.secret_hash),
                key_package_event_id_hex: request.key_package_event_id.map(|id| id.to_hex()),
                received_at: request.received_at,
            })
            .collect();
        requests.sort_by(|a, b| {
            a.group_id_hex
                .cmp(&b.group_id_hex)
                .then_with(|| a.requester_npub.cmp(&b.requester_npub))
        });

        InviteLinkStoreDisk {
            version: INVITE_LINK_STATE_VERSION,
            links,
            requests,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct InviteLinkStoreDisk {
    version: u32,
    links: Vec<InviteLinkGroupDisk>,
    requests: Vec<JoinRequestDisk>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct InviteLinkGroupDisk {
    group_id_hex: String,
    links: Vec<InviteLinkMeta>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct JoinRequestDisk {
    requester_npub: String,
    group_id_hex: String,
    secret_hash_hex: String,
    key_package_event_id_hex: Option<String>,
    received_at: u64,
}

pub struct InviteLinkStore {
    path: Option<PathBuf>,
    state: Mutex<InviteLinkState>,
}

impl Default for InviteLinkStore {
    fn default() -> Self {
        Self {
            path: None,
            state: Mutex::new(InviteLinkState::default()),
        }
    }
}

impl InviteLinkStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn load(path: Option<PathBuf>) -> Self {
        let state = path
            .as_ref()
            .and_then(|path| fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice::<InviteLinkStoreDisk>(&bytes).ok())
            .filter(|disk| disk.version == INVITE_LINK_STATE_VERSION)
            .and_then(|disk| InviteLinkState::from_disk(disk).ok())
            .unwrap_or_default();

        Self {
            path,
            state: Mutex::new(state),
        }
    }

    pub fn create_link(
        &self,
        group_id: &GroupId,
        group_name: &str,
        admin: &Identity,
        relays: Vec<String>,
    ) -> Result<String> {
        let mut secret = [0u8; 32];
        getrandom::getrandom(&mut secret).map_err(|e| Error::InvalidInput(e.to_string()))?;

        let secret_hash = sha256(&secret);

        let token = InviteToken {
            group_id: group_id.as_slice().to_vec(),
            group_name: group_name.to_string(),
            admin_npub: admin.public_key().to_bytes().to_vec(),
            relays,
            invite_secret: secret.to_vec(),
            created_at: Timestamp::now().as_secs(),
        };

        let meta = InviteLinkMeta {
            secret_hash,
            created_at: token.created_at,
            revoked: false,
        };

        let encoded = encode_invite_token(&token)?;

        let mut state = self.state.lock().unwrap();
        state
            .links
            .entry(group_id.as_slice().to_vec())
            .or_default()
            .push(meta);
        self.save_state(&state)?;

        Ok(encoded)
    }

    pub fn revoke_link(&self, group_id: &GroupId, secret_hash: &[u8; 32]) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        if let Some(group_links) = state.links.get_mut(group_id.as_slice()) {
            for link in group_links.iter_mut() {
                if &link.secret_hash == secret_hash {
                    link.revoked = true;
                    self.save_state(&state)?;
                    return Ok(());
                }
            }
        }
        Err(Error::InvalidInput("invite link not found".into()))
    }

    pub fn active_links(&self, group_id: &GroupId) -> Vec<InviteLinkMeta> {
        let state = self.state.lock().unwrap();
        state
            .links
            .get(group_id.as_slice())
            .map(|v| v.iter().filter(|l| !l.revoked).cloned().collect())
            .unwrap_or_default()
    }

    pub fn validate_secret(&self, group_id: &GroupId, secret_hash: &[u8; 32]) -> bool {
        let state = self.state.lock().unwrap();
        state
            .links
            .get(group_id.as_slice())
            .map(|v| {
                v.iter()
                    .any(|l| !l.revoked && &l.secret_hash == secret_hash)
            })
            .unwrap_or(false)
    }

    pub fn add_join_request(&self, request: JoinRequest) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        let group_requests = state
            .requests
            .entry(request.group_id.as_slice().to_vec())
            .or_default();
        if group_requests
            .iter()
            .any(|r| r.requester == request.requester)
        {
            return Ok(());
        }
        group_requests.push(request);
        self.save_state(&state)
    }

    pub fn pending_join_requests(&self, group_id: &GroupId) -> Vec<JoinRequest> {
        let state = self.state.lock().unwrap();
        state
            .requests
            .get(group_id.as_slice())
            .cloned()
            .unwrap_or_default()
    }

    pub fn remove_join_request(&self, group_id: &GroupId, requester: &PublicKey) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        let mut changed = false;
        if let Some(group_requests) = state.requests.get_mut(group_id.as_slice()) {
            let before = group_requests.len();
            group_requests.retain(|r| r.requester != *requester);
            changed = group_requests.len() != before;
        }
        if changed {
            self.save_state(&state)?;
        }
        Ok(())
    }

    fn save_state(&self, state: &InviteLinkState) -> Result<()> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| {
                Error::Storage(format!(
                    "create invite-link-state dir {}: {e}",
                    parent.display()
                ))
            })?;
        }
        let bytes = serde_json::to_vec(&state.to_disk())?;
        let tmp = invite_link_state_tmp_path(path);
        fs::write(&tmp, bytes).map_err(|e| {
            Error::Storage(format!("write invite link state {}: {e}", tmp.display()))
        })?;
        fs::rename(&tmp, path).map_err(|e| {
            Error::Storage(format!("replace invite link state {}: {e}", path.display()))
        })?;
        Ok(())
    }
}

pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().into()
}

pub fn encode_invite_token(token: &InviteToken) -> Result<String> {
    let json = serde_json::to_vec(token)?;
    Ok(format!("sinvite1{}", hex::encode(&json)))
}

pub fn decode_invite_token(encoded: &str) -> Result<InviteToken> {
    let hex_str = encoded
        .strip_prefix("sinvite1")
        .ok_or_else(|| Error::InvalidInput("not a sinvite1 token".into()))?;
    let json = hex::decode(hex_str).map_err(|e| Error::InvalidInput(e.to_string()))?;
    serde_json::from_slice(&json).map_err(|e| e.into())
}

pub fn build_join_request_rumor(
    group_id: &GroupId,
    invite_secret: &[u8],
    requester: &PublicKey,
    key_package_event_id: Option<&EventId>,
) -> UnsignedEvent {
    let secret_hash = sha256(invite_secret);
    let content = serde_json::json!({
        "group_id": hex::encode(group_id.as_slice()),
        "invite_secret_hash": hex::encode(secret_hash),
        "requester_npub": requester.to_bech32().expect("valid pubkey"),
        "key_package_event_id": key_package_event_id.map(|id| id.to_hex()),
    });
    EventBuilder::new(Kind::Custom(JOIN_REQUEST_RUMOR_KIND), content.to_string())
        .tag(Tag::public_key(*requester))
        .build(*requester)
}

#[derive(Debug, Clone, Deserialize)]
pub struct JoinRequestPayload {
    pub group_id: String,
    pub invite_secret_hash: String,
    pub requester_npub: String,
    pub key_package_event_id: Option<String>,
}

pub fn parse_join_request_rumor(rumor: &UnsignedEvent) -> Result<JoinRequestPayload> {
    serde_json::from_str(&rumor.content).map_err(|e| e.into())
}

pub(crate) fn invite_link_state_path_for_db(db_path: &Path) -> PathBuf {
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-invites.json");
    db_path.with_file_name(format!("{file_name}{INVITE_LINK_STATE_FILE_SUFFIX}"))
}

fn invite_link_state_tmp_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-invites.json");
    path.with_file_name(format!("{file_name}.tmp"))
}

fn hex_vec(context: &str, value: &str) -> Result<Vec<u8>> {
    hex::decode(value).map_err(|e| Error::InvalidInput(format!("{context}: {e}")))
}

fn secret_hash_from_hex(value: &str) -> Result<[u8; 32]> {
    let bytes = hex_vec("join request secret hash", value)?;
    bytes
        .try_into()
        .map_err(|_| Error::InvalidInput("join request secret hash length".into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;

    #[test]
    fn invite_links_and_requests_survive_reload() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("invites.json");
        let group_id = GroupId::from_slice(&[7u8; 32]);
        let admin = Identity::generate();
        let requester = Identity::generate().public_key();

        let store = InviteLinkStore::load(Some(path.clone()));
        let token = store
            .create_link(
                &group_id,
                "group",
                &admin,
                vec!["wss://relay.example".into()],
            )
            .expect("create link");
        let decoded = decode_invite_token(&token).expect("decode token");
        let request = JoinRequest {
            requester,
            group_id: group_id.clone(),
            secret_hash: sha256(&decoded.invite_secret),
            key_package_event_id: None,
            received_at: 42,
        };
        store.add_join_request(request).expect("add request");

        let reloaded = InviteLinkStore::load(Some(path));
        assert_eq!(reloaded.active_links(&group_id).len(), 1);
        assert_eq!(reloaded.pending_join_requests(&group_id).len(), 1);
        assert!(reloaded.validate_secret(&group_id, &sha256(&decoded.invite_secret)));
    }
}
