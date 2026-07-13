use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use fs2::FileExt;
use nostr::{PublicKey, RelayUrl};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use sonar_core::client::{MediaDownloadObserver, SonarClient};
use sonar_core::conversation_index::{ConversationChangeListener, MessageChangeListener};
use sonar_core::marmot::ChatMessage;
use sonar_core::GroupId;
use zeroize::Zeroize;

use crate::secret_store::AccountSecrets;
use crate::spool;
use crate::store::{JournalEntry, MessageDto, Store};

const MAX_TEXT_BYTES: usize = 64 * 1024;
const BACKFILL_GROUPS: usize = 50;
const BACKFILL_MESSAGES: usize = 50;

struct EventWriter {
    store: Arc<Mutex<Store>>,
    dm_groups: Arc<Mutex<HashMap<String, String>>>,
    dirty_groups: Arc<Mutex<HashSet<String>>>,
}

impl ConversationChangeListener for EventWriter {
    fn on_conversation_changed(&self, group_id_hex: String) {
        if let Ok(mut dirty) = self.dirty_groups.lock() {
            dirty.insert(group_id_hex);
        }
    }
}

impl MessageChangeListener for EventWriter {
    fn on_message_committed(&self, message: ChatMessage) {
        let Ok(message) = MessageDto::try_from(&message) else {
            return;
        };
        if message.mine {
            return;
        }
        let group_id = message.group_id.clone();
        let allowed = self
            .dm_groups
            .lock()
            .ok()
            .and_then(|groups| groups.get(&group_id).cloned());
        if allowed.as_deref() != Some(message.sender.as_str()) {
            return;
        }
        if let Ok(store) = self.store.lock() {
            let _ = store.append_inbound(&message.sender, &message);
        }
    }
}

pub struct Account {
    client: SonarClient,
    store: Arc<Mutex<Store>>,
    state_dir: PathBuf,
    master_key: [u8; 32],
    blossom_server: String,
    media_hosts: HashSet<String>,
    account_id: String,
    dm_groups: Arc<Mutex<HashMap<String, String>>>,
    dirty_groups: Arc<Mutex<HashSet<String>>>,
    reconcile_tick: AtomicU64,
    startup_hydrated: AtomicBool,
    _lock: File,
}

impl Drop for Account {
    fn drop(&mut self) {
        self.master_key.zeroize();
    }
}

impl Account {
    pub async fn open(
        state_dir: PathBuf,
        secrets: AccountSecrets,
        master_key: [u8; 32],
        relays: Vec<RelayUrl>,
        blossom_server: String,
        media_hosts: HashSet<String>,
    ) -> Result<Self, String> {
        let lock = account_lock(&state_dir)?;
        spool::janitor(&state_dir);
        let store = Arc::new(Mutex::new(Store::open(
            &state_dir.join("bridge-state.sqlite"),
            secrets.db_key,
        )?));
        let client = SonarClient::connect_local_first(
            secrets.identity.clone(),
            relays,
            state_dir.join("sonar.sqlite"),
            secrets.db_key,
        )
        .await
        .map_err(|error| format!("open Sonar account: {error}"))?;
        let dm_groups = Arc::new(Mutex::new(HashMap::new()));
        let dirty_groups = Arc::new(Mutex::new(HashSet::new()));
        let event_writer = Arc::new(EventWriter {
            store: store.clone(),
            dm_groups: dm_groups.clone(),
            dirty_groups: dirty_groups.clone(),
        });
        client.set_message_change_listener(Some(event_writer.clone()));
        client.set_conversation_change_listener(Some(event_writer));
        let account = Self {
            client,
            store,
            state_dir,
            master_key,
            blossom_server,
            media_hosts,
            account_id: secrets.account_id.clone(),
            dm_groups,
            dirty_groups,
            reconcile_tick: AtomicU64::new(0),
            startup_hydrated: AtomicBool::new(false),
            _lock: lock,
        };
        account
            .client
            .publish_key_package_background()
            .await
            .map_err(|error| format!("prepare KeyPackage: {error}"))?;
        Ok(account)
    }

