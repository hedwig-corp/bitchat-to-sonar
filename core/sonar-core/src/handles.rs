//! Unified human-readable handles (`vincenzo@sonarprivacy.xyz`).
//!
//! One claimed handle serves two resolutions:
//! - **NIP-05** (chat): `https://<domain>/.well-known/nostr.json?name=<local>`
//!   maps the handle to the owner's Nostr pubkey so peers can start a secure
//!   chat by typing a name instead of pasting an `npub1…`.
//! - **BIP-353** (payments): a DNS TXT record at
//!   `<local>.user._bitcoin-payment.<domain>` carries the owner's BOLT12 offer
//!   so any wallet can pay `name@domain`.
//!
//! Claiming is self-service: the app signs a kind-23353 Nostr event with the
//! identity key (`content` = `{"domain","handle","offer"?}`) and POSTs it to
//! the registrar (`services/handle-registrar/` in this repo). The registrar
//! verifies the schnorr signature, binds the handle to the pubkey first-come-
//! first-served, publishes the DNS TXT record, and serves the NIP-05 document.
//! The signed event is *not* published to relays.
//!
//! The claimed address is persisted in a small JSON sidecar next to the chat
//! database (same pattern as the sync/outbox/push sidecars) so every later
//! kind-0 profile publish can merge the `nip05` field without the host apps
//! having to thread it through each call site — a republish from a host that
//! only knows the nickname must never clobber the claimed handle.

use std::fs;
use std::path::{Path, PathBuf};

use nostr::prelude::*;
use serde::{Deserialize, Serialize};

use crate::{Error, Result};

/// Ephemeral-range kind for handle registration events (see
/// `docs/bip353-registration.md`). POSTed to the registrar, never to relays.
pub const HANDLE_REGISTRATION_KIND: u16 = 23353;

/// The default handle domain: bare nicknames (`vincenzo`) resolve here.
pub const DEFAULT_HANDLE_DOMAIN: &str = "sonarprivacy.xyz";

/// The registrar endpoint that accepts signed kind-23353 claims.
pub const DEFAULT_REGISTRAR_URL: &str = "https://bip353.sonarprivacy.xyz";

/// Longest accepted local part. NIP-05 does not bound it; DNS labels cap at 63
/// octets and the BIP-353 record prepends the local part as a label, so 63 is
/// the real-world ceiling.
const MAX_LOCAL_PART_LEN: usize = 63;

/// Hard cap on a `.well-known/nostr.json` response body. Well-formed documents
/// are tiny; the cap bounds memory against a hostile or misconfigured server.
pub(crate) const NIP05_MAX_RESPONSE_BYTES: usize = 64 * 1024;

pub(crate) const HANDLE_STATE_FILE_SUFFIX: &str = ".sonar-handle.json";
const HANDLE_STATE_VERSION: u32 = 1;

/// Sidecar path for the claimed-handle state, derived from the chat DB path
/// like every other sidecar (`sonar.db` → `sonar.db.sonar-handle.json`).
pub(crate) fn handle_state_path_for_db(db_path: &Path) -> PathBuf {
    let name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sonar.db");
    db_path.with_file_name(format!("{name}{HANDLE_STATE_FILE_SUFFIX}"))
}

#[derive(Serialize, Deserialize)]
struct HandleStateDisk {
    version: u32,
    /// Full claimed address, e.g. `vincenzo@sonarprivacy.xyz`.
    address: Option<String>,
}

/// Load the claimed address from the sidecar. Missing/corrupt files read as
/// "no handle" — the claim is recoverable by re-claiming (idempotent for the
/// same key), so corruption must never take the account down.
pub(crate) fn load_claimed_address(path: &Path) -> Option<String> {
    let bytes = fs::read(path).ok()?;
    let disk: HandleStateDisk = serde_json::from_slice(&bytes).ok()?;
    disk.address.filter(|a| !a.is_empty())
}

