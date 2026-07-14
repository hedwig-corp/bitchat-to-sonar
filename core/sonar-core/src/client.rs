//! Relay-connected Sonar client: ties an [`Identity`] + [`MarmotEngine`] to
//! nostr relays. This is the async I/O layer; all protocol logic lives in
//! [`crate::marmot`].
//!
//! M1 scope: explicit polling via [`SonarClient::sync`] (deterministic for
//! e2e tests). Live subscriptions land with the native shells.

use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, LazyLock, Mutex, Weak};
use std::time::{Duration, Instant};

use futures_util::future::{BoxFuture, Shared};
use futures_util::FutureExt;
use mdk_core::prelude::*;
use nostr::prelude::*;
use nostr_blossom::prelude::*;
use nostr_sdk::{Client, RelayPoolNotification, RelayStatus};
use serde::{Deserialize, Serialize};

use sonar_stickers::{
    build_installed_packs_tags, parse_installed_pack_list, parse_pack_event, sha256_hex,
    validate_sha256_hex, InstalledPackList, PackAddress, StickerPack, StickerRef,
    STICKER_PACK_KIND, USER_STICKER_PACKS_KIND,
};

use crate::conversation_index::{
    index_db_path_for_db, wipe_index_for_db, ConversationChangeListener, ConversationIndex,
    ConversationSummary,
};
use crate::identity::Identity;
use crate::invite_link::invite_link_state_path_for_db;
use crate::marmot::{
    ChatMessage, DeliveryState, GroupCreation, GroupInvite, GroupMembershipUpdate, Incoming,
    MarmotEngine, RecentMessagePage, KEY_PACKAGE_KIND, SYNC_STATE_FILE_SUFFIX,
};
use crate::outbox::{outbox_state_path_for_db, OutboxState};
use crate::push::{push_token_cache_path_for_db, wipe_push_token_cache_for_db, PushTokenCache};
use crate::sonar_descriptor::{
    descriptor_d_tags, descriptor_events, descriptor_tags, parse_descriptor_event, SonarDescriptor,
    SONAR_DESCRIPTOR_KIND, SONAR_META_DESCRIPTOR_D_TAG,
};
use crate::sticker_cache::{
    wipe_sticker_cache_for_db, StickerCache, MAX_STICKER_CACHE_BYTES,
    STICKER_CACHE_PREFETCH_IMAGE_LIMIT,
};
use crate::{Error, Result};

/// Blossom user-server-list event kind (BUD-03): the user's preferred blob
/// servers, newest first.
const BLOSSOM_SERVER_LIST_KIND: u16 = 10063;

/// Fallback Blossom server when the user has published no kind-10063 list.
/// primal.net returns HTTP 415 for Marmot ciphertext uploads (even with
/// `application/octet-stream`); nostr.download accepts them (201 Created).
pub const DEFAULT_BLOSSOM_SERVER: &str = "https://nostr.download";

/// MIP-04 uploads ciphertext, not the original media bytes. Blossom servers
/// validate the request body's media type, so encrypted blobs must use the
/// generic binary MIME even though the encrypted imeta keeps the source MIME.
const ENCRYPTED_BLOB_MIME_TYPE: &str = "application/octet-stream";

/// One attachment for an album send (see [`SonarClient::send_media_multi`]).
/// Raw plaintext bytes plus the source filename and MIME; each item is
/// encrypted + uploaded independently before the single message is published.
#[derive(Debug, Clone)]
pub struct MediaUpload {
    pub data: Vec<u8>,
    pub filename: String,
    pub mime: String,
}

/// Hard ceiling on a single downloaded media blob. The URL comes from the
/// SENDER (untrusted), so this bounds memory use against a malicious/huge blob.
/// Comfortably above any real image while well under MDK's 100 MB MIP-04 limit.
const MAX_MEDIA_DOWNLOAD_BYTES: usize = 25 * 1024 * 1024;
const MEDIA_DOWNLOAD_ATTEMPTS: usize = 3;
const MEDIA_DOWNLOAD_RETRY_DELAY: Duration = Duration::from_millis(350);
const MEDIA_DOWNLOAD_CANCEL_POLL: Duration = Duration::from_millis(100);
const MEDIA_DOWNLOAD_PROGRESS_INTERVAL: Duration = Duration::from_millis(100);
const STICKER_PREFETCH_CONCURRENCY: usize = 4;
const STICKER_PREFETCH_DOWNLOAD_BYTES: usize = MAX_STICKER_CACHE_BYTES;
const SONAR_DIRECT_DM_DESCRIPTION: &str = "sonar.direct-dm.v1";

/// Shared HTTP client for Blossom media downloads. Built once so every blob
/// reuses keep-alive connections + the TLS session cache instead of paying a
/// fresh connect + handshake per download (the White Noise reference client
/// keeps a single static client for exactly this reason).
static HTTP_CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(60))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new())
});

/// Download raw bytes for an encrypted media blob by its full imeta URL.
///
/// Hardening (the URL is attacker-controllable — it is whatever the message
/// sender put in the imeta tag): require **https** (no SSRF to plaintext/local
/// schemes) and stream with a hard size cap (no memory-DoS from a server that
/// lies about / omits Content-Length). Integrity is still verified afterwards by
/// `decrypt_from_download` (AEAD + original-hash check).
/// Host-facing progress/cancellation hook for an attachment transfer. The
/// callback must be cheap: downloads invoke it from a Rust runtime worker.
pub trait MediaDownloadObserver: Send + Sync {
    fn on_progress(&self, bytes_received: u64, total_bytes: Option<u64>);
    fn is_cancelled(&self) -> bool;
}

fn media_download_cancelled(observer: Option<&dyn MediaDownloadObserver>) -> bool {
    observer.is_some_and(MediaDownloadObserver::is_cancelled)
}

#[cfg(test)]
async fn http_get(url: &str, observer: Option<&dyn MediaDownloadObserver>) -> Result<Vec<u8>> {
    http_get_with_limit_observer(url, MAX_MEDIA_DOWNLOAD_BYTES, observer).await
}

async fn http_get_with_limit_observer(
    url: &str,
    max_bytes: usize,
    observer: Option<&dyn MediaDownloadObserver>,
) -> Result<Vec<u8>> {
    if media_download_cancelled(observer) {
        return Err(Error::MediaDownloadCancelled);
    }
    if !url.starts_with("https://") {
        return Err(Error::Http(format!("refusing non-https media url: {url}")));
    }
    let send = HTTP_CLIENT.get(url).send();
    tokio::pin!(send);
    let mut resp = loop {
        tokio::select! {
            result = &mut send => break result.map_err(|e| Error::Http(e.to_string()))?,
            _ = tokio::time::sleep(MEDIA_DOWNLOAD_CANCEL_POLL) => {
                if media_download_cancelled(observer) {
                    return Err(Error::MediaDownloadCancelled);
                }
            }
        }
    };
    if !resp.status().is_success() {
        return Err(Error::Http(format!("GET {url} -> HTTP {}", resp.status())));
    }
    let total = resp.content_length();
    if let Some(len) = total {
        if len > max_bytes as u64 {
            return Err(Error::Http(format!(
                "media too large: {len} bytes (cap {max_bytes})"
            )));
        }
    }
    if let Some(observer) = observer {
        observer.on_progress(0, total);
    }
    let mut out: Vec<u8> = Vec::new();
    let mut last_progress = Instant::now();
    loop {
        let chunk = loop {
            let next = resp.chunk();
            tokio::pin!(next);
            tokio::select! {
                result = &mut next => break result.map_err(|e| Error::Http(e.to_string()))?,
                _ = tokio::time::sleep(MEDIA_DOWNLOAD_CANCEL_POLL) => {
                    if media_download_cancelled(observer) {
                        return Err(Error::MediaDownloadCancelled);
                    }
                }
            }
        };
        let Some(chunk) = chunk else { break };
        if chunk.len() > max_bytes.saturating_sub(out.len()) {
            return Err(Error::Http("media exceeds size cap".into()));
        }
        out.extend_from_slice(&chunk);
        if let Some(observer) = observer {
            let finished = total.is_some_and(|expected| out.len() as u64 >= expected);
            if finished || last_progress.elapsed() >= MEDIA_DOWNLOAD_PROGRESS_INTERVAL {
                observer.on_progress(out.len() as u64, total);
                last_progress = Instant::now();
            }
        }
    }
    if let Some(observer) = observer {
        observer.on_progress(out.len() as u64, total.or(Some(out.len() as u64)));
    }
    Ok(out)
}

/// Download public bytes from an HTTPS URL (for plaintext sticker images).
pub async fn http_get_public(url: &str) -> Result<Vec<u8>> {
    http_get_with_retries(url, None).await
}

#[derive(Clone, Debug)]
struct StickerImageFetchOutcome {
    bytes: Vec<u8>,
    source: &'static str,
    cache_read_us: u64,
    download_us: u64,
    verify_us: u64,
    cache_write_us: u64,
}

async fn fetch_sticker_image_with_cache(
    sticker_cache: &StickerCache,
    url: &str,
    expected_sha256: &str,
    max_download_bytes: usize,
) -> Result<StickerImageFetchOutcome> {
    let expected = expected_sha256.to_ascii_lowercase();
    validate_sha256_hex(&expected).map_err(|e| Error::Http(format!("bad sticker sha256: {e}")))?;
    let cache_started = Instant::now();
    match sticker_cache.read(&expected) {
        Ok(Some(cached)) => {
            return Ok(StickerImageFetchOutcome {
                bytes: cached,
                source: "disk",
                cache_read_us: cache_started.elapsed().as_micros() as u64,
                download_us: 0,
                verify_us: 0,
                cache_write_us: 0,
            });
        }
        Ok(None) => {}
        Err(err) => {
            tracing::debug!(%err, "sticker cache read failed; falling back to HTTPS");
        }
    }
    if !url.starts_with("https://") {
        return Err(Error::Http("sticker URL must be HTTPS".into()));
    }
    let download_started = Instant::now();
    let bytes = http_get_with_retries_limit(url, max_download_bytes).await?;
    let download_us = download_started.elapsed().as_micros() as u64;
    let verify_started = Instant::now();
    let actual = sha256_hex(&bytes);
    let verify_us = verify_started.elapsed().as_micros() as u64;
    if actual != expected {
        return Err(Error::Http(format!(
            "sticker image sha256 mismatch: expected {expected}, got {actual}"
        )));
    }
    let cache_write_started = Instant::now();
    match sticker_cache.write(&expected, &bytes) {
        Ok(false) => {
            return Err(Error::Storage("sticker cache session invalidated".into()));
        }
        Ok(true) => {}
        Err(err) => {
            // The cache is best-effort. Rendering verified bytes should still
            // succeed when storage is temporarily unavailable.
            tracing::debug!(%err, "sticker cache write failed");
        }
    }
    Ok(StickerImageFetchOutcome {
        bytes,
        source: "network",
        download_us,
        verify_us,
        cache_write_us: cache_write_started.elapsed().as_micros() as u64,
        cache_read_us: 0,
    })
}

#[derive(Clone, Debug)]
enum SharedStickerFetchError {
    InvalidInput(String),
    Storage(String),
    Http(String),
    RelayFetch(String),
    NoRelayConnected,
    Other(String),
}

impl SharedStickerFetchError {
    fn from_error(error: Error) -> Self {
        match error {
            Error::InvalidInput(message) => Self::InvalidInput(message),
            Error::Storage(message) => Self::Storage(message),
            Error::Http(message) => Self::Http(message),
            Error::RelayFetch(message) => Self::RelayFetch(message),
            Error::NoRelayConnected => Self::NoRelayConnected,
            other => Self::Other(other.to_string()),
        }
    }

    fn into_error(self) -> Error {
        match self {
            Self::InvalidInput(message) => Error::InvalidInput(message),
            Self::Storage(message) => Error::Storage(message),
            Self::Http(message) => Error::Http(message),
            Self::RelayFetch(message) => Error::RelayFetch(message),
            Self::NoRelayConnected => Error::NoRelayConnected,
            Self::Other(message) => Error::RelayFetch(message),
        }
    }
}

type SharedStickerFetchResult<T> = std::result::Result<Arc<T>, SharedStickerFetchError>;
type SharedStickerFetchFuture<T> = Shared<BoxFuture<'static, SharedStickerFetchResult<T>>>;
type SharedStickerFetchGates<T> =
    Arc<tokio::sync::Mutex<HashMap<String, Weak<SharedStickerFetchFuture<T>>>>>;

async fn shared_sticker_fetch<T, F>(
    gates: &SharedStickerFetchGates<T>,
    key: String,
    fetch: F,
) -> (Result<Arc<T>>, bool)
where
    T: Send + Sync + 'static,
    F: Future<Output = Result<T>> + Send + 'static,
{
    let (future, reused) = {
        let mut gates = gates.lock().await;
        if let Some(future) = gates.get(&key).and_then(Weak::upgrade) {
            (future, true)
        } else {
            // Weak values bound the table to requests that are actually in
            // flight. `Shared` lets every follower receive the same success or
            // error, including verified bytes that could not be persisted.
            gates.retain(|_, future| future.strong_count() > 0);
            let future = Arc::new(
                fetch
                    .map(|result| {
                        result
                            .map(Arc::new)
                            .map_err(SharedStickerFetchError::from_error)
                    })
                    .boxed()
                    .shared(),
            );
            gates.insert(key, Arc::downgrade(&future));
            (future, false)
        }
    };
    let result = future
        .as_ref()
        .clone()
        .await
        .map_err(SharedStickerFetchError::into_error);
    // The shared future retains its completed Arc result. Drop our future
    // handle before handing the result back so an uncontended caller can
    // recover the original buffer without a full allocation/copy.
    drop(future);
    (result, reused)
}

type StickerImageFetchGates = SharedStickerFetchGates<StickerImageFetchOutcome>;

#[derive(Clone, Debug)]
struct StickerPackFetchOutcome {
    pack: StickerPack,
    source: &'static str,
}

type StickerPackFetchGates = SharedStickerFetchGates<StickerPackFetchOutcome>;

#[derive(Debug)]
struct StickerPrefetchCancellation {
    cancelled: AtomicBool,
    notify: tokio::sync::Notify,
}

impl StickerPrefetchCancellation {
    fn new() -> Self {
        Self {
            cancelled: AtomicBool::new(false),
            notify: tokio::sync::Notify::new(),
        }
    }

    fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
        self.notify.notify_waiters();
    }

    fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    async fn cancelled(&self) {
        loop {
            let notified = self.notify.notified();
            if self.is_cancelled() {
                return;
            }
            notified.await;
        }
    }
}

type StickerPrefetchRegistry = Arc<Mutex<HashMap<String, Arc<StickerPrefetchCancellation>>>>;

struct StickerPrefetchRegistration {
    coordinate: String,
    cancellation: Arc<StickerPrefetchCancellation>,
    registry: StickerPrefetchRegistry,
}

impl Drop for StickerPrefetchRegistration {
    fn drop(&mut self) {
        if let Ok(mut registry) = self.registry.lock() {
            if registry
                .get(&self.coordinate)
                .is_some_and(|current| Arc::ptr_eq(current, &self.cancellation))
            {
                registry.remove(&self.coordinate);
            }
        }
    }
}

async fn fetch_sticker_pack_singleflight(
    gates: &StickerPackFetchGates,
    sticker_cache: &StickerCache,
    nostr: &Client,
    default_relays: &[RelayUrl],
    author_pubkey_hex: &str,
    identifier: &str,
    relay_urls: &[String],
    coordinate: &str,
) -> Result<(Arc<StickerPackFetchOutcome>, bool)> {
    let cache = sticker_cache.clone();
    let nostr = nostr.clone();
    let default_relays = default_relays.to_vec();
    let author_pubkey_hex = author_pubkey_hex.to_owned();
    let identifier = identifier.to_owned();
    let relay_urls = relay_urls.to_vec();
    let coordinate_owned = coordinate.to_owned();
    let mut source_relays = if relay_urls.is_empty() {
        default_relays.iter().map(ToString::to_string).collect()
    } else {
        relay_urls.to_vec()
    };
    source_relays.sort_unstable();
    source_relays.dedup();
    let fetch_key = format!("{}\0{}", coordinate, source_relays.join("\0"));
    let (result, reused) = shared_sticker_fetch(gates, fetch_key, async move {
        match SonarClient::fetch_sticker_pack_with_client(
            &nostr,
            &default_relays,
            &author_pubkey_hex,
            &identifier,
            &relay_urls,
        )
        .await
        {
            Ok(pack) => {
                match cache.remember_validated_pack(&pack) {
                    Ok(true) => {}
                    Ok(false) => {
                        return Err(Error::Storage("sticker cache session invalidated".into()));
                    }
                    Err(err) => tracing::debug!(
                        %err,
                        coordinate = %pack.address,
                        "sticker pack metadata cache write failed"
                    ),
                }
                Ok(StickerPackFetchOutcome {
                    pack,
                    source: "network",
                })
            }
            Err(network_err) => match cache.read_validated_pack(&coordinate_owned) {
                Ok(Some(pack)) => {
                    tracing::debug!(
                        err = %network_err,
                        coordinate = %coordinate_owned,
                        "sticker pack relay refresh failed; using validated local metadata"
                    );
                    Ok(StickerPackFetchOutcome {
                        pack,
                        source: "fallback_disk",
                    })
                }
                Ok(None) => Err(network_err),
                Err(cache_err) => {
                    tracing::debug!(
                        err = %cache_err,
                        coordinate = %coordinate_owned,
                        "sticker pack metadata fallback read failed"
                    );
                    Err(network_err)
                }
            },
        }
    })
    .await;
    Ok((result?, reused))
}

async fn fetch_sticker_image_singleflight(
    gates: &StickerImageFetchGates,
    sticker_cache: &StickerCache,
    url: &str,
    expected_sha256: &str,
    max_download_bytes: usize,
    purpose: &'static str,
) -> Result<Vec<u8>> {
    let started = Instant::now();
    let key = format!("{}\0{}", expected_sha256.to_ascii_lowercase(), url);
    let cache = sticker_cache.clone();
    let url = url.to_owned();
    let expected_sha256 = expected_sha256.to_owned();
    let (result, reused) = shared_sticker_fetch(gates, key, async move {
        fetch_sticker_image_with_cache(&cache, &url, &expected_sha256, max_download_bytes).await
    })
    .await;
    let shared_outcome = result?;
    let outcome =
        Arc::try_unwrap(shared_outcome).unwrap_or_else(|outcome| outcome.as_ref().clone());
    let StickerImageFetchOutcome {
        bytes,
        source,
        cache_read_us,
        download_us,
        verify_us,
        cache_write_us,
    } = outcome;
    if reused {
        tracing::debug!(
            purpose,
            source = "shared",
            bytes = bytes.len(),
            total_us = started.elapsed().as_micros() as u64,
            "SONAR_BENCH sticker_image_fetch"
        );
    } else if source == "disk" {
        tracing::debug!(
            purpose,
            source = "disk",
            bytes = bytes.len(),
            cache_read_us,
            total_us = started.elapsed().as_micros() as u64,
            "SONAR_BENCH sticker_image_fetch"
        );
    } else {
        tracing::debug!(
            purpose,
            source = "network",
            bytes = bytes.len(),
            download_us,
            verify_us,
            cache_write_us,
            total_us = started.elapsed().as_micros() as u64,
            "SONAR_BENCH sticker_image_fetch"
        );
    }
    Ok(bytes)
}

type StickerPrefetchTaskResult = (String, Result<Vec<u8>>);
type StickerPrefetchJoinResult =
    std::result::Result<StickerPrefetchTaskResult, tokio::task::JoinError>;

fn log_sticker_prefetch_result(outcome: Option<StickerPrefetchJoinResult>) -> (usize, usize) {
    match outcome {
        Some(Ok((url, Err(err)))) => {
            tracing::debug!(%err, %url, "sticker prefetch: image failed");
            (0, 1)
        }
        Some(Err(err)) => {
            tracing::debug!(%err, "sticker prefetch: image task failed");
            (0, 1)
        }
        Some(Ok((_, Ok(_)))) => (1, 0),
        None => (0, 0),
    }
}

async fn http_get_with_retries(
    url: &str,
    observer: Option<&dyn MediaDownloadObserver>,
) -> Result<Vec<u8>> {
    http_get_with_retries_limit_observer(url, MAX_MEDIA_DOWNLOAD_BYTES, observer).await
}

async fn http_get_with_retries_limit(url: &str, max_bytes: usize) -> Result<Vec<u8>> {
    http_get_with_retries_limit_observer(url, max_bytes, None).await
}

async fn http_get_with_retries_limit_observer(
    url: &str,
    max_bytes: usize,
    observer: Option<&dyn MediaDownloadObserver>,
) -> Result<Vec<u8>> {
    for attempt in 1..=MEDIA_DOWNLOAD_ATTEMPTS {
        match http_get_with_limit_observer(url, max_bytes, observer).await {
            Ok(bytes) => return Ok(bytes),
            Err(error)
                if attempt < MEDIA_DOWNLOAD_ATTEMPTS && retryable_media_http_error(&error) =>
            {
                tokio::select! {
                    _ = tokio::time::sleep(MEDIA_DOWNLOAD_RETRY_DELAY) => {}
                    _ = async {
                        while !media_download_cancelled(observer) {
                            tokio::time::sleep(MEDIA_DOWNLOAD_CANCEL_POLL).await;
                        }
                    } => return Err(Error::MediaDownloadCancelled),
                }
            }
            Err(error) => return Err(error),
        }
    }
    unreachable!("media download retry loop always returns");
}

fn retryable_media_http_error(error: &Error) -> bool {
    let Error::Http(message) = error else {
        return false;
    };
    if message.contains("refusing non-https")
        || message.contains("media too large")
        || message.contains("media exceeds size cap")
    {
        return false;
    }
    if message.contains("HTTP 4") && !message.contains("HTTP 408") && !message.contains("HTTP 429")
    {
        return false;
    }
    true
}

const FETCH_TIMEOUT: Duration = Duration::from_secs(10);

/// Extra lookback applied ONLY to the gift-wrap (welcome) `.since` filter.
/// NIP-59 deliberately backdates a gift wrap's `created_at` (up to ~2 days, we
/// use a comfortable margin) to defeat timing analysis, so a tight watermark
/// would silently miss a just-received welcome. Mirrors White Noise's
/// `GIFTWRAP_LOOKBACK_BUFFER`.
const GIFTWRAP_LOOKBACK_SECS: u64 = 7 * 24 * 60 * 60;

/// Safety overlap subtracted from the watermark on every incremental fetch, to
/// cover clock skew and events that landed on a relay mid-sync. Already-seen
/// events are tolerated (MDK dedups on processing), so a small overlap is free.
const SYNC_OVERLAP_SECS: u64 = 5 * 60;

/// Stable subscription ids for the live Marmot tail (so re-subscribing the
/// group filter REPLACES it rather than stacking new subscriptions).
const SUB_MARMOT_WELCOMES: &str = "sonar-marmot-welcomes";
const SUB_MARMOT_GROUPS: &str = "sonar-marmot-groups";

/// Hard cap on the live Marmot event buffer. The handler pushes here while the
/// host drains via `drain_pending_marmot`; if a host has not wired draining yet
/// (e.g. a platform still on the poll path), this bounds memory — dropped live
/// events are recovered by the watermarked `sync()` safety net, so capping never
/// loses a message permanently. When full, the oldest half is dropped (amortizes
/// the shift cost vs dropping one-at-a-time).
/// Combined live buffer budget. Split so giftwrap floods cannot wipe group
/// commits and vice versa (P1).
const MARMOT_GROUP_BUFFER_CAP: usize = 768;
const MARMOT_GIFTWRAP_BUFFER_CAP: usize = 512;
#[allow(dead_code)]
const MARMOT_BUFFER_CAP: usize = MARMOT_GROUP_BUFFER_CAP + MARMOT_GIFTWRAP_BUFFER_CAP;
const DIRECT_DM_BUFFER_CAP: usize = 1024;
const LIVE_EVENT_DEDUP_TTL: Duration = Duration::from_secs(60);
const LIVE_EVENT_DEDUP_CAP: usize = 4096;

/// Live kind-445 subscription tail. Historical recovery is owned by the
/// per-group catch-up queue; the live sub must stay thin so cold start does
/// not flood the pending buffer (and steal CPU/network from sends).
const LIVE_GROUP_TAIL_SECS: u64 = 30 * 60;

/// Compute the live kind-445 `since` floor.
///
/// - watermark 0 (first session): still bound by the live tail so cold start
///   does not open an unbounded historical flood.
/// - otherwise: max(watermark - overlap, now - live_tail).
fn live_group_since_secs(watermark_secs: u64, now_secs: u64) -> u64 {
    let live_floor = now_secs.saturating_sub(LIVE_GROUP_TAIL_SECS);
    if watermark_secs == 0 {
        live_floor
    } else {
        watermark_secs
            .saturating_sub(SYNC_OVERLAP_SECS)
            .max(live_floor)
    }
}

/// Push into a live buffer with half-drop overflow. Returns true if a drop ran.
fn push_live_buffer<T>(buf: &mut Vec<T>, item: T, cap: usize) -> bool {
    let mut dropped = false;
    if buf.len() >= cap {
        let n = (cap / 2).max(1);
        buf.drain(0..n.min(buf.len()));
        dropped = true;
    }
    buf.push(item);
    dropped
}

fn take_catchup_entry(
    queue: &mut VecDeque<(String, u64)>,
    preferred: Option<&str>,
) -> Option<(String, u64)> {
    if let Some(pref) = preferred {
        if let Some(idx) = queue.iter().position(|(id, _)| id == pref) {
            return queue.remove(idx);
        }
    }
    queue.pop_front()
}

#[cfg(test)]
fn map_mls_hex_to_nostr_hex(mls_hex: &str, pairs: &[(String, String)]) -> Option<String> {
    let clean = mls_hex.trim().to_ascii_lowercase();
    if clean.is_empty() {
        return None;
    }
    pairs
        .iter()
        .find(|(mls, _)| mls == &clean)
        .map(|(_, nostr)| nostr.clone())
}

/// Minimum number of relays that must be connected before `connect()` returns.
/// Modeled after whitenoise-rs `min_connected_relays = 2`. A quorum of 2
/// means the client can send and fetch immediately; the remaining relays
/// finish connecting in the background.
const MIN_CONNECTED_RELAYS: usize = 2;

/// Per-relay connection timeout used by the quorum-connect loop. If no relay
/// connects within this window the client errors with `NoRelayConnections`.
const RELAY_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// Relay EOSE/fetch completion quorum. Keep this aligned with the connection
/// quorum so slow relays do not hold background sync or push processing open.
const RELAY_FETCH_QUORUM: usize = MIN_CONNECTED_RELAYS;

fn relay_fetch_quorum(total_relays: usize) -> usize {
    if total_relays == 0 {
        0
    } else {
        RELAY_FETCH_QUORUM.min(total_relays).max(1)
    }
}

/// Whether a push-token share pass should run given how many relays are
/// currently connected. The share sends a gift-wrapped DM per group member
/// through the nostr client, which fails with "no relays specified" when no
/// relay is live. Since the share re-runs on every sync/wake, skipping while
/// disconnected costs nothing and avoids one logged failure per recipient.
fn should_share_push_tokens(connected_relays: usize) -> bool {
    connected_relays > 0
}

fn parse_mesh_id8_hex(value: &str, label: &'static str) -> Result<[u8; 8]> {
    let bytes = hex::decode(value.trim())
        .map_err(|e| Error::InvalidInput(format!("{label} must be 8-byte hex: {e}")))?;
    if bytes.len() != 8 {
        return Err(Error::InvalidInput(format!("{label} must be 8 bytes")));
    }
    let mut out = [0u8; 8];
    out.copy_from_slice(&bytes);
    Ok(out)
}

fn parse_optional_mesh_id8_hex(value: &str, label: &'static str) -> Result<Option<[u8; 8]>> {
    let clean = value.trim();
    if clean.is_empty() {
        return Ok(None);
    }
    parse_mesh_id8_hex(clean, label).map(Some)
}

/// Shorter timeout for backfill fetches (new group from welcome, empty
/// transcript repair). These are less critical than the main sync fetch — the
/// live tail covers new events, so a short timeout is acceptable.
const BACKFILL_TIMEOUT: Duration = Duration::from_secs(3);

