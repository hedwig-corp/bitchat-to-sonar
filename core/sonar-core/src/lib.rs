//! Sonar core: headless Rust engine for the Sonar messenger.
//!
//! Owns identity (Nostr keypairs, kind-0 profiles) and Marmot messaging
//! (MLS over Nostr via MDK). Native shells (SwiftUI / Compose) bind to this
//! crate and stay UI-only.

pub mod client;
pub mod error;
pub mod geohash;
pub mod identity;
pub mod marmot;
pub mod mesh;
pub mod noise;

pub use error::Error;

/// Re-exported so FFI/shell crates can name MLS group ids without depending
/// on MDK directly.
pub use mdk_core::GroupId;

/// Crate-wide result type.
pub type Result<T> = std::result::Result<T, Error>;
