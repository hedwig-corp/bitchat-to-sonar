# Vendored fork of iroh-roq (RTP over iroh QUIC)

Source: https://github.com/n0-computer/iroh-roq (MIT/Apache-2.0).

Why vendored: crates.io `iroh-roq 0.1.0` pins `iroh ^0.33`, whose dependency
tree (rcgen 0.13.2, netwatch 0.3) does not compile on our current toolchain.
This fork is ported to **iroh 1.0** (which builds cleanly):

- `iroh = "0.35"` → `iroh = "1"`
- `iroh-quinn-proto = "0.13"` → `noq-proto = "1"` (iroh 1.0's renamed QUIC proto)
- `noq_proto::coding::Codec` (single trait) → `Encodable` / `Decodable`

Used by `sonar-core` (the `calls` feature) as a `path` dependency for the P2P
call media transport. Re-merge upstream once iroh-roq releases on iroh 1.0.