/// Cap the number of groups backfilled per sync cycle. Prevents pathological
/// cases with dozens of empty-transcript groups from stacking serial timeouts.
/// Excess groups are re-queued for the next sync.
const MAX_BACKFILLS_PER_SYNC: usize = 8;

const SYNC_STATE_VERSION: u32 = 1;
const SYNC_STATE_PROCESSED_EVENT_CAP: usize = 20_000;

#[derive(Debug)]
struct LiveEventDeduper {
    ttl: Duration,
    capacity: usize,
    seen_at: HashMap<EventId, Instant>,
    order: VecDeque<EventId>,
}

impl LiveEventDeduper {
    fn new(ttl: Duration, capacity: usize) -> Self {
        Self {
            ttl,
            capacity: capacity.max(1),
            seen_at: HashMap::new(),
            order: VecDeque::new(),
        }
    }

    fn should_accept(&mut self, event_id: &EventId, now: Instant) -> bool {
        self.prune_expired(now);

        if self.seen_at.contains_key(event_id) {
            return false;
        }

        let event_id = *event_id;
        self.seen_at.insert(event_id, now);
        self.order.push_back(event_id);
        self.prune_overflow();
        true
    }

    fn prune_expired(&mut self, now: Instant) {
        loop {
            let Some(event_id) = self.order.front() else {
                return;
            };
            let Some(first_seen) = self.seen_at.get(event_id).copied() else {
                self.order.pop_front();
                continue;
            };
            if now.duration_since(first_seen) < self.ttl {
                return;
            }
            let event_id = self.order.pop_front().expect("front exists");
            self.seen_at.remove(&event_id);
        }
    }

