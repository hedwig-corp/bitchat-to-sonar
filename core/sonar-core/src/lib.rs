//! Sonar core: headless Rust engine for the Sonar messenger.
//!
//! Owns identity (Nostr keypairs, kind-0 profiles) and Marmot messaging
//! (MLS over Nostr via MDK). Native shells (SwiftUI / Compose) bind to this
//! crate and stay UI-only.

pub mod account_backup;
pub mod call;
pub mod client;
pub mod conversation_index;
pub mod error;
pub mod geohash;
pub mod handles;
pub mod identity;
pub mod invite_link;
pub mod marmot;
pub mod media_staging;
pub mod mention;
pub mod mesh;
pub mod mesh_engine;
pub mod noise;
pub mod notification;
pub mod outbox;
pub mod own_profile;
pub mod push;
pub mod relay_directory;
pub mod reply;
pub mod sonar_descriptor;
pub mod sqlcipher_runtime;
pub mod sticker_cache;
pub mod timezone;

pub use error::Error;

/// Re-exported so FFI/shell crates can name MLS group ids without depending
/// on MDK directly.
pub use mdk_core::GroupId;

/// Crate-wide result type.
pub type Result<T> = std::result::Result<T, Error>;
