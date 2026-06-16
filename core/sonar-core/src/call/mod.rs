//! Peer-to-peer voice & video calls.
//!
//! Architecture (full plan: `docs/plans/2026-06-16-p2p-calls-iroh-callme.md`):
//! the real-time media path is **iroh** (QUIC + NAT hole-punching, peers
//! addressed by an Ed25519 `NodeId`) carrying RTP-over-QUIC (iroh-roq) audio,
//! lifted from n0's `callme` reference. iroh gives authenticated, encrypted,
//! server-less transport; the one thing it does not provide — out-of-band
//! signaling — Sonar supplies by riding a tiny [`signaling`] control protocol
//! (`☎CALL`) over its EXISTING end-to-end-encrypted channels (Marmot/MLS,
//! NIP-17), exactly like the `⚡PAY` feature.
//!
//! The [`signaling`] submodule is **pure** (no iroh/audio deps) and always
//! compiled, so both apps share one codec and `cargo test` covers it. The iroh
//! endpoint + cpal/opus media pipeline live behind the `calls` / `calls-audio`
//! Cargo features (added in a later phase) so the messaging core stays lean.

pub mod signaling;

/// The iroh QUIC transport for call media. Gated behind the `calls` feature so
/// the default build never compiles iroh.
#[cfg(feature = "calls")]
pub mod transport;