/// Persist the claimed address atomically (tmp + rename), matching the other
/// sidecars so a crash mid-write can't leave a truncated file.
pub(crate) fn store_claimed_address(path: &Path, address: Option<&str>) -> Result<()> {
    let disk = HandleStateDisk {
        version: HANDLE_STATE_VERSION,
        address: address.map(str::to_owned),
    };
    let bytes = serde_json::to_vec(&disk)
        .map_err(|e| Error::InvalidInput(format!("handle state serialize: {e}")))?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, bytes)
        .map_err(|e| Error::InvalidInput(format!("handle state write {}: {e}", tmp.display())))?;
    fs::rename(&tmp, path)
        .map_err(|e| Error::InvalidInput(format!("handle state rename {}: {e}", path.display())))?;
    Ok(())
}

/// Remove the sidecar (account wipe). Missing file is fine.
pub(crate) fn wipe_handle_state_for_db(db_path: &Path) -> Result<()> {
    let path = handle_state_path_for_db(db_path);
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(Error::InvalidInput(format!(
            "handle state wipe {}: {e}",
            path.display()
        ))),
    }
}

/// A handle input split into its parts, normalized to lowercase.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedHandle {
    pub local: String,
    pub domain: String,
}

impl ParsedHandle {
    pub fn address(&self) -> String {
        format!("{}@{}", self.local, self.domain)
    }
}

/// True if `s` is a valid handle local part (already lowercased): the NIP-05
/// charset `a-z0-9-_.`, must start and end alphanumeric, capped at the DNS
/// label limit so the same name is claimable as a BIP-353 record.
///
/// Consecutive dots are rejected to match the registrar: the local part
/// becomes DNS labels under `user._bitcoin-payment.<domain>`, and an empty
/// label (`a..b`) is unservable — the app must not build and sign a claim the
/// server will always refuse.
pub fn is_valid_local_part(s: &str) -> bool {
    if s.is_empty() || s.len() > MAX_LOCAL_PART_LEN {
        return false;
    }
    let bytes = s.as_bytes();
    let alnum = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit();
    if !alnum(bytes[0]) || !alnum(bytes[bytes.len() - 1]) {
        return false;
    }
    if s.split('.').any(|label| label.is_empty() || label.len() > 63) {
        return false;
    }
    bytes
        .iter()
        .all(|&b| alnum(b) || b == b'-' || b == b'_' || b == b'.')
}

/// WHATWG URL's "ends in a number" test, applied to a host's last label.
///
/// The URL parser (`url` 2.5.8, under `reqwest`) treats a host whose final part
/// parses as a number as an IPv4 address, and its IPv4 grammar accepts hex and
/// octal octets — not just decimal. Testing the TLD for all-ASCII-digits alone
/// therefore caught `1.2.3.4` but let every hex form through:
/// `0x7f.0x0.0x0.0x1` and the short `0x7f.0x1` both normalise to `127.0.0.1`,
/// `0xa9.0xfe.0xa9.0xfe` to the link-local metadata address `169.254.169.254`,
/// `0xc0.0xa8.0x1.0x1` to `192.168.1.1`.
///
/// Octal needs no separate arm — `0177.0.0.01` is all digits already. An empty
/// label counts as a number (`0x` with an empty body parses as 0, which is what
/// makes `0x.0x.0x.0x1` a host), and that also keeps the trailing-dot form
/// `1.2.3.4.` rejected.
///
/// Rejecting is the safe direction for the cases where the URL parser would
/// *fail* instead of normalising (`1.0x7f000001` overflows its 2-part slot):
/// such a host can never be fetched anyway.
fn label_is_ipv4_number(label: &str) -> bool {
    match label.strip_prefix("0x") {
        Some(hex) => hex.bytes().all(|b| b.is_ascii_hexdigit()),
        None => label.bytes().all(|b| b.is_ascii_digit()),
    }
}

