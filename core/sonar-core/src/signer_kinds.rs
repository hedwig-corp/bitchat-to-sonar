//! The Nostr kinds signed with the ACCOUNT identity key.
//!
//! External-signer (NIP-55) hosts request permission for exactly these kinds
//! at login, so the whole app works off the signer's remembered grants
//! without approval prompts. **When the core starts signing a new kind with
//! the identity key, add it here** — the FFI exports this list
//! (`identity_signed_kinds`) and the Kotlin mirror (`Nip55.SIGN_EVENT_KINDS`)
//! is pinned against it by a cross-boundary test, so forgetting the mirror
//! fails CI, but forgetting THIS list silently costs signer users an
//! approval screen per event.
//!
//! Kind-445 group messages and outer kind-1059 gift wraps are signed by
//! ephemeral/MDK keys and never reach the signer.

/// Identity-signed kinds, one entry per signing call site:
/// - 22242 — NIP-42 relay auth (implicit via the `nostr_sdk::Client` signer)
/// - 24242 — Blossom BUD-01 HTTP authorization (vendored blossom client)
/// - 0     — profile metadata (`client::publish_profile*`)
/// - 13    — NIP-59 seals (`marmot::gift_wrap_*`, push notify, NIP-17 DMs)
/// - 30078 — Sonar descriptor (`client::publish_sonar_descriptor*`)
/// - 10063 — Blossom server list (`client::set_blossom_servers`)
/// - 10031 — user sticker-pack list (`client` sticker paths)
/// - 30443 — Marmot KeyPackage envelope (`marmot::key_package_event`)
/// - 23353 — handle-registrar claim (`handles::build_claim_event`)
pub const IDENTITY_SIGNED_KINDS: [u16; 9] =
    [22242, 24242, 0, 13, 30078, 10063, 10031, 30443, 23353];

#[cfg(test)]
mod tests {
    use super::*;

    /// Pins the list against the constants the actual signing sites use, so
    /// renumbering a kind cannot silently strand the permission batch.
    #[test]
    fn list_matches_signing_site_constants() {
        assert!(IDENTITY_SIGNED_KINDS.contains(&crate::marmot::KEY_PACKAGE_KIND));
        assert!(IDENTITY_SIGNED_KINDS.contains(&crate::handles::HANDLE_REGISTRATION_KIND));
        assert!(IDENTITY_SIGNED_KINDS.contains(&crate::sonar_descriptor::SONAR_DESCRIPTOR_KIND));
        assert!(IDENTITY_SIGNED_KINDS.contains(&sonar_stickers::USER_STICKER_PACKS_KIND));
        // NIP-42 auth, Blossom auth + server list, seals: fixed protocol kinds.
        assert!(IDENTITY_SIGNED_KINDS.contains(&22242));
        assert!(IDENTITY_SIGNED_KINDS.contains(&(nostr::Kind::BlossomAuth.as_u16())));
        assert!(IDENTITY_SIGNED_KINDS.contains(&10063));
        assert!(IDENTITY_SIGNED_KINDS.contains(&(nostr::Kind::Seal.as_u16())));
        assert!(IDENTITY_SIGNED_KINDS.contains(&(nostr::Kind::Metadata.as_u16())));
    }
}
