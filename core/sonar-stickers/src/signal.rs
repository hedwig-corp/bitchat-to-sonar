//! Optional Signal import support.
//!
//! The first shipped crate keeps Signal import intentionally narrow: public
//! provenance and URL parsing can live behind this feature later without
//! leaking Signal pack keys into public Nostr events by default.

/// Parsed `signal.art/addstickers` link material.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignalPackLink {
    pub pack_id: String,
    pub pack_key: String,
}