    pub async fn tick(&self) {
        let _ = self.client.drain_pending_marmot().await;
        if !self.startup_hydrated.swap(true, Ordering::Relaxed) {
            let _ = self.hydrate_recent_dm_groups(BACKFILL_GROUPS);
            let _ = self.seed_bounded_backfill();
        }
        let _ = self.refresh_dirty_dm_groups();
        let reconcile_tick = self.reconcile_tick.fetch_add(1, Ordering::Relaxed);
        if reconcile_tick % 15 == 0 {
            // This only reloads durable local outbox metadata and spawns relay
            // publishes. It never waits for relay acknowledgements or scans
            // transcript history on the account actor.
            self.client.reload_outbox_and_retry().await;
        }
        if reconcile_tick % 15 == 14 {
            // Exact callbacks are the fast path. This bounded local repair is
            // the fallback if the bridge-log write briefly fails after the
            // core transcript row has already committed.
            let _ = self.seed_backfill(20, BACKFILL_MESSAGES);
        }
    }

    pub async fn handle(&self, method: &str, params: Value) -> Result<Value, RpcFailure> {
        match method {
            "hello" => Ok(json!({
                "protocol": 1,
                "features": ["durable_outbound", "inbound_replay", "text", "media_path", "local_first"]
            })),
            "identity" => Ok(json!({
                "account_id": self.account_id,
                "npub": self.client.identity().npub(),
                "pubkey_hex": self.client.identity().public_key().to_hex()
            })),
            "health" => serde_json::to_value(self.client.sync_state_snapshot().await)
                .map_err(|error| RpcFailure::internal(error.to_string())),
            "resolve_dm" => self.resolve_dm(params),
            "send_text" => self.send_text(params).await,
            "send_media" => self.send_media(params).await,
            "events" => self.events(params),
            "ack_events" => self.ack_events(params),
            "fetch_media" => self.fetch_media(params).await,
            "release_media" => self.release_media(params),
            _ => Err(RpcFailure::invalid("unknown_method", "unknown RPC method")),
        }
    }

    fn resolve_dm(&self, params: Value) -> Result<Value, RpcFailure> {
        let request: PeerRequest = decode(params)?;
        let peer = parse_peer(&request.peer)?;
        self.reject_self_peer(&peer)?;
        // Portal creation must remain an immediate local operation. Reuse a
        // validated bridge mapping when one exists, but never enumerate every
        // Sonar group on the identifier-resolution path.
        let group = self
            .cached_dm_group(&peer.to_hex(), &peer)?
            .map(|group| hex::encode(group.as_slice()));
        if let Some(ref group_id) = group {
            self.store
                .lock()
                .map_err(lock_failure)?
                .set_group(&peer.to_hex(), group_id)
                .map_err(store_failure)?;
        }
        Ok(json!({"peer_hex": peer.to_hex(), "group_id": group, "pending": group.is_none()}))
    }

    async fn send_text(&self, params: Value) -> Result<Value, RpcFailure> {
        let request: SendTextRequest = decode(params)?;
        validate_transaction_key(&request.transaction_key)?;
        if request.text.len() > MAX_TEXT_BYTES {
            return Err(RpcFailure::invalid("text_too_large", "text exceeds 64 KiB"));
        }
        let peer = parse_peer(&request.peer)?;
        self.reject_self_peer(&peer)?;
        let entry = self
            .store
            .lock()
            .map_err(lock_failure)?
            .put_text(&request.transaction_key, &peer.to_hex(), &request.text)
            .map_err(store_failure)?;
        self.finish_or_queue(entry).await
    }

    async fn send_media(&self, params: Value) -> Result<Value, RpcFailure> {
        let request: SendMediaRequest = decode(params)?;
        validate_transaction_key(&request.transaction_key)?;
        if request.caption.len() > MAX_TEXT_BYTES {
            return Err(RpcFailure::invalid(
                "caption_too_large",
                "caption exceeds 64 KiB",
            ));
        }
        validate_mime(&request.mime)?;
        let peer = parse_peer(&request.peer)?;
        self.reject_self_peer(&peer)?;
        let source = PathBuf::from(&request.source_path);
        let imported = spool::import(
            &self.state_dir,
            &self.master_key,
            &request.transaction_key,
            &source,
        )
        .map_err(|error| RpcFailure::invalid("invalid_media", error))?;
        let entry = self
            .store
            .lock()
            .map_err(lock_failure)?
            .put_media(
                &request.transaction_key,
                &peer.to_hex(),
                &imported.content_hash,
                imported
                    .path
                    .to_str()
                    .ok_or_else(|| RpcFailure::internal("non-UTF-8 spool path"))?,
                &sanitize_filename(&request.filename),
                &request.mime,
                &request.caption,
            )
            .map_err(store_failure)?;
        self.finish_or_queue(entry).await
    }

