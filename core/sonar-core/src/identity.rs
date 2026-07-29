//! Nostr identity management.
//!
//! Sonar identity model (decided 2026-06-11):
//! - A fresh identity is generated silently by default (zero-friction onboarding).
//! - An existing identity can be imported from an `nsec` (bech32) or hex secret key.
//! - Anonymous/ephemeral usage stays first-class: an [`Identity`] is only
//!   persisted when the caller decides to (the core never writes keys to disk
//!   itself; native shells own keychain storage).
//!
//! External-signer model (added 2026-07-29 for Amber / NIP-55):
//! - An identity is either **local** (holds the raw [`Keys`]) or **remote**
//!   (holds only the public key plus a [`NostrSigner`] that proxies signing /
//!   NIP-44 to an external signer app; the secret never enters this process).
//! - Every signature and NIP-44/NIP-59 operation must go through
//!   [`Identity::signer`] so both flavors behave identically.
//! - Deterministic derivations that need raw secret bytes (geohash ephemeral
//!   identities, the iroh call identity) read [`Identity::kdf_root`]: for local
//!   accounts these are the secret-key bytes (unchanged, wire-compatible with
//!   existing installs); for remote accounts the host supplies a device-local
//!   random root instead.
//! - Operations that fundamentally require the secret itself (nsec export,
//!   the Blossom account backup's wrapping key) call [`Identity::local_keys`]
//!   and surface [`Error::NeedsLocalKey`] on remote accounts.

use std::sync::Arc;

use nostr::prelude::*;

use crate::{Error, Result};

/// A Sonar identity: a Nostr keypair (or an external signer for it) plus the
/// root material for deterministic sub-key derivations.
#[derive(Clone)]
pub struct Identity {
    public_key: PublicKey,
    signer: Arc<dyn NostrSigner>,
    /// Present only for local accounts.
    keys: Option<Keys>,
    /// Root for deterministic derivations (geohash keys, iroh call identity).
    /// Local accounts: the secret-key bytes. Remote accounts: a host-provided
    /// device-local random root.
    kdf_root: [u8; 32],
}

impl std::fmt::Debug for Identity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never derive Debug here: it must not print secret material.
        f.debug_struct("Identity")
            .field("public_key", &self.public_key)
            .field("local", &self.keys.is_some())
            .finish()
    }
}

impl Identity {
    fn from_keys(keys: Keys) -> Self {
        let kdf_root = keys.secret_key().to_secret_bytes();
        Self {
            public_key: keys.public_key(),
            signer: Arc::new(keys.clone()),
            keys: Some(keys),
            kdf_root,
        }
    }

    /// Generate a brand-new identity (default onboarding path).
    pub fn generate() -> Self {
        Self::from_keys(Keys::generate())
    }

    /// Import an existing identity from an `nsec1...` bech32 string or 64-char
    /// hex secret key.
    pub fn import(secret: &str) -> Result<Self> {
        Ok(Self::from_keys(Keys::parse(secret)?))
    }

    /// An identity whose secret lives in an external signer (Amber / NIP-55).
    ///
    /// `kdf_root` is a host-generated, device-local random 32-byte root for
    /// deterministic derivations. It is NOT the account secret: losing it
    /// only rotates the geohash/call sub-identities, never the account.
    pub fn with_remote_signer(
        public_key: PublicKey,
        signer: Arc<dyn NostrSigner>,
        kdf_root: [u8; 32],
    ) -> Self {
        Self {
            public_key,
            signer,
            keys: None,
            kdf_root,
        }
    }

    /// The signer for every signature / NIP-44 / NIP-59 operation on this
    /// identity. For local accounts this is the in-process [`Keys`].
    pub fn signer(&self) -> Arc<dyn NostrSigner> {
        self.signer.clone()
    }

    /// The raw local keys, when this account holds them in-process.
    ///
    /// Only for operations that cannot be expressed through a signer (nsec
    /// export, backup-wrapping KDF). Everything else must use [`Self::signer`].
    pub fn local_keys(&self) -> Result<&Keys> {
        self.keys
            .as_ref()
            .ok_or(Error::NeedsLocalKey("local secret key"))
    }

    /// True when the secret key is held in-process (nsec export possible).
    pub fn has_local_keys(&self) -> bool {
        self.keys.is_some()
    }

    /// Root bytes for deterministic sub-key derivations. See the module docs
    /// for local-vs-remote semantics.
    pub fn kdf_root(&self) -> &[u8; 32] {
        &self.kdf_root
    }

    /// Public key (hex-displayable, bech32 via `to_bech32`).
    pub fn public_key(&self) -> PublicKey {
        self.public_key
    }

    /// `npub1...` form of the public key.
    pub fn npub(&self) -> String {
        self.public_key
            .to_bech32()
            .expect("bech32 encoding of a valid public key cannot fail")
    }

    /// Export the secret key as `nsec1...` (for user-driven backup only).
    /// Fails for external-signer accounts — the secret is not in this process.
    pub fn export_nsec(&self) -> Result<String> {
        Ok(self
            .local_keys()?
            .secret_key()
            .to_bech32()
            .expect("bech32 encoding of a valid secret key cannot fail"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_then_export_and_reimport_roundtrips() {
        let id = Identity::generate();
        let nsec = id.export_nsec().unwrap();
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

    #[test]
    fn local_kdf_root_is_secret_bytes() {
        // Existing installs derive geohash/call identities from the secret-key
        // bytes; the kdf_root of a local account must stay byte-identical.
        let id = Identity::generate();
        assert_eq!(
            id.kdf_root(),
            &id.local_keys().unwrap().secret_key().to_secret_bytes()
        );
    }

    #[test]
    fn remote_identity_has_no_local_keys() {
        let signing = Keys::generate();
        let id = Identity::with_remote_signer(
            signing.public_key(),
            Arc::new(signing.clone()),
            [7u8; 32],
        );
        assert!(!id.has_local_keys());
        assert!(matches!(
            id.local_keys(),
            Err(Error::NeedsLocalKey(_))
        ));
        assert!(id.export_nsec().is_err());
        assert_eq!(id.public_key(), signing.public_key());
        assert_eq!(id.kdf_root(), &[7u8; 32]);
    }

    #[test]
    fn debug_never_prints_secret_material() {
        let id = Identity::generate();
        let debug = format!("{id:?}");
        let nsec = id.export_nsec().unwrap();
        let secret_hex = id
            .local_keys()
            .unwrap()
            .secret_key()
            .to_secret_hex();
        assert!(!debug.contains(&nsec));
        assert!(!debug.contains(&secret_hex));
    }
}
