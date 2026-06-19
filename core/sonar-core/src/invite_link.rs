//! Group invite link: bech32 token (`sinvite1…`) for shareable group join requests.
//!
//! Each link embeds one admin's npub as the sole approver — join requests are
//! gift-wrapped to that admin only. This serializes MLS commits and avoids
//! conflicting epoch transitions when multiple admins could approve concurrently.

use std::collections::HashMap;
use std::sync::Mutex;

use nostr::prelude::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{Error, GroupId, Result};

pub const JOIN_REQUEST_RUMOR_KIND: u16 = 4445;

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

pub struct InviteLinkStore {
    links: Mutex<HashMap<Vec<u8>, Vec<InviteLinkMeta>>>,
    requests: Mutex<HashMap<Vec<u8>, Vec<JoinRequest>>>,
}

impl Default for InviteLinkStore {
    fn default() -> Self {
        Self {
            links: Mutex::new(HashMap::new()),
            requests: Mutex::new(HashMap::new()),
        }
    }
}

impl InviteLinkStore {
    pub fn new() -> Self {
        Self::default()
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

        let mut links = self.links.lock().unwrap();
        links
            .entry(group_id.as_slice().to_vec())
            .or_default()
            .push(meta);

        encode_invite_token(&token)
    }

    pub fn revoke_link(&self, group_id: &GroupId, secret_hash: &[u8; 32]) -> Result<()> {
        let mut links = self.links.lock().unwrap();
        if let Some(group_links) = links.get_mut(group_id.as_slice()) {
            for link in group_links.iter_mut() {
                if &link.secret_hash == secret_hash {
                    link.revoked = true;
                    return Ok(());
                }
            }
        }
        Err(Error::InvalidInput("invite link not found".into()))
    }

    pub fn active_links(&self, group_id: &GroupId) -> Vec<InviteLinkMeta> {
        let links = self.links.lock().unwrap();
        links
            .get(group_id.as_slice())
            .map(|v| v.iter().filter(|l| !l.revoked).cloned().collect())
            .unwrap_or_default()
    }

    pub fn validate_secret(&self, group_id: &GroupId, secret_hash: &[u8; 32]) -> bool {
        let links = self.links.lock().unwrap();
        links
            .get(group_id.as_slice())
            .map(|v| v.iter().any(|l| !l.revoked && &l.secret_hash == secret_hash))
            .unwrap_or(false)
    }

    pub fn add_join_request(&self, request: JoinRequest) -> Result<()> {
        let mut requests = self.requests.lock().unwrap();
        let group_requests = requests
            .entry(request.group_id.as_slice().to_vec())
            .or_default();
        if group_requests
            .iter()
            .any(|r| r.requester == request.requester)
        {
            return Ok(());
        }
        group_requests.push(request);
        Ok(())
    }

    pub fn pending_join_requests(&self, group_id: &GroupId) -> Vec<JoinRequest> {
        let requests = self.requests.lock().unwrap();
        requests
            .get(group_id.as_slice())
            .cloned()
            .unwrap_or_default()
    }

    pub fn remove_join_request(&self, group_id: &GroupId, requester: &PublicKey) {
        let mut requests = self.requests.lock().unwrap();
        if let Some(group_requests) = requests.get_mut(group_id.as_slice()) {
            group_requests.retain(|r| r.requester != *requester);
        }
    }
}

use crate::identity::Identity;

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
