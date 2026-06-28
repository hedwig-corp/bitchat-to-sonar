use nostr::PublicKey;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("invalid key: {0}")]
    InvalidKey(String),

    #[error("invalid input: {0}")]
    InvalidInput(String),

    #[error("nostr key error: {0}")]
    NostrKey(#[from] nostr::key::Error),

    #[error("mdk error: {0}")]
    Mdk(#[from] mdk_core::Error),

    #[error("storage error: {0}")]
    Storage(String),

    #[error("event builder error: {0}")]
    EventBuilder(#[from] nostr::event::builder::Error),

    #[error("event error: {0}")]
    NostrEvent(#[from] nostr::event::Error),

    #[error("nip59 gift wrap error: {0}")]
    Nip59(#[from] nostr::nips::nip59::Error),

    #[error("nip44 encryption error: {0}")]
    Nip44(#[from] nostr::nips::nip44::Error),

    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("nostr client error: {0}")]
    NostrClient(#[from] nostr_sdk::client::Error),

    #[error("nostr publish error: {0}")]
    NostrPublish(String),

    #[error("relay fetch error: {0}")]
    RelayFetch(String),

    #[error("no key package found on relays for {0}")]
    KeyPackageNotFound(PublicKey),

    #[error("encrypted media error: {0}")]
    Media(String),

    #[error("blossom storage error: {0}")]
    Blossom(String),

    #[error("http error: {0}")]
    Http(String),

    #[error("no relay connected within timeout")]
    NoRelayConnected,

    #[error("rng error: {0}")]
    Rng(#[from] getrandom::Error),
}