    fn prune_overflow(&mut self) {
        while self.seen_at.len() > self.capacity {
            let Some(event_id) = self.order.pop_front() else {
                return;
            };
            self.seen_at.remove(&event_id);
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct SyncStateDisk {
    version: u32,
    watermark_secs: u64,
    processed_event_ids: Vec<String>,
}

/// Point-in-time relay/sync diagnostics, serialized into the exported debug
/// bundle (`snapshot.json`) and rendered on the Diagnostics screen. Must never
/// carry message content or key material.
#[derive(Clone, Debug, Serialize)]
pub struct SyncStateSnapshot {
    pub generated_at_secs: u64,
    pub watermark_secs: u64,
    pub live_marmot_enabled: bool,
    pub subscribed_group_count: usize,
    pub pending_marmot_buffered: usize,
    /// Outbox publishes currently in flight (P0 send-priority signal).
    pub send_inflight: usize,
    /// Cumulative live-buffer half-drops (giftwraps + group messages).
    pub buffer_drops_total: usize,
    /// Groups still queued for initial historical catch-up.
    pub catchup_queue_len: usize,
    pub relays: Vec<RelaySnapshot>,
    pub group_floors: Vec<GroupFloorSnapshot>,
}

/// One relay's connection state as reported by the nostr-sdk pool.
#[derive(Clone, Debug, Serialize)]
pub struct RelaySnapshot {
    pub url: String,
    pub status: String,
}

/// Per-group relay catch-up floor: the newest peer-authored message stored
/// locally, i.e. where a missing-message resync for that chat would start.
#[derive(Clone, Debug, Serialize)]
pub struct GroupFloorSnapshot {
    pub group_id_hex: String,
    pub floor_secs: u64,
}

#[derive(Debug)]
struct SyncState {
    path: Option<PathBuf>,
    watermark_secs: u64,
    processed_event_ids: HashSet<String>,
    processed_event_order: VecDeque<String>,
    dirty: bool,
}

impl SyncState {
    fn load(path: Option<PathBuf>, fallback_watermark_secs: u64, storage_empty: bool) -> Self {
        if storage_empty {
            return Self::new(path, 0, Vec::new());
        }

        let disk = path
            .as_ref()
            .and_then(|path| fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice::<SyncStateDisk>(&bytes).ok())
            .filter(|state| state.version == SYNC_STATE_VERSION);

        let (disk_watermark, processed_event_ids) = disk
            .map(|state| (state.watermark_secs, state.processed_event_ids))
            .unwrap_or((0, Vec::new()));
        let watermark_secs = conservative_watermark(disk_watermark, fallback_watermark_secs);

        Self::new(path, watermark_secs, processed_event_ids)
    }

    fn new(path: Option<PathBuf>, watermark_secs: u64, processed_event_ids: Vec<String>) -> Self {
        let mut state = Self {
            path,
            watermark_secs,
            processed_event_ids: HashSet::new(),
            processed_event_order: VecDeque::new(),
            dirty: false,
        };
        for id in processed_event_ids {
            state.mark_processed_id(id);
        }
        state.dirty = false;
        state
    }

    fn watermark_secs(&self) -> u64 {
        self.watermark_secs
    }

    fn has_processed(&self, event_id: &str) -> bool {
        self.processed_event_ids.contains(event_id)
    }

    fn mark_processed(&mut self, event_id: &EventId) {
        self.mark_processed_id(event_id.to_hex());
    }

    fn mark_processed_id(&mut self, event_id: String) {
        if !self.processed_event_ids.insert(event_id.clone()) {
            return;
        }
        self.processed_event_order.push_back(event_id);
        while self.processed_event_order.len() > SYNC_STATE_PROCESSED_EVENT_CAP {
            if let Some(oldest) = self.processed_event_order.pop_front() {
                self.processed_event_ids.remove(&oldest);
            }
        }
        self.dirty = true;
    }

    fn advance_watermark(&mut self, watermark_secs: u64) {
        if watermark_secs > self.watermark_secs {
            tracing::info!(
                from = self.watermark_secs,
                to = watermark_secs,
                "sync watermark advanced"
            );
            self.watermark_secs = watermark_secs;
            self.dirty = true;
        }
    }

    fn rewind_for_retry(&mut self, event_secs: u64) {
        if self.watermark_secs == 0 {
            return;
        }
        let retry_from = event_secs.saturating_sub(SYNC_OVERLAP_SECS);
        if retry_from < self.watermark_secs {
            tracing::warn!(
                from = self.watermark_secs,
                to = retry_from,
                "sync watermark rewound for retry"
            );
            self.watermark_secs = retry_from;
            self.dirty = true;
        }
    }

    fn save_if_dirty(&mut self) -> Result<()> {
        if !self.dirty {
            return Ok(());
        }
        let Some(path) = self.path.as_ref() else {
            self.dirty = false;
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| {
                Error::Storage(format!("create sync-state dir {}: {e}", parent.display()))
            })?;
        }
        let disk = SyncStateDisk {
            version: SYNC_STATE_VERSION,
            watermark_secs: self.watermark_secs,
            processed_event_ids: self.processed_event_order.iter().cloned().collect(),
        };
        let bytes = serde_json::to_vec(&disk)?;
        let tmp = sync_state_tmp_path(path);
        fs::write(&tmp, bytes)
            .map_err(|e| Error::Storage(format!("write sync state {}: {e}", tmp.display())))?;
        fs::rename(&tmp, path)
            .map_err(|e| Error::Storage(format!("replace sync state {}: {e}", path.display())))?;
        self.dirty = false;
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct MarmotProcessReport {
    processed: usize,
    retryable_failures: usize,
    oldest_retryable_secs: Option<u64>,
}

impl MarmotProcessReport {
    fn record_processed(&mut self) {
        self.processed += 1;
    }

    fn record_retryable(&mut self, event_secs: u64) {
        self.retryable_failures += 1;
        self.oldest_retryable_secs = Some(
            self.oldest_retryable_secs
                .map_or(event_secs, |oldest| oldest.min(event_secs)),
        );
    }

    fn absorb(&mut self, other: Self) {
        self.processed += other.processed;
        self.retryable_failures += other.retryable_failures;
        if let Some(secs) = other.oldest_retryable_secs {
            self.oldest_retryable_secs = Some(
                self.oldest_retryable_secs
                    .map_or(secs, |oldest| oldest.min(secs)),
            );
        }
    }
}

#[derive(Debug)]
struct RelayFetchOutcome {
    events: Vec<Event>,
    completed_relays: usize,
    total_relays: usize,
}

impl RelayFetchOutcome {
    /// True when enough relays answered to treat the fetch as complete.
    ///
    /// The bar is the fetch quorum, NOT all relays: the fetch loop stops
    /// waiting once the quorum answers (late relays stream into the pending
    /// buffer), so with more relays than the quorum an all-relays bar can
    /// never be met — every sync would be marked retryable, the watermark
    /// would never advance, and one permanently-dead relay in the list would
    /// requeue per-group catch-ups forever.
    fn completed_quorum(&self) -> bool {
        self.completed_relays >= relay_fetch_quorum(self.total_relays)
    }
}

/// Info about an incoming message discovered during drain, used by hosts to
/// fire rich local notifications (sender name + preview).
#[derive(Clone, Debug)]
pub struct DrainNotification {
    pub sender_pubkey: String,
    pub group_name: String,
    pub content_preview: String,
}

/// One received geohash channel event (ephemeral kind-20000), buffered from the
/// live subscription. Geohash channels are public ephemeral events — relays do
/// NOT store them, so we accumulate them in memory as the subscription delivers.
struct RawGeo {
    id: String,
    pubkey: PublicKey,
    nickname: String,
    content: String,
    ts: u64,
}

/// One received geohash 1:1 DM (NIP-17 over the per-geohash identity).
struct RawGeoDm {
    id: String,
    sender: PublicKey,
    content: String,
    ts: u64,
    mine: bool,
}

type GeoDmBuf = Arc<Mutex<HashMap<(String, String), Vec<RawGeoDm>>>>;

/// One received account-level 1:1 DM (NIP-17 over the main Sonar/bitchat
/// identity). The rumor content is a `bitchat1:` embedded private-message
/// packet, matching iOS plain bitchat fallback.
struct RawDirectDm {
    event_id: String,
    id: String,
    sender: PublicKey,
    content: String,
    ts: u64,
}

type DirectDmBuf = Arc<Mutex<Vec<RawDirectDm>>>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DirectDm {
    pub event_id: String,
    pub id: String,
    pub sender_pubkey: String,
    pub content: String,
    pub created_at: u64,
}

/// Live presence (kind-20001) per geohash channel: participant pubkey hex →
/// last-seen unix seconds. Presence events are ephemeral heartbeats, so we keep
/// only the most recent timestamp per participant and count those still within
/// the TTL when reporting "N here now".
type GeoPresenceBuf = Arc<Mutex<HashMap<String, HashMap<String, u64>>>>;

/// How long a presence heartbeat keeps a participant counted as "here now".
/// iOS re-broadcasts kind-20001 every 40-80s, well within this window.
const PRESENCE_TTL_SECS: u64 = 300;

/// A user's public Nostr profile (kind-0 metadata, NIP-01). Marmot identity IS
/// a Nostr pubkey (MIP-00), and MIP-00 leaves display names out of scope, so the
/// standard Nostr profile mechanism resolves a member's human-readable name and
/// avatar. All fields are optional (a peer may not have published a profile).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Profile {
    pub name: Option<String>,
    pub display_name: Option<String>,
    pub about: Option<String>,
    pub picture: Option<String>,
    pub nip05: Option<String>,
}

impl Profile {
    /// The best human-readable label: display_name, else name, else None.
    pub fn best_name(&self) -> Option<&str> {
        self.display_name
            .as_deref()
            .filter(|s| !s.trim().is_empty())
            .or_else(|| self.name.as_deref().filter(|s| !s.trim().is_empty()))
    }
}

pub struct SonarClient {
    engine: MarmotEngine,
    nostr: Client,
    relays: Vec<RelayUrl>,
    geo: Arc<Mutex<HashMap<String, Vec<RawGeo>>>>,
    geo_dm: GeoDmBuf,
    direct_dm: DirectDmBuf,
    geo_presence: GeoPresenceBuf,
    geo_subscribed: Arc<Mutex<HashSet<String>>>,
    identity_secret: [u8; 32],
    /// Durable relay sync cursor plus recently processed event IDs. This keeps
    /// restart catch-up conservative: a failed event can be replayed later
    /// instead of being skipped by an advanced watermark.
    sync_state: Arc<Mutex<SyncState>>,
    /// Durable local delivery metadata for Signal-style outgoing text sends.
    /// The actual decrypted message body stays in MDK storage; this sidecar
    /// records pending/sent/failed state and the encrypted relay event to retry.
    outbox_state: Arc<Mutex<OutboxState>>,
    /// Live giftwraps (1059→us) buffered by the notification handler.
    pending_marmot_giftwraps: Arc<Mutex<Vec<Event>>>,
    /// Live MLS group messages (kind 445) buffered by the notification handler.
    /// Split from giftwraps so one flood cannot wipe the other (P1).
    pending_marmot_groups: Arc<Mutex<Vec<Event>>>,
    /// Fired whenever a live Marmot event is buffered, so `wait_for_marmot_event`
    /// wakes the host to drain in real time (push) instead of polling.
    marmot_notify: Arc<tokio::sync::Notify>,
    /// Count of outbox publish tasks in flight. Historical catch-up yields while
    /// this is non-zero so user sends keep relay/runtime priority (P0).
    send_inflight: Arc<AtomicUsize>,
    /// Excludes sends from OUR in-flight membership changes. A membership flow
    /// (add/remove/leave/auto-commit) holds write from commit creation through
    /// publish+merge; send paths hold read around encrypt+local-write, so a
    /// message can never be encrypted at a pre-removal epoch while our own
    /// removal commit is on the wire. Deliberately client-wide, not per-group:
    /// membership changes are rare and the write window is bounded by the
    /// relay publish. (Incoming membership commits from OTHERS are inherently
    /// racy with sends across the network and are not gated.)
    membership_gate: Arc<tokio::sync::RwLock<()>>,
    /// How many times the live pending buffer dropped its oldest half.
    buffer_drops_total: Arc<AtomicUsize>,
    /// True after the real-session Marmot live tail is opened. Local group
    /// changes use this to decide whether to refresh the live kind-445 filter.
    live_marmot_enabled: Arc<Mutex<bool>>,
    /// The group-id set currently installed in the live kind-445 subscription.
    /// This prevents stacking duplicate REQs and lets deletes narrow/unsubscribe.
    marmot_group_subscriptions: Arc<Mutex<HashSet<String>>>,
    /// Startup repair queue for existing groups whose local DB has MLS/group
    /// state but no chat-message page. This covers older installs where the
    /// sync watermark could be advanced by membership/commit events before the
    /// transcript body was locally populated.
    initial_empty_transcript_backfills: Arc<Mutex<HashSet<String>>>,
    initial_backfill_scanned: Arc<AtomicBool>,
    /// Startup repair queue for existing groups that already have transcript
    /// rows. Each entry is the per-group relay fetch floor derived from the
    /// latest locally stored peer-authored chat message, so one chat's newer
    /// activity cannot hide another chat's missing Marmot messages. The queue is
    /// drained FIFO, one group per background sync/self-heal pass, to keep
    /// repair work bounded and avoid one flaky chat starving the rest.
    initial_group_message_catchups: Arc<Mutex<VecDeque<(String, u64)>>>,
    initial_group_message_catchup_scanned: Arc<AtomicBool>,
    /// Host can mark the open conversation so cold-start catch-up services it first.
    preferred_catchup_group: Arc<Mutex<Option<String>>>,
    /// Rate-limit ensure_subscriptions welcome/group resubscribes (P2 churn).
    last_ensure_subscriptions_at: Arc<Mutex<Option<Instant>>>,
    /// Whether to join geohash-nearest relays on subscribe (real sessions); off
    /// for in-memory/test sessions so they stay network-free against a MockRelay.
    allow_geo_relays: bool,
    /// Persistent conversation-summary index (None for in-memory sessions).
    conversation_index: Option<Arc<Mutex<ConversationIndex>>>,
    /// Host-registered callback fired when a conversation summary changes.
    change_listener: Arc<Mutex<Option<Arc<dyn ConversationChangeListener>>>>,
    /// In-memory store for invite link secrets and pending join requests.
    invite_links: Arc<crate::invite_link::InviteLinkStore>,
    /// Cached push tokens for group members (pubkey hex → encrypted token).
    push_token_cache: PushTokenCache,
    /// Durable path for cached member push tokens (None for in-memory tests).
    push_token_cache_path: Option<PathBuf>,
    /// Directory for content-addressed sticker image bytes (None for in-memory tests).
    sticker_cache: StickerCache,
    /// Per-pack and per-image single-flight gates shared by foreground and
    /// prefetch paths. These are process-local; durable results live in
    /// `sticker_cache` and remain identical across every host platform.
    sticker_pack_fetch_gates: StickerPackFetchGates,
    sticker_image_fetch_gates: StickerImageFetchGates,
    /// Per-coordinate install prefetch cancellation. Uninstall cancels the
    /// matching task immediately; the cache generation separately cancels all
    /// old-session tasks during identity wipe.
    sticker_prefetch_registry: StickerPrefetchRegistry,
    /// This device's own push registration (set after `register_push_token`).
    own_push_registration: Arc<Mutex<Option<crate::push::OwnPushRegistration>>>,
}

impl SonarClient {
    /// Connect an identity to the given relays with a persistent, encrypted
    /// SQLCipher store at `db_path`.
    ///
    /// `db_key` is the 32-byte SQLCipher key, owned by the host (Keychain on
    /// iOS). The parent directory of `db_path` must already exist. Marmot state
    /// (groups, messages, MLS secrets) survives process restarts: reconnecting
    /// at the same path with the same key reopens the same database.
    pub async fn connect(
        identity: Identity,
        relays: Vec<RelayUrl>,
        db_path: impl AsRef<Path>,
        db_key: [u8; 32],
    ) -> Result<Self> {
        let db_path = db_path.as_ref();
        let engine = MarmotEngine::persistent(identity.clone(), db_path, db_key)?;
        let index_path = index_db_path_for_db(db_path);
        let index = match ConversationIndex::open(&index_path, db_key) {
            Ok(idx) => Some(idx),
            Err(err) => {
                tracing::warn!(%err, "conversation index open failed; continuing without");
                None
            }
        };
        let mut client = Self::with_engine(
            identity,
            relays,
            engine,
            true,
            Some(sync_state_path_for_db(db_path)),
            Some(outbox_state_path_for_db(db_path)),
            Some(invite_link_state_path_for_db(db_path)),
            Some(push_token_cache_path_for_db(db_path)),
            StickerCache::for_db(db_path)?,
            index.map(|idx| Arc::new(Mutex::new(idx))),
        )
        .await?;
        client.materialize_index_if_empty();
        Ok(client)
    }

    /// Connect with a volatile in-memory store. State is lost when the client is
    /// dropped. Intended for tests and ephemeral/anonymous sessions.
    pub async fn connect_in_memory(identity: Identity, relays: Vec<RelayUrl>) -> Result<Self> {
        let engine = MarmotEngine::in_memory(identity.clone());
        Self::with_engine(
            identity,
            relays,
            engine,
            false,
            None,
            None,
            None,
            None,
            StickerCache::disabled(),
            None,
        )
        .await
    }

    async fn with_engine(
        identity: Identity,
        relays: Vec<RelayUrl>,
        engine: MarmotEngine,
        allow_geo_relays: bool,
        sync_state_path: Option<PathBuf>,
        outbox_state_path: Option<PathBuf>,
        invite_link_state_path: Option<PathBuf>,
        push_token_cache_path: Option<PathBuf>,
        sticker_cache: StickerCache,
        conversation_index: Option<Arc<Mutex<ConversationIndex>>>,
    ) -> Result<Self> {
        let boot_start = std::time::Instant::now();
        let nostr = Client::new(identity.keys().clone());
        for relay in &relays {
            nostr.add_relay(relay.clone()).await?;
        }
        tracing::info!(
            elapsed_ms = boot_start.elapsed().as_millis() as u64,
            relay_count = relays.len(),
            "relays added"
        );

        // Quorum-connect: spawn background tasks for all relays, then race
        // their connection futures and return once MIN_CONNECTED_RELAYS are
        // live. Mirrors whitenoise-rs `prepare_relay_urls` which uses
        // FuturesUnordered and returns at the quorum threshold.
        nostr.connect().await;
        let quorum = MIN_CONNECTED_RELAYS.min(relays.len());
        if quorum > 0 {
            let relay_handles: Vec<_> = {
                let map = nostr.relays().await;
                relays
                    .iter()
                    .filter_map(|url| map.get(url).cloned().map(|handle| (url.clone(), handle)))
                    .collect()
            };
            let (tx, mut rx) = tokio::sync::mpsc::channel::<()>(relay_handles.len().max(1));
            for (url, handle) in relay_handles {
                let tx = tx.clone();
                let timeout = RELAY_CONNECT_TIMEOUT;
                tokio::spawn(async move {
                    handle.wait_for_connection(timeout).await;
                    if handle.status() == RelayStatus::Connected {
                        tracing::info!(relay = %url, "relay connected");
                        let _ = tx.send(()).await;
                    } else {
                        tracing::warn!(
                            relay = %url,
                            status = ?handle.status(),
                            "relay not connected after timeout"
                        );
                    }
                });
            }
            drop(tx);
            let mut connected = 0usize;
            let deadline = tokio::time::Instant::now() + RELAY_CONNECT_TIMEOUT;
            loop {
                let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero() {
                    break;
                }
                match tokio::time::timeout(remaining, rx.recv()).await {
                    Ok(Some(())) => {
                        connected += 1;
                        if connected >= quorum {
                            break;
                        }
                    }
                    _ => break,
                }
            }
            if connected == 0 {
                return Err(crate::Error::NoRelayConnected);
            }
            if connected < quorum {
                tracing::warn!(
                    connected,
                    quorum,
                    "relay quorum NOT reached before timeout — continuing degraded"
                );
            }
            tracing::info!(
                connected,
                total = relays.len(),
                elapsed_ms = boot_start.elapsed().as_millis() as u64,
                "relay quorum reached"
            );
        }

        // Background collector for geohash channel events (kind-20000, public,
        // ephemeral) and geohash 1:1 DMs (kind-1059 NIP-17 gift wraps). Both are
        // delivered live to active subscriptions; relays don't store them.
        let geo: Arc<Mutex<HashMap<String, Vec<RawGeo>>>> = Arc::new(Mutex::new(HashMap::new()));
        let geo_dm: GeoDmBuf = Arc::new(Mutex::new(HashMap::new()));
        let direct_dm: DirectDmBuf = Arc::new(Mutex::new(Vec::new()));
        let geo_presence: GeoPresenceBuf = Arc::new(Mutex::new(HashMap::new()));
        let geo_subscribed: Arc<Mutex<HashSet<String>>> = Arc::new(Mutex::new(HashSet::new()));
        let identity_secret = identity.keys().secret_key().to_secret_bytes();

        let pending_marmot_giftwraps: Arc<Mutex<Vec<Event>>> = Arc::new(Mutex::new(Vec::new()));
        let pending_marmot_groups: Arc<Mutex<Vec<Event>>> = Arc::new(Mutex::new(Vec::new()));
        let marmot_notify = Arc::new(tokio::sync::Notify::new());
        let send_inflight = Arc::new(AtomicUsize::new(0));
        let membership_gate = Arc::new(tokio::sync::RwLock::new(()));
        let buffer_drops_total = Arc::new(AtomicUsize::new(0));
        let live_marmot_enabled = Arc::new(Mutex::new(false));
        let marmot_group_subscriptions = Arc::new(Mutex::new(HashSet::new()));
        let initial_empty_transcript_backfills = Arc::new(Mutex::new(HashSet::new()));
        let initial_backfill_scanned = Arc::new(AtomicBool::new(false));
        let initial_group_message_catchups = Arc::new(Mutex::new(VecDeque::new()));
        let initial_group_message_catchup_scanned = Arc::new(AtomicBool::new(false));
        let preferred_catchup_group = Arc::new(Mutex::new(None));
        let last_ensure_subscriptions_at = Arc::new(Mutex::new(None));
        let push_token_cache = crate::push::load_push_token_cache(push_token_cache_path.as_deref());

        let handler_geo = geo.clone();
        let handler_dm = geo_dm.clone();
        let handler_presence = geo_presence.clone();
        let handler_subs = geo_subscribed.clone();
        let handler_giftwraps = pending_marmot_giftwraps.clone();
        let handler_groups = pending_marmot_groups.clone();
        let handler_notify = marmot_notify.clone();
        let handler_buffer_drops = buffer_drops_total.clone();
        // Our MAIN identity pubkey hex: a kind-1059 with this `p` tag is a Marmot
        // welcome (vs a geohash DM, whose `p` is a per-geohash ephemeral key).
        let my_pubkey_hex = identity.keys().public_key().to_hex();
        let mut notifications = nostr.notifications();
        tokio::spawn(async move {
            let mut live_dedup = LiveEventDeduper::new(LIVE_EVENT_DEDUP_TTL, LIVE_EVENT_DEDUP_CAP);
            loop {
                let notification = match notifications.recv().await {
                    Ok(n) => n,
                    // The notification stream is a BOUNDED tokio broadcast. A busy
                    // channel (e.g. a whole-country region geohash with many
                    // people broadcasting presence + messages) can make us fall
                    // behind: `Lagged` means some events were dropped — keep
                    // going, do NOT exit. The old `while let Ok` killed the
                    // collector permanently on the first lag, so Android stopped
                    // seeing ANY participants/messages while iOS (no such loop)
                    // kept working.
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                };
                let event = match notification {
                    RelayPoolNotification::Event { event, .. } => event,
                    // EOSE marks the end of a subscription's stored-history
                    // burst — the key signal when diagnosing "old messages
                    // not syncing" from an exported debug bundle.
                    RelayPoolNotification::Message {
                        relay_url,
                        message: RelayMessage::EndOfStoredEvents(subscription_id),
                    } => {
                        tracing::info!(
                            relay = %relay_url,
                            subscription = %subscription_id,
                            "relay EOSE"
                        );
                        continue;
                    }
                    _ => continue,
                };
                let kind = event.kind.as_u16();
                if !matches!(kind, 20000 | 20001 | 1059 | 445) {
                    continue;
                }
                if !live_dedup.should_accept(&event.id, Instant::now()) {
                    continue;
                }

                match kind {
                    20000 => {
                        let Some(geohash) = tag_value(&event, Alphabet::G) else {
                            continue;
                        };
                        let nickname = tag_value(&event, Alphabet::N).unwrap_or_default();
                        let id = event.id.to_hex();
                        let ts = event.created_at.as_secs();
                        // Count a message AUTHOR as an active participant too —
                        // iOS's GeohashParticipantTracker counts both message
                        // authors and presence broadcasters within the activity
                        // window, so a busy channel shows e.g. "5 here now" even
                        // if those people aren't sending presence heartbeats.
                        // Counting only presence (the old behaviour) showed "1".
                        {
                            let mut pmap = handler_presence.lock().unwrap();
                            let slot = pmap
                                .entry(geohash.clone())
                                .or_default()
                                .entry(event.pubkey.to_hex())
                                .or_insert(0);
                            if ts > *slot {
                                *slot = ts;
                            }
                        }
                        let mut map = handler_geo.lock().unwrap();
                        let bucket = map.entry(geohash).or_default();
                        if !bucket.iter().any(|r| r.id == id) {
                            bucket.push(RawGeo {
                                id,
                                pubkey: event.pubkey,
                                nickname,
                                content: event.content.clone(),
                                ts,
                            });
                        }
                    }
                    20001 => {
                        // Presence heartbeat: record the freshest timestamp per
                        // participant so "N here now" counts live participants.
                        let Some(geohash) = tag_value(&event, Alphabet::G) else {
                            continue;
                        };
                        let mut map = handler_presence.lock().unwrap();
                        let bucket = map.entry(geohash).or_default();
                        let ts = event.created_at.as_secs();
                        let slot = bucket.entry(event.pubkey.to_hex()).or_insert(0);
                        if ts > *slot {
                            *slot = ts;
                        }
                    }
                    1059 => {
                        // Gift wrap: the `p` tag names the recipient key.
                        let Some(p_hex) = tag_value(&event, Alphabet::P) else {
                            continue;
                        };
                        // Addressed to our MAIN identity → Marmot welcome,
                        // MLS message, or push token share (kind 447).
                        // Buffer everything; kind-447 is intercepted in
                        // process_marmot_events before the MLS engine sees it.
                        if p_hex == my_pubkey_hex {
                            {
                                let mut buf = handler_giftwraps.lock().unwrap();
                                if buf.len() >= MARMOT_GIFTWRAP_BUFFER_CAP {
                                    tracing::warn!(
                                        dropped = MARMOT_GIFTWRAP_BUFFER_CAP / 2,
                                        "pending marmot buffer overflow — dropping oldest gift wraps"
                                    );
                                    buf.drain(0..MARMOT_GIFTWRAP_BUFFER_CAP / 2);
                                    handler_buffer_drops.fetch_add(1, Ordering::Relaxed);
                                }
                                buf.push((*event).clone());
                            }
                            handler_notify.notify_one();
                            continue;
                        }
                        // Otherwise the `p` tag names a per-geohash recipient key:
                        // find which active channel it targets, unwrap with that
                        // key, and record the kind-14 DM.
                        let subs: Vec<String> =
                            handler_subs.lock().unwrap().iter().cloned().collect();
                        for geohash in subs {
                            let keys = match crate::geohash::derive_geohash_keys(
                                &identity_secret,
                                &geohash,
                            ) {
                                Ok(keys) => keys,
                                Err(err) => {
                                    tracing::warn!(%geohash, %err, "geohash key derivation failed");
                                    continue;
                                }
                            };
                            if keys.public_key().to_hex() != p_hex {
                                continue;
                            }
                            match UnwrappedGift::from_gift_wrap(&keys, &event).await {
                                Err(err) => {
                                    tracing::warn!(
                                        event_id = %event.id,
                                        %err,
                                        "geohash gift wrap unwrap failed"
                                    );
                                }
                                Ok(unwrapped) => {
                                    if unwrapped.rumor.kind.as_u16() != 14 {
                                        break;
                                    }
                                    let peer_hex = unwrapped.sender.to_hex();
                                    let id = unwrapped
                                        .rumor
                                        .id
                                        .map(|i| i.to_hex())
                                        .unwrap_or_else(|| event.id.to_hex());
                                    let mut map = handler_dm.lock().unwrap();
                                    let bucket =
                                        map.entry((geohash.clone(), peer_hex)).or_default();
                                    if !bucket.iter().any(|r| r.id == id) {
                                        bucket.push(RawGeoDm {
                                            id,
                                            sender: unwrapped.sender,
                                            content: unwrapped.rumor.content.clone(),
                                            ts: unwrapped.rumor.created_at.as_secs(),
                                            mine: false,
                                        });
                                    }
                                }
                            }
                            break;
                        }
                    }
                    445 => {
                        // Live MLS group message for one of our subscribed groups
                        // (the relay only sends 445s matching our `#h` filter).
                        // Buffer + wake; processing happens on the host's engine
                        // thread via drain_pending_marmot.
                        {
                            let mut buf = handler_groups.lock().unwrap();
                            if buf.len() >= MARMOT_GROUP_BUFFER_CAP {
                                tracing::warn!(
                                    dropped = MARMOT_GROUP_BUFFER_CAP / 2,
                                    "pending marmot buffer overflow — dropping oldest group messages"
                                );
                                buf.drain(0..MARMOT_GROUP_BUFFER_CAP / 2);
                                handler_buffer_drops.fetch_add(1, Ordering::Relaxed);
                            }
                            buf.push((*event).clone());
                        }
                        handler_notify.notify_one();
                    }
                    _ => {}
                }
            }
        });

        // Resume incremental sync across restarts from the newest REMOTE event
        // already in the store. Local sends and local-only bookkeeping can be
        // newer than peer messages missed while offline; they must not seed the
        // relay cursor or a restart can subscribe from beyond the missing peer
        // messages. The gift-wrap fetch still applies its 7-day NIP-59 lookback.
        let resume_watermark = engine.latest_remote_event_secs();
        let groups_empty = engine
            .groups()
            .map(|groups| groups.is_empty())
            .unwrap_or(true);
        let storage_empty = groups_empty && engine.latest_message_secs() == 0;
        let sync_state = Arc::new(Mutex::new(SyncState::load(
            sync_state_path,
            resume_watermark,
            storage_empty,
        )));
        let outbox_state = Arc::new(Mutex::new(OutboxState::load(outbox_state_path)));
        let client = Self {
            engine,
            nostr,
            relays,
            geo,
            geo_dm,
            direct_dm,
            geo_presence,
            geo_subscribed,
            identity_secret,
            sync_state,
            outbox_state,
            pending_marmot_giftwraps,
            pending_marmot_groups,
            marmot_notify,
            send_inflight,
            membership_gate,
            buffer_drops_total,
            live_marmot_enabled,
            marmot_group_subscriptions,
            initial_empty_transcript_backfills,
            initial_backfill_scanned,
            initial_group_message_catchups,
            initial_group_message_catchup_scanned,
            preferred_catchup_group,
            last_ensure_subscriptions_at,
            allow_geo_relays,
            conversation_index,
            change_listener: Arc::new(Mutex::new(None)),
            invite_links: Arc::new(crate::invite_link::InviteLinkStore::load(
                invite_link_state_path,
            )),
            push_token_cache,
            push_token_cache_path,
            sticker_cache,
            sticker_pack_fetch_gates: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            sticker_image_fetch_gates: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            sticker_prefetch_registry: Arc::new(Mutex::new(HashMap::new())),
            own_push_registration: Arc::new(Mutex::new(None)),
        };
        // Open the live Marmot subscriptions for real sessions. In-memory test
        // sessions (allow_geo_relays=false) stay on the explicit `sync()` path so
        // the e2e tests remain deterministic and network-shaped.
        if allow_geo_relays {
            if let Err(err) = client.subscribe_marmot().await {
                tracing::debug!(%err, "marmot live subscribe failed (sync() still covers it)");
            }
            tracing::info!(
                elapsed_ms = boot_start.elapsed().as_millis() as u64,
                "subscribe_marmot done"
            );
            client.retry_outbox().await;
            tracing::info!(
                elapsed_ms = boot_start.elapsed().as_millis() as u64,
                "with_engine complete"
            );
        }
        Ok(client)
    }

    pub fn identity(&self) -> &Identity {
        self.engine.identity()
    }

    /// Access the transport-free Marmot engine. Primarily for tests that exercise
    /// the media crypto path (encrypt/imeta/decrypt) without a Blossom server.
    pub fn engine(&self) -> &MarmotEngine {
        &self.engine
    }

    /// Publish our kind-30443 KeyPackage so others can start groups with us.
    /// Waits for the relay OK acks — callers that need durability (a peer is
    /// about to fetch the KeyPackage) use this.
    pub async fn publish_key_package(&self) -> Result<()> {
        let event = self.engine.key_package_event(self.relays.clone())?;
        self.nostr.send_event(&event).await?;
        Ok(())
    }

    /// Like [`Self::publish_key_package`], but the relay send is spawned, not
    /// awaited: each `send_event` waits up to the per-relay OK timeout, and on
    /// cold start that wait sat on the host's serialized engine queue ahead of
    /// the first message drain (measured ~50s of `t3→t3a` on device). The
    /// KeyPackage is a replaceable event republished on every relay connect,
    /// so a lost send self-heals on the next connect; failures are logged,
    /// not returned. Event creation (MLS key material persistence) still
    /// happens synchronously before this returns.
    pub async fn publish_key_package_background(&self) -> Result<()> {
        let event = self.engine.key_package_event(self.relays.clone())?;
        let nostr = self.nostr.clone();
        tokio::spawn(async move {
            if let Err(err) = nostr.send_event(&event).await {
                tracing::warn!(%err, "background KeyPackage publish failed");
            }
        });
        Ok(())
    }

    /// Fetch ALL of `author`'s KeyPackage events from the relays (a peer may have
    /// several under different `d` tags — e.g. multiple devices, or a stale slot
    /// from an old install). Newest first.
    pub async fn fetch_all_key_packages(&self, author: PublicKey) -> Result<Vec<Event>> {
        let filter = Filter::new()
            .kind(Kind::Custom(KEY_PACKAGE_KIND))
            .author(author);
        let mut events: Vec<Event> = self
            .nostr
            .fetch_events(filter, FETCH_TIMEOUT)
            .await?
            .into_iter()
            .collect();
        events.sort_by_key(|e| std::cmp::Reverse(e.created_at));
        Ok(events)
    }

    /// Create a 1:1 group inviting the holder of a SPECIFIC KeyPackage event and
    /// deliver the welcome. Used to invite via a chosen KeyPackage when a peer has
    /// several (the newest may be a stale slot the peer no longer holds the key
    /// material for, which the recipient rejects as "unknown key package").
    pub async fn start_dm_with_key_package(
        &self,
        key_package: Event,
        name: &str,
    ) -> Result<GroupId> {
        let creation = self.engine.create_group_with_description(
            name,
            SONAR_DIRECT_DM_DESCRIPTION,
            vec![key_package],
            self.relays.clone(),
        )?;
        self.publish_group_creation(creation).await
    }

    async fn fetch_key_packages_for_members(&self, members: Vec<PublicKey>) -> Result<Vec<Event>> {
        let mut deduped = Vec::new();
        let mut seen = HashSet::new();
        for member in members {
            if member == self.identity().public_key() {
                continue;
            }
            if seen.insert(member) {
                deduped.push(member);
            }
        }
        if deduped.is_empty() {
            return Err(Error::InvalidInput(
                "group must include at least one other member".into(),
            ));
        }

        let mut key_packages = Vec::with_capacity(deduped.len());
        for member in deduped {
            key_packages.push(self.fetch_key_package(member).await?);
        }
        Ok(key_packages)
    }

    /// Fetch the freshest KeyPackage event for `author` from the relays.
    pub async fn fetch_key_package(&self, author: PublicKey) -> Result<Event> {
        let filter = Filter::new()
            .kind(Kind::Custom(KEY_PACKAGE_KIND))
            .author(author)
            .limit(1);
        let events = self.nostr.fetch_events(filter, FETCH_TIMEOUT).await?;
        events
            .into_iter()
            .next()
            .ok_or(Error::KeyPackageNotFound(author))
    }

    /// Publish our kind-0 profile (NIP-01 metadata) so peers can resolve our
    /// display name + avatar. `name` is used for both `name` and `display_name`;
    /// `about`/`picture` are optional (a bad picture URL is dropped, not fatal).
    pub async fn publish_profile(
        &self,
        name: &str,
        about: Option<&str>,
        picture: Option<&str>,
    ) -> Result<()> {
        let mut metadata = Metadata::new().name(name).display_name(name);
        if let Some(about) = about.filter(|s| !s.is_empty()) {
            metadata = metadata.about(about);
        }
        if let Some(url) = picture
            .filter(|s| !s.is_empty())
            .and_then(|p| Url::parse(p).ok())
        {
            metadata = metadata.picture(url);
        }
        self.nostr.set_metadata(&metadata).await?;
        Ok(())
    }

    /// Like [`Self::publish_profile`], but the relay send is spawned, not
    /// awaited — see [`Self::publish_key_package_background`] for why. Kind-0
    /// is a replaceable event republished on every relay connect and on
    /// rename, so a lost send self-heals; failures are logged, not returned.
    pub async fn publish_profile_background(
        &self,
        name: &str,
        about: Option<&str>,
        picture: Option<&str>,
    ) {
        let mut metadata = Metadata::new().name(name).display_name(name);
        if let Some(about) = about.filter(|s| !s.is_empty()) {
            metadata = metadata.about(about);
        }
        if let Some(url) = picture
            .filter(|s| !s.is_empty())
            .and_then(|p| Url::parse(p).ok())
        {
            metadata = metadata.picture(url);
        }
        let nostr = self.nostr.clone();
        tokio::spawn(async move {
            if let Err(err) = nostr.set_metadata(&metadata).await {
                tracing::warn!(%err, "background profile publish failed");
            }
        });
    }

    /// Fetch a peer's kind-0 profile from the relays. Returns `None` if they have
    /// not published one. Used to show a human name/avatar for a Marmot member
    /// instead of a raw npub.
    pub async fn fetch_profile(&self, author: PublicKey) -> Result<Option<Profile>> {
        let metadata = self.nostr.fetch_metadata(author, FETCH_TIMEOUT).await?;
        Ok(metadata.map(|m| Profile {
            name: m.name,
            display_name: m.display_name,
            about: m.about,
            picture: m.picture,
            nip05: m.nip05,
        }))
    }

    /// Publish Sonar's public, NIP-78-style app descriptor. This is intentionally
    /// capability + route metadata only: live Iroh node addresses stay inside
    /// encrypted ☎CALL OFFER/ANSWER messages.
    pub async fn publish_sonar_descriptor(
        &self,
        calls_enabled: bool,
        signaling: Vec<String>,
        bolt12_offer: Option<String>,
    ) -> Result<()> {
        // Publish the legacy call-only descriptor (old clients + call discovery
        // without a wallet) and, ONLY when we actually have an offer, the unified
        // meta descriptor that carries it. Both are replaceable events, so
        // emitting the meta with `None` would clobber a previously-published
        // offer on the relays and make us unpayable — an offer-less / not-yet-
        // ready publish must never wipe a known offer. See `descriptor_events`.
        for (d_tag, content) in descriptor_events(calls_enabled, signaling, bolt12_offer)? {
            let builder = EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), content)
                .tags(descriptor_tags(d_tag));
            self.nostr.send_event_builder(builder).await?;
        }
        Ok(())
    }

    /// Fetch a peer's freshest valid Sonar descriptor from our account relays.
    /// Returns `None` for White Noise-only peers, old Sonar clients, privacy-off
    /// clients, relay misses, or malformed descriptors.
    pub async fn fetch_sonar_descriptor(
        &self,
        author: PublicKey,
    ) -> Result<Option<SonarDescriptor>> {
        let mut events = Vec::new();
        for d_tag in descriptor_d_tags() {
            let filter = Filter::new()
                .kind(Kind::Custom(SONAR_DESCRIPTOR_KIND))
                .author(author)
                .custom_tag(SingleLetterTag::lowercase(Alphabet::D), d_tag)
                .limit(5);
            events.extend(
                self.nostr
                    .fetch_events_from(self.relays.clone(), filter, FETCH_TIMEOUT)
                    .await?
                    .into_iter(),
            );
        }
        Ok(newest_valid_sonar_descriptor(events, author))
    }

    /// Start a multi-member Marmot group: fetch each member's KeyPackage,
    /// create the MLS group, and deliver the gift-wrapped welcomes.
    pub async fn start_group(&self, members: Vec<PublicKey>, name: &str) -> Result<GroupId> {
        let key_packages = self.fetch_key_packages_for_members(members).await?;
        let creation = self
            .engine
            .create_group(name, key_packages, self.relays.clone())?;
        self.publish_group_creation(creation).await
    }

    /// Start a 1:1 DM group with `peer`: fetch their KeyPackage, create the MLS
    /// group, and deliver the gift-wrapped welcome.
    ///
    /// If a 1:1 group with `peer` already exists, returns its id instead of
    /// creating a duplicate.
    pub async fn start_dm(&self, peer: PublicKey, name: &str) -> Result<GroupId> {
        if peer == self.identity().public_key() {
            return Err(Error::InvalidInput(
                "direct message requires another member".into(),
            ));
        }
        if let Some(existing) = self.find_dm_group_with(&peer)? {
            return Ok(existing);
        }
        let key_packages = self.fetch_key_packages_for_members(vec![peer]).await?;
        let creation = self.engine.create_group_with_description(
            name,
            SONAR_DIRECT_DM_DESCRIPTION,
            key_packages,
            self.relays.clone(),
        )?;
        self.publish_group_creation(creation).await
    }

    /// Scan active groups for an existing 1:1 DM with `peer`.
    fn find_dm_group_with(&self, peer: &PublicKey) -> Result<Option<GroupId>> {
        let groups = self.engine.groups()?;
        let me = self.identity().public_key();
        for group in groups {
            let members = self.engine.members(&group.mls_group_id)?;
            if Self::is_reusable_dm_group(&group, &members, &me, peer) {
                return Ok(Some(group.mls_group_id));
            }
        }
        Ok(None)
    }

    fn is_reusable_dm_group(
        group: &group_types::Group,
        members: &[PublicKey],
        me: &PublicKey,
        peer: &PublicKey,
    ) -> bool {
        if members.len() != 2 || !members.contains(peer) || !members.contains(me) {
            return false;
        }

        group.description == SONAR_DIRECT_DM_DESCRIPTION
            || (group.description.is_empty() && group.name.is_empty())
    }

    async fn publish_group_creation(&self, creation: GroupCreation) -> Result<GroupId> {
        let group_id = creation.group.mls_group_id;
        let mut wrapped_welcomes = Vec::with_capacity(creation.welcomes.len());

        for (member, rumor) in creation.welcomes {
            match self.engine.gift_wrap_welcome(&member, rumor).await {
                Ok(wrapped) => wrapped_welcomes.push(wrapped),
                Err(err) => {
                    self.discard_unpublished_group_creation(&group_id);
                    return Err(err);
                }
            }
        }

        let mut published_welcomes = 0usize;
        for wrapped in wrapped_welcomes {
            if let Err(err) = self.publish_marmot_event(&wrapped, "group welcome").await {
                if published_welcomes == 0 {
                    self.discard_unpublished_group_creation(&group_id);
                } else {
                    tracing::debug!(
                        %err,
                        ?group_id,
                        published_welcomes,
                        "marmot group creation welcome publish partially failed; keeping pending group state"
                    );
                }
                return Err(err.into());
            }
            published_welcomes += 1;
        }

        self.engine.merge_pending_commit(&group_id)?;
        let name = self
            .engine
            .groups()
            .ok()
            .and_then(|gs| {
                gs.into_iter()
                    .find(|g| g.mls_group_id == group_id)
                    .map(|g| g.name)
            })
            .unwrap_or_default();
        self.ensure_index_for_group(&group_id, &name);
        let group_id_hex = hex::encode(group_id.as_slice());
        self.notify_conversation_changed(&group_id_hex);
        if let Err(err) = self.resubscribe_marmot_groups_if_live().await {
            tracing::debug!(%err, "marmot group live resubscribe failed after local group create");
        }
        Ok(group_id)
    }

    fn discard_unpublished_group_creation(&self, group_id: &GroupId) {
        let _ = self.engine.clear_pending_commit(group_id);
        let _ = self.engine.delete_group(group_id);
    }

    async fn publish_membership_update(&self, update: GroupMembershipUpdate) -> Result<()> {
        let group_id = update.group_id.clone();
        let requires_commit_merge = update.requires_commit_merge;
        let mut wrapped_welcomes = Vec::with_capacity(update.welcomes.len());

        for (member, rumor) in update.welcomes {
            match self.engine.gift_wrap_welcome(&member, rumor).await {
                Ok(wrapped) => wrapped_welcomes.push(wrapped),
                Err(err) => {
                    if requires_commit_merge {
                        let _ = self.engine.clear_pending_commit(&group_id);
                    }
                    return Err(err);
                }
            }
        }

        if let Err(err) = self
            .publish_marmot_event(&update.evolution_event, "membership update")
            .await
        {
            if requires_commit_merge {
                let _ = self.engine.clear_pending_commit(&group_id);
            }
            return Err(err.into());
        }

        for wrapped in wrapped_welcomes {
            if let Err(err) = self
                .publish_marmot_event(&wrapped, "membership welcome")
                .await
            {
                tracing::debug!(
                    %err,
                    ?group_id,
                    "marmot membership welcome publish failed after commit publish; keeping pending commit"
                );
                return Err(err.into());
            }
        }

        if requires_commit_merge {
            self.engine.merge_pending_commit(&group_id)?;
        }
        if let Err(err) = self.resubscribe_marmot_groups_if_live().await {
            tracing::debug!(%err, "marmot group live resubscribe failed after membership update");
        }
        Ok(())
    }

    async fn publish_marmot_event(&self, event: &Event, context: &'static str) -> Result<()> {
        let output = self.nostr.send_event(event).await?;
        require_relay_success(&output, context)
    }

    async fn ensure_relays_connected(&self, relays: &[RelayUrl]) -> Result<()> {
        for relay in relays {
            self.nostr.add_relay(relay.clone()).await?;
            self.nostr.connect_relay(relay.clone()).await?;
        }
        Ok(())
    }

    /// Add members to an existing group.
    pub async fn add_group_members(
        &self,
        group_id: &GroupId,
        members: Vec<PublicKey>,
    ) -> Result<()> {
        let key_packages = self.fetch_key_packages_for_members(members).await?;
        let _epoch = self.membership_gate.write().await;
        let update = self.engine.add_members(group_id, key_packages)?;
        self.publish_membership_update(update).await
    }

    /// Remove members from an existing group.
    pub async fn remove_group_members(
        &self,
        group_id: &GroupId,
        members: Vec<PublicKey>,
    ) -> Result<()> {
        if members.is_empty() {
            return Err(Error::InvalidInput(
                "remove_group_members requires at least one member".into(),
            ));
        }
        // Write-hold the gate from commit creation through publish+merge so no
        // send can encrypt at the pre-removal epoch while the commit is on the
        // wire — the removed member must not be able to read anything sent
        // after the removal was initiated.
        let _epoch = self.membership_gate.write().await;
        let update = self.engine.remove_members(group_id, &members)?;
        self.publish_membership_update(update).await
    }

    /// Notify the group that this member is leaving, then remove the group from
    /// local storage so it disappears from the chat list.
    pub async fn leave_group(&self, group_id: &GroupId) -> Result<()> {
        let _epoch = self.membership_gate.write().await;
        let leave_update = match self.engine.leave_group(group_id) {
            Ok(update) => update,
            Err(err) if err.to_string().contains("self-demote") => {
                let demote = self.engine.self_demote(group_id)?;
                self.publish_membership_update(demote).await?;
                self.engine.leave_group(group_id)?
            }
            Err(err) => return Err(err),
        };
        self.publish_membership_update(leave_update).await?;
        self.engine.delete_group(group_id)?;
        let _ = self.resubscribe_marmot_groups_if_live().await;
        Ok(())
    }

    // ── Invite links ──────────────────────────────────────────────────

    pub fn create_invite_link(&self, group_id: &GroupId, group_name: &str) -> Result<String> {
        let relay_strings: Vec<String> = self.relays.iter().map(|r| r.to_string()).collect();
        self.invite_links
            .create_link(group_id, group_name, self.engine.identity(), relay_strings)
    }

    pub fn revoke_invite_link(&self, group_id: &GroupId, secret_hash: &[u8; 32]) -> Result<()> {
        self.invite_links.revoke_link(group_id, secret_hash)
    }

    pub fn active_invite_links(
        &self,
        group_id: &GroupId,
    ) -> Vec<crate::invite_link::InviteLinkMeta> {
        self.invite_links.active_links(group_id)
    }

    pub async fn request_join_via_link(&self, token_str: &str) -> Result<()> {
        let token = crate::invite_link::decode_invite_token(token_str)?;
        let admin = PublicKey::from_slice(&token.admin_npub)
            .map_err(|e| Error::InvalidInput(e.to_string()))?;
        let group_id = GroupId::from_slice(&token.group_id);
        let invite_relays: Vec<RelayUrl> = token
            .relays
            .iter()
            .map(|url| {
                RelayUrl::parse(url)
                    .map_err(|e| Error::InvalidInput(format!("invite relay {url}: {e}")))
            })
            .collect::<Result<_>>()?;
        let publish_relays = if invite_relays.is_empty() {
            self.relays.clone()
        } else {
            invite_relays
        };

        self.ensure_relays_connected(&publish_relays).await?;
        let kp_event = self.engine.key_package_event(publish_relays.clone())?;
        let output = self
            .nostr
            .send_event_to(publish_relays.clone(), &kp_event)
            .await?;
        require_relay_success(&output, "invite key package publish")?;

        let rumor = crate::invite_link::build_join_request_rumor(
            &group_id,
            &token.invite_secret,
            &self.engine.identity().public_key(),
            Some(&kp_event.id),
        );
        let wrapped = self.engine.gift_wrap_rumor(&admin, rumor).await?;
        let output = self.nostr.send_event_to(publish_relays, &wrapped).await?;
        require_relay_success(&output, "invite join request publish")
    }

    pub fn pending_join_requests(
        &self,
        group_id: &GroupId,
    ) -> Vec<crate::invite_link::JoinRequest> {
        self.invite_links.pending_join_requests(group_id)
    }

    pub async fn approve_join_request(
        &self,
        group_id: &GroupId,
        requester: &PublicKey,
    ) -> Result<()> {
        if !self
            .invite_links
            .pending_join_requests(group_id)
            .iter()
            .any(|r| r.requester == *requester)
        {
            return Err(Error::InvalidInput("no pending join request".into()));
        }
        self.add_group_members(group_id, vec![*requester]).await?;
        self.invite_links.remove_join_request(group_id, requester)?;
        Ok(())
    }

    pub fn decline_join_request(&self, group_id: &GroupId, requester: &PublicKey) -> Result<()> {
        self.invite_links.remove_join_request(group_id, requester)
    }

    pub fn store_join_request(&self, request: crate::invite_link::JoinRequest) -> Result<bool> {
        if !self
            .invite_links
            .validate_secret(&request.group_id, &request.secret_hash)
        {
            return Ok(false);
        }
        self.invite_links.add_join_request(request)?;
        Ok(true)
    }

    /// Pending multi-member invites waiting for explicit user action.
    pub fn pending_group_invites(&self) -> Result<Vec<GroupInvite>> {
        self.engine.pending_group_invites()
    }

    /// Accept a pending group invite by welcome event id, then backfill its
    /// existing group history and widen the live subscription.
    pub async fn accept_group_invite(&self, welcome_id: &EventId) -> Result<GroupId> {
        let group_id = self.engine.accept_group_invite(welcome_id)?;
        if let Some(group) = self
            .engine
            .groups()?
            .into_iter()
            .find(|g| g.mls_group_id == group_id)
        {
            self.ensure_index_for_group(&group_id, &group.name);
            let nostr_group_id = hex::encode(group.nostr_group_id);
            if let Err(err) = self.backfill_group(&nostr_group_id).await {
                tracing::debug!(
                    %err,
                    %nostr_group_id,
                    "marmot group backfill failed after accepting invite"
                );
            }
        }
        let group_id_hex = hex::encode(group_id.as_slice());
        self.notify_conversation_changed(&group_id_hex);
        let _ = self.resubscribe_marmot_groups_if_live().await;
        Ok(group_id)
    }

    /// Decline a pending group invite by welcome event id.
    pub fn decline_group_invite(&self, welcome_id: &EventId) -> Result<()> {
        self.engine.decline_group_invite(welcome_id)
    }

    /// Encrypt and durably record a text message locally before relay publish.
    ///
    /// This is Signal-style send sequencing: the MDK local DB becomes visible
    /// first, Sonar marks the row pending in the outbox, and relay publish runs
    /// in the background. Publish success/failure only updates local delivery
    /// state; it does not gate transcript visibility.
    pub async fn send_text(&self, group_id: &GroupId, text: &str) -> Result<()> {
        let local_started = Instant::now();
        // One MLS write guard covers encrypt + local-row write, so a
        // concurrently drained commit cannot land in between now that sends
        // no longer share the host's serialized engine queue with sync.
        let (event, incoming) = {
            let _epoch = self.membership_gate.read().await;
            self.engine.create_and_process_text_message(group_id, text)?
        };
        let Incoming::Message(message) = incoming else {
            return Err(Error::Storage(
                "created text message did not produce a local transcript row".into(),
            ));
        };
        let group_id_hex = hex::encode(group_id.as_slice());
        let group_name = self.resolve_group_name(group_id);
        self.mark_outbox_pending(group_id, &message, &event)?;
        let event_id = event.id;
        let local_ms = local_started.elapsed().as_millis() as u64;
        tracing::info!(
            message_id = %message.id.to_hex(),
            event_id = %event_id.to_hex(),
            local_ms,
            "send_local_pending"
        );
        let publish_ack =
            self.spawn_outbox_publish(message.id.to_hex(), group_id_hex.clone(), event);
        self.notify_conversation_changed(&group_id_hex);
        // Deferred bookkeeping: index + sync-state disk writes don't block
        // the caller so the next send can start immediately.
        self.spawn_send_bookkeeping(group_name, message, event_id);
        self.spawn_push_notification(group_id.clone(), publish_ack);
        Ok(())
    }

    fn spawn_send_bookkeeping(
        &self,
        group_name: Option<String>,
        message: ChatMessage,
        event_id: EventId,
    ) {
        let conversation_index = self.conversation_index.clone();
        let sync_state = self.sync_state.clone();
        let event_id_hex = event_id.to_hex();
        std::thread::spawn(move || {
            if let Some(ref idx) = conversation_index {
                let group_id_hex = hex::encode(message.group_id.as_slice());
                let name = group_name.as_deref().unwrap_or("");
                if let Err(e) = idx.lock().unwrap().upsert_summary(
                    &group_id_hex,
                    name,
                    &index_preview(&message),
                    &message.sender.to_string(),
                    message.created_at.as_secs(),
                    message.mine,
                ) {
                    tracing::warn!(%e, "deferred index upsert failed");
                }
            }
            {
                let mut state = sync_state.lock().unwrap();
                state.mark_processed_id(event_id_hex);
                if let Err(e) = state.save_if_dirty() {
                    tracing::debug!(%e, "deferred sync-state persist failed");
                }
            }
        });
    }

    fn spawn_push_notification(
        &self,
        group_id: GroupId,
        publish_ack: tokio::sync::oneshot::Receiver<bool>,
    ) {
        let members = match self.engine.members(&group_id) {
            Ok(m) => m,
            Err(e) => {
                tracing::debug!(%e, "push notify: failed to list members");
                return;
            }
        };
        let my_pubkey = self.engine.identity().public_key();
        let identity_keys = self.engine.identity().keys().clone();
        let nostr = self.nostr.clone();
        let tokens = self.push_token_cache.lock().unwrap().clone();
        tokio::spawn(async move {
            // Push traffic shares the relay pool with the encrypted message.
            // Give the user-visible send priority and wait until its first ACK
            // or until every content publish attempt has failed. The failure
            // case still preserves the previous best-effort push behavior while
            // the durable outbox owns later content retries.
            match publish_ack.await {
                Ok(true) => {}
                Ok(false) => {
                    tracing::debug!(
                        "message publish was not acknowledged; sending best-effort push"
                    );
                }
                Err(_) => {
                    tracing::debug!("push notify skipped: message publish did not start");
                    return;
                }
            }
            for member in &members {
                if member == &my_pubkey {
                    continue;
                }
                let Some(info) = tokens.get(&member.to_hex()) else {
                    continue;
                };
                let rumor = EventBuilder::new(
                    Kind::Custom(crate::push::KIND_NOTIFICATION_REQUEST),
                    &info.encrypted_token_b64,
                )
                .tags([
                    Tag::custom(TagKind::custom("v"), ["mip05-v1"]),
                    Tag::custom(TagKind::custom("encoding"), ["base64"]),
                ])
                .build(my_pubkey);

                let seal_builder =
                    match EventBuilder::seal(&identity_keys, &info.server_pubkey, rumor).await {
                        Ok(b) => b,
                        Err(e) => {
                            tracing::debug!(member = %member, %e, "push notify seal failed");
                            continue;
                        }
                    };
                let seal = match seal_builder.sign(&identity_keys).await {
                    Ok(s) => s,
                    Err(e) => {
                        tracing::debug!(member = %member, %e, "push notify sign seal failed");
                        continue;
                    }
                };
                let ephemeral = Keys::generate();
                let content = match nip44::encrypt(
                    ephemeral.secret_key(),
                    &info.server_pubkey,
                    seal.as_json(),
                    nip44::Version::default(),
                ) {
                    Ok(c) => c,
                    Err(e) => {
                        tracing::debug!(member = %member, %e, "push notify encrypt failed");
                        continue;
                    }
                };
                let wrapped = match EventBuilder::new(Kind::GiftWrap, content)
                    .tags([Tag::public_key(info.server_pubkey)])
                    .custom_created_at(Timestamp::now())
                    .sign_with_keys(&ephemeral)
                {
                    Ok(w) => w,
                    Err(e) => {
                        tracing::debug!(member = %member, %e, "push notify sign failed");
                        continue;
                    }
                };
                if let Err(e) = nostr.send_event(&wrapped).await {
                    tracing::debug!(member = %member, %e, "push notify send failed");
                } else {
                    // Keep the event at info for the default diagnostics export,
                    // but the recipient npub only at debug (verbose) — the
                    // default profile must stay free of peer identifiers.
                    tracing::info!("push notification sent to transponder");
                    tracing::debug!(member = %member, "push notification recipient");
                }
            }
        });
    }

    /// Send a sticker message to a group. Follows the same Signal-style
    /// local-first sequencing as `send_text`.
    pub async fn send_sticker(&self, group_id: &GroupId, sticker_ref: &StickerRef) -> Result<()> {
        let (event, incoming) = {
            let _epoch = self.membership_gate.read().await;
            self.engine
                .create_and_process_sticker_message(group_id, sticker_ref)?
        };
        let Incoming::Message(message) = incoming else {
            return Err(Error::Storage(
                "created sticker message did not produce a local transcript row".into(),
            ));
        };
        let group_id_hex = hex::encode(group_id.as_slice());
        let group_name = self.resolve_group_name(group_id);
        self.mark_outbox_pending(group_id, &message, &event)?;
        let event_id = event.id;
        let publish_ack =
            self.spawn_outbox_publish(message.id.to_hex(), group_id_hex.clone(), event);
        self.notify_conversation_changed(&group_id_hex);
        self.spawn_send_bookkeeping(group_name, message, event_id);
        self.spawn_push_notification(group_id.clone(), publish_ack);
        Ok(())
    }

    /// Fetch a sticker pack from relays by its pack address coordinate.
    pub async fn fetch_sticker_pack(
        &self,
        author_pubkey_hex: &str,
        identifier: &str,
        relay_urls: &[String],
    ) -> Result<StickerPack> {
        let coordinate = format!(
            "30031:{}:{}",
            author_pubkey_hex.to_ascii_lowercase(),
            identifier
        );
        let started = Instant::now();
        let (outcome, reused) = fetch_sticker_pack_singleflight(
            &self.sticker_pack_fetch_gates,
            &self.sticker_cache,
            &self.nostr,
            &self.relays,
            author_pubkey_hex,
            identifier,
            relay_urls,
            &coordinate,
        )
        .await?;
        let source = if reused { "shared" } else { outcome.source };
        tracing::debug!(
            purpose = "foreground",
            source,
            stickers = outcome.pack.stickers.len(),
            total_us = started.elapsed().as_micros() as u64,
            "SONAR_BENCH sticker_pack_fetch"
        );
        Ok(outcome.pack.clone())
    }

    async fn fetch_sticker_pack_with_client(
        nostr: &Client,
        default_relays: &[RelayUrl],
        author_pubkey_hex: &str,
        identifier: &str,
        relay_urls: &[String],
    ) -> Result<StickerPack> {
        let author = PublicKey::from_hex(author_pubkey_hex)
            .map_err(|e| Error::InvalidInput(format!("invalid pack author pubkey: {e}")))?;
        let filter = Filter::new()
            .kind(Kind::Custom(STICKER_PACK_KIND))
            .author(author)
            .custom_tag(
                SingleLetterTag::lowercase(Alphabet::D),
                identifier.to_string(),
            )
            .limit(1);

        let relays: Vec<String> = if relay_urls.is_empty() {
            default_relays.iter().map(|u| u.to_string()).collect()
        } else {
            relay_urls.to_vec()
        };
        let timeout = Duration::from_secs(10);
        let events = nostr.fetch_events_from(relays, filter, timeout).await?;
        let event = events
            .into_iter()
            .next()
            .ok_or_else(|| Error::Http("sticker pack not found on relays".into()))?;
        parse_pack_event(&event).map_err(|e| Error::Http(format!("invalid sticker pack: {e}")))
    }

    /// Download a public sticker image (HTTPS), verify SHA256, and persist to the
    /// content-addressed disk cache when configured.
    pub async fn fetch_sticker_image(&self, url: &str, expected_sha256: &str) -> Result<Vec<u8>> {
        fetch_sticker_image_singleflight(
            &self.sticker_image_fetch_gates,
            &self.sticker_cache,
            url,
            expected_sha256,
            MAX_STICKER_CACHE_BYTES,
            "foreground",
        )
        .await
    }

    /// Return a verified local sticker only if the latest locally validated pack
    /// still authorizes the exact coordinate + shortcode + plaintext hash.
    /// Never consults relays or HTTP.
    pub fn cached_sticker_image_for_ref(
        &self,
        sticker_ref: &StickerRef,
    ) -> Result<Option<Vec<u8>>> {
        let started = Instant::now();
        let result = self.sticker_cache.read_validated_image(
            &sticker_ref.pack.coordinate(),
            &sticker_ref.shortcode,
            &sticker_ref.plaintext_sha256,
        );
        match &result {
            Ok(Some(bytes)) => tracing::debug!(
                purpose = "foreground",
                outcome = "hit",
                bytes = bytes.len(),
                total_us = started.elapsed().as_micros() as u64,
                "SONAR_BENCH sticker_ref_cache_lookup"
            ),
            Ok(None) => tracing::debug!(
                purpose = "foreground",
                outcome = "miss",
                bytes = 0,
                total_us = started.elapsed().as_micros() as u64,
                "SONAR_BENCH sticker_ref_cache_lookup"
            ),
            Err(err) => tracing::debug!(%err, "sticker reference cache lookup failed"),
        }
        result
    }

    /// Schedule bounded best-effort prefetch without holding the install/FFI
    /// call or the host's serialized Marmot queue open on network I/O.
    fn spawn_sticker_pack_prefetch(&self, coordinate: String) {
        let cancellation = Arc::new(StickerPrefetchCancellation::new());
        let registration = {
            let mut registry = match self.sticker_prefetch_registry.lock() {
                Ok(registry) => registry,
                Err(_) => {
                    tracing::debug!(coordinate, "sticker prefetch registry lock poisoned");
                    return;
                }
            };
            if let Some(previous) = registry.insert(coordinate.clone(), cancellation.clone()) {
                previous.cancel();
            }
            StickerPrefetchRegistration {
                coordinate: coordinate.clone(),
                cancellation: cancellation.clone(),
                registry: self.sticker_prefetch_registry.clone(),
            }
        };
        let nostr = self.nostr.clone();
        let relays = self.relays.clone();
        let sticker_cache = self.sticker_cache.clone();
        let sticker_pack_fetch_gates = self.sticker_pack_fetch_gates.clone();
        let sticker_image_fetch_gates = self.sticker_image_fetch_gates.clone();
        let _prefetch = tokio::spawn(async move {
            let _registration = registration;
            if cancellation.is_cancelled() {
                return;
            }
            let prefetch_started = Instant::now();
            let address = match PackAddress::parse(&coordinate) {
                Ok(address) => address,
                Err(err) => {
                    tracing::debug!(%err, coordinate, "sticker prefetch: bad coordinate");
                    return;
                }
            };
            let pack_started = Instant::now();
            let coordinate = address.coordinate();
            let pack_fetch = fetch_sticker_pack_singleflight(
                &sticker_pack_fetch_gates,
                &sticker_cache,
                &nostr,
                &relays,
                &address.author_pubkey_hex,
                &address.identifier,
                &[],
                &coordinate,
            );
            tokio::pin!(pack_fetch);
            let pack_result = loop {
                tokio::select! {
                    result = &mut pack_fetch => break Some(result),
                    _ = cancellation.cancelled() => break None,
                    _ = tokio::time::sleep(Duration::from_millis(25)) => {
                        if !matches!(sticker_cache.session_is_current(), Ok(true)) {
                            break None;
                        }
                    }
                }
            };
            let (outcome, reused) = match pack_result {
                None => return,
                Some(result) => match result {
                    Ok(result) => result,
                    Err(err) => {
                        tracing::debug!(%err, coordinate, "sticker prefetch: pack fetch failed");
                        return;
                    }
                },
            };
            let source = if reused { "shared" } else { outcome.source };
            let pack = outcome.pack.clone();
            let pack_us = pack_started.elapsed().as_micros() as u64;
            tracing::debug!(
                purpose = "prefetch",
                source,
                stickers = pack.stickers.len(),
                total_us = pack_us,
                "SONAR_BENCH sticker_pack_fetch"
            );
            let mut tasks = tokio::task::JoinSet::new();
            let mut attempted = 0usize;
            let mut succeeded = 0usize;
            let mut failed = 0usize;
            let mut invalidated = false;
            'stickers: for sticker in pack
                .stickers
                .into_iter()
                .take(STICKER_CACHE_PREFETCH_IMAGE_LIMIT)
            {
                if cancellation.is_cancelled() {
                    invalidated = true;
                    break;
                }
                match sticker_cache.session_is_current() {
                    Ok(true) => {}
                    Ok(false) => {
                        invalidated = true;
                        break;
                    }
                    Err(err) => {
                        tracing::debug!(%err, coordinate, "sticker prefetch: cache session check failed");
                        invalidated = true;
                        break;
                    }
                }
                while tasks.len() >= STICKER_PREFETCH_CONCURRENCY {
                    tokio::select! {
                        outcome = tasks.join_next() => {
                            let counts = log_sticker_prefetch_result(outcome);
                            succeeded += counts.0;
                            failed += counts.1;
                        }
                        _ = cancellation.cancelled() => {
                            invalidated = true;
                            break 'stickers;
                        }
                        _ = tokio::time::sleep(Duration::from_millis(25)) => {
                            if !matches!(sticker_cache.session_is_current(), Ok(true)) {
                                invalidated = true;
                                break 'stickers;
                            }
                        }
                    }
                }
                attempted += 1;
                let cache = sticker_cache.clone();
                let image_gates = sticker_image_fetch_gates.clone();
                tasks.spawn(async move {
                    let url = sticker.url;
                    let result = fetch_sticker_image_singleflight(
                        &image_gates,
                        &cache,
                        &url,
                        &sticker.sha256,
                        STICKER_PREFETCH_DOWNLOAD_BYTES,
                        "prefetch",
                    )
                    .await;
                    (url, result)
                });
            }
            if invalidated {
                tracing::debug!(
                    coordinate,
                    "sticker prefetch: cache session invalidated; cancelling remaining downloads"
                );
                tasks.abort_all();
            }
            while !tasks.is_empty() {
                if invalidated {
                    let counts = log_sticker_prefetch_result(tasks.join_next().await);
                    succeeded += counts.0;
                    failed += counts.1;
                    continue;
                }
                tokio::select! {
                    outcome = tasks.join_next() => {
                        let counts = log_sticker_prefetch_result(outcome);
                        succeeded += counts.0;
                        failed += counts.1;
                    }
                    _ = cancellation.cancelled() => {
                        invalidated = true;
                        tasks.abort_all();
                    }
                    _ = tokio::time::sleep(Duration::from_millis(25)) => {
                        if !matches!(sticker_cache.session_is_current(), Ok(true)) {
                            invalidated = true;
                            tasks.abort_all();
                        }
                    }
                }
            }
            tracing::debug!(
                purpose = "prefetch",
                attempted,
                succeeded,
                failed,
                pack_us,
                total_us = prefetch_started.elapsed().as_micros() as u64,
                "SONAR_BENCH sticker_pack_prefetch_finished"
            );
        });
    }

    pub async fn fetch_installed_packs(&self) -> Result<Vec<PackAddress>> {
        let filter = Filter::new()
            .kind(Kind::Custom(USER_STICKER_PACKS_KIND))
            .author(self.identity().public_key())
            .limit(1);
        let relays: Vec<String> = self.relays.iter().map(|u| u.to_string()).collect();
        let timeout = Duration::from_secs(10);
        let events = self
            .nostr
            .fetch_events_from(relays, filter, timeout)
            .await?;
        match events.into_iter().next() {
            Some(event) => {
                let list = parse_installed_pack_list(&event)
                    .map_err(|e| Error::Http(format!("invalid installed pack list: {e}")))?;
                Ok(list.packs)
            }
            None => Ok(Vec::new()),
        }
    }

    async fn publish_installed_packs(&self, packs: Vec<PackAddress>) -> Result<()> {
        let list = InstalledPackList::new(packs);
        let tags = build_installed_packs_tags(&list);
        let builder = EventBuilder::new(Kind::Custom(USER_STICKER_PACKS_KIND), "").tags(tags);
        self.nostr.send_event_builder(builder).await?;
        Ok(())
    }

    pub async fn install_sticker_pack(&self, coordinate: &str) -> Result<()> {
        let address = PackAddress::parse(coordinate)
            .map_err(|e| Error::Http(format!("invalid pack coordinate: {e}")))?;
        let coordinate = address.coordinate();
        let mut packs = self.fetch_installed_packs().await?;
        if !packs.iter().any(|p| p.coordinate() == coordinate) {
            packs.push(address);
        }
        self.publish_installed_packs(packs).await?;
        self.spawn_sticker_pack_prefetch(coordinate);
        Ok(())
    }

    pub async fn uninstall_sticker_pack(&self, coordinate: &str) -> Result<()> {
        let address = PackAddress::parse(coordinate)
            .map_err(|e| Error::Http(format!("invalid pack coordinate: {e}")))?;
        let coordinate = address.coordinate();
        if let Ok(registry) = self.sticker_prefetch_registry.lock() {
            if let Some(cancellation) = registry.get(&coordinate) {
                cancellation.cancel();
            }
        }
        let mut packs = self.fetch_installed_packs().await?;
        packs.retain(|p| p.coordinate() != coordinate);
        self.publish_installed_packs(packs).await
    }

    fn mark_outbox_pending(
        &self,
        group_id: &GroupId,
        message: &ChatMessage,
        event: &Event,
    ) -> Result<()> {
        self.outbox_state.lock().unwrap().mark_pending(
            hex::encode(group_id.as_slice()),
            message.id.to_hex(),
            event.id.to_hex(),
            event.as_json(),
            Timestamp::now().as_secs(),
        )
    }

    /// Publish an outbox event and notify hosts when delivery state flips.
    ///
    /// [group_id_hex] must be the **MLS** group id hosts use for
    /// `conversationChanged` / `messages_page` — not the Nostr `#h` tag
    /// (`nostr_group_id`). Kind-445 `#h` is for relay filtering only.
    fn spawn_outbox_publish(
        &self,
        message_id_hex: String,
        group_id_hex: String,
        event: Event,
    ) -> tokio::sync::oneshot::Receiver<bool> {
        let (publish_result_tx, publish_result_rx) = tokio::sync::oneshot::channel();
        if self.relays.is_empty() {
            return publish_result_rx;
        }
        let nostr = self.nostr.clone();
        let outbox_state = self.outbox_state.clone();
        let change_listener = self.change_listener.clone();
        let relays = self.relays.clone();
        let send_inflight = self.send_inflight.clone();
        send_inflight.fetch_add(1, Ordering::Relaxed);
        let publish_started = Instant::now();
        let event_id_hex = event.id.to_hex();
        tracing::info!(
            message_id = %message_id_hex,
            event_id = %event_id_hex,
            relays = relays.len(),
            "send_publish_start"
        );
        tokio::spawn(async move {
            let mut publish_result_tx = Some(publish_result_tx);
            let notify = || {
                if let Some(listener) = change_listener.lock().unwrap().clone() {
                    listener.on_conversation_changed(group_id_hex.clone());
                }
            };
            // First-ack wins (Signal-style): the pool's `send_event` joins ALL
            // relays, so one dead relay delays the Sending→Sent flip by its
            // full timeout even though the fastest relay usually acks in well
            // under a second. Fan out one publish per Marmot relay and mark
            // the message Sent on the FIRST OK — the remaining publishes keep
            // running in the background for redundancy. Only when EVERY relay
            // has failed does the message flip to failed (outbox-retryable).
            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
            for url in relays {
                let nostr = nostr.clone();
                let event = event.clone();
                let tx = tx.clone();
                let url_log = url.to_string();
                tokio::spawn(async move {
                    let started = Instant::now();
                    let outcome = match nostr.send_event_to([url], &event).await {
                        Ok(output) if !output.success.is_empty() => Ok(url_log),
                        Ok(output) => Err(output
                            .failed
                            .values()
                            .next()
                            .cloned()
                            .unwrap_or_else(|| "relay rejected event".to_string())),
                        Err(err) => Err(err.to_string()),
                    };
                    let _ = tx.send((outcome, started.elapsed().as_millis() as u64));
                });
            }
            drop(tx);
            let mut failures: Vec<String> = Vec::new();
            while let Some((outcome, _relay_ms)) = rx.recv().await {
                match outcome {
                    Ok(relay_url) => {
                        let rtt_ms = publish_started.elapsed().as_millis() as u64;
                        let _ = outbox_state
                            .lock()
                            .unwrap()
                            .mark_sent_by_message_id(&message_id_hex, Timestamp::now().as_secs());
                        tracing::info!(
                            message_id = %message_id_hex,
                            event_id = %event_id_hex,
                            relay = %relay_url,
                            rtt_ms,
                            "send_first_ack"
                        );
                        if let Some(tx) = publish_result_tx.take() {
                            let _ = tx.send(true);
                        }
                        notify();
                        send_inflight.fetch_sub(1, Ordering::Relaxed);
                        return;
                    }
                    Err(err) => failures.push(err),
                }
            }
            // The channel closed without a single OK: every relay failed.
            let reason = if failures.is_empty() {
                "no relay accepted the event".to_string()
            } else {
                failures.join(", ")
            };
            let rtt_ms = publish_started.elapsed().as_millis() as u64;
            tracing::warn!(
                message_id = %message_id_hex,
                event_id = %event_id_hex,
                rtt_ms,
                %reason,
                "send_publish_failed"
            );
            let _ = outbox_state.lock().unwrap().mark_failed_by_message_id(
                &message_id_hex,
                reason,
                Timestamp::now().as_secs(),
            );
            if let Some(tx) = publish_result_tx.take() {
                let _ = tx.send(false);
            }
            notify();
            send_inflight.fetch_sub(1, Ordering::Relaxed);
        });
        publish_result_rx
    }

    pub async fn reload_outbox_and_retry(&self) {
        if self.relays.is_empty() {
            return;
        }
        self.outbox_state.lock().unwrap().reload_from_disk();
        self.retry_outbox().await;
    }

    async fn retry_outbox(&self) {
        if self.relays.is_empty() {
            return;
        }
        let active_group_ids = match self.engine.groups() {
            Ok(groups) => groups
                .into_iter()
                .map(|group| hex::encode(group.mls_group_id.as_slice()))
                .collect::<HashSet<_>>(),
            Err(err) => {
                tracing::debug!(%err, "failed to load active Marmot groups for outbox retry");
                return;
            }
        };
        let retryable = {
            let mut outbox = self.outbox_state.lock().unwrap();
            match outbox.retryable_events(Timestamp::now().as_secs(), &active_group_ids) {
                Ok(events) => events,
                Err(err) => {
                    tracing::debug!(%err, "failed to load retryable outbox events");
                    return;
                }
            }
        };
        for (message_id_hex, group_id_hex, event) in retryable {
            // group_id_hex is the MLS id stored at mark_pending — same key hosts use.
            self.spawn_outbox_publish(message_id_hex, group_id_hex, event);
        }
    }

    fn record_delivery_for_incoming(&self, incoming: &Incoming) {
        let Incoming::Message(message) = incoming else {
            return;
        };
        if !message.mine {
            return;
        }
        if let Err(err) = self
            .outbox_state
            .lock()
            .unwrap()
            .mark_sent_by_message_id(&message.id.to_hex(), Timestamp::now().as_secs())
        {
            tracing::debug!(%err, "failed to mark outbox message sent after incoming echo");
        }
    }

    // ── Encrypted media (Marmot MIP-04 + Blossom) ─────────────────────────

    /// Send a media attachment to `group_id`: encrypt with the group key
    /// (MIP-04), upload the ciphertext to a Blossom server, then publish a
    /// kind-445 message carrying the `imeta` tag and optional `caption`. The
    /// message is only published AFTER a successful upload, so a failed upload
    /// never leaves a dangling reference. `server_url` empty →
    /// [`DEFAULT_BLOSSOM_SERVER`].
    pub async fn send_media(
        &self,
        group_id: &GroupId,
        data: Vec<u8>,
        filename: &str,
        mime: &str,
        caption: &str,
        server_url: &str,
    ) -> Result<()> {
        self.send_media_multi(
            group_id,
            vec![MediaUpload {
                data,
                filename: filename.to_string(),
                mime: mime.to_string(),
            }],
            caption,
            server_url,
        )
        .await
    }

    /// Send N media attachments as ONE message (album): encrypt each with the
    /// group key (MIP-04), upload every ciphertext to Blossom, then publish a
    /// single kind-445 event carrying all `imeta` tags in order plus the optional
    /// `caption`. Every upload must succeed BEFORE the message is published, so a
    /// failed upload never leaves a dangling reference and nothing partial hits
    /// the wire. `items` must be non-empty. `server_url` empty →
    /// [`DEFAULT_BLOSSOM_SERVER`].
    pub async fn send_media_multi(
        &self,
        group_id: &GroupId,
        items: Vec<MediaUpload>,
        caption: &str,
        server_url: &str,
    ) -> Result<()> {
        if items.is_empty() {
            return Err(Error::Media("no media to send".into()));
        }
        // Encrypt + upload every attachment first; only then build + publish the
        // single message. Any failure aborts the whole album with nothing sent.
        let mut uploads = Vec::with_capacity(items.len());
        for item in &items {
            let upload =
                self.engine
                    .encrypt_media(group_id, &item.data, &item.mime, &item.filename)?;
            let url = self
                .blossom_upload(server_url, upload.encrypted_data.clone())
                .await?;
            uploads.push((upload, url));
        }
        let refs: Vec<_> = uploads.iter().map(|(u, url)| (u, url.as_str())).collect();
        // Local-first, same sequencing as `send_text`: encrypt + write the
        // local row under one MLS guard, mark the durable outbox pending, and
        // publish in the background with first-ACK delivery state. Media rows
        // previously published inline and skipped the outbox entirely, so a
        // relay failure either surfaced as a send error (pre-refactor) or
        // could have stranded a false-Sent row.
        let (event, incoming) = {
            let _epoch = self.membership_gate.read().await;
            self.engine
                .create_and_process_media_event_multi(group_id, &refs, caption)?
        };
        let Incoming::Message(message) = incoming else {
            return Err(Error::Storage(
                "created media message did not produce a local transcript row".into(),
            ));
        };
        let group_id_hex = hex::encode(group_id.as_slice());
        let group_name = self.resolve_group_name(group_id);
        self.mark_outbox_pending(group_id, &message, &event)?;
        let event_id = event.id;
        let publish_ack =
            self.spawn_outbox_publish(message.id.to_hex(), group_id_hex.clone(), event);
        self.notify_conversation_changed(&group_id_hex);
        self.spawn_send_bookkeeping(group_name, message, event_id);
        self.spawn_push_notification(group_id.clone(), publish_ack);
        Ok(())
    }

    /// Download the encrypted blob at `url` and decrypt it with the group media
    /// key (resolved from the message's imeta tag). Returns plaintext bytes.
    pub async fn fetch_media(&self, group_id: &GroupId, url: &str) -> Result<Vec<u8>> {
        let ciphertext = http_get_with_retries(url, None).await?;
        self.engine.decrypt_media_by_url(group_id, url, &ciphertext)
    }

    /// Download, authenticate, and decrypt an attachment into a host-owned
    /// file. Only the final byte count crosses FFI, keeping large documents and
    /// videos out of Swift/Kotlin reactive state. The host supplies a unique
    /// partial path and atomically promotes it into its cache after success.
    pub async fn fetch_media_to_file(
        &self,
        group_id: &GroupId,
        url: &str,
        destination: &Path,
        observer: &dyn MediaDownloadObserver,
    ) -> Result<u64> {
        let ciphertext = http_get_with_retries(url, Some(observer)).await?;
        if observer.is_cancelled() {
            return Err(Error::MediaDownloadCancelled);
        }
        let plaintext = self
            .engine
            .decrypt_media_by_url(group_id, url, &ciphertext)?;
        if observer.is_cancelled() {
            return Err(Error::MediaDownloadCancelled);
        }
        let parent = destination
            .parent()
            .ok_or_else(|| Error::InvalidInput("media destination has no parent".into()))?;
        fs::create_dir_all(parent)
            .map_err(|error| Error::Storage(format!("create media cache directory: {error}")))?;
        let mut options = fs::OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(destination)
            .map_err(|error| Error::Storage(format!("create media cache file: {error}")))?;
        use std::io::Write as _;
        if let Err(error) = file.write_all(&plaintext).and_then(|_| file.sync_all()) {
            drop(file);
            let _ = fs::remove_file(destination);
            return Err(Error::Storage(format!("write media cache file: {error}")));
        }
        Ok(plaintext.len() as u64)
    }

    /// Upload an encrypted blob to a Blossom server (BUD-02), authed with our
    /// Nostr key, returning the URL where it can be fetched.
    async fn blossom_upload(&self, server_url: &str, data: Vec<u8>) -> Result<String> {
        let server = if server_url.is_empty() {
            DEFAULT_BLOSSOM_SERVER
        } else {
            server_url
        };
        let base = Url::parse(server)
            .map_err(|e| Error::Blossom(format!("bad server url {server}: {e}")))?;
        let descriptor = BlossomClient::new(base)
            .upload_blob(
                data,
                Some(ENCRYPTED_BLOB_MIME_TYPE.to_string()),
                None,
                Some(self.identity().keys()),
            )
            .await
            .map_err(|e| Error::Blossom(e.to_string()))?;
        Ok(descriptor.url.to_string())
    }

    /// The user's Blossom server list (kind-10063 / BUD-03). Empty if unset.
    pub async fn blossom_servers(&self) -> Result<Vec<String>> {
        let filter = Filter::new()
            .kind(Kind::Custom(BLOSSOM_SERVER_LIST_KIND))
            .author(self.identity().public_key())
            .limit(1);
        let mut servers = Vec::new();
        for event in self.nostr.fetch_events(filter, FETCH_TIMEOUT).await? {
            for tag in event.tags.iter() {
                if tag.kind() == TagKind::Custom("server".into()) {
                    if let Some(url) = tag.content() {
                        servers.push(url.to_string());
                    }
                }
            }
        }
        Ok(servers)
    }

    /// Publish our Blossom server list (kind-10063) so peers and our other
    /// devices know where our blobs live.
    pub async fn publish_blossom_servers(&self, servers: Vec<String>) -> Result<()> {
        let tags = servers
            .into_iter()
            .map(|s| Tag::custom(TagKind::Custom("server".into()), [s]));
        let builder = EventBuilder::new(Kind::Custom(BLOSSOM_SERVER_LIST_KIND), "").tags(tags);
        self.nostr.send_event_builder(builder).await?;
        Ok(())
    }

    /// Poll the relays once for anything NEW since the last sync: gift-wrapped
    /// welcomes addressed to us (which may add groups), then kind-445 messages
    /// for every known group.
    ///
    /// A monotonic per-session watermark scopes each fetch with `.since(...)`,
    /// so a repeat poll only pulls events newer than the last one instead of
    /// re-downloading + re-processing the entire history every time (the naive
    /// version made every 5s poll a full backfill, which also starved media
    /// downloads queued behind it on the host). All group messages are fetched
    /// in ONE request batched on the `#h` tag, not one fetch per group. This is
    /// the same `last_synced_at` + batched-subscription pattern the White Noise
    /// reference client uses. Duplicate/already-processed events are tolerated.
    pub async fn sync(&self) -> Result<()> {
        self.sync_inner(false).await
    }

    /// Like `sync()` but bypasses the live-subscription short-circuit. Use after
    /// a foreground resume or relay reconnect to catch events that arrived while
    /// the subscription was dead.
    pub async fn sync_force(&self) -> Result<()> {
        self.sync_inner(true).await
    }

    async fn sync_inner(&self, force: bool) -> Result<()> {
        // Watermark from the previous successful sync (0 on the first poll of a
        // session → an unbounded backfill, bounded only by the `#p`/`#h` scope).
        let since_secs = self.sync_watermark_secs();

        let mut process_report = match self.run_initial_group_message_catchup().await {
            Ok(report) => report,
            Err(err) => {
                tracing::debug!(%err, "initial Marmot per-group catch-up failed");
                MarmotProcessReport::default()
            }
        };

        // When watermarked persistent subscriptions are active, sync() is
        // redundant — subscribe_marmot() already opened subscriptions with
        // `since=watermark` so the relay's EOSE burst covers the gap. The only
        // exception is the very first session (watermark==0), where we need at
        // least one full fetch to bootstrap the watermark.
        let is_live = *self.live_marmot_enabled.lock().unwrap();
        tracing::info!(is_live, since_secs, force, "sync() called");
        if is_live && since_secs > 0 && !force {
            tracing::info!("sync() short-circuited — live subscriptions active");
            self.save_or_rewind_without_advancing_watermark(process_report)?;
            self.retry_outbox().await;
            self.share_push_token_with_groups().await;
            return Ok(());
        }

        // Capture the start time as the next watermark BEFORE fetching, so any
        // event that lands mid-sync is re-covered by the overlap next poll.
        let started = Timestamp::now().as_secs();

        let mut wraps = Filter::new()
            .kind(Kind::GiftWrap)
            .pubkey(self.identity().public_key());
        if since_secs > 0 {
            // Gift wraps are backdated (NIP-59) → extra lookback so we don't
            // skip a just-received welcome whose wrapper timestamp is in the past.
            wraps = wraps.since(Timestamp::from_secs(
                since_secs.saturating_sub(GIFTWRAP_LOOKBACK_SECS),
            ));
        }
        // Scope to OUR Marmot relays, not the whole pool: `subscribe_geohash`
        // adds up to a dozen geohash-nearest relays per opened channel, none of
        // which carry our 1059/445 events — fetching from them only makes the
        // sync wait on their EOSE. The MLS group + KeyPackage relay lists are
        // built from `self.relays`, so conformant peers publish welcomes there.
        let ids_before = self.current_group_ids()?;
        let wraps = self
            .fetch_marmot_events_from_relay_quorum(wraps, FETCH_TIMEOUT, "gift wrap sync")
            .await?;
        if !wraps.completed_quorum() {
            process_report.record_retryable(started);
        }
        let (wrap_report, _) = self.process_marmot_events(wraps.events, "gift wrap").await;
        process_report.absorb(wrap_report);

        // A welcome processed during sync can add group(s). Backfill all new
        // groups in ONE batched fetch, then widen the live tail if it is enabled.
        let new_group_ids: Vec<String> = self
            .current_group_ids()?
            .into_iter()
            .filter(|id| !ids_before.contains(id))
            .collect();
        if !new_group_ids.is_empty() {
            match self.backfill_groups(&new_group_ids).await {
                Ok(report) => process_report.absorb(report),
                Err(err) => {
                    tracing::debug!(%err, "batched new-group backfill failed during sync");
                    process_report.record_retryable(Timestamp::now().as_secs());
                }
            }
        }
        // Existing installs can have group/MLS rows locally while the chat
        // transcript page is empty. Full-backfill those groups once. The scan
        // is deferred from client construction to the first sync so it does not
        // delay local-only first paint.
        self.populate_empty_transcript_backfills_once();
        let empty_transcript_group_ids = self.take_initial_empty_transcript_backfills();
        if !empty_transcript_group_ids.is_empty() {
            // Cap per-sync to avoid stacking timeouts when many groups need repair.
            let (batch, overflow): (Vec<_>, Vec<_>) = empty_transcript_group_ids
                .into_iter()
                .enumerate()
                .partition(|(i, _)| *i < MAX_BACKFILLS_PER_SYNC);
            for (_, id) in &overflow {
                self.requeue_initial_empty_transcript_backfill(id);
            }
            let batch_ids: Vec<String> = batch.into_iter().map(|(_, id)| id).collect();
            match self.backfill_groups(&batch_ids).await {
                Ok(report) => process_report.absorb(report),
                Err(err) => {
                    tracing::debug!(%err, "batched empty transcript backfill failed");
                    for id in &batch_ids {
                        self.requeue_initial_empty_transcript_backfill(id);
                    }
                    process_report.record_retryable(Timestamp::now().as_secs());
                }
            }
        }
        if let Err(err) = self.resubscribe_marmot_groups_if_live().await {
            tracing::debug!(%err, "marmot group live resubscribe failed during sync");
        }

        // Fetch kind-445 for ALL known groups in one request (batched `#h`),
        // including any group a welcome just added above. Skip when the live
        // subscription tail is active — it already delivers these events, and
        // the watermarked fetch is redundant work that stacks a 10s timeout.
        let is_live = *self.live_marmot_enabled.lock().unwrap();
        let group_ids: Vec<String> = self.current_group_ids()?.into_iter().collect();
        if !group_ids.is_empty() && !is_live {
            let mut filter = Filter::new()
                .kind(Kind::MlsGroupMessage)
                .custom_tags(SingleLetterTag::lowercase(Alphabet::H), group_ids);
            if since_secs > 0 {
                filter = filter.since(Timestamp::from_secs(
                    since_secs.saturating_sub(SYNC_OVERLAP_SECS),
                ));
            }
            let events = self
                .fetch_marmot_events_from_relay_quorum(filter, FETCH_TIMEOUT, "group message sync")
                .await?;
            if !events.completed_quorum() {
                process_report.record_retryable(started);
            }
            let (msg_report, _) = self
                .process_marmot_events(events.events, "group message")
                .await;
            process_report.absorb(msg_report);
        }

        if process_report.retryable_failures == 0 {
            self.advance_sync_watermark(started)?;
        } else if let Some(secs) = process_report.oldest_retryable_secs {
            self.rewind_sync_watermark_for_retry(secs)?;
        } else {
            self.save_sync_state()?;
        }
        self.retry_outbox().await;
        self.share_push_token_with_groups().await;
        Ok(())
    }

    /// Open persistent Marmot subscriptions:
    /// welcomes (kind-1059 → us) and group messages (kind-445 on our `#h`).
    /// The relay delivers historical events (EOSE burst) then pushes new ones.
    /// Events flow to the notification handler → buffer → `drain_pending_marmot`.
    ///
    /// Welcomes use the durable watermark lookback. Group messages use a thin
    /// live tail; bounded per-group catch-up owns older history so cold start
    /// cannot flood the live buffer or compete with a user send.
    pub async fn subscribe_marmot(&self) -> Result<()> {
        let since_secs = self.sync_watermark_secs();
        let mut wraps = Filter::new()
            .kind(Kind::GiftWrap)
            .pubkey(self.identity().public_key());
        if since_secs > 0 {
            wraps = wraps.since(Timestamp::from_secs(
                since_secs.saturating_sub(GIFTWRAP_LOOKBACK_SECS),
            ));
        }
        self.nostr
            .subscribe_with_id(SubscriptionId::new(SUB_MARMOT_WELCOMES), wraps, None)
            .await?;
        tracing::info!(since_secs, "marmot welcomes subscription opened");
        *self.live_marmot_enabled.lock().unwrap() = true;
        self.subscribe_group_messages().await
    }

    /// (Re)subscribe the kind-445 tail to the CURRENT group set, using the
    /// sync watermark as `since` (not `now`). Re-running with the same id
    /// REPLACES the filter, so calling this after a welcome adds a group widens
    /// the subscription. History for a newly-added group is fetched separately
    /// by `backfill_group`.
    async fn subscribe_group_messages(&self) -> Result<()> {
        let group_ids = self.current_group_ids()?;
        let sub_id = SubscriptionId::new(SUB_MARMOT_GROUPS);

        if group_ids.is_empty() {
            let had_subscription = {
                let current = self.marmot_group_subscriptions.lock().unwrap();
                !current.is_empty()
            };
            if had_subscription {
                self.nostr.unsubscribe(&sub_id).await;
                self.marmot_group_subscriptions.lock().unwrap().clear();
                tracing::info!("marmot group subscription closed (no groups)");
            }
            return Ok(());
        }

        {
            let current = self.marmot_group_subscriptions.lock().unwrap();
            if *current == group_ids {
                return Ok(());
            }
        }

        // Live tail is intentionally thin. Historical recovery is the catch-up
        // queue's job; using the full watermark here re-floods cold start.
        let watermark_secs = self.sync_watermark_secs();
        let now_secs = Timestamp::now().as_secs();
        let since_secs = live_group_since_secs(watermark_secs, now_secs);
        let mut group_id_list: Vec<String> = group_ids.iter().cloned().collect();
        group_id_list.sort();
        let mut filter = Filter::new()
            .kind(Kind::MlsGroupMessage)
            .custom_tags(SingleLetterTag::lowercase(Alphabet::H), group_id_list);
        filter = filter.since(Timestamp::from_secs(since_secs));
        self.nostr.subscribe_with_id(sub_id, filter, None).await?;
        tracing::info!(
            since_secs,
            watermark_secs,
            live_tail_secs = LIVE_GROUP_TAIL_SECS,
            groups = group_ids.len(),
            "marmot group subscription opened"
        );
        *self.marmot_group_subscriptions.lock().unwrap() = group_ids;
        Ok(())
    }

    fn current_group_ids(&self) -> Result<HashSet<String>> {
        Ok(self
            .engine
            .groups()?
            .into_iter()
            .map(|g| hex::encode(g.nostr_group_id))
            .collect())
    }

    fn empty_transcript_group_ids(engine: &MarmotEngine) -> HashSet<String> {
        let Ok(groups) = engine.groups() else {
            return HashSet::new();
        };
        groups
            .into_iter()
            .filter_map(
                |group| match engine.messages_page(&group.mls_group_id, 1, 0) {
                    Ok(page) if page.is_empty() => Some(hex::encode(group.nostr_group_id)),
                    _ => None,
                },
            )
            .collect()
    }

    fn populate_empty_transcript_backfills_once(&self) {
        if self.initial_backfill_scanned.swap(true, Ordering::Relaxed) {
            return;
        }
        let mut set = self.initial_empty_transcript_backfills.lock().unwrap();
        *set = Self::empty_transcript_group_ids(&self.engine);
    }

    fn take_initial_empty_transcript_backfills(&self) -> Vec<String> {
        self.initial_empty_transcript_backfills
            .lock()
            .unwrap()
            .drain()
            .collect()
    }

    fn requeue_initial_empty_transcript_backfill(&self, group_id_hex: &str) {
        self.initial_empty_transcript_backfills
            .lock()
            .unwrap()
            .insert(group_id_hex.to_string());
    }

    fn group_message_catchup_floors(engine: &MarmotEngine) -> HashMap<String, u64> {
        let Ok(groups) = engine.groups() else {
            return HashMap::new();
        };
        groups
            .into_iter()
            .filter_map(|group| {
                let has_local_chat = engine
                    .messages_page(&group.mls_group_id, 1, 0)
                    .map(|page| !page.is_empty())
                    .unwrap_or(false);
                if !has_local_chat {
                    return None;
                }
                let floor = engine
                    .latest_remote_chat_message_secs(&group.mls_group_id)
                    .unwrap_or(0);
                Some((hex::encode(group.nostr_group_id), floor))
            })
            .collect()
    }

    fn populate_initial_group_message_catchups_once(&self) {
        if self
            .initial_group_message_catchup_scanned
            .swap(true, Ordering::Relaxed)
        {
            return;
        }
        let mut queue = self.initial_group_message_catchups.lock().unwrap();
        *queue =
            Self::group_message_catchup_queue(Self::group_message_catchup_floors(&self.engine));
        tracing::info!(
            groups = queue.len(),
            "initial group message catch-up queued"
        );
    }

    fn take_initial_group_message_catchup(&self) -> Option<(String, u64)> {
        let preferred = self.preferred_catchup_group.lock().unwrap().clone();
        let mut queue = self.initial_group_message_catchups.lock().unwrap();
        take_catchup_entry(&mut queue, preferred.as_deref())
    }

    fn requeue_initial_group_message_catchup(&self, group_id: String, floor: u64) {
        tracing::debug!(group = %group_id, floor, "group message catch-up requeued");
        let mut queue = self.initial_group_message_catchups.lock().unwrap();
        Self::push_group_message_catchup_back(&mut queue, group_id, floor);
    }

    fn group_message_catchup_queue(floors: HashMap<String, u64>) -> VecDeque<(String, u64)> {
        let mut entries: Vec<_> = floors.into_iter().collect();
        entries.sort_by(|a, b| a.0.cmp(&b.0));
        entries.into()
    }

    fn push_group_message_catchup_back(
        queue: &mut VecDeque<(String, u64)>,
        group_id: String,
        floor: u64,
    ) {
        queue.retain(|(queued_id, _)| queued_id != &group_id);
        queue.push_back((group_id, floor));
    }

    async fn run_initial_group_message_catchup(&self) -> Result<MarmotProcessReport> {
        if self.relays.is_empty() {
            return Ok(MarmotProcessReport::default());
        }
        // P0: never compete with an in-flight user send. Live drain still runs;
        // only historical catch-up yields. This cannot break MLS groups because
        // send encrypts against current local epoch and publish is network-only.
        if self.send_inflight.load(Ordering::Relaxed) > 0 {
            tracing::debug!(
                inflight = self.send_inflight.load(Ordering::Relaxed),
                "deferring group catch-up while send publish is in flight"
            );
            return Ok(MarmotProcessReport::default());
        }
        self.populate_initial_group_message_catchups_once();
        let Some((group_id, floor)) = self.take_initial_group_message_catchup() else {
            return Ok(MarmotProcessReport::default());
        };

        let group_ids = vec![group_id.clone()];
        match self
            .backfill_groups_since(
                &group_ids,
                Some(floor),
                "initial per-group message catch-up",
            )
            .await
        {
            Ok(report) => {
                if report.retryable_failures > 0 {
                    self.requeue_initial_group_message_catchup(group_id, floor);
                }
                Ok(report)
            }
            Err(err) => {
                self.requeue_initial_group_message_catchup(group_id, floor);
                Err(err)
            }
        }
    }

    async fn resubscribe_marmot_groups_if_live(&self) -> Result<()> {
        let is_live = *self.live_marmot_enabled.lock().unwrap();
        if !is_live {
            return Ok(());
        }
        self.subscribe_group_messages().await
    }

    /// Prefer catch-up for the open chat.
    ///
    /// Hosts pass the MLS group id hex (same id used by send_text / messages).
    /// We map it to the public nostr group id used by the catch-up queue (#h tag).
    /// Unknown/empty clears the preference.
    pub fn prefer_catchup_group(&self, mls_group_id_hex: Option<String>) {
        let preferred = match mls_group_id_hex {
            None => None,
            Some(raw) => {
                let clean = raw.trim().to_ascii_lowercase();
                if clean.is_empty() {
                    None
                } else if let Ok(groups) = self.engine.groups() {
                    groups.into_iter().find_map(|g| {
                        let mls = hex::encode(g.mls_group_id.as_slice());
                        if mls == clean {
                            Some(hex::encode(g.nostr_group_id))
                        } else {
                            None
                        }
                    })
                } else {
                    // Fall back to treating the input as already-nostr hex so
                    // tests/tools can still target the queue key directly.
                    Some(clean)
                }
            }
        };
        *self.preferred_catchup_group.lock().unwrap() = preferred;
    }

    /// Re-subscribe with the current watermark and group set. Idempotent:
    /// `subscribe_with_id` replaces existing filters. Hosts call this
    /// periodically (every 25-60s) to self-heal after relay disconnects,
    /// replacing the heavy `sync()` poll on the idle path. It may also run one
    /// bounded per-chat repair fetch for existing installs, so callers must keep
    /// it on a background/IO queue and never in the local-first chat-open path.
    pub async fn ensure_subscriptions(&self) -> Result<()> {
        if !*self.live_marmot_enabled.lock().unwrap() {
            return Ok(());
        }
        // P2: hosts call this every 25-60s. Avoid thrashing welcome/group REQs
        // when nothing changed and we recently ensured.
        const MIN_ENSURE_INTERVAL: Duration = Duration::from_secs(20);
        let now = Instant::now();
        let should_resub = {
            let mut last = self.last_ensure_subscriptions_at.lock().unwrap();
            match *last {
                Some(prev) if now.duration_since(prev) < MIN_ENSURE_INTERVAL => false,
                _ => {
                    *last = Some(now);
                    true
                }
            }
        };
        if should_resub {
            self.subscribe_marmot().await?;
        }
        match self.run_initial_group_message_catchup().await {
            Ok(report) => self.save_or_rewind_without_advancing_watermark(report)?,
            Err(err) => tracing::debug!(%err, "initial Marmot per-group catch-up failed"),
        }
        Ok(())
    }

    fn sync_watermark_secs(&self) -> u64 {
        self.sync_state.lock().unwrap().watermark_secs()
    }

    /// Point-in-time relay/sync diagnostics for the Diagnostics screen and
    /// the exported debug bundle. Contains NO message content and NO key
    /// material: relay URLs and statuses, the sync watermark, live
    /// subscription state, and per-group catch-up floors (group ids are the
    /// public nostr group ids already visible on relays as `#h` tags).
    pub async fn sync_state_snapshot(&self) -> SyncStateSnapshot {
        // Take the relay map from the `.await` BEFORE acquiring any std Mutex
        // below, so no lock guard is ever held across an await point.
        let relay_map = self.nostr.relays().await;
        let relays = self
            .relays
            .iter()
            .map(|url| RelaySnapshot {
                url: url.to_string(),
                // `RelayStatus` `Display` is the stable public string
                // ("Connected", ...); avoid `Debug` for this serialized field.
                status: relay_map
                    .get(url)
                    .map(|handle| handle.status().to_string())
                    .unwrap_or_else(|| "unknown".into()),
            })
            .collect();
        let mut group_floors: Vec<GroupFloorSnapshot> =
            Self::group_message_catchup_floors(&self.engine)
                .into_iter()
                .map(|(group_id_hex, floor_secs)| GroupFloorSnapshot {
                    group_id_hex,
                    floor_secs,
                })
                .collect();
        group_floors.sort_by(|a, b| a.group_id_hex.cmp(&b.group_id_hex));
        SyncStateSnapshot {
            generated_at_secs: Timestamp::now().as_secs(),
            watermark_secs: self.sync_watermark_secs(),
            live_marmot_enabled: *self.live_marmot_enabled.lock().unwrap(),
            subscribed_group_count: self.marmot_group_subscriptions.lock().unwrap().len(),
            pending_marmot_buffered: self.pending_marmot_giftwraps.lock().unwrap().len()
                + self.pending_marmot_groups.lock().unwrap().len(),
            send_inflight: self.send_inflight.load(Ordering::Relaxed),
            buffer_drops_total: self.buffer_drops_total.load(Ordering::Relaxed),
            catchup_queue_len: self.initial_group_message_catchups.lock().unwrap().len(),
            relays,
            group_floors,
        }
    }

    fn is_sync_event_processed(&self, event_id: &EventId) -> bool {
        self.sync_state
            .lock()
            .unwrap()
            .has_processed(&event_id.to_hex())
    }

    fn mark_sync_event_processed(&self, event_id: &EventId) {
        self.sync_state.lock().unwrap().mark_processed(event_id);
    }

    fn save_sync_state(&self) -> Result<()> {
        self.sync_state.lock().unwrap().save_if_dirty()
    }

    fn advance_sync_watermark(&self, watermark_secs: u64) -> Result<()> {
        {
            let mut state = self.sync_state.lock().unwrap();
            state.advance_watermark(watermark_secs);
        }
        self.save_sync_state()
    }

    fn rewind_sync_watermark_for_retry(&self, event_secs: u64) -> Result<()> {
        {
            let mut state = self.sync_state.lock().unwrap();
            state.rewind_for_retry(event_secs);
        }
        self.save_sync_state()
    }

    fn save_or_rewind_without_advancing_watermark(
        &self,
        report: MarmotProcessReport,
    ) -> Result<()> {
        if let Some(secs) = report.oldest_retryable_secs {
            self.rewind_sync_watermark_for_retry(secs)
        } else {
            self.save_sync_state()
        }
    }

    async fn fetch_marmot_events_from_relay_quorum(
        &self,
        filter: Filter,
        timeout: Duration,
        context: &'static str,
    ) -> Result<RelayFetchOutcome> {
        let total_relays = self.relays.len();
        if total_relays == 0 {
            return Ok(RelayFetchOutcome {
                events: Vec::new(),
                completed_relays: 0,
                total_relays: 0,
            });
        }

        let quorum = relay_fetch_quorum(total_relays);
        let mut tasks = tokio::task::JoinSet::new();
        for relay in self.relays.clone() {
            let nostr = self.nostr.clone();
            let filter = filter.clone();
            tasks.spawn(async move {
                let relay_label = relay.to_string();
                let result = nostr.fetch_events_from(vec![relay], filter, timeout).await;
                (relay_label, result)
            });
        }

        let deadline = tokio::time::Instant::now() + timeout;
        let mut completed_relays = 0usize;
        let mut failed_relays = 0usize;
        let mut events = Vec::new();
        let mut seen = HashSet::new();
        let mut last_error: Option<String> = None;

        while completed_relays < quorum && completed_relays + failed_relays < total_relays {
            let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
            if remaining.is_zero() {
                break;
            }

            match tokio::time::timeout(remaining, tasks.join_next()).await {
                Ok(Some(Ok((relay, Ok(relay_events))))) => {
                    completed_relays += 1;
                    let mut accepted = 0usize;
                    for event in relay_events {
                        if seen.insert(event.id.to_hex()) {
                            events.push(event);
                            accepted += 1;
                        }
                    }
                    tracing::debug!(
                        relay,
                        accepted,
                        completed_relays,
                        quorum,
                        total_relays,
                        context,
                        "relay fetch completed"
                    );
                }
                Ok(Some(Ok((relay, Err(err))))) => {
                    failed_relays += 1;
                    last_error = Some(err.to_string());
                    tracing::debug!(
                        relay,
                        %err,
                        failed_relays,
                        total_relays,
                        context,
                        "relay fetch failed"
                    );
                }
                Ok(Some(Err(err))) => {
                    failed_relays += 1;
                    last_error = Some(err.to_string());
                    tracing::debug!(
                        %err,
                        failed_relays,
                        total_relays,
                        context,
                        "relay fetch task failed"
                    );
                }
                Ok(None) => break,
                Err(_) => break,
            }
        }

        if completed_relays == 0 {
            tasks.abort_all();
            return Err(Error::RelayFetch(format!(
                "{context}: no relay fetch completed before quorum/timeout{}",
                last_error
                    .as_deref()
                    .map(|err| format!("; last error: {err}"))
                    .unwrap_or_default()
            )));
        }

        if completed_relays < total_relays {
            tracing::debug!(
                completed_relays,
                failed_relays,
                total_relays,
                quorum,
                context,
                "relay fetch returned before all relays completed"
            );
            let pending = self.pending_marmot_groups.clone();
            let buffer_drops = self.buffer_drops_total.clone();
            let notify = self.marmot_notify.clone();
            let mut late_seen = seen.clone();
            tokio::spawn(async move {
                let mut late_events = 0usize;
                while let Some(joined) = tasks.join_next().await {
                    match joined {
                        Ok((relay, Ok(relay_events))) => {
                            let mut accepted = 0usize;
                            for event in relay_events {
                                if !late_seen.insert(event.id.to_hex()) {
                                    continue;
                                }
                                {
                                    let mut buf = pending.lock().unwrap();
                                    if push_live_buffer(&mut buf, event, MARMOT_GROUP_BUFFER_CAP) {
                                        buffer_drops.fetch_add(1, Ordering::Relaxed);
                                    }
                                }
                                accepted += 1;
                                late_events += 1;
                            }
                            tracing::debug!(
                                relay,
                                accepted,
                                context,
                                "late relay fetch buffered events"
                            );
                        }
                        Ok((relay, Err(err))) => {
                            tracing::debug!(
                                relay,
                                %err,
                                context,
                                "late relay fetch failed"
                            );
                        }
                        Err(err) => {
                            tracing::debug!(
                                %err,
                                context,
                                "late relay fetch task failed"
                            );
                        }
                    }
                }
                if late_events > 0 {
                    notify.notify_one();
                }
            });
        } else {
            tasks.abort_all();
        }

        Ok(RelayFetchOutcome {
            events,
            completed_relays,
            total_relays,
        })
    }

    async fn process_marmot_events(
        &self,
        events: impl IntoIterator<Item = Event>,
        context: &'static str,
    ) -> (MarmotProcessReport, Vec<DrainNotification>) {
        let mut report = MarmotProcessReport::default();
        let mut notifications: Vec<DrainNotification> = Vec::new();
        let mut changed_groups: HashSet<String> = HashSet::new();
        let group_names: HashMap<Vec<u8>, String> = self
            .engine
            .groups()
            .unwrap_or_default()
            .into_iter()
            .map(|g| (g.mls_group_id.as_slice().to_vec(), g.name))
            .collect();
        for event in sort_marmot_events(events) {
            if self.is_sync_event_processed(&event.id) {
                report.record_processed();
                continue;
            }

            // Intercept account-level gift wraps that are not Marmot MLS input
            // before they reach the MLS engine: push-token shares (kind 447)
            // and plain bitchat fallback DMs (NIP-17 kind 14).
            if event.kind == Kind::GiftWrap {
                if let Ok(unwrapped) =
                    UnwrappedGift::from_gift_wrap(self.engine.identity().keys(), &event).await
                {
                    if unwrapped.rumor.kind.as_u16() == crate::push::KIND_PUSH_TOKEN_SHARE {
                        match self
                            .handle_push_token_share(&unwrapped.sender, &unwrapped.rumor.content)
                        {
                            Ok(()) => {
                                self.mark_sync_event_processed(&event.id);
                                report.record_processed();
                            }
                            Err(err) => {
                                tracing::debug!(
                                    %err,
                                    event_id = %event.id,
                                    event_created_at = event.created_at.as_secs(),
                                    context,
                                    "push token share needs retry"
                                );
                                report.record_retryable(event.created_at.as_secs());
                            }
                        }
                        continue;
                    }
                    if unwrapped.rumor.kind.as_u16() == 14 {
                        if let Some(dm) = crate::mesh::decode_nip17_private_message_content(
                            &unwrapped.rumor.content,
                        ) {
                            let event_id = event.id.to_hex();
                            let mut buf = self.direct_dm.lock().unwrap();
                            if !buf.iter().any(|existing| {
                                existing.event_id == event_id
                                    || (existing.id == dm.message_id
                                        && existing.sender == unwrapped.sender)
                            }) {
                                if buf.len() >= DIRECT_DM_BUFFER_CAP {
                                    buf.drain(0..DIRECT_DM_BUFFER_CAP / 2);
                                }
                                buf.push(RawDirectDm {
                                    event_id,
                                    id: dm.message_id,
                                    sender: unwrapped.sender,
                                    content: dm.content,
                                    ts: unwrapped.rumor.created_at.as_secs(),
                                });
                            }
                            report.record_retryable(event.created_at.as_secs());
                        } else {
                            tracing::debug!(
                                event_id = %event.id,
                                "ignoring non-bitchat account-level NIP-17 DM"
                            );
                            self.mark_sync_event_processed(&event.id);
                            report.record_processed();
                        }
                        continue;
                    }
                }
            }

            match self.engine.process_incoming(&event).await {
                Ok(Incoming::Failed) => {
                    // Count the delivery as handled so one bad ciphertext does
                    // not pin the global watermark, but do NOT add it to Sonar's
                    // durable processed-ID set. MDK can change a Failed record
                    // to Retryable after an MLS commit rollback; a later relay
                    // catch-up must then reach MDK so the missing message can be
                    // decrypted and stored.
                    tracing::debug!(
                        event_id = %event.id,
                        event_created_at = event.created_at.as_secs(),
                        context,
                        "marmot event failed in MDK; preserving rollback retry"
                    );
                    report.record_processed();
                }
                Ok(Incoming::GroupProposal(update)) => {
                    // Capture the group id before `update` is moved: a merged
                    // proposal changes local membership, which the conversation
                    // listener must see (same silent-miss class as welcomes).
                    let proposal_group_hex = hex::encode(update.group_id.as_slice());
                    // Auto-committing a peer proposal is a membership change
                    // like any other: exclude sends until publish+merge done.
                    let _epoch = self.membership_gate.write().await;
                    match self.publish_membership_update(update).await {
                        Ok(()) => {
                            changed_groups.insert(proposal_group_hex);
                            self.mark_sync_event_processed(&event.id);
                            report.record_processed();
                        }
                        Err(err) => {
                            tracing::debug!(
                                %err,
                                event_id = %event.id,
                                event_created_at = event.created_at.as_secs(),
                                context,
                                "marmot auto-commit publish failed; leaving sync cursor behind it"
                            );
                            report.record_retryable(event.created_at.as_secs());
                        }
                    }
                }
                Ok(Incoming::JoinRequest(request)) => {
                    let group_hex = hex::encode(request.group_id.as_slice());
                    if self.store_join_request(request).unwrap_or(false) {
                        changed_groups.insert(group_hex);
                    }
                    self.mark_sync_event_processed(&event.id);
                    report.record_processed();
                }
                Ok(ref incoming @ Incoming::Message(ref message)) => {
                    self.record_delivery_for_incoming(incoming);
                    let cached_name = group_names
                        .get(message.group_id.as_slice())
                        .map(|s| s.as_str());
                    self.upsert_index_for_message(message, cached_name);
                    changed_groups.insert(hex::encode(message.group_id.as_slice()));
                    if !message.mine {
                        let preview = if message.content.len() > 100 {
                            let mut end = 100;
                            while !message.content.is_char_boundary(end) {
                                end -= 1;
                            }
                            format!("{}…", &message.content[..end])
                        } else {
                            message.content.clone()
                        };
                        notifications.push(DrainNotification {
                            sender_pubkey: message.sender.to_string(),
                            group_name: cached_name.unwrap_or("").to_string(),
                            content_preview: preview,
                        });
                    }
                    self.mark_sync_event_processed(&event.id);
                    report.record_processed();
                }
                Ok(incoming) => {
                    self.record_delivery_for_incoming(&incoming);
                    // A welcome or membership update that created or changed a
                    // group must notify the conversation listener like a message
                    // does: the hosts' chat lists are event-driven, so without
                    // this a brand-new conversation stays invisible until an
                    // unrelated slow heartbeat repaints the list. GroupUpdated
                    // also covers kind-445 commit/proposal merges, whose
                    // member-list change the row should reflect.
                    if let Incoming::GroupUpdated(group_id)
                    | Incoming::GroupInvitePending(group_id) = &incoming
                    {
                        changed_groups.insert(hex::encode(group_id.as_slice()));
                    }
                    self.mark_sync_event_processed(&event.id);
                    report.record_processed();
                }
                Err(err) if is_terminal_marmot_processing_error(&err) => {
                    tracing::debug!(
                        %err,
                        event_id = %event.id,
                        context,
                        "terminal marmot event failure; marking event processed"
                    );
                    self.mark_sync_event_processed(&event.id);
                    report.record_processed();
                }
                Err(err) => {
                    tracing::debug!(
                        %err,
                        event_id = %event.id,
                        event_created_at = event.created_at.as_secs(),
                        context,
                        "marmot event processing failed; leaving sync cursor behind it"
                    );
                    report.record_retryable(event.created_at.as_secs());
                }
            }
        }
        self.notify_conversations_changed(&changed_groups);
        (report, notifications)
    }

    /// One-off fetch of a single group's full kind-445 history (no `since`),
    /// processed through the engine. Used when a welcome adds a group whose
    /// messages predate the sync watermark, so they'd be missed by both the
    /// watermarked `sync()` and the since-now live subscription.
    async fn backfill_group(&self, group_id_hex: &str) -> Result<MarmotProcessReport> {
        let group_ids = vec![group_id_hex.to_string()];
        self.backfill_groups_since(&group_ids, None, "group backfill")
            .await
    }

    /// Batched variant: fetches kind-445 history for multiple groups in ONE
    /// request using a combined `#h` filter. Same as `backfill_group` but
    /// avoids serial timeouts when multiple groups need backfill.
    async fn backfill_groups(&self, group_id_hexes: &[String]) -> Result<MarmotProcessReport> {
        self.backfill_groups_since(group_id_hexes, None, "batched group backfill")
            .await
    }

    async fn backfill_groups_since(
        &self,
        group_id_hexes: &[String],
        since_secs: Option<u64>,
        context: &'static str,
    ) -> Result<MarmotProcessReport> {
        if group_id_hexes.is_empty() {
            return Ok(MarmotProcessReport::default());
        }
        let mut filter = Filter::new().kind(Kind::MlsGroupMessage).custom_tags(
            SingleLetterTag::lowercase(Alphabet::H),
            group_id_hexes.to_vec(),
        );
        if let Some(secs) = since_secs.filter(|secs| *secs > 0) {
            filter = filter.since(Timestamp::from_secs(secs.saturating_sub(SYNC_OVERLAP_SECS)));
        }
        let events = self
            .fetch_marmot_events_from_relay_quorum(filter, BACKFILL_TIMEOUT, context)
            .await?;
        let partial = !events.completed_quorum();
        let (mut report, _) = self
            .process_marmot_events(events.events, "backfilled group message")
            .await;
        if partial {
            report.record_retryable(Timestamp::now().as_secs());
        }
        Ok(report)
    }

    /// Park until a live Marmot event is buffered (or `timeout_secs` elapses).
    /// Returns true if there is something to drain. This is the host's "wait for
    /// push" primitive — it touches NO engine state, so it is the one Marmot call
    /// the host may run OFF its serialized engine queue.
    pub async fn wait_for_marmot_event(&self, timeout_secs: u64) -> bool {
        if !self.pending_marmot_giftwraps.lock().unwrap().is_empty()
            || !self.pending_marmot_groups.lock().unwrap().is_empty()
        {
            return true;
        }
        tokio::time::timeout(
            Duration::from_secs(timeout_secs.max(1)),
            self.marmot_notify.notified(),
        )
        .await
        .is_ok()
    }

    /// Process every buffered live Marmot event through the MLS engine, then
    /// widen the group subscription if a welcome just added a group. Returns true
    /// if anything was drained. MUST run on the host's serialized engine thread
    /// (it mutates MLS state); the notification handler only ever BUFFERS.
    pub async fn drain_pending_marmot(&self) -> Result<Vec<DrainNotification>> {
        let mut events: Vec<Event> = {
            let mut giftwraps = self.pending_marmot_giftwraps.lock().unwrap();
            let mut groups = self.pending_marmot_groups.lock().unwrap();
            if giftwraps.is_empty() && groups.is_empty() {
                return Ok(Vec::new());
            }
            let mut out = std::mem::take(&mut *giftwraps);
            out.append(&mut *groups);
            out
        };
        sort_marmot_events_in_place(&mut events);
        let ids_before = self.current_group_ids()?;
        let (mut process_report, notifications) = self
            .process_marmot_events(events, "live marmot event")
            .await;
        // A welcome may have joined new group(s): backfill each one's history
        // (predates the watermark + the since-now sub) and widen the live sub.
        let new_ids: Vec<String> = self
            .current_group_ids()?
            .into_iter()
            .filter(|id| !ids_before.contains(id))
            .collect();
        if !new_ids.is_empty() {
            match self.backfill_groups(&new_ids).await {
                Ok(report) => process_report.absorb(report),
                Err(err) => {
                    tracing::debug!(%err, "batched group backfill failed (sync will retry)");
                    process_report.record_retryable(Timestamp::now().as_secs());
                }
            }
            let _ = self.resubscribe_marmot_groups_if_live().await;
        }
        if let Some(secs) = process_report.oldest_retryable_secs {
            self.rewind_sync_watermark_for_retry(secs)?;
        } else if process_report.processed > 0 {
            // Live subscriptions prove only that these buffered events were
            // processed. They do not provide a relay EOSE/completeness signal,
            // so advancing the durable cursor to "now" can skip older live
            // events dropped by the bounded buffer or by a flaky connection.
            // Persist processed IDs, but leave the watermark for the next
            // complete sync/subscription catch-up window.
            self.save_sync_state()?;
        } else {
            self.save_sync_state()?;
        }
        Ok(notifications)
    }

    pub fn groups(&self) -> Result<Vec<group_types::Group>> {
        self.engine.groups()
    }

    pub fn messages(&self, group_id: &GroupId) -> Result<Vec<ChatMessage>> {
        self.engine.messages(group_id).map(|msgs| {
            msgs.into_iter()
                .map(|m| self.with_delivery_state(m))
                .collect()
        })
    }

    pub fn messages_page(
        &self,
        group_id: &GroupId,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<ChatMessage>> {
        self.engine
            .messages_page(group_id, limit, offset)
            .map(|msgs| {
                msgs.into_iter()
                    .map(|m| self.with_delivery_state(m))
                    .collect()
            })
    }

    pub fn recent_message_pages(
        &self,
        group_limit: usize,
        page_limit: usize,
    ) -> Result<Vec<RecentMessagePage>> {
        self.engine
            .recent_message_pages(group_limit, page_limit)
            .map(|pages| {
                pages
                    .into_iter()
                    .map(|mut page| {
                        page.messages = page
                            .messages
                            .into_iter()
                            .map(|m| self.with_delivery_state(m))
                            .collect();
                        page
                    })
                    .collect()
            })
    }

    fn with_delivery_state(&self, mut message: ChatMessage) -> ChatMessage {
        if let Some(state) = self
            .outbox_state
            .lock()
            .unwrap()
            .status_for_message(&message.id.to_hex())
        {
            message.delivery_state = state;
        } else if message.mine {
            message.delivery_state = DeliveryState::Sent;
        } else {
            message.delivery_state = DeliveryState::Received;
        }
        message
    }

    pub fn members(&self, group_id: &GroupId) -> Result<Vec<PublicKey>> {
        self.engine.members(group_id)
    }

    /// Delete a single Marmot chat's local state (see
    /// [`MarmotEngine::delete_group`]) and narrow the live 445 subscription so we
    /// stop receiving its messages. Local-only; the peer is not notified.
    pub async fn delete_group(&self, group_id: &GroupId) -> Result<()> {
        let group_id_hex = hex::encode(group_id.as_slice());
        self.engine.delete_group(group_id)?;
        self.outbox_state
            .lock()
            .unwrap()
            .remove_group_entries(&group_id_hex)?;
        self.remove_index_for_group(group_id);
        self.notify_conversation_changed(&group_id_hex);
        let _ = self.resubscribe_marmot_groups_if_live().await;
        Ok(())
    }

    // ── Conversation index (Signal-style summary table) ──────────────────

    pub fn set_conversation_change_listener(
        &self,
        listener: Option<Arc<dyn ConversationChangeListener>>,
    ) {
        *self.change_listener.lock().unwrap() = listener;
    }

    pub fn conversation_summaries(&self) -> Vec<ConversationSummary> {
        let Some(ref idx) = self.conversation_index else {
            return Vec::new();
        };
        idx.lock().unwrap().summaries_ordered().unwrap_or_default()
    }

    pub fn conversation_summary(&self, group_id_hex: &str) -> Option<ConversationSummary> {
        let idx = self.conversation_index.as_ref()?;
        idx.lock().unwrap().summary(group_id_hex).ok().flatten()
    }

    pub fn mark_conversation_read(&self, group_id_hex: &str) {
        if let Some(ref idx) = self.conversation_index {
            if let Err(e) = idx.lock().unwrap().mark_read(group_id_hex) {
                tracing::warn!(%e, "index mark_read failed");
            }
            self.notify_conversation_changed(group_id_hex);
        }
    }

    pub fn messages_cursor_page(
        &self,
        group_id: &GroupId,
        before_secs: Option<u64>,
        before_id: Option<&nostr::EventId>,
        limit: usize,
    ) -> Result<Vec<ChatMessage>> {
        self.engine
            .messages_cursor_page(group_id, before_secs, before_id, limit)
            .map(|msgs| {
                msgs.into_iter()
                    .map(|m| self.with_delivery_state(m))
                    .collect()
            })
    }

    fn upsert_index_for_message(&self, message: &ChatMessage, group_name: Option<&str>) {
        let Some(ref idx) = self.conversation_index else {
            return;
        };
        let group_id_hex = hex::encode(message.group_id.as_slice());
        let name = group_name.unwrap_or("");
        if let Err(e) = idx.lock().unwrap().upsert_summary(
            &group_id_hex,
            name,
            &index_preview(message),
            &message.sender.to_string(),
            message.created_at.as_secs(),
            message.mine,
        ) {
            tracing::warn!(%e, "index upsert failed");
        }
    }

    fn ensure_index_for_group(&self, group_id: &GroupId, name: &str) {
        let Some(ref idx) = self.conversation_index else {
            return;
        };
        let group_id_hex = hex::encode(group_id.as_slice());
        if let Err(e) = idx.lock().unwrap().ensure_group(&group_id_hex, name) {
            tracing::warn!(%e, "index ensure_group failed");
        }
    }

    fn resolve_group_name(&self, group_id: &GroupId) -> Option<String> {
        self.engine.groups().ok().and_then(|gs| {
            gs.into_iter()
                .find(|g| g.mls_group_id == *group_id)
                .map(|g| g.name)
        })
    }

    fn remove_index_for_group(&self, group_id: &GroupId) {
        let Some(ref idx) = self.conversation_index else {
            return;
        };
        let group_id_hex = hex::encode(group_id.as_slice());
        if let Err(e) = idx.lock().unwrap().remove_group(&group_id_hex) {
            tracing::warn!(%e, "index remove_group failed");
        }
    }

    fn notify_conversation_changed(&self, group_id_hex: &str) {
        if let Some(l) = self.change_listener.lock().unwrap().clone() {
            let id = group_id_hex.to_owned();
            l.on_conversation_changed(id);
        }
    }

    fn notify_conversations_changed(&self, group_ids: &HashSet<String>) {
        let listener = self.change_listener.lock().unwrap().clone();
        if let Some(l) = listener {
            for id in group_ids {
                l.on_conversation_changed(id.clone());
            }
        }
    }

    fn materialize_index_if_empty(&mut self) {
        let Some(ref idx) = self.conversation_index else {
            return;
        };
        let idx_guard = idx.lock().unwrap();
        if !idx_guard.is_empty() {
            return;
        }
        if let Err(e) = idx_guard.materialize_from(&self.engine) {
            tracing::warn!(%e, "index materialize failed");
        }
    }

    // ── Geohash public channels (kind-20000 over Nostr) ──

    /// Add + connect the Nostr relays geographically nearest [geohash] — the SAME
    /// set bitchat's `GeoRelayDirectory` uses for that geohash. Without this our
    /// channel events land on different relays than a bitchat client subscribes
    /// to, so neither side sees the other. Best-effort per relay.
    async fn ensure_geohash_relays(&self, geohash: &str) {
        if !self.allow_geo_relays {
            return; // in-memory/test session: stay network-free
        }
        // bitchat picks the 5 nearest relays from ITS relay directory. A peer's
        // directory can differ (or be a stale bundle when its fetch fails — seen
        // on bitchat-android), so its top pick may rank lower in ours. Join a
        // WIDER set (12) than bitchat's 5 so the two overlap on at least one
        // relay even when the directories don't perfectly agree.
        for url in crate::relay_directory::closest_relays_for_geohash(geohash, 12) {
            if self.nostr.add_relay(&url).await.is_ok() {
                let _ = self.nostr.connect_relay(&url).await;
            }
        }
    }

    /// Subscribe to a geohash channel so the relay delivers its live
    /// (ephemeral) messages into our buffer. Idempotent.
    pub async fn subscribe_geohash(&self, geohash: &str) -> Result<()> {
        {
            let mut subs = self.geo_subscribed.lock().unwrap();
            if !subs.insert(geohash.to_string()) {
                return Ok(());
            }
        }
        // Join the geohash's nearest relays (bitchat's set) BEFORE subscribing,
        // so the subscription covers them and our publishes reach bitchat.
        self.ensure_geohash_relays(geohash).await;
        // Public channel messages (kind-20000) tagged with this geohash.
        let channel = Filter::new()
            .kind(Kind::Custom(20000))
            .custom_tag(SingleLetterTag::lowercase(Alphabet::G), geohash);
        self.nostr.subscribe(channel, None).await?;

        // Presence heartbeats (kind-20001) tagged with this geohash.
        let presence = Filter::new()
            .kind(Kind::Custom(20001))
            .custom_tag(SingleLetterTag::lowercase(Alphabet::G), geohash);
        self.nostr.subscribe(presence, None).await?;

        // 1:1 DMs (NIP-17 gift wraps) addressed to our per-geohash key.
        let geo_pk =
            crate::geohash::derive_geohash_keys(&self.identity_secret, geohash)?.public_key();
        let dms = Filter::new().kind(Kind::GiftWrap).pubkey(geo_pk);
        self.nostr.subscribe(dms, None).await?;
        Ok(())
    }

    /// Send a 1:1 encrypted DM to a participant in a geohash channel (NIP-17
    /// gift wrap from our per-geohash key to theirs).
    pub async fn send_geo_dm(&self, geohash: &str, recipient_hex: &str, text: &str) -> Result<()> {
        self.subscribe_geohash(geohash).await?;
        let keys = crate::geohash::derive_geohash_keys(&self.identity_secret, geohash)?;
        let recipient = PublicKey::from_hex(recipient_hex)?;
        let rumor = EventBuilder::new(Kind::Custom(14), text)
            .tags([Tag::public_key(recipient)])
            .build(keys.public_key());
        let ts = rumor.created_at.as_secs();
        let gift = EventBuilder::gift_wrap(&keys, &recipient, rumor, []).await?;
        // Record locally first, then publish in the background so the UI shows
        // the message instantly (relays don't echo to the sender anyway).
        let id = gift.id.to_hex();
        {
            let mut map = self.geo_dm.lock().unwrap();
            let bucket = map
                .entry((geohash.to_string(), recipient_hex.to_string()))
                .or_default();
            bucket.push(RawGeoDm {
                id,
                sender: keys.public_key(),
                content: text.to_string(),
                ts,
                mine: true,
            });
        }
        let nostr = self.nostr.clone();
        tokio::spawn(async move {
            let _ = nostr.send_event(&gift).await;
        });
        Ok(())
    }

    /// The 1:1 geohash DM conversation with `peer_hex`, oldest first.
    pub async fn fetch_geo_dm(
        &self,
        geohash: &str,
        peer_hex: &str,
    ) -> Result<Vec<crate::geohash::GeoMessage>> {
        self.subscribe_geohash(geohash).await?;
        let map = self.geo_dm.lock().unwrap();
        let mut out: Vec<crate::geohash::GeoMessage> = map
            .get(&(geohash.to_string(), peer_hex.to_string()))
            .map(|bucket| {
                bucket
                    .iter()
                    .map(|r| crate::geohash::GeoMessage {
                        id: r.id.clone(),
                        sender_pubkey: r.sender.to_hex(),
                        nickname: String::new(),
                        content: r.content.clone(),
                        created_at: r.ts,
                        mine: r.mine,
                    })
                    .collect()
            })
            .unwrap_or_default();
        out.sort_by_key(|m| m.created_at);
        Ok(out)
    }

    /// Send an account-level NIP-17 DM to a plain bitchat peer. The rumor
    /// content is `bitchat1:` with an embedded private-message packet so iOS
    /// bitchat can route it through the same private-chat handler as its own
    /// Nostr fallback.
    pub async fn send_direct_dm(
        &self,
        recipient_hex: &str,
        sender_peer_id_hex: &str,
        recipient_peer_id_hex: &str,
        message_id: &str,
        text: &str,
    ) -> Result<()> {
        let recipient = PublicKey::parse(recipient_hex)?;
        let sender_peer_id = parse_mesh_id8_hex(sender_peer_id_hex, "sender peer id")?;
        let recipient_peer_id =
            parse_optional_mesh_id8_hex(recipient_peer_id_hex, "recipient peer id")?;
        let msg = crate::mesh::PrivateMessage {
            message_id: message_id.to_string(),
            content: text.to_string(),
        };
        let timestamp_ms = Timestamp::now().as_secs().saturating_mul(1000);
        let embedded = crate::mesh::encode_nip17_private_message_content(
            sender_peer_id,
            recipient_peer_id,
            timestamp_ms,
            &msg,
        )
        .ok_or_else(|| Error::InvalidInput("direct DM is too large to encode".into()))?;
        let rumor = EventBuilder::new(Kind::Custom(14), embedded)
            .tags([Tag::public_key(recipient)])
            .build(self.engine.identity().public_key());
        let gift =
            EventBuilder::gift_wrap(self.engine.identity().keys(), &recipient, rumor, []).await?;
        let output = self.nostr.send_event(&gift).await?;
        require_relay_success(&output, "direct NIP-17 DM")
    }

    /// Drain account-level direct NIP-17 DMs buffered by sync/live gift-wrap
    /// processing. Hosts persist these into their local conversation store.
    pub fn drain_direct_dms(&self) -> Vec<DirectDm> {
        let mut buf = self.direct_dm.lock().unwrap();
        let mut out: Vec<DirectDm> = std::mem::take(&mut *buf)
            .into_iter()
            .map(|r| DirectDm {
                event_id: r.event_id,
                id: r.id,
                sender_pubkey: r.sender.to_hex(),
                content: r.content,
                created_at: r.ts,
            })
            .collect();
        out.sort_by_key(|m| m.created_at);
        out
    }

    /// Mark account-level direct NIP-17 gift wraps durable after the host has
    /// persisted or intentionally consumed the drained message.
    pub fn acknowledge_direct_dms(&self, event_ids: &[String]) -> Result<()> {
        let ids: HashSet<String> = event_ids
            .iter()
            .map(|id| id.trim().to_lowercase())
            .filter(|id| !id.is_empty())
            .collect();
        if ids.is_empty() {
            return Ok(());
        }
        self.direct_dm
            .lock()
            .unwrap()
            .retain(|dm| !ids.contains(&dm.event_id));
        {
            let mut state = self.sync_state.lock().unwrap();
            for id in ids {
                state.mark_processed_id(id);
            }
        }
        self.save_sync_state()
    }

    /// Publish a public message to a geohash channel, signed with this
    /// identity's stable per-geohash ephemeral key, carrying the display
    /// nickname in an `n` tag.
    pub async fn send_geohash(&self, geohash: &str, text: &str, nickname: &str) -> Result<()> {
        self.subscribe_geohash(geohash).await?;
        let secret = self.identity().keys().secret_key().to_secret_bytes();
        let geo = crate::geohash::derive_geohash_keys(&secret, geohash)?;
        let tags = vec![
            Tag::custom(
                TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::G)),
                [geohash.to_string()],
            ),
            Tag::custom(
                TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::N)),
                [nickname.to_string()],
            ),
        ];
        let event = EventBuilder::new(Kind::Custom(20000), text)
            .tags(tags)
            .sign_with_keys(&geo)?;
        // Record locally + count ourselves FIRST so the UI shows the message
        // INSTANTLY, then publish in the BACKGROUND. send_event() awaits a relay
        // round-trip across EVERY connected relay (a dozen for a geohash); doing
        // that before recording made the user wait seconds for their own message
        // to appear. Relays don't echo to the sender, so the local copy is what
        // the UI renders either way.
        let id = event.id.to_hex();
        let ts = event.created_at.as_secs();
        self.geo_presence
            .lock()
            .unwrap()
            .entry(geohash.to_string())
            .or_default()
            .insert(event.pubkey.to_hex(), ts);
        {
            let mut map = self.geo.lock().unwrap();
            let bucket = map.entry(geohash.to_string()).or_default();
            if !bucket.iter().any(|r| r.id == id) {
                bucket.push(RawGeo {
                    id,
                    pubkey: event.pubkey,
                    nickname: nickname.to_string(),
                    content: text.to_string(),
                    ts,
                });
            }
        }
        let nostr = self.nostr.clone();
        tokio::spawn(async move {
            let _ = nostr.send_event(&event).await;
        });
        Ok(())
    }

    /// Broadcast a presence heartbeat (kind-20001) for a geohash channel, so
    /// other participants count this device in "N here now". Empty content, a
    /// single `g`=geohash tag, signed with the stable per-geohash ephemeral key
    /// (the same key used for messages, so presence and authorship line up).
    /// Wire-compatible with the iOS `createGeohashPresenceEvent`. Call this on
    /// channel open and re-call on a ~60s heartbeat while the channel is active.
    pub async fn send_geohash_presence(&self, geohash: &str) -> Result<()> {
        self.subscribe_geohash(geohash).await?;
        let secret = self.identity().keys().secret_key().to_secret_bytes();
        let geo = crate::geohash::derive_geohash_keys(&secret, geohash)?;
        let event = EventBuilder::new(Kind::Custom(20001), "")
            .tags([Tag::custom(
                TagKind::SingleLetter(SingleLetterTag::lowercase(Alphabet::G)),
                [geohash.to_string()],
            )])
            .sign_with_keys(&geo)?;
        // Count ourselves locally first, then publish in the background — the
        // heartbeat fires for several channels each tick and must not block the
        // poll on relay round-trips.
        {
            let mut map = self.geo_presence.lock().unwrap();
            let bucket = map.entry(geohash.to_string()).or_default();
            bucket.insert(event.pubkey.to_hex(), event.created_at.as_secs());
        }
        let nostr = self.nostr.clone();
        tokio::spawn(async move {
            let _ = nostr.send_event(&event).await;
        });
        Ok(())
    }

    /// Number of participants currently "here now" in a geohash channel: the
    /// count of distinct presence heartbeats (kind-20001) seen within the TTL.
    /// Subscribes on first access. Includes this device once it has announced.
    pub async fn geohash_presence_count(&self, geohash: &str) -> Result<u32> {
        self.subscribe_geohash(geohash).await?;
        let cutoff = Timestamp::now().as_secs().saturating_sub(PRESENCE_TTL_SECS);
        let mut map = self.geo_presence.lock().unwrap();
        let count = match map.get_mut(geohash) {
            Some(bucket) => {
                // Evict stale heartbeats while we're here so the map can't grow
                // unbounded over a long session in a busy channel.
                bucket.retain(|_, &mut ts| ts >= cutoff);
                bucket.len()
            }
            None => 0,
        };
        Ok(count as u32)
    }

    /// Recent messages for a geohash channel from the live buffer, oldest
    /// first. Subscribes on first access (so a subsequent call sees messages
    /// delivered since).
    pub async fn fetch_geohash(
        &self,
        geohash: &str,
        limit: usize,
    ) -> Result<Vec<crate::geohash::GeoMessage>> {
        self.subscribe_geohash(geohash).await?;
        let secret = self.identity().keys().secret_key().to_secret_bytes();
        let my_pk = crate::geohash::derive_geohash_keys(&secret, geohash)?.public_key();
        let map = self.geo.lock().unwrap();
        let mut out: Vec<crate::geohash::GeoMessage> = map
            .get(geohash)
            .map(|bucket| {
                bucket
                    .iter()
                    .map(|r| crate::geohash::GeoMessage {
                        id: r.id.clone(),
                        sender_pubkey: r.pubkey.to_hex(),
                        nickname: r.nickname.clone(),
                        content: r.content.clone(),
                        created_at: r.ts,
                        mine: r.pubkey == my_pk,
                    })
                    .collect()
            })
            .unwrap_or_default();
        out.sort_by_key(|m| m.created_at);
        if out.len() > limit {
            out.drain(0..out.len() - limit);
        }
        Ok(out)
    }

    /// Erase a persistent database at `db_path` (and its SQLite sidecars).
    ///
    /// Free function — no live client may hold the DB open. Used by panic-wipe
    /// before the Swift host also clears the Keychain key.
    pub fn wipe_database(db_path: impl AsRef<Path>) -> Result<()> {
        let db_path = db_path.as_ref();
        let db_result = MarmotEngine::wipe(db_path);
        let index_result = wipe_index_for_db(db_path);
        let push_result = wipe_push_token_cache_for_db(db_path);
        let sticker_result = wipe_sticker_cache_for_db(db_path);
        db_result?;
        index_result?;
        push_result?;
        sticker_result
    }

    /// MIP-05: encrypt a device push token to the transponder's public key.
    ///
    /// The transponder is stateless, so registration must not publish a kind-446
    /// notification request. Instead, the encrypted token is cached locally and
    /// shared with all joined group members via NIP-44 DMs so they can send
    /// sender-side push notifications on future messages.
    pub async fn register_push_token(
        &self,
        platform: &str,
        token: &[u8],
        server_npub: &str,
    ) -> Result<()> {
        use crate::push;

        let server_pubkey = PublicKey::parse(server_npub)?;
        let plat = push::platform_byte(platform)?;
        let (content, _) = push::encode_notification_request(plat, token, &server_pubkey)?;

        // Store our own registration so we can share it with group members.
        let own_reg = push::OwnPushRegistration {
            encrypted_token_b64: content.clone(),
            server_pubkey,
        };
        *self.own_push_registration.lock().unwrap() = Some(own_reg);

        // Share our encrypted push token with all group members.
        self.share_push_token_with_groups().await;

        Ok(())
    }

    /// Send our encrypted push token to every member of every joined group
    /// via a NIP-44 encrypted DM (kind 447). Group members cache this to send
    /// sender-side notifications to us.
    async fn share_push_token_with_groups(&self) {
        // Relay guard: the per-recipient gift-wrapped DM below goes out through
        // `self.nostr.send_event`, which fails with "no relays specified" when
        // the nostr client has no live relays. This runs at the end of every
        // sync/wake (`sync_inner`, the live short-circuit, and the token-update
        // path), often BEFORE relays attach — with many groups that floods the
        // log with one failure per member (~275/session on a real 43-group
        // account). Skip the whole pass when no relay is connected: it re-runs
        // on the next sync once relays are up, so deferring is free and this
        // never blocks chat open/send/scroll/paint. Take the relay map from the
        // `.await` before touching any std Mutex so no guard is held across it.
        let connected_relays = self
            .nostr
            .relays()
            .await
            .values()
            .filter(|handle| handle.status() == RelayStatus::Connected)
            .count();
        if !should_share_push_tokens(connected_relays) {
            tracing::debug!(
                connected_relays,
                "push token share: no connected relays, deferring to next sync"
            );
            return;
        }

        let own_reg = self.own_push_registration.lock().unwrap().clone();
        let Some(reg) = own_reg else { return };

        let groups = match self.engine.groups() {
            Ok(g) => g,
            Err(e) => {
                tracing::warn!(%e, "push token share: failed to list groups");
                return;
            }
        };

        let my_pubkey = self.engine.identity().public_key();
        let payload = crate::push::PushTokenSharePayload {
            encrypted_token: reg.encrypted_token_b64.clone(),
            server_pubkey: reg.server_pubkey.to_hex(),
        };
        let payload_json = match serde_json::to_string(&payload) {
            Ok(j) => j,
            Err(e) => {
                tracing::warn!(%e, "push token share: JSON serialization failed");
                return;
            }
        };

        for group in &groups {
            let members = match self.engine.members(&group.mls_group_id) {
                Ok(m) => m,
                Err(_) => continue,
            };
            for member in &members {
                if member == &my_pubkey {
                    continue;
                }
                if let Err(e) = self.send_push_token_dm(member, &payload_json).await {
                    tracing::debug!(
                        recipient = %member,
                        %e,
                        "push token share DM failed"
                    );
                }
            }
        }
        tracing::info!("push token shared with group members");
    }

    /// NIP-44 encrypted DM carrying our push token info (kind 447).
    async fn send_push_token_dm(&self, recipient: &PublicKey, payload_json: &str) -> Result<()> {
        let rumor = EventBuilder::new(
            Kind::Custom(crate::push::KIND_PUSH_TOKEN_SHARE),
            payload_json,
        )
        .tags([Tag::public_key(*recipient)])
        .build(self.engine.identity().public_key());

        let wrapped = self.engine.gift_wrap_rumor(recipient, rumor).await?;
        self.nostr.send_event(&wrapped).await?;
        Ok(())
    }

    /// Process an incoming push token share DM (kind 447) from a group member.
    fn handle_push_token_share(&self, sender: &PublicKey, content: &str) -> Result<()> {
        let payload: crate::push::PushTokenSharePayload = match serde_json::from_str(content) {
            Ok(p) => p,
            Err(e) => {
                tracing::debug!(%e, "ignoring malformed push token share");
                return Ok(());
            }
        };
        let server_pubkey = match PublicKey::parse(&payload.server_pubkey) {
            Ok(pk) => pk,
            Err(e) => {
                tracing::debug!(%e, "ignoring push token share with bad server pubkey");
                return Ok(());
            }
        };
        let cached = crate::push::CachedPushToken {
            encrypted_token_b64: payload.encrypted_token,
            server_pubkey,
        };
        {
            let mut cache = self.push_token_cache.lock().unwrap();
            cache.insert(sender.to_hex(), cached);
            crate::push::save_push_token_cache(self.push_token_cache_path.as_deref(), &cache)?;
        }
        // Event at info for the default export; sender npub only at debug so
        // the default diagnostics profile carries no peer identifiers.
        tracing::info!("cached push token from group member");
        tracing::debug!(sender = %sender, "push token sender");
        Ok(())
    }
}

