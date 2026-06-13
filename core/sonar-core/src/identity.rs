//! Nostr identity management.
//!
//! Sonar identity model (decided 2026-06-11):
//! - A fresh identity is generated silently by default (zero-friction onboarding).
//! - An existing identity can be imported from an `nsec` (bech32) or hex secret key.
//! - Anonymous/ephemeral usage stays first-class: an [`Identity`] is only
//!   persisted when the caller decides to (the core never writes keys to disk
//!   itself; native shells own keychain storage).

use nostr::prelude::*;

use crate::Result;

/// A Sonar identity: a Nostr keypair plus optional kind-0 profile metadata.
#[derive(Debug, Clone)]
pub struct Identity {
    keys: Keys,
}

impl Identity {
    /// Generate a brand-new identity (default onboarding path).
    pub fn generate() -> Self {
        Self {
            keys: Keys::generate(),
        }
    }

    /// Import an existing identity from an `nsec1...` bech32 string or 64-char
    /// hex secret key.
    pub fn import(secret: &str) -> Result<Self> {
        let keys = Keys::parse(secret)?;
        Ok(Self { keys })
    }

    /// The underlying signing keys.
    pub fn keys(&self) -> &Keys {
        &self.keys
    }

    /// Public key (hex-displayable, bech32 via `to_bech32`).
    pub fn public_key(&self) -> PublicKey {
        self.keys.public_key()
    }

    /// `npub1...` form of the public key.
    pub fn npub(&self) -> String {
        self.keys
            .public_key()
            .to_bech32()
            .expect("bech32 encoding of a valid public key cannot fail")
    }

    /// Export the secret key as `nsec1...` (for user-driven backup only).
    pub fn export_nsec(&self) -> String {
        self.keys
            .secret_key()
            .to_bech32()
            .expect("bech32 encoding of a valid secret key cannot fail")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_then_export_and_reimport_roundtrips() {
        let id = Identity::generate();
        let nsec = id.export_nsec();
        let reimported = Identity::import(&nsec).unwrap();
        assert_eq!(id.public_key(), reimported.public_key());
    }

    #[test]
    fn import_rejects_garbage() {
        assert!(Identity::import("not-a-key").is_err());
        assert!(Identity::import("npub1invalid").is_err());
    }

    #[test]
    fn npub_is_bech32() {
        let id = Identity::generate();
        assert!(id.npub().starts_with("npub1"));
    }
}
