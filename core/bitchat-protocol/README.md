# bitchat-protocol

The bitchat BLE mesh wire protocol as one crate: packet framing (v1/v2,
compression, routes, padding), the TLV payloads, Ed25519 packet signatures,
peer-id derivation, and the Noise XX session with bitchat's explicit-nonce
transport framing. Byte-compatible with
[permissionlesstech/bitchat](https://github.com/permissionlesstech/bitchat) and
[permissionlesstech/bitchat-android](https://github.com/permissionlesstech/bitchat-android),
pinned by vectors generated from those codecs.

* `SPEC.md` — the wire format, the compatibility matrix, and the rules the
  tests enforce.
* `vectors/` — upstream-generated vectors and their generator sources.
* `tests/vectors.rs` — replays them; `tests/mesh_legacy.rs` — the protocol
  tests that predate the crate.

Sonar consumes it through `sonar-core::mesh` / `sonar-core::noise` (thin
re-exports) and the mesh engine; the iOS app still carries a Swift copy of the
codec (`ios/bitchat/Protocols`), kept in step by hand until it moves onto the
crate through UniFFI.

```sh
cargo test -p bitchat-protocol
```
