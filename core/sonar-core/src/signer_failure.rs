//! External-signer failure classification across the `SignerError` boundary.
//!
//! `nostr::signer::SignerError` erases its source to a plain `String`, so the
//! FFI signer adapter cannot hand the core a typed "transient vs permanent"
//! outcome. Instead the adapter embeds one of these stable markers in the
//! error text and the core classifies on them. The markers are core-owned so
//! the producing (sonar-ffi) and consuming (sync/drain retry policy) sides
//! cannot drift apart.
//!
//! - **Transient** — the signer could not be reached *right now*: the app is
//!   backgrounded with no remembered grant, the approval timed out, the
//!   signer app was busy. The operation must stay retryable; classifying it
//!   terminal would durably drop undecrypted welcomes/DMs.
//! - **Permanent** — the user explicitly rejected the request. Retrying would
//!   re-prompt forever; the caller treats it like a genuine failure.
//!
//! Failures from in-process `Keys` never carry a marker and keep their
//! pre-external-signer classification (genuine crypto failure ⇒ terminal).

/// Marker embedded by the FFI adapter when the user explicitly rejected.
pub const PERMANENT_MARKER: &str = "sonar-signer-permanent:";

/// Marker embedded by the FFI adapter for retryable transport failures.
pub const TRANSIENT_MARKER: &str = "sonar-signer-transient:";

/// True when `message` carries the transient external-signer marker.
pub fn is_transient_signer_failure(message: &str) -> bool {
    message.contains(TRANSIENT_MARKER)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_markers() {
        assert!(is_transient_signer_failure(
            "external signer sonar-signer-transient:nip44_decrypt: backgrounded"
        ));
        assert!(!is_transient_signer_failure(
            "external signer sonar-signer-permanent:sign_event: rejected"
        ));
        assert!(!is_transient_signer_failure("bad ciphertext"));
    }
}