fn conservative_watermark(disk_watermark_secs: u64, fallback_watermark_secs: u64) -> u64 {
    match (disk_watermark_secs, fallback_watermark_secs) {
        (0, _) | (_, 0) => 0,
        (disk, fallback) => disk.min(fallback),
    }
}

fn sync_state_path_for_db(db_path: &Path) -> PathBuf {
    let name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar.db");
    db_path.with_file_name(format!("{name}{SYNC_STATE_FILE_SUFFIX}"))
}

fn sync_state_tmp_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar-sync.json");
    path.with_file_name(format!("{name}.tmp"))
}

fn is_terminal_marmot_processing_error(err: &Error) -> bool {
    matches!(
        err,
        Error::Nip59(_)
            | Error::Nip44(_)
            | Error::NostrEvent(_)
            | Error::Mdk(mdk_core::Error::WelcomePreviouslyFailed(_))
    )
}

/// Chat-list preview text stored in the conversation index for `message`.
/// The caption/text wins when present; a caption-less media message previews
/// as its attachment kind ("Photo", "3 photos", "Voice note", filename) so an
/// arriving album never shows an empty home row.
fn index_preview(message: &ChatMessage) -> String {
    if !message.content.is_empty() || message.media.is_empty() {
        return message.content.clone();
    }
    let media = &message.media;
    if media.len() > 1 && media.iter().all(|m| m.mime_type.starts_with("image/")) {
        return format!("{} photos", media.len());
    }
    let first = &media[0];
    if first.mime_type.starts_with("image/") {
        "Photo".to_owned()
    } else if first.mime_type.starts_with("audio/") {
        "Voice note".to_owned()
    } else if first.filename.is_empty() {
        "File".to_owned()
    } else {
        first.filename.clone()
    }
}

