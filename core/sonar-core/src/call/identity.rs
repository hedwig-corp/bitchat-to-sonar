//! The call's iroh identity, derived from the existing Sonar identity.
//!
//! iroh requires an Ed25519 keypair; the Sonar identity is a Nostr secp256k1 key.
//! Rather than persist a separate key, we **derive** the 32-byte iroh secret from
//! the Nostr secret with HKDF-SHA256 + domain separation. Properties:
//!
//! - **Deterministic** — the same Sonar identity always yields the same iroh
//!   `NodeId`, so it survives reinstall-with-identity and lets a peer recognise
//!   the same caller across calls; no extra keystore entry to manage.
//! - **Domain-separated** — distinct from the Nostr key and from any other
//!   derived key; revealing the iroh `NodeId` leaks nothing about the Nostr key.
//! - **Sonar-bound** — the derived `NodeAddr` only ever travels inside an
//!   authenticated, end-to-end-encrypted `☎CALL` message (over Marmot / NIP-17),
//!   so the media session is cryptographically bound to the Sonar identity on
//!   both ends — you can only place/accept a call with another Sonar user.

use hkdf::Hkdf;
use sha2::Sha256;

/// Domain-separation label for the iroh call key. Bump the version suffix if the
/// derivation ever changes (it would rotate every user's call `NodeId`).
const IROH_KEY_INFO: &[u8] = b"sonar/call/iroh/v1";

/// Derive the 32-byte iroh (Ed25519) call secret from the Sonar Nostr secret
/// (`identity.keys().secret_key().to_secret_bytes()`). Pass the result to
/// `CallTransport::bind`.
pub fn derive_iroh_secret(nostr_secret: &[u8; 32]) -> [u8; 32] {
    // No salt: the Nostr secret is already high-entropy; the `info` label gives
    // domain separation.
    let hk = Hkdf::<Sha256>::new(None, nostr_secret);
    let mut out = [0u8; 32];
    hk.expand(IROH_KEY_INFO, &mut out)
        .expect("32 bytes is a valid HKDF-SHA256 output length");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derivation_is_deterministic_distinct_and_per_identity() {
        let nsk = [7u8; 32];
        let a = derive_iroh_secret(&nsk);
        let b = derive_iroh_secret(&nsk);
        assert_eq!(a, b, "same identity → same iroh key (stable NodeId)");
        assert_ne!(a, nsk, "iroh key is domain-separated from the Nostr key");
        let other = derive_iroh_secret(&[8u8; 32]);
        assert_ne!(a, other, "different identities → different iroh keys");
    }
}