    async fn finish_or_queue(&self, entry: JournalEntry) -> Result<Value, RpcFailure> {
        if entry.status == "sent" {
            return Ok(journal_result(&entry, false));
        }
        if entry.status == "sending" {
            return Ok(journal_result(&entry, true));
        }
        match self.process_entry(entry.clone()).await {
            Ok(result) => Ok(result),
            Err(error) if error.retryable => {
                let current = self
                    .store
                    .lock()
                    .map_err(lock_failure)?
                    .journal(&entry.txn_key)
                    .map_err(store_failure)?
                    .ok_or_else(|| RpcFailure::internal("journal command disappeared"))?;
                Ok(journal_result(&current, current.status == "sending"))
            }
            Err(error) => Err(error),
        }
    }

    async fn process_entry(&self, entry: JournalEntry) -> Result<Value, RpcFailure> {
        let peer = parse_peer(&entry.peer_hex)?;
        let group = match self.cached_dm_group(&entry.peer_hex, &peer)? {
            Some(group) => group,
            None => match self.client.dm_group_with(&peer).map_err(core_failure)? {
                Some(group) => group,
                None => self
                    .client
                    .start_dm(peer, "Sonar direct message")
                    .await
                    .map_err(|error| {
                        RpcFailure::retryable("peer_unavailable", error.to_string())
                    })?,
            },
        };
        let group_hex = hex::encode(group.as_slice());
        self.dm_groups
            .lock()
            .map_err(lock_failure)?
            .insert(group_hex.clone(), entry.peer_hex.clone());
        self.store
            .lock()
            .map_err(lock_failure)?
            .set_group(&entry.peer_hex, &group_hex)
            .map_err(store_failure)?;

        let claimed = self
            .store
            .lock()
            .map_err(lock_failure)?
            .begin_attempt(&entry.txn_key)
            .map_err(store_failure)?;
        if !claimed {
            let current = self
                .store
                .lock()
                .map_err(lock_failure)?
                .journal(&entry.txn_key)
                .map_err(store_failure)?
                .ok_or_else(|| RpcFailure::internal("journal command disappeared"))?;
            return Ok(journal_result(&current, current.status != "sent"));
        }

        let attempt = self.process_claimed(&entry, group).await;
        if let Err(ref error) = attempt {
            let _ = self
                .store
                .lock()
                .map_err(lock_failure)?
                .record_attempt_error(&entry.txn_key, &error.message);
            let current = self
                .store
                .lock()
                .map_err(lock_failure)?
                .journal(&entry.txn_key)
                .map_err(store_failure)?
                .ok_or_else(|| RpcFailure::internal("journal command disappeared"))?;
            // Once a command is claimed, any failure is ambiguous: the Sonar
            // transcript commit may have happened even if later bookkeeping
            // failed. Never replay it blindly.
            return Ok(journal_result(&current, true));
        }
        attempt
    }

    async fn process_claimed(
        &self,
        entry: &JournalEntry,
        group: GroupId,
    ) -> Result<Value, RpcFailure> {
        let group_hex = hex::encode(group.as_slice());
        let message = match entry.kind.as_str() {
            "text" => self
                .client
                .send_text_receipt(&group, &entry.body)
                .await
                .map_err(|error| RpcFailure::retryable("send_failed", error.to_string()))?,
            "media" => {
                let sealed = entry
                    .media_path
                    .as_deref()
                    .ok_or_else(|| RpcFailure::internal("media journal has no spool path"))?;
                let temp =
                    spool::decrypt_temp(&self.state_dir, &self.master_key, Path::new(sealed))
                        .map_err(RpcFailure::internal)?;
                let result = self
                    .client
                    .send_media_from_path_receipt(
                        &group,
                        &temp,
                        entry.filename.as_deref().unwrap_or("attachment"),
                        entry.mime.as_deref().unwrap_or("application/octet-stream"),
                        entry.caption.as_deref().unwrap_or(""),
                        &self.blossom_server,
                    )
                    .await;
                spool::remove(&temp);
                let message = result.map_err(|error| {
                    RpcFailure::retryable("media_send_failed", error.to_string())
                })?;
                spool::remove(Path::new(sealed));
                message
            }
            _ => return Err(RpcFailure::internal("unsupported journal command kind")),
        };
        let message_id = message.id.to_hex();
        self.store
            .lock()
            .map_err(lock_failure)?
            .complete(&entry.txn_key, &group_hex, &message_id)
            .map_err(store_failure)?;
        Ok(json!({
            "queued": false,
            "indeterminate": false,
            "status": "sent",
            "group_id": group_hex,
            "message_id": message_id
        }))
    }