/// Read the value of a single-letter tag (e.g. `g`=geohash, `n`=nickname).
fn tag_value(event: &Event, letter: Alphabet) -> Option<String> {
    event
        .tags
        .iter()
        .find(|t| t.single_letter_tag() == Some(SingleLetterTag::lowercase(letter)))
        .and_then(|t| t.content().map(|s| s.to_string()))
}

fn sort_marmot_events(events: impl IntoIterator<Item = Event>) -> Vec<Event> {
    let mut events: Vec<Event> = events.into_iter().collect();
    sort_marmot_events_in_place(&mut events);
    events
}

fn newest_valid_sonar_descriptor(
    events: impl IntoIterator<Item = Event>,
    author: PublicKey,
) -> Option<SonarDescriptor> {
    let mut newest: Option<SonarDescriptor> = None;
    let mut newest_meta: Option<SonarDescriptor> = None;
    for event in events.into_iter().filter(|event| event.pubkey == author) {
        let is_meta =
            tag_value(&event, Alphabet::D).as_deref() == Some(SONAR_META_DESCRIPTOR_D_TAG);
        let Some(descriptor) = parse_descriptor_event(&event) else {
            continue;
        };
        if newest.as_ref().map_or(true, |current| {
            descriptor.published_at_secs > current.published_at_secs
        }) {
            newest = Some(descriptor.clone());
        }
        if is_meta
            && newest_meta.as_ref().map_or(true, |current| {
                descriptor.published_at_secs > current.published_at_secs
            })
        {
            newest_meta = Some(descriptor);
        }
    }

    let mut descriptor = newest?;
    if descriptor.bolt12_offer.is_none() {
        if let Some(meta) = newest_meta {
            descriptor.bolt12_offer = meta.bolt12_offer;
            descriptor.payment_receipts = meta.payment_receipts;
        }
    }
    Some(descriptor)
}

