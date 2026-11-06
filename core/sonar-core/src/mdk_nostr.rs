//! Bridge between Sonar's `nostr` (crates.io 0.44, used with `nostr-sdk` for
//! the relay pool) and the `rust-nostr` fork MDK v0.11+ builds on (0.45-dev,
//! `erskingardner/rust-nostr`, aliased here as `nostr_mdk`).
//!
//! MDK's protocol crates (`cgka-*`, `storage-sqlite`) are nostr-free; only
//! `transport-nostr-peeler` and the account-identity proof take nostr types.
//! Everything crossing that seam goes through this module, so the rest of
//! sonar-core keeps one `nostr` and the two versions never mix by accident.
//!
//! Conversions go through each type's wire form (NIP-01 JSON for events, the
//! 32-byte secret for keys), so a converted event keeps its id and signature
//! byte for byte. A failure is a bug in one of the two crates, never something
//! to paper over: callers surface it as `Error::Mdk`.

use transport_nostr_peeler::NostrTransportEvent;

use crate::{Error, Result};

/// The fork's `Keys` for our account key. The secret never leaves memory.
pub(crate) fn keys_to_mdk(keys: &nostr::Keys) -> Result<nostr_mdk::prelude::Keys> {
    let secret = nostr_mdk::prelude::SecretKey::from_slice(&keys.secret_key().secret_bytes())
        .map_err(|e| Error::Mdk(format!("secret key bridge: {e}")))?;
    Ok(nostr_mdk::prelude::Keys::new(secret))
}

/// MDK's transport DTO for a signed Sonar event. Field for field, so the
/// id/signature MDK checks are the ones the relay saw.
pub(crate) fn transport_event(event: &nostr::Event) -> NostrTransportEvent {
    NostrTransportEvent {
        id: event.id.to_hex(),
        pubkey: event.pubkey.to_hex(),
        created_at: event.created_at.as_secs(),
        kind: u64::from(event.kind.as_u16()),
        tags: event.tags.iter().map(|tag| tag.as_slice().to_vec()).collect(),
        content: event.content.clone(),
        sig: Some(event.sig.to_string()),
    }
}

/// A signed Sonar event from MDK's transport DTO, verified.
pub(crate) fn event_from_transport(dto: &NostrTransportEvent) -> Result<nostr::Event> {
    let json = serde_json::to_string(dto)
        .map_err(|e| Error::Mdk(format!("transport event JSON: {e}")))?;
    let event: nostr::Event = serde_json::from_str(&json)
        .map_err(|e| Error::Mdk(format!("transport event parse: {e}")))?;
    event
        .verify()
        .map_err(|e| Error::Mdk(format!("transport event signature: {e}")))?;
    Ok(event)
}

/// The fork's unsigned event as a Sonar one (the account-identity proof).
pub(crate) fn unsigned_from_mdk(
    event: &nostr_mdk::prelude::UnsignedEvent,
) -> Result<nostr::UnsignedEvent> {
    let json = serde_json::to_string(event)
        .map_err(|e| Error::Mdk(format!("unsigned event JSON: {e}")))?;
    serde_json::from_str(&json).map_err(|e| Error::Mdk(format!("unsigned event parse: {e}")))
}

/// A signed Sonar event as the fork's (the account-identity proof).
pub(crate) fn event_to_mdk(event: &nostr::Event) -> Result<nostr_mdk::prelude::Event> {
    let json =
        serde_json::to_string(event).map_err(|e| Error::Mdk(format!("event JSON: {e}")))?;
    serde_json::from_str(&json).map_err(|e| Error::Mdk(format!("event parse (to MDK): {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::prelude::*;

    #[test]
    fn an_event_crosses_the_seam_with_its_id_and_signature() {
        let keys = Keys::generate();
        let event = EventBuilder::new(Kind::MlsGroupMessage, "ciphertext")
            .tag(Tag::custom(TagKind::h(), ["ab".repeat(32)]))
            .sign_with_keys(&keys)
            .unwrap();
        let back = event_from_transport(&transport_event(&event)).unwrap();
        assert_eq!(back.id, event.id);
        assert_eq!(back.sig, event.sig);
        let fork = event_to_mdk(&event).unwrap();
        assert_eq!(fork.id.to_hex(), event.id.to_hex());
        assert!(fork.verify().is_ok());
    }

    #[test]
    fn keys_keep_their_public_key() {
        let keys = Keys::generate();
        let fork = keys_to_mdk(&keys).unwrap();
        assert_eq!(fork.public_key().to_hex(), keys.public_key().to_hex());
    }
}