    fn events(&self, params: Value) -> Result<Value, RpcFailure> {
        let request: EventsRequest = decode(params)?;
        let events = self
            .store
            .lock()
            .map_err(lock_failure)?
            .events_after(request.after, request.limit.unwrap_or(50))
            .map_err(store_failure)?;
        Ok(json!({"events": events}))
    }

    fn ack_events(&self, params: Value) -> Result<Value, RpcFailure> {
        let request: AckEventsRequest = decode(params)?;
        self.store
            .lock()
            .map_err(lock_failure)?
            .acknowledge_events(request.through)
            .map_err(store_failure)?;
        Ok(json!({"acknowledged": request.through}))
    }

    fn reject_self_peer(&self, peer: &PublicKey) -> Result<(), RpcFailure> {
        if *peer == self.client.identity().public_key() {
            return Err(RpcFailure::invalid(
                "self_chat",
                "a Sonar direct message requires another identity",
            ));
        }
        Ok(())
    }

    fn cached_dm_group(
        &self,
        peer_hex: &str,
        peer: &PublicKey,
    ) -> Result<Option<GroupId>, RpcFailure> {
        let Some(group_id_hex) = self
            .store
            .lock()
            .map_err(lock_failure)?
            .group_for_peer(peer_hex)
            .map_err(store_failure)?
        else {
            return Ok(None);
        };
        let Ok(group) = parse_group_hex(&group_id_hex) else {
            return Ok(None);
        };
        let mapped_peer = self
            .client
            .dm_peer_for_group(&group)
            .map_err(core_failure)?;
        Ok((mapped_peer.as_ref() == Some(peer)).then_some(group))
    }