fn sort_marmot_events_in_place(events: &mut [Event]) {
    events.sort_by(|a, b| {
        a.created_at
            .as_secs()
            .cmp(&b.created_at.as_secs())
            .then_with(|| a.id.to_hex().cmp(&b.id.to_hex()))
    });
}

fn require_relay_success(
    output: &nostr_sdk::pool::Output<EventId>,
    context: &'static str,
) -> Result<()> {
    if !output.success.is_empty() {
        if !output.failed.is_empty() {
            tracing::debug!(
                context,
                success_count = output.success.len(),
                failed_count = output.failed.len(),
                "nostr publish partially succeeded"
            );
        }
        return Ok(());
    }

    let failures = if output.failed.is_empty() {
        "no relay accepted the event".to_string()
    } else {
        output
            .failed
            .iter()
            .map(|(relay, reason)| format!("{relay:?}: {reason}"))
            .collect::<Vec<_>>()
            .join(", ")
    };
    Err(Error::NostrPublish(format!(
        "{context}: no relay accepted event {} ({failures})",
        output.val
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct CancelledDownload;

    impl MediaDownloadObserver for CancelledDownload {
        fn on_progress(&self, _: u64, _: Option<u64>) {}

        fn is_cancelled(&self) -> bool {
            true
        }
    }

    #[tokio::test]
    async fn media_download_honors_cancellation_before_network_io() {
        let error = http_get(
            "https://download.invalid/never-requested",
            Some(&CancelledDownload),
        )
        .await
        .expect_err("cancelled transfer must fail");

        assert!(matches!(error, Error::MediaDownloadCancelled));
    }
    use crate::sonar_descriptor::{
        descriptor_content_json, meta_descriptor_content_json, SONAR_CALL_DESCRIPTOR_D_TAG,
    };
    use sha2::Digest;
    use std::collections::{HashMap, HashSet, VecDeque};
    use std::io::{Read, Write};
    use std::net::TcpListener;

    #[tokio::test]
    async fn blossom_upload_sends_binary_content_type_and_accepts_created() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock Blossom");
        let base = format!(
            "http://{}",
            listener.local_addr().expect("listener address")
        );
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept upload");
            let mut request = Vec::new();
            let mut chunk = [0u8; 4096];
            let header_end = loop {
                let read = stream.read(&mut chunk).expect("read upload request");
                assert!(read > 0, "upload request ended before its headers");
                request.extend_from_slice(&chunk[..read]);
                if let Some(pos) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                    break pos;
                }
            };
            let headers = String::from_utf8_lossy(&request[..header_end]).to_string();
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().expect("content length"))
                })
                .expect("upload content length");
            let body_start = header_end + 4;
            while request.len() < body_start + content_length {
                let read = stream.read(&mut chunk).expect("read upload body");
                assert!(read > 0, "upload request ended before its body");
                request.extend_from_slice(&chunk[..read]);
            }
            let body = &request[body_start..body_start + content_length];
            let sha = hex::encode(sha2::Sha256::digest(body));
            let json = format!(
                "{{\"url\":\"http://blossom.test/{sha}\",\"sha256\":\"{sha}\",\"size\":{},\"type\":\"application/octet-stream\",\"uploaded\":0}}",
                body.len()
            );
            // BUD-02 requires 201 for a newly stored blob. The media integration
            // test exercises the complementary 200 response for an existing blob.
            let response = format!(
                "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{json}",
                json.len()
            );
            stream
                .write_all(response.as_bytes())
                .expect("write response");
            headers
        });

        let client = SonarClient::connect_in_memory(Identity::generate(), Vec::new())
            .await
            .expect("client without relays");
        client
            .blossom_upload(&base, b"encrypted image ciphertext".to_vec())
            .await
            .expect("ciphertext uploads");

        let headers = server.join().expect("mock Blossom exits");
        assert!(
            headers.lines().any(|line| {
                let Some((name, value)) = line.split_once(':') else {
                    return false;
                };
                name.eq_ignore_ascii_case("content-type")
                    && value.trim().eq_ignore_ascii_case(ENCRYPTED_BLOB_MIME_TYPE)
            }),
            "encrypted uploads must use {ENCRYPTED_BLOB_MIME_TYPE}, got:\n{headers}"
        );
    }

    fn test_event_id(seed: u8) -> EventId {
        EventId::from_slice(&[seed; 32]).expect("event id")
    }

    fn signed_event(keys: &Keys, created_at_secs: u64, content: &str) -> Event {
        EventBuilder::new(Kind::MlsGroupMessage, content)
            .custom_created_at(Timestamp::from_secs(created_at_secs))
            .sign_with_keys(keys)
            .expect("event signs")
    }

    fn signed_descriptor_event(
        keys: &Keys,
        d_tag: &'static str,
        created_at_secs: u64,
        content: String,
    ) -> Event {
        EventBuilder::new(Kind::Custom(SONAR_DESCRIPTOR_KIND), content)
            .tags(descriptor_tags(d_tag))
            .custom_created_at(Timestamp::from_secs(created_at_secs))
            .sign_with_keys(keys)
            .expect("descriptor signs")
    }

    #[test]
    fn relay_fetch_quorum_matches_connection_quorum() {
        assert_eq!(relay_fetch_quorum(0), 0);
        assert_eq!(relay_fetch_quorum(1), 1);
        assert_eq!(relay_fetch_quorum(2), 2);
        assert_eq!(relay_fetch_quorum(3), 2);
        assert_eq!(relay_fetch_quorum(5), 2);
    }

    #[test]
    fn index_preview_labels_media_only_messages() {
        let media_ref = |mime: &str, filename: &str| crate::marmot::MediaRef {
            url: "https://blossom.test/x".to_owned(),
            mime_type: mime.to_owned(),
            filename: filename.to_owned(),
            width: None,
            height: None,
            duration_ms: None,
        };
        let msg = |content: &str, media: Vec<crate::marmot::MediaRef>| ChatMessage {
            id: test_event_id(9),
            group_id: GroupId::from_slice(&[1u8; 32]),
            sender: Keys::generate().public_key(),
            content: content.to_owned(),
            created_at: Timestamp::from_secs(1),
            mine: false,
            delivery_state: crate::marmot::DeliveryState::Received,
            media,
            sticker_ref: None,
            classification: crate::marmot::MessageClassification::Text,
        };
        // Caption/text always wins.
        assert_eq!(
            index_preview(&msg("hi", vec![media_ref("image/jpeg", "a.jpg")])),
            "hi"
        );
        // Caption-less media previews by kind — an album never shows blank.
        assert_eq!(
            index_preview(&msg("", vec![media_ref("image/jpeg", "a.jpg")])),
            "Photo"
        );
        assert_eq!(
            index_preview(&msg(
                "",
                vec![
                    media_ref("image/jpeg", "a.jpg"),
                    media_ref("image/png", "b.png"),
                    media_ref("image/jpeg", "c.jpg"),
                ]
            )),
            "3 photos"
        );
        assert_eq!(
            index_preview(&msg("", vec![media_ref("audio/mp4", "voice.m4a")])),
            "Voice note"
        );
        assert_eq!(
            index_preview(&msg("", vec![media_ref("application/pdf", "doc.pdf")])),
            "doc.pdf"
        );
        assert_eq!(index_preview(&msg("", vec![])), "");
    }

    #[test]
    fn push_token_share_skips_until_a_relay_is_connected() {
        // No live relay: skip so the per-recipient gift-wrapped DM never fires
        // "no relays specified" (the ~275/session flood on a real account).
        assert!(!should_share_push_tokens(0));
        // At least one connected relay: the DM can actually go out.
        assert!(should_share_push_tokens(1));
        assert!(should_share_push_tokens(5));
    }

    #[test]
    fn relay_fetch_outcome_quorum_is_the_completeness_bar() {
        // Quorum answered (the most the fetch loop ever waits for): complete,
        // even though 3 of 5 relays never responded — one dead relay in the
        // list must not block watermark advancement forever.
        let quorum_met = RelayFetchOutcome {
            events: Vec::new(),
            completed_relays: relay_fetch_quorum(5),
            total_relays: 5,
        };
        // Below quorum: retryable.
        let below_quorum = RelayFetchOutcome {
            events: Vec::new(),
            completed_relays: 1,
            total_relays: 5,
        };

        assert!(quorum_met.completed_quorum());
        assert!(!below_quorum.completed_quorum());
    }

    #[test]
    fn media_http_retry_classifier_retries_transient_body_errors() {
        assert!(retryable_media_http_error(&Error::Http(
            "error decoding response body".into()
        )));
        assert!(retryable_media_http_error(&Error::Http(
            "GET https://example.test/blob -> HTTP 503 Service Unavailable".into()
        )));
    }

    #[test]
    fn media_http_retry_classifier_rejects_permanent_errors() {
        assert!(!retryable_media_http_error(&Error::Http(
            "refusing non-https media url: http://127.0.0.1/blob".into()
        )));
        assert!(!retryable_media_http_error(&Error::Http(
            "GET https://example.test/blob -> HTTP 404 Not Found".into()
        )));
        assert!(!retryable_media_http_error(&Error::Http(
            "media exceeds size cap".into()
        )));
    }

    #[test]
    fn sticker_prefetch_download_cap_is_cacheable() {
        let prefetch_limit = std::hint::black_box(STICKER_PREFETCH_DOWNLOAD_BYTES);
        assert_eq!(prefetch_limit, MAX_STICKER_CACHE_BYTES);
        assert!(prefetch_limit < MAX_MEDIA_DOWNLOAD_BYTES);
    }

    #[tokio::test]
    async fn sticker_singleflight_shares_nonpersistent_success() {
        let gates: SharedStickerFetchGates<Vec<u8>> =
            Arc::new(tokio::sync::Mutex::new(HashMap::new()));
        let calls = Arc::new(AtomicUsize::new(0));
        let first_calls = calls.clone();
        let second_calls = calls.clone();

        let (first, second) = tokio::join!(
            shared_sticker_fetch(&gates, "same-sha".into(), async move {
                first_calls.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(20)).await;
                Ok(vec![1, 2, 3])
            }),
            shared_sticker_fetch(&gates, "same-sha".into(), async move {
                second_calls.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(20)).await;
                Ok(vec![4, 5, 6])
            }),
        );

        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_ne!(first.1, second.1);
        assert_eq!(first.0.unwrap().as_slice(), second.0.unwrap().as_slice());
    }

    #[tokio::test]
    async fn sticker_singleflight_shares_fetch_error() {
        let gates: SharedStickerFetchGates<Vec<u8>> =
            Arc::new(tokio::sync::Mutex::new(HashMap::new()));
        let calls = Arc::new(AtomicUsize::new(0));
        let first_calls = calls.clone();
        let second_calls = calls.clone();

        let (first, second) = tokio::join!(
            shared_sticker_fetch(&gates, "same-sha".into(), async move {
                first_calls.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(20)).await;
                Err(Error::Http("offline".into()))
            }),
            shared_sticker_fetch(&gates, "same-sha".into(), async move {
                second_calls.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(20)).await;
                Err(Error::Http("unexpected retry".into()))
            }),
        );

        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_ne!(first.1, second.1);
        assert_eq!(
            first.0.unwrap_err().to_string(),
            second.0.unwrap_err().to_string()
        );
    }

    /// Mixed-operation stress: concurrent sends, incoming processing, and
    /// transcript reads on one engine, followed by a member removal, then a
    /// post-removal send. Verifies (a) no row is lost under contention,
    /// (b) the removed member cannot read a message sent after the removal
    /// commit merged, while a remaining member can.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn stress_mixed_ops_and_removal_epoch_boundary() {
        let relays = vec![RelayUrl::parse("wss://relay.example.com").expect("relay url")];
        let alice = std::sync::Arc::new(MarmotEngine::in_memory(Identity::generate()));
        let bob = MarmotEngine::in_memory(Identity::generate());
        let carol = MarmotEngine::in_memory(Identity::generate());
        let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");
        let carol_kp = carol.key_package_event(relays.clone()).expect("carol kp");

        let creation = alice
            .create_group("alice, bob & carol", vec![bob_kp, carol_kp], relays)
            .expect("alice creates group");
        let group_id = creation.group.mls_group_id.clone();
        for (member, engine) in [
            (bob.identity().public_key(), &bob),
            (carol.identity().public_key(), &carol),
        ] {
            let (_, welcome) = creation
                .welcomes
                .iter()
                .find(|(pubkey, _)| *pubkey == member)
                .cloned()
                .expect("welcome");
            let wrapped = alice
                .gift_wrap_welcome(&member, welcome)
                .await
                .expect("wrap welcome");
            // A >2-member group welcome lands as a pending invite that the
            // member must accept explicitly (White Noise semantics).
            match engine
                .process_incoming(&wrapped)
                .await
                .expect("member processes welcome")
            {
                Incoming::GroupUpdated(_) => {}
                Incoming::GroupInvitePending(_) => {
                    let invite = engine.pending_group_invites().expect("pending invites")[0].id;
                    engine
                        .accept_group_invite(&invite)
                        .expect("member accepts invite");
                }
                other => panic!("unexpected welcome result: {other:?}"),
            }
        }
        alice
            .merge_pending_commit(&group_id)
            .expect("alice merges creation commit");

        let bob_group_id = bob.groups().expect("bob groups")[0].mls_group_id.clone();
        let incoming_events: Vec<Event> = (0..10)
            .map(|i| {
                bob.create_text_message(&bob_group_id, &format!("bob under load {i}"))
                    .expect("bob creates message")
            })
            .collect();

        // Phase 1: sends + incoming + reads all concurrent.
        let sender = {
            let alice = alice.clone();
            let group_id = group_id.clone();
            tokio::task::spawn_blocking(move || {
                for i in 0..20 {
                    alice
                        .create_and_process_text_message(&group_id, &format!("alice load {i}"))
                        .expect("alice sends under load");
                }
            })
        };
        let receiver = {
            let alice = alice.clone();
            tokio::spawn(async move {
                for event in incoming_events {
                    assert!(matches!(
                        alice
                            .process_incoming(&event)
                            .await
                            .expect("alice processes incoming under load"),
                        Incoming::Message(_)
                    ));
                }
            })
        };
        let reader = {
            let alice = alice.clone();
            let group_id = group_id.clone();
            tokio::task::spawn_blocking(move || {
                for _ in 0..50 {
                    let _ = alice.messages(&group_id).expect("read under load");
                    let _ = alice.groups().expect("groups under load");
                }
            })
        };
        sender.await.expect("send task");
        receiver.await.expect("receive task");
        reader.await.expect("read task");

        let transcript = alice.messages(&group_id).expect("alice transcript");
        assert_eq!(transcript.iter().filter(|m| m.mine).count(), 20);
        assert_eq!(transcript.iter().filter(|m| !m.mine).count(), 10);

        // Phase 2: remove carol, merge, then send. Carol processes the removal
        // commit (learning she is out); bob processes it and must still read
        // the post-removal message, carol must not.
        let removal = alice
            .remove_members(&group_id, &[carol.identity().public_key()])
            .expect("alice removes carol");
        assert!(removal.requires_commit_merge);
        let carol_group_id = carol.groups().expect("carol groups")[0].mls_group_id.clone();
        bob.process_incoming(&removal.evolution_event)
            .await
            .expect("bob processes removal commit");
        carol
            .process_incoming(&removal.evolution_event)
            .await
            .expect("carol processes removal commit");
        alice
            .merge_pending_commit(&group_id)
            .expect("alice merges removal");
        assert!(
            !alice
                .members(&group_id)
                .expect("alice members")
                .contains(&carol.identity().public_key()),
            "carol must be out of the group after the merge"
        );

        let (post_removal_event, _) = alice
            .create_and_process_text_message(&group_id, "after carol removal")
            .expect("alice sends post-removal");
        assert!(matches!(
            bob.process_incoming(&post_removal_event)
                .await
                .expect("bob still reads post-removal message"),
            Incoming::Message(_)
        ));
        let carol_result = carol.process_incoming(&post_removal_event).await;
        let carol_readable = matches!(carol_result, Ok(Incoming::Message(_)));
        assert!(
            !carol_readable,
            "removed member must not be able to read a post-removal message, got {carol_result:?}"
        );
        // Guard against a silent DB write: carol's transcript must not contain it.
        let carol_rows = carol.messages(&carol_group_id).unwrap_or_default();
        assert!(
            !carol_rows.iter().any(|m| m.content == "after carol removal"),
            "post-removal message must not appear in carol's transcript"
        );
    }

    /// Sends now run on a dedicated host lane concurrent with sync/drain; the
    /// engine's internal MLS write lock is what keeps that safe. Hammer one
    /// engine with parallel outgoing sends and incoming processing and verify
    /// every row lands in the transcript.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_sends_and_incoming_processing_land_every_row() {
        let relays = vec![RelayUrl::parse("wss://relay.example.com").expect("relay url")];
        let alice = std::sync::Arc::new(MarmotEngine::in_memory(Identity::generate()));
        let bob = MarmotEngine::in_memory(Identity::generate());
        let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");

        let creation = alice
            .create_group("alice & bob", vec![bob_kp], relays)
            .expect("alice creates group");
        let group_id = creation.group.mls_group_id.clone();
        let (bob_pubkey, bob_welcome) = creation
            .welcomes
            .into_iter()
            .find(|(pubkey, _)| *pubkey == bob.identity().public_key())
            .expect("bob welcome");
        let bob_wrapped = alice
            .gift_wrap_welcome(&bob_pubkey, bob_welcome)
            .await
            .expect("wrap bob welcome");
        assert!(matches!(
            bob.process_incoming(&bob_wrapped)
                .await
                .expect("bob processes welcome"),
            Incoming::GroupUpdated(_)
        ));
        alice
            .merge_pending_commit(&group_id)
            .expect("alice merges pending commit");

        let bob_group_id = bob.groups().expect("bob groups")[0].mls_group_id.clone();
        let incoming_events: Vec<Event> = (0..10)
            .map(|i| {
                bob.create_text_message(&bob_group_id, &format!("from bob {i}"))
                    .expect("bob creates message")
            })
            .collect();

        let sender = {
            let alice = alice.clone();
            let group_id = group_id.clone();
            tokio::task::spawn_blocking(move || {
                for i in 0..10 {
                    alice
                        .create_and_process_text_message(&group_id, &format!("from alice {i}"))
                        .expect("alice sends");
                }
            })
        };
        let receiver = {
            let alice = alice.clone();
            tokio::spawn(async move {
                for event in incoming_events {
                    assert!(matches!(
                        alice
                            .process_incoming(&event)
                            .await
                            .expect("alice processes incoming"),
                        Incoming::Message(_)
                    ));
                }
            })
        };
        sender.await.expect("send task");
        receiver.await.expect("receive task");

        let transcript = alice.messages(&group_id).expect("alice transcript");
        let mine = transcript.iter().filter(|m| m.mine).count();
        let theirs = transcript.iter().filter(|m| !m.mine).count();
        assert_eq!(mine, 10, "every concurrent send must land");
        assert_eq!(theirs, 10, "every concurrent incoming must land");
    }

    #[test]
    fn sort_marmot_events_orders_by_created_at() {
        let keys = Keys::generate();
        let newer = signed_event(&keys, 30, "newer");
        let oldest = signed_event(&keys, 10, "oldest");
        let middle = signed_event(&keys, 20, "middle");

        let sorted = sort_marmot_events([newer, oldest, middle]);
        let contents: Vec<&str> = sorted.iter().map(|event| event.content.as_str()).collect();

        assert_eq!(contents, ["oldest", "middle", "newer"]);
    }

    #[tokio::test]
    async fn group_message_catchup_floor_uses_peer_message_not_later_local_send() {
        let relays = vec![RelayUrl::parse("wss://relay.example.com").expect("relay url")];
        let alice = MarmotEngine::in_memory(Identity::generate());
        let bob = MarmotEngine::in_memory(Identity::generate());
        let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");

        let creation = alice
            .create_group("alice & bob", vec![bob_kp], relays)
            .expect("alice creates group");
        let group_id = creation.group.mls_group_id.clone();
        let nostr_group_id_hex = hex::encode(creation.group.nostr_group_id);
        let (bob_pubkey, bob_welcome) = creation
            .welcomes
            .into_iter()
            .find(|(pubkey, _)| *pubkey == bob.identity().public_key())
            .expect("bob welcome");
        let bob_wrapped = alice
            .gift_wrap_welcome(&bob_pubkey, bob_welcome)
            .await
            .expect("wrap bob welcome");
        assert!(matches!(
            bob.process_incoming(&bob_wrapped)
                .await
                .expect("bob processes welcome"),
            Incoming::GroupUpdated(_)
        ));
        alice
            .merge_pending_commit(&group_id)
            .expect("alice merges pending commit");

        let bob_group_id = bob.groups().expect("bob groups")[0].mls_group_id.clone();
        let bob_event = bob
            .create_text_message(&bob_group_id, "remote first")
            .expect("bob creates message");
        let bob_message_secs = bob_event.created_at.as_secs();
        assert!(matches!(
            alice
                .process_incoming(&bob_event)
                .await
                .expect("alice processes remote message"),
            Incoming::Message(_)
        ));

        tokio::time::sleep(Duration::from_secs(1)).await;
        let alice_event = alice
            .create_text_message(&group_id, "local later")
            .expect("alice creates local message");
        assert!(alice_event.created_at.as_secs() > bob_message_secs);
        assert!(matches!(
            alice
                .process_incoming(&alice_event)
                .await
                .expect("alice processes local message"),
            Incoming::Message(_)
        ));

        let floors = SonarClient::group_message_catchup_floors(&alice);
        assert_eq!(
            floors.get(&nostr_group_id_hex).copied(),
            Some(bob_message_secs)
        );
    }

    #[tokio::test]
    async fn media_roundtrip_decrypts_for_sender_and_peer() {
        // Reproduction baseline for CLI/app media playback: proves the end-to-end
        // MIP-04 crypto round-trip (encrypt -> imeta-in-encrypted-rumor -> store
        // -> decrypt) works fully offline, with no relay/Blossom/app dependency.
        // If a voice note "can't play", the failure is downstream of this path
        // (codec, network, or app rendering) -- not the media crypto itself.
        let relays = vec![RelayUrl::parse("wss://relay.example.com").expect("relay url")];
        let alice = MarmotEngine::in_memory(Identity::generate());
        let bob = MarmotEngine::in_memory(Identity::generate());
        let bob_kp = bob.key_package_event(relays.clone()).expect("bob kp");
        let creation = alice
            .create_group("alice & bob", vec![bob_kp], relays)
            .expect("alice creates group");
        let group_id = creation.group.mls_group_id.clone();
        let (bob_pubkey, bob_welcome) = creation
            .welcomes
            .into_iter()
            .find(|(pk, _)| *pk == bob.identity().public_key())
            .expect("bob welcome");
        let bob_wrapped = alice
            .gift_wrap_welcome(&bob_pubkey, bob_welcome)
            .await
            .expect("wrap bob welcome");
        assert!(matches!(
            bob.process_incoming(&bob_wrapped)
                .await
                .expect("bob welcome"),
            Incoming::GroupUpdated(_)
        ));
        alice
            .merge_pending_commit(&group_id)
            .expect("alice merges pending commit");
        let bob_group_id = bob.groups().expect("bob groups")[0].mls_group_id.clone();

        // Alice sends a "voice note" -- arbitrary bytes stand in for AAC audio.
        let original = b"fake-aac-audio-bytes".to_vec();
        let url = "https://blossom.test/abcdef0123";
        let upload = alice
            .encrypt_media(&group_id, &original, "audio/mp4", "voice.m4a")
            .expect("alice encrypts media");
        let event = alice
            .create_media_event(&group_id, &upload, url, "listen to this")
            .expect("alice creates media event");

        // Both sides store the message; the imeta rides inside the encrypted rumor.
        assert!(matches!(
            alice
                .process_incoming(&event)
                .await
                .expect("alice stores own media"),
            Incoming::Message(_)
        ));
        assert!(matches!(
            bob.process_incoming(&event)
                .await
                .expect("bob receives media"),
            Incoming::Message(_)
        ));

        // Bob's transcript surfaces a media reference pointing at the blob URL.
        let bob_msg = bob
            .messages(&bob_group_id)
            .expect("bob messages")
            .into_iter()
            .find(|m| !m.media.is_empty())
            .expect("bob has a media message");
        assert_eq!(bob_msg.media[0].url, url);
        assert_eq!(bob_msg.media[0].mime_type, "audio/mp4");

        // The "downloaded" ciphertext decrypts back to the original bytes for
        // BOTH sender and receiver, keyed off the locally stored imeta.
        let alice_plain = alice
            .decrypt_media_by_url(&group_id, url, &upload.encrypted_data)
            .expect("alice decrypts own media");
        let bob_plain = bob
            .decrypt_media_by_url(&bob_group_id, url, &upload.encrypted_data)
            .expect("bob decrypts received media");
        assert_eq!(alice_plain, original);
        assert_eq!(bob_plain, original);
    }

    #[test]
    fn group_message_catchup_retry_rotates_failed_group_to_back() {
        let mut queue = VecDeque::from([
            ("aaa".to_string(), 100),
            ("bbb".to_string(), 200),
            ("ccc".to_string(), 300),
        ]);

        let (group_id, floor) = queue.pop_front().expect("first queued group");
        SonarClient::push_group_message_catchup_back(&mut queue, group_id, floor);

        let queued: Vec<_> = queue.into_iter().collect();
        assert_eq!(
            queued,
            vec![
                ("bbb".to_string(), 200),
                ("ccc".to_string(), 300),
                ("aaa".to_string(), 100),
            ]
        );
    }

    #[test]
    fn live_event_deduper_suppresses_duplicates_inside_ttl() {
        let mut deduper = LiveEventDeduper::new(Duration::from_secs(60), 16);
        let now = Instant::now();
        let event_id = test_event_id(1);

        assert!(deduper.should_accept(&event_id, now));
        assert!(!deduper.should_accept(&event_id, now + Duration::from_secs(1)));
    }

    #[test]
    fn live_event_deduper_allows_event_after_ttl() {
        let mut deduper = LiveEventDeduper::new(Duration::from_secs(5), 16);
        let now = Instant::now();
        let event_id = test_event_id(1);

        assert!(deduper.should_accept(&event_id, now));
        assert!(deduper.should_accept(&event_id, now + Duration::from_secs(6)));
    }

    #[test]
    fn live_event_deduper_evicts_oldest_entry_at_capacity() {
        let mut deduper = LiveEventDeduper::new(Duration::from_secs(60), 2);
        let now = Instant::now();
        let first = test_event_id(1);
        let second = test_event_id(2);
        let third = test_event_id(3);

        assert!(deduper.should_accept(&first, now));
        assert!(deduper.should_accept(&second, now));
        assert!(deduper.should_accept(&third, now));
        assert!(deduper.should_accept(&first, now + Duration::from_secs(1)));
    }

    #[test]
    fn newest_valid_sonar_descriptor_preserves_offer_from_freshest_meta() {
        let keys = Keys::generate();
        let offer = "lno1qsgqmqvgm96frzdg8m0gc6nzeqffvzsqzrxqy32afmr3jn9ggl9g2s8sugfvxn4xqzqxqsq";
        let old_meta = signed_descriptor_event(
            &keys,
            SONAR_META_DESCRIPTOR_D_TAG,
            10,
            meta_descriptor_content_json(true, vec!["marmot".to_string()], Some(offer.to_string()))
                .expect("meta descriptor json"),
        );
        let new_call = signed_descriptor_event(
            &keys,
            SONAR_CALL_DESCRIPTOR_D_TAG,
            20,
            descriptor_content_json(true, vec!["marmot".to_string()])
                .expect("call descriptor json"),
        );

        let descriptor = newest_valid_sonar_descriptor([old_meta, new_call], keys.public_key())
            .expect("freshest descriptor");

        assert_eq!(descriptor.published_at_secs, 20);
        assert_eq!(descriptor.bolt12_offer, Some(offer.to_string()));
        assert_eq!(
            descriptor.payment_receipts,
            vec!["sonar.payment.receipt.v1".to_string()]
        );
    }

    #[test]
    fn newest_valid_sonar_descriptor_respects_freshest_meta_without_offer() {
        let keys = Keys::generate();
        let offer = "lno1qsgqmqvgm96frzdg8m0gc6nzeqffvzsqzrxqy32afmr3jn9ggl9g2s8sugfvxn4xqzqxqsq";
        let old_meta = signed_descriptor_event(
            &keys,
            SONAR_META_DESCRIPTOR_D_TAG,
            10,
            meta_descriptor_content_json(true, vec!["marmot".to_string()], Some(offer.to_string()))
                .expect("meta descriptor json"),
        );
        let clear_meta = signed_descriptor_event(
            &keys,
            SONAR_META_DESCRIPTOR_D_TAG,
            20,
            meta_descriptor_content_json(true, vec!["marmot".to_string()], None)
                .expect("meta descriptor json"),
        );
        let new_call = signed_descriptor_event(
            &keys,
            SONAR_CALL_DESCRIPTOR_D_TAG,
            30,
            descriptor_content_json(true, vec!["marmot".to_string()])
                .expect("call descriptor json"),
        );

        let descriptor =
            newest_valid_sonar_descriptor([old_meta, clear_meta, new_call], keys.public_key())
                .expect("freshest descriptor");

        assert_eq!(descriptor.published_at_secs, 30);
        assert!(descriptor.bolt12_offer.is_none());
        assert!(descriptor.payment_receipts.is_empty());
    }

    #[test]
    fn p3_catchup_priority_and_live_since_are_cheap() {
        use std::time::Instant;
        let now = 1_700_000_000u64;
        let start = Instant::now();
        for i in 0..50_000u64 {
            let _ = live_group_since_secs(now.saturating_sub(i % 10_000), now);
            let mut q = VecDeque::from([
                ("a".into(), 1u64),
                ("b".into(), 2u64),
                ("active".into(), 3u64),
            ]);
            let _ = take_catchup_entry(&mut q, Some("active"));
        }
        let elapsed = start.elapsed();
        // Pure policy helpers must stay negligible vs network RTT.
        assert!(
            elapsed.as_millis() < 500,
            "policy helpers too slow: {elapsed:?}"
        );
    }

    #[test]
    fn map_mls_hex_to_nostr_hex_finds_pair() {
        let pairs = vec![("aa".into(), "n1".into()), ("bb".into(), "n2".into())];
        assert_eq!(
            map_mls_hex_to_nostr_hex("BB", &pairs).as_deref(),
            Some("n2")
        );
        assert_eq!(map_mls_hex_to_nostr_hex("", &pairs), None);
        assert_eq!(map_mls_hex_to_nostr_hex("zz", &pairs), None);
    }

    #[test]
    fn prefer_catchup_promotes_active_group() {
        let mut q = VecDeque::from([
            ("aaa".into(), 1u64),
            ("bbb".into(), 2u64),
            ("ccc".into(), 3u64),
        ]);
        let got = take_catchup_entry(&mut q, Some("ccc")).expect("preferred");
        assert_eq!(got.0, "ccc");
        assert_eq!(q.front().map(|e| e.0.as_str()), Some("aaa"));
    }

    #[test]
    fn split_buffers_keep_group_events_when_giftwraps_flood() {
        let mut giftwraps: Vec<u32> = Vec::new();
        let mut groups: Vec<u32> = Vec::new();
        for i in 0..(MARMOT_GIFTWRAP_BUFFER_CAP as u32 + 10) {
            let _ = push_live_buffer(&mut giftwraps, i, MARMOT_GIFTWRAP_BUFFER_CAP);
        }
        let dropped = push_live_buffer(&mut groups, 42u32, MARMOT_GROUP_BUFFER_CAP);
        assert!(!dropped);
        assert_eq!(groups, vec![42]);
        assert!(giftwraps.len() <= MARMOT_GIFTWRAP_BUFFER_CAP);
        assert!(giftwraps.len() >= MARMOT_GIFTWRAP_BUFFER_CAP / 2);
    }

    #[test]
    fn live_group_since_secs_prefers_thin_tail_over_ancient_watermark() {
        let now = 1_700_000_000u64;
        let ancient = now - 30 * 24 * 60 * 60;
        let since = live_group_since_secs(ancient, now);
        assert_eq!(since, now - LIVE_GROUP_TAIL_SECS);
    }

    #[test]
    fn live_group_since_secs_keeps_recent_watermark_with_overlap() {
        let now = 1_700_000_000u64;
        let watermark = now - 60;
        let since = live_group_since_secs(watermark, now);
        assert_eq!(since, watermark - SYNC_OVERLAP_SECS);
    }

    #[test]
    fn live_group_since_secs_first_session_still_bounded() {
        let now = 1_700_000_000u64;
        let since = live_group_since_secs(0, now);
        assert_eq!(since, now - LIVE_GROUP_TAIL_SECS);
    }

    #[test]
    fn sync_state_uses_conservative_watermark() {
        assert_eq!(conservative_watermark(1_000, 500), 500);
        assert_eq!(conservative_watermark(500, 1_000), 500);
        assert_eq!(conservative_watermark(0, 1_000), 0);
        assert_eq!(conservative_watermark(1_000, 0), 0);
    }

    #[test]
    fn sync_state_ignores_stale_sidecar_when_storage_is_empty() {
        let temp = tempfile::tempdir().expect("tempdir");
        let path = temp.path().join("marmot.sqlite.sonar-sync.json");
        let disk = SyncStateDisk {
            version: SYNC_STATE_VERSION,
            watermark_secs: 1_000,
            processed_event_ids: vec!["abc".to_string()],
        };
        fs::write(&path, serde_json::to_vec(&disk).expect("json")).expect("write state");

        let state = SyncState::load(Some(path), 0, true);

        assert_eq!(state.watermark_secs(), 0);
        assert!(!state.has_processed("abc"));
    }

    #[test]
    fn sync_state_rewinds_for_retry_with_overlap() {
        let mut state = SyncState::new(None, 1_000, Vec::new());

        state.rewind_for_retry(900);

        assert_eq!(state.watermark_secs(), 900 - SYNC_OVERLAP_SECS);
    }

    #[tokio::test]
    async fn failed_group_message_remains_visible_to_mdk_rollback_retry() {
        let relays = vec![RelayUrl::parse("wss://relay.example.com").expect("relay url")];
        let alice = MarmotEngine::in_memory(Identity::generate());
        let bob = MarmotEngine::in_memory(Identity::generate());
        let charlie = SonarClient::connect_in_memory(Identity::generate(), Vec::new())
            .await
            .expect("charlie starts without relays");
        let bob_kp = bob
            .key_package_event(relays.clone())
            .expect("bob key package");
        let charlie_kp = charlie
            .engine
            .key_package_event(relays.clone())
            .expect("charlie key package");
        let creation = alice
            .create_group("rollback retry", vec![bob_kp, charlie_kp], relays.clone())
            .expect("alice creates group");
        let alice_group_id = creation.group.mls_group_id.clone();

        for (member, welcome) in creation.welcomes {
            let wrapped = alice
                .gift_wrap_welcome(&member, welcome)
                .await
                .expect("wrap welcome");
            if member == bob.identity().public_key() {
                assert!(matches!(
                    bob.process_incoming(&wrapped)
                        .await
                        .expect("bob processes welcome"),
                    Incoming::GroupInvitePending(_)
                ));
                let invite = bob.pending_group_invites().expect("bob invites").remove(0);
                bob.accept_group_invite(&invite.id)
                    .expect("bob accepts invite");
            } else {
                let (report, _) = charlie
                    .process_marmot_events([wrapped], "test charlie welcome")
                    .await;
                assert_eq!(report.processed, 1);
                let invite = charlie
                    .engine
                    .pending_group_invites()
                    .expect("charlie invites")
                    .remove(0);
                charlie
                    .engine
                    .accept_group_invite(&invite.id)
                    .expect("charlie accepts invite");
            }
        }
        alice
            .merge_pending_commit(&creation.group.mls_group_id)
            .expect("merge pending commit");

        let bob_group_id = bob.groups().expect("bob groups")[0].mls_group_id.clone();
        let charlie_group_id = charlie.engine.groups().expect("charlie groups")[0]
            .mls_group_id
            .clone();
        let dave = MarmotEngine::in_memory(Identity::generate());
        let erin = MarmotEngine::in_memory(Identity::generate());

        // Bob's earlier commit is the MIP-03 winner, but Charlie sees Alice's
        // competing commit first and therefore cannot initially decrypt Bob's
        // message from the winning epoch.
        let bob_update = bob
            .add_members(
                &bob_group_id,
                vec![dave
                    .key_package_event(relays.clone())
                    .expect("dave key package")],
            )
            .expect("bob creates earlier commit");
        tokio::time::sleep(Duration::from_secs(1)).await;
        let alice_update = alice
            .add_members(
                &alice_group_id,
                vec![erin.key_package_event(relays).expect("erin key package")],
            )
            .expect("alice creates later commit");
        assert!(
            bob_update.evolution_event.created_at < alice_update.evolution_event.created_at,
            "competing commits need deterministic MIP-03 order"
        );
        bob.merge_pending_commit(&bob_group_id)
            .expect("bob merges winning commit");
        let bob_message = bob
            .create_text_message(&bob_group_id, "message recovered after rollback")
            .expect("bob creates message in winning epoch");

        let (wrong_commit, _) = charlie
            .process_marmot_events([alice_update.evolution_event], "test losing commit first")
            .await;
        assert_eq!(wrong_commit.processed, 1);

        let (first_failure, _) = charlie
            .process_marmot_events([bob_message.clone()], "test initial message failure")
            .await;
        assert_eq!(first_failure.retryable_failures, 1);

        // A duplicate relay delivery reaches MDK's Incoming::Failed branch.
        // Sonar used to add the event to its own durable processed-ID set here.
        let (failed_redelivery, _) = charlie
            .process_marmot_events([bob_message.clone()], "test failed redelivery")
            .await;
        assert_eq!(failed_redelivery.processed, 1);
        assert!(
            !charlie.is_sync_event_processed(&bob_message.id),
            "Sonar dedup must not hide an MDK Failed event that a later MLS rollback can make Retryable"
        );

        let (winning_commit, _) = charlie
            .process_marmot_events([bob_update.evolution_event], "test winning commit rollback")
            .await;
        assert_eq!(winning_commit.processed, 1);

        let (recovered, _) = charlie
            .process_marmot_events([bob_message], "test retry after rollback")
            .await;
        assert_eq!(recovered.processed, 1);
        assert!(
            charlie
                .engine
                .messages(&charlie_group_id)
                .expect("charlie transcript")
                .iter()
                .any(|message| message.content == "message recovered after rollback"),
            "relay redelivery after rollback must restore the missing peer message"
        );
    }

    #[test]
    fn relay_publish_requires_at_least_one_successful_relay() {
        let relay = RelayUrl::parse("wss://relay.example.com").expect("relay url");
        let accepted = nostr_sdk::pool::Output {
            val: EventId::all_zeros(),
            success: HashSet::from([relay.clone()]),
            failed: HashMap::new(),
        };
        assert!(require_relay_success(&accepted, "test publish").is_ok());

        let rejected = nostr_sdk::pool::Output {
            val: EventId::all_zeros(),
            success: HashSet::new(),
            failed: HashMap::from([(relay, "blocked".to_string())]),
        };
        let err = require_relay_success(&rejected, "test publish").expect_err("must fail");
        assert!(err
            .to_string()
            .contains("test publish: no relay accepted event"));
    }

    #[tokio::test]
    async fn push_registration_does_not_require_transponder_publish() {
        let client = SonarClient::connect_in_memory(Identity::generate(), Vec::new())
            .await
            .expect("client starts without relays");
        let server_pubkey = Keys::generate().public_key();

        client
            .register_push_token("apns", b"device-token", &server_pubkey.to_hex())
            .await
            .expect("push registration should only cache and share the token");

        let own = client
            .own_push_registration
            .lock()
            .unwrap()
            .clone()
            .expect("own push registration cached");

        assert_eq!(own.server_pubkey, server_pubkey);
        assert!(!own.encrypted_token_b64.is_empty());
    }

    struct RecordingChangeListener {
        changed: Mutex<Vec<String>>,
    }

    impl ConversationChangeListener for RecordingChangeListener {
        fn on_conversation_changed(&self, group_id_hex: String) {
            self.changed.lock().unwrap().push(group_id_hex);
        }
    }

    #[tokio::test]
    async fn welcome_for_new_conversation_notifies_change_listener() {
        // A 1:1 welcome is auto-accepted as Incoming::GroupUpdated. The host
        // chat lists are event-driven, so processing it must emit a
        // conversation-changed notification for the new group — otherwise a
        // brand-new chat stays invisible until an unrelated refresh.
        let relays = vec![RelayUrl::parse("wss://relay.example.com").expect("relay url")];
        let alice = MarmotEngine::in_memory(Identity::generate());
        let bob = SonarClient::connect_in_memory(Identity::generate(), Vec::new())
            .await
            .expect("client starts without relays");
        let listener = Arc::new(RecordingChangeListener {
            changed: Mutex::new(Vec::new()),
        });
        bob.set_conversation_change_listener(Some(listener.clone()));

        let bob_kp = bob
            .engine
            .key_package_event(relays.clone())
            .expect("bob key package");
        let creation = alice
            .create_group("alice & bob", vec![bob_kp], relays)
            .expect("alice creates group");
        let (bob_pubkey, bob_welcome) = creation
            .welcomes
            .into_iter()
            .find(|(pk, _)| *pk == bob.identity().public_key())
            .expect("bob welcome");
        let wrapped = alice
            .gift_wrap_welcome(&bob_pubkey, bob_welcome)
            .await
            .expect("wrap bob welcome");

        let (report, _) = bob.process_marmot_events([wrapped], "test welcome").await;
        assert_eq!(report.processed, 1);

        let bob_groups = bob.engine.groups().expect("bob groups");
        assert_eq!(bob_groups.len(), 1);
        let expected = hex::encode(bob_groups[0].mls_group_id.as_slice());
        let changed = listener.changed.lock().unwrap().clone();
        assert_eq!(
            changed,
            vec![expected],
            "welcome must notify the conversation listener exactly once for the new group"
        );
    }

    #[tokio::test]
    async fn pending_multimember_invite_notifies_change_listener() {
        // A multi-member welcome (member_count > 2) is stored PENDING rather than
        // auto-accepted, so it resolves to Incoming::GroupInvitePending and its
        // group is not yet in groups() (only pending_group_invites()). It must
        // still notify the conversation listener so the invite row appears in the
        // backgrounded host without waiting for a heartbeat.
        let relays = vec![RelayUrl::parse("wss://relay.example.com").expect("relay url")];
        let alice = MarmotEngine::in_memory(Identity::generate());
        let carol = MarmotEngine::in_memory(Identity::generate());
        let bob = SonarClient::connect_in_memory(Identity::generate(), Vec::new())
            .await
            .expect("client starts without relays");
        let listener = Arc::new(RecordingChangeListener {
            changed: Mutex::new(Vec::new()),
        });
        bob.set_conversation_change_listener(Some(listener.clone()));

        let bob_kp = bob
            .engine
            .key_package_event(relays.clone())
            .expect("bob key package");
        let carol_kp = carol
            .key_package_event(relays.clone())
            .expect("carol key package");
        let creation = alice
            .create_group("alice, bob & carol", vec![bob_kp, carol_kp], relays)
            .expect("alice creates 3-member group");
        let (bob_pubkey, bob_welcome) = creation
            .welcomes
            .into_iter()
            .find(|(pk, _)| *pk == bob.identity().public_key())
            .expect("bob welcome");
        let wrapped = alice
            .gift_wrap_welcome(&bob_pubkey, bob_welcome)
            .await
            .expect("wrap bob welcome");

        let (report, _) = bob
            .process_marmot_events([wrapped], "test pending invite")
            .await;
        assert_eq!(report.processed, 1);

        // Pending invite: the group is NOT active yet, only surfaced as an invite.
        assert!(bob.engine.groups().expect("bob groups").is_empty());
        let invites = bob.pending_group_invites().expect("pending invites");
        assert_eq!(invites.len(), 1);
        let expected = hex::encode(invites[0].group_id.as_slice());
        let changed = listener.changed.lock().unwrap().clone();
        assert_eq!(
            changed,
            vec![expected],
            "pending invite must notify the conversation listener exactly once"
        );
    }
}