/// True if `s` looks like a resolvable *public* DNS name for a handle domain:
/// ASCII letters/digits/hyphens in dot-separated labels, at least one dot.
///
/// SSRF hardening — the domain comes from attacker-controlled data (a peer's
/// kind-0 `nip05` field, or typed input), and resolution auto-fires from the
/// contact-profile screen. Reject IP literals (a numeric TLD is an IPv4
/// address in *any* radix — see `label_is_ipv4_number`; `[` opens an IPv6
/// literal) and well-known internal suffixes so the client never GETs
/// loopback/link-local/metadata or LAN hosts by name.
/// (A public name that *resolves* to a private IP — DNS rebinding — is out of
/// scope for a client-side string check; impact stays bounded by the GET-only,
/// no-redirect, 64KB-capped fetch path.)
fn is_valid_domain(s: &str) -> bool {
    if s.is_empty() || s.len() > 253 || !s.contains('.') {
        return false;
    }
    let labels: Vec<&str> = s.split('.').collect();
    // Numeric TLD ⇒ IPv4 literal (1.2.3.4, 0x7f.0x1); bracket ⇒ IPv6 literal.
    if s.starts_with('[') || labels.last().is_some_and(|tld| label_is_ipv4_number(tld)) {
        return false;
    }
    // Include `localhost` as a suffix so `foo.localhost` (loopback on most
    // resolvers) is rejected — bare `localhost` alone already fails the
    // "must contain a dot" check above.
    const INTERNAL_SUFFIXES: [&str; 6] =
        ["local", "internal", "localdomain", "home.arpa", "lan", "localhost"];
    if labels.first().is_some_and(|l| *l == "localhost")
        || INTERNAL_SUFFIXES
            .iter()
            .any(|suffix| s == *suffix || s.ends_with(&format!(".{suffix}")))
    {
        return false;
    }
    labels.iter().all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    })
}

/// Parse user input into a handle. Bare nicknames (`vincenzo`) resolve against
/// `default_domain`; full addresses (`alice@example.com`) resolve against the
/// given domain. Input is trimmed, lowercased, and a leading `₿` (the BIP-353
/// display prefix) is stripped, so a pasted payment address round-trips.
pub fn parse_handle_input(input: &str, default_domain: &str) -> Result<ParsedHandle> {
    let cleaned = input.trim().trim_start_matches('₿').trim().to_lowercase();
    if cleaned.is_empty() {
        return Err(Error::InvalidInput("empty handle".into()));
    }
    let (local, domain) = match cleaned.split_once('@') {
        Some((l, d)) => (l.to_owned(), d.to_owned()),
        None => (cleaned, default_domain.to_owned()),
    };
    if !is_valid_local_part(&local) {
        return Err(Error::InvalidInput(format!("invalid handle name: {local}")));
    }
    if local.contains('@') || !is_valid_domain(&domain) {
        return Err(Error::InvalidInput(format!(
            "invalid handle domain: {domain}"
        )));
    }
    Ok(ParsedHandle { local, domain })
}

/// True if `input` is plausibly a handle a user typed to find someone: either
/// `name@domain` or a bare local part. Used by search UIs to decide whether to
/// offer a "resolve handle" action without hitting the network.
///
/// Bare inputs that look like bech32 keys/events or Lightning strings are
/// excluded — they are charset-valid local parts but the user meant something
/// else, and the npub/invite paths must keep priority in search.
pub fn looks_like_handle(input: &str) -> bool {
    let cleaned = input.trim().trim_start_matches('₿').trim().to_lowercase();
    if !cleaned.contains('@') {
        const NOT_HANDLES: [&str; 8] = [
            "npub1", "nsec1", "note1", "nevent1", "nprofile1", "lno1", "lnbc", "lnurl",
        ];
        if NOT_HANDLES.iter().any(|p| cleaned.starts_with(p)) {
            return false;
        }
    }
    parse_handle_input(&cleaned, DEFAULT_HANDLE_DOMAIN).is_ok()
}