    async fn fetch_media(&self, params: Value) -> Result<Value, RpcFailure> {
        let request: FetchMediaRequest = decode(params)?;
        let parsed = nostr::Url::parse(&request.url)
            .map_err(|_| RpcFailure::invalid("invalid_media_url", "invalid media URL"))?;
        let host = parsed
            .host_str()
            .map(str::to_ascii_lowercase)
            .ok_or_else(|| RpcFailure::invalid("invalid_media_url", "media URL has no host"))?;
        if !self.media_hosts.contains(&host) {
            return Err(RpcFailure::invalid(
                "media_host_not_allowed",
                "media host is not in network.media_download_hosts",
            ));
        }
        let group = parse_group(&request.group_id)?;
        let export_dir = self.state_dir.join("exports");
        fs::create_dir_all(&export_dir)
            .map_err(|error| RpcFailure::internal(format!("create export directory: {error}")))?;
        if fs::symlink_metadata(&export_dir)
            .map_err(|error| RpcFailure::internal(format!("inspect export directory: {error}")))?
            .file_type()
            .is_symlink()
        {
            return Err(RpcFailure::invalid(
                "unsafe_export_path",
                "export directory must not be a symbolic link",
            ));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&export_dir, fs::Permissions::from_mode(0o700)).map_err(
                |error| RpcFailure::internal(format!("secure export directory: {error}")),
            )?;
        }
        let mut random = [0u8; 16];
        getrandom::getrandom(&mut random)
            .map_err(|error| RpcFailure::internal(error.to_string()))?;
        let path = export_dir.join(hex::encode(random));
        let bytes = self
            .client
            .fetch_media_to_file(&group, &request.url, &path, &NeverCancel)
            .await
            .map_err(|error| RpcFailure::retryable("media_fetch_failed", error.to_string()))?;
        Ok(json!({"path": path, "size": bytes}))
    }

    fn release_media(&self, params: Value) -> Result<Value, RpcFailure> {
        let request: ReleaseMediaRequest = decode(params)?;
        let path = PathBuf::from(request.path);
        let exports = self.state_dir.join("exports");
        if path.parent() != Some(exports.as_path()) {
            return Err(RpcFailure::invalid(
                "invalid_path",
                "not a daemon export path",
            ));
        }
        spool::remove(&path);
        Ok(json!({"released": true}))
    }

    fn seed_bounded_backfill(&self) -> Result<(), String> {
        self.seed_backfill(BACKFILL_GROUPS, BACKFILL_MESSAGES)
    }

    fn seed_backfill(&self, group_limit: usize, message_limit: usize) -> Result<(), String> {
        for summary in self.client.conversation_summaries_page(group_limit, 0) {
            let group = parse_group_hex(&summary.group_id_hex)?;
            let Some(peer_hex) = self
                .dm_groups
                .lock()
                .map_err(|_| "DM group map lock poisoned".to_string())?
                .get(&summary.group_id_hex)
                .cloned()
            else {
                continue;
            };
            self.seed_group(&group, &peer_hex, message_limit)?;
        }
        Ok(())
    }

    fn refresh_dirty_dm_groups(&self) -> Result<(), String> {
        let dirty = std::mem::take(
            &mut *self
                .dirty_groups
                .lock()
                .map_err(|_| "dirty group map lock poisoned".to_string())?,
        );
        if dirty.is_empty() {
            return Ok(());
        }
        let parsed = dirty
            .iter()
            .map(|group_id_hex| parse_group_hex(group_id_hex))
            .collect::<Result<Vec<_>, _>>()?;
        let resolved = self
            .client
            .dm_peers_for_groups(&parsed)
            .map_err(|error| error.to_string())?
            .into_iter()
            .map(|(group_id, peer)| (hex::encode(group_id.as_slice()), peer.to_hex()))
            .collect::<HashMap<_, _>>();
        let mut groups = self
            .dm_groups
            .lock()
            .map_err(|_| "DM group map lock poisoned".to_string())?;
        let mut proven_non_dm = Vec::new();
        for group_id_hex in dirty {
            if let Some(peer) = resolved.get(&group_id_hex) {
                groups.insert(group_id_hex, peer.clone());
            } else {
                groups.remove(&group_id_hex);
                proven_non_dm.push(group_id_hex);
            }
        }
        drop(groups);
        if !proven_non_dm.is_empty() {
            let store = self
                .store
                .lock()
                .map_err(|_| "bridge state lock poisoned".to_string())?;
            for group_id_hex in proven_non_dm {
                store.purge_inbound_group(&group_id_hex)?;
            }
        }
        for (group_id_hex, peer_hex) in resolved {
            self.store
                .lock()
                .map_err(|_| "bridge state lock poisoned".to_string())?
                .set_group(&peer_hex, &group_id_hex)?;
            self.seed_group(
                &parse_group_hex(&group_id_hex)?,
                &peer_hex,
                BACKFILL_MESSAGES,
            )?;
        }
        Ok(())
    }

    fn seed_group(
        &self,
        group: &GroupId,
        peer_hex: &str,
        message_limit: usize,
    ) -> Result<(), String> {
        for message in self
            .client
            .messages_cursor_page(group, None, None, message_limit)
            .map_err(|error| error.to_string())?
        {
            let Ok(message) = MessageDto::try_from(&message) else {
                continue;
            };
            if !message.mine && message.sender == peer_hex {
                self.store
                    .lock()
                    .map_err(|_| "bridge state lock poisoned".to_string())?
                    .append_inbound(peer_hex, &message)?;
            }
        }
        Ok(())
    }
}