/// The NIP-05 lookup URL for a parsed handle.
pub(crate) fn nip05_url(handle: &ParsedHandle) -> String {
    format!(
        "https://{}/.well-known/nostr.json?name={}",
        handle.domain, handle.local
    )
}

/// A handle resolved to its owner's pubkey via NIP-05.
#[derive(Debug, Clone)]
pub struct ResolvedHandle {
    /// Canonical `name@domain` that was resolved.
    pub address: String,
    /// The owner's verified public key.
    pub pubkey: PublicKey,
}

/// Extract and validate the pubkey for `local` from a NIP-05 response body.
///
/// Verification, not just extraction: the document must contain an entry for
/// exactly the queried (lowercased) name, and the value must parse as a valid
/// x-only pubkey in hex (NIP-05 forbids npub-encoded values). A server that
/// answers with someone else's mapping or junk fails closed.
pub(crate) fn parse_nip05_response(body: &[u8], local: &str) -> Result<PublicKey> {
    #[derive(Deserialize)]
    struct Nip05Doc {
        names: std::collections::HashMap<String, String>,
    }
    if body.len() > NIP05_MAX_RESPONSE_BYTES {
        return Err(Error::Http("nip05 response too large".into()));
    }
    let doc: Nip05Doc = serde_json::from_slice(body)
        .map_err(|e| Error::Http(format!("nip05 response parse: {e}")))?;
    let hex = doc
        .names
        .get(local)
        .ok_or_else(|| Error::HandleNotFound(local.to_owned()))?;
    PublicKey::from_hex(hex).map_err(|e| Error::Http(format!("nip05 pubkey invalid: {e}")))
}

/// Registration event content, serialized into the kind-23353 `content` field.
/// `offer` is omitted (not null) when absent so a chat-only claim — made before
/// the wallet is ready — does not register an empty payment record.
#[derive(Serialize, Deserialize)]
pub(crate) struct ClaimContent {
    pub domain: String,
    pub handle: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub offer: Option<String>,
}

/// Registrar success response (subset we consume).
#[derive(Deserialize)]
pub(crate) struct ClaimResponse {
    pub address: String,
}

/// Build and sign the kind-23353 registration event. Signed with the identity
/// key — handle ownership is the account key, so restoring the nsec restores
/// the handle (re-claims from the same key are idempotent server-side).
pub(crate) fn build_claim_event(
    keys: &Keys,
    handle: &ParsedHandle,
    offer: Option<&str>,
) -> Result<Event> {
    let content = serde_json::to_string(&ClaimContent {
        domain: handle.domain.clone(),
        handle: handle.local.clone(),
        offer: offer.map(str::to_owned),
    })
    .map_err(|e| Error::InvalidInput(format!("claim content serialize: {e}")))?;
    EventBuilder::new(Kind::Custom(HANDLE_REGISTRATION_KIND), content)
        .sign_with_keys(keys)
        .map_err(Error::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_bare_nick_uses_default_domain() {
        let h = parse_handle_input("Vincenzo", "sonarprivacy.xyz").unwrap();
        assert_eq!(h.local, "vincenzo");
        assert_eq!(h.domain, "sonarprivacy.xyz");
        assert_eq!(h.address(), "vincenzo@sonarprivacy.xyz");
    }

    #[test]
    fn parse_full_address_keeps_domain() {
        let h = parse_handle_input("  Alice@Example.COM ", "sonarprivacy.xyz").unwrap();
        assert_eq!(h.local, "alice");
        assert_eq!(h.domain, "example.com");
    }

    #[test]
    fn parse_strips_bitcoin_prefix() {
        let h = parse_handle_input("₿vincenzo@sonarprivacy.xyz", "sonarprivacy.xyz").unwrap();
        assert_eq!(h.address(), "vincenzo@sonarprivacy.xyz");
    }

    #[test]
    fn parse_rejects_bad_input() {
        for bad in [
            "",
            " ",
            "@",
            "a@",
            "@example.com",
            "has space@example.com",
            "a@nodot",
            "-lead@example.com",
            "trail-@example.com",
            "a@@example.com",
            "emoji😀@example.com",
        ] {
            assert!(
                parse_handle_input(bad, "sonarprivacy.xyz").is_err(),
                "expected rejection: {bad:?}"
            );
        }
        // 64-char local part exceeds the DNS label cap.
        let long = "a".repeat(64);
        assert!(parse_handle_input(&long, "sonarprivacy.xyz").is_err());
        let ok = "a".repeat(63);
        assert!(parse_handle_input(&ok, "sonarprivacy.xyz").is_ok());
    }

    #[test]
    fn local_part_charset() {
        assert!(is_valid_local_part("alice"));
        assert!(is_valid_local_part("a.b-c_d9"));
        assert!(!is_valid_local_part("Alice")); // caller lowercases first
        assert!(!is_valid_local_part(".dot"));
        assert!(!is_valid_local_part("dot."));
        assert!(!is_valid_local_part("a..b")); // empty DNS label — registrar rejects
        assert!(!is_valid_local_part(""));
    }

    #[test]
    fn domain_rejects_internal_and_ip_hosts() {
        // The domain is attacker-controlled (peer kind-0 nip05) — IP literals
        // and internal suffixes must never reach the HTTP client.
        for bad in [
            "169.254.169.254",
            "10.0.0.1",
            "127.0.0.1",
            "printer.local",
            "vault.internal",
            "router.lan",
            "box.home.arpa",
            "host.localdomain",
            "foo.localhost",
        ] {
            assert!(
                parse_handle_input(&format!("alice@{bad}"), DEFAULT_HANDLE_DOMAIN).is_err(),
                "expected rejection: {bad}"
            );
        }
        assert!(parse_handle_input("alice@example.com", DEFAULT_HANDLE_DOMAIN).is_ok());
        // Numeric label is fine when it isn't the TLD.
        assert!(parse_handle_input("alice@1password.com", DEFAULT_HANDLE_DOMAIN).is_ok());
    }

    /// Regression: the IP-literal filter used to test the TLD for ASCII digits
    /// only, so every non-decimal IPv4 form walked past it and reqwest's WHATWG
    /// URL parser normalised the host back to a private address before
    /// connecting. Each `bad` below was verified against `url` 2.5.8 — the
    /// comment is the host it resolves to.
    #[test]
    fn domain_rejects_non_decimal_ipv4_literals() {
        for bad in [
            "0x7f.0x0.0x0.0x1",    // 127.0.0.1
            "0xa9.0xfe.0xa9.0xfe", // 169.254.169.254 — link-local metadata
            "0xc0.0xa8.0x1.0x1",   // 192.168.1.1
            "0x7f.0x1",            // 127.0.0.1 — short 2-part form
            "0x.0x.0x.0x1",        // 0.0.0.1 — empty hex body parses as 0
            "0177.0.0.01",         // 127.0.0.1 — octal, all-digits arm
            "1.0x7f000001",        // URL parse *failure*; reject anyway
        ] {
            assert!(
                parse_handle_input(&format!("alice@{bad}"), DEFAULT_HANDLE_DOMAIN).is_err(),
                "expected rejection of non-decimal IPv4 literal: {bad}"
            );
        }
        // A hex-looking label is only an IPv4 octet when the host *ends* in a
        // number. These are ordinary names and must still resolve.
        for good in ["0x7f.example.com", "0xdeadbeef.org", "1password.com"] {
            assert!(
                parse_handle_input(&format!("alice@{good}"), DEFAULT_HANDLE_DOMAIN).is_ok(),
                "expected acceptance of public domain: {good}"
            );
        }
    }

    #[test]
    fn nip05_url_shape() {
        let h = parse_handle_input("vincenzo", DEFAULT_HANDLE_DOMAIN).unwrap();
        assert_eq!(
            nip05_url(&h),
            "https://sonarprivacy.xyz/.well-known/nostr.json?name=vincenzo"
        );
    }

    #[test]
    fn nip05_response_verified() {
        let keys = Keys::generate();
        let hex = keys.public_key().to_hex();
        let body = format!(r#"{{"names":{{"vincenzo":"{hex}"}}}}"#);
        let pk = parse_nip05_response(body.as_bytes(), "vincenzo").unwrap();
        assert_eq!(pk, keys.public_key());
    }

    #[test]
    fn nip05_response_missing_name_fails() {
        let body = br#"{"names":{"other":"deadbeef"}}"#;
        assert!(matches!(
            parse_nip05_response(body, "vincenzo"),
            Err(Error::HandleNotFound(_))
        ));
    }

    #[test]
    fn nip05_response_invalid_pubkey_fails() {
        let body = br#"{"names":{"vincenzo":"not-hex"}}"#;
        assert!(parse_nip05_response(body, "vincenzo").is_err());
        // npub-encoded values are invalid per NIP-05 (hex required).
        let keys = Keys::generate();
        let npub = keys.public_key().to_bech32().unwrap();
        let body = format!(r#"{{"names":{{"vincenzo":"{npub}"}}}}"#);
        assert!(parse_nip05_response(body.as_bytes(), "vincenzo").is_err());
    }

    #[test]
    fn nip05_response_garbage_fails() {
        assert!(parse_nip05_response(b"not json", "a").is_err());
        assert!(parse_nip05_response(b"{}", "a").is_err());
    }

    #[test]
    fn claim_event_signed_and_shaped() {
        let keys = Keys::generate();
        let h = parse_handle_input("vincenzo", DEFAULT_HANDLE_DOMAIN).unwrap();
        let ev = build_claim_event(&keys, &h, Some("lno1test")).unwrap();
        assert_eq!(ev.kind, Kind::Custom(HANDLE_REGISTRATION_KIND));
        assert_eq!(ev.pubkey, keys.public_key());
        ev.verify().unwrap();
        let content: ClaimContent = serde_json::from_str(&ev.content).unwrap();
        assert_eq!(content.domain, DEFAULT_HANDLE_DOMAIN);
        assert_eq!(content.handle, "vincenzo");
        assert_eq!(content.offer.as_deref(), Some("lno1test"));
    }

    #[test]
    fn claim_event_omits_absent_offer() {
        let keys = Keys::generate();
        let h = parse_handle_input("vincenzo", DEFAULT_HANDLE_DOMAIN).unwrap();
        let ev = build_claim_event(&keys, &h, None).unwrap();
        assert!(!ev.content.contains("offer"));
    }

    #[test]
    fn handle_state_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("sonar.db");
        let path = handle_state_path_for_db(&db);
        assert!(load_claimed_address(&path).is_none());
        store_claimed_address(&path, Some("vincenzo@sonarprivacy.xyz")).unwrap();
        assert_eq!(
            load_claimed_address(&path).as_deref(),
            Some("vincenzo@sonarprivacy.xyz")
        );
        store_claimed_address(&path, None).unwrap();
        assert!(load_claimed_address(&path).is_none());
        wipe_handle_state_for_db(&db).unwrap();
        wipe_handle_state_for_db(&db).unwrap(); // idempotent
    }

    #[test]
    fn looks_like_handle_gate() {
        assert!(looks_like_handle("vincenzo"));
        assert!(looks_like_handle("alice@example.com"));
        assert!(!looks_like_handle("npub1abc")); // '@'-less but...
        assert!(!looks_like_handle("has space"));
        assert!(!looks_like_handle(""));
    }
}