impl Account {
    fn hydrate_recent_dm_groups(&self, limit: usize) -> Result<(), String> {
        let group_ids = self
            .client
            .conversation_summaries_page(limit, 0)
            .into_iter()
            .map(|summary| parse_group_hex(&summary.group_id_hex))
            .collect::<Result<Vec<_>, _>>()?;
        let resolved = self
            .client
            .dm_peers_for_groups(&group_ids)
            .map_err(|error| error.to_string())?;
        let mut direct = self
            .dm_groups
            .lock()
            .map_err(|_| "DM group map lock poisoned".to_string())?;
        for (group_id, peer) in resolved {
            let group_id_hex = hex::encode(group_id.as_slice());
            let peer_hex = peer.to_hex();
            direct.insert(group_id_hex.clone(), peer_hex.clone());
            self.store
                .lock()
                .map_err(|_| "bridge state lock poisoned".to_string())?
                .set_group(&peer_hex, &group_id_hex)?;
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct RpcFailure {
    pub code: &'static str,
    pub message: String,
    pub retryable: bool,
}

impl RpcFailure {
    fn invalid(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retryable: false,
        }
    }

    fn internal(message: impl Into<String>) -> Self {
        Self {
            code: "internal",
            message: message.into(),
            retryable: false,
        }
    }

    fn retryable(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retryable: true,
        }
    }
}

#[derive(Deserialize)]
struct PeerRequest {
    peer: String,
}

#[derive(Deserialize)]
struct SendTextRequest {
    transaction_key: String,
    peer: String,
    text: String,
}

#[derive(Deserialize)]
struct SendMediaRequest {
    transaction_key: String,
    peer: String,
    source_path: String,
    filename: String,
    mime: String,
    #[serde(default)]
    caption: String,
}

#[derive(Deserialize)]
struct EventsRequest {
    #[serde(default)]
    after: u64,
    limit: Option<usize>,
}

#[derive(Deserialize)]
struct AckEventsRequest {
    through: u64,
}

#[derive(Deserialize)]
struct FetchMediaRequest {
    group_id: String,
    url: String,
}

#[derive(Deserialize)]
struct ReleaseMediaRequest {
    path: String,
}

struct NeverCancel;

impl MediaDownloadObserver for NeverCancel {
    fn on_progress(&self, _downloaded: u64, _total: Option<u64>) {}
    fn is_cancelled(&self) -> bool {
        false
    }
}

fn decode<T: for<'de> Deserialize<'de>>(value: Value) -> Result<T, RpcFailure> {
    serde_json::from_value(value)
        .map_err(|error| RpcFailure::invalid("invalid_params", error.to_string()))
}

fn parse_peer(value: &str) -> Result<PublicKey, RpcFailure> {
    PublicKey::parse(value)
        .map_err(|_| RpcFailure::invalid("invalid_peer", "peer must be an npub or 64-char hex key"))
}

fn parse_group(value: &str) -> Result<GroupId, RpcFailure> {
    parse_group_hex(value).map_err(|error| RpcFailure::invalid("invalid_group", error))
}

fn parse_group_hex(value: &str) -> Result<GroupId, String> {
    let bytes = hex::decode(value).map_err(|_| "group id is not hex")?;
    if bytes.is_empty() || bytes.len() > 255 {
        return Err("group id has an invalid length".into());
    }
    Ok(GroupId::from_slice(&bytes))
}

fn validate_transaction_key(value: &str) -> Result<(), RpcFailure> {
    if value.is_empty() || value.len() > 255 || value.chars().any(char::is_control) {
        return Err(RpcFailure::invalid(
            "invalid_transaction",
            "invalid transaction key",
        ));
    }
    Ok(())
}

fn validate_mime(value: &str) -> Result<(), RpcFailure> {
    let valid = value.len() <= 255
        && value.split_once('/').is_some_and(|(kind, subtype)| {
            !kind.is_empty()
                && !subtype.is_empty()
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_graphic() && !matches!(byte, b'"' | b'\\'))
        });
    if !valid {
        return Err(RpcFailure::invalid(
            "invalid_mime",
            "MIME type must be a printable type/subtype value no longer than 255 bytes",
        ));
    }
    Ok(())
}

fn provisional_id(transaction_key: &str) -> String {
    format!(
        "pending:{}",
        hex::encode(Sha256::digest(transaction_key.as_bytes()))
    )
}

fn journal_result(entry: &JournalEntry, indeterminate: bool) -> Value {
    json!({
        "queued": entry.status != "sent",
        "indeterminate": indeterminate,
        "status": entry.status,
        "last_error": entry.error,
        "group_id": entry.group_id,
        "message_id": entry.message_id.clone().unwrap_or_else(|| provisional_id(&entry.txn_key))
    })
}

fn sanitize_filename(value: &str) -> String {
    let value = value
        .chars()
        .filter(|character| !character.is_control() && !matches!(character, '/' | '\\'))
        .take(255)
        .collect::<String>();
    if value.trim().is_empty() {
        "attachment".into()
    } else {
        value
    }
}

fn core_failure(error: sonar_core::Error) -> RpcFailure {
    RpcFailure::internal(error.to_string())
}

fn store_failure(error: String) -> RpcFailure {
    RpcFailure::internal(error)
}
fn lock_failure<T>(_error: std::sync::PoisonError<T>) -> RpcFailure {
    RpcFailure::internal("bridge state lock poisoned")
}

fn account_lock(state_dir: &Path) -> Result<File, String> {
    let path = state_dir.join("daemon.lock");
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path)
        .map_err(|error| format!("open account lock: {error}"))?;
    file.try_lock_exclusive()
        .map_err(|_| "another daemon already owns this account".to_string())?;
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn media_metadata_is_bounded() {
        assert!(validate_mime("image/png").is_ok());
        assert!(validate_mime("").is_err());
        assert!(validate_mime("image").is_err());
        assert!(validate_mime("image/png\nsecret").is_err());
        assert!(validate_mime(&format!("image/{}", "x".repeat(256))).is_err());
    }
}
