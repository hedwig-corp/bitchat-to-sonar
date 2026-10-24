# Upstream drop-in: replay `bitchat-ios.json` in permissionlesstech/bitchat

Two test files that make the upstream iOS client guard its own wire format
with the byte-exact vectors in
[`../../vectors/bitchat-ios.json`](../../vectors/bitchat-ios.json). The
vectors were produced by upstream's own encoders at `30c58eee` (v1.8.0) via the
generator under `../../vectors/generators/bitchat-ios-swift/`; the replay
asserts that the codec still produces exactly those bytes, so any wire-format
drift (intentional or not) fails a unit test instead of surfacing as an
Android/iOS/third-party interop bug.

| File | Drop it at (upstream repo) | Framework | Kinds replayed |
|---|---|---|---|
| `BitchatVectorReplayTests.swift` | `localPackages/BitFoundation/Tests/BitFoundationTests/` | Swift Testing, `@testable import BitFoundation` | `padding`, `optimal_block_size`, `unpad`, `should_compress`, `compress`, `packet_encode`, `packet_decode_reject`, `packet_decode_accept`, `peer_id`, `capabilities` (99 cases) |
| `BitchatAppVectorReplayTests.swift` | `bitchatTests/Protocols/` | XCTest, `@testable import bitchat` | `announce_tlv`, `announce_decode`, `peer_state_tlv`, `private_message_tlv`, `noise_payload`, `file_packet_tlv`, `fragment_payload` (80 cases) |

The BitFoundation suite also contains `everyKindInTheFileIsReplayedSomewhere`,
which fails if the vector file ever grows a kind neither file knows about, and
prints how many app-target cases it skipped (they are not visible from the
package: `bitchat/Protocols` and `bitchat/Services/BLE` are app-target code).

## Where the test finds the vectors

Both files resolve the JSON in this order and **skip** (Swift Testing:
suite disabled with a message; XCTest: `XCTSkip`) rather than fail when nothing
is found:

1. `SONAR_VECTOR_FILE=/abs/path/bitchat-ios.json` in the environment.
2. A `bitchat-ios.json` next to the test source file (resolved via `#filePath`,
   so it works from `swift test` and from Xcode without a resources
   declaration in `Package.swift`).
3. (app file only) a `bitchat-ios.json` resource in the test bundle.

For upstream, the simplest layout is one copy of the JSON at
`localPackages/BitFoundation/Tests/BitFoundationTests/bitchat-ios.json` and a
second at `bitchatTests/Protocols/bitchat-ios.json` (or a single copy plus
`SONAR_VECTOR_FILE` set in the scheme / CI).

## How to run

```sh
# BitFoundation package suite (what we ran; 11 tests, 99 cases, 0 failures on Xcode 27 / Swift 6.4)
SONAR_VECTOR_FILE=$PWD/path/to/bitchat-ios.json \
  swift test --package-path localPackages/BitFoundation --filter BitchatVectorReplayTests

# App suite, inside the Xcode project (needs the app built)
SONAR_VECTOR_FILE=... xcodebuild test -scheme bitchat \
  -only-testing:bitchatTests/BitchatAppVectorReplayTests
```

Each test prints one `REPLAY kind=<kind> cases=<n> file=<path>` line so the
count of replayed cases is visible in the log.

### How the app file was verified without building the app

`BitchatAppVectorReplayTests.swift` carries a `#if canImport(bitchat)` guard
around its `@testable import bitchat`. That guard is true in the app target;
it exists so the same file also compiles inside the BitFoundation package test
target when the app codec sources are copied next to it, which is how it was
compile-checked and run here: the `App*.swift` copies/stubs under
`../../vectors/generators/bitchat-ios-swift/` (`Packets.swift`,
`BitchatFilePacket.swift` minus `PrivateMediaMessageIdentity`,
`NoisePayload.swift`, `BLEOutboundFragmentPlanner.swift`, plus a stub
`NoisePayloadType` / `BLEOutboundFragmentTransferRequest` / `TransportConfig`)
were dropped into `Tests/BitFoundationTests/` of a detached `origin/main`
worktree and `swift test --filter 'BitchatVectorReplayTests|BitchatAppVectorReplayTests'`
ran both: 7 XCTest methods, 80 cases, 0 failures. A mutation check (five
expected values corrupted in a copy of the JSON) produced five failures, so the
assertions are live.

## The `repeat:` hex encoding

Every byte field in the vectors is a lowercase hex string. To keep the file
small, a run of one byte repeated **1024 times or more** is written as

```
repeat:xx*N        e.g. "repeat:00*65535"
```

where `xx` is the byte in hex and `N` the count in decimal. Both replay files
expand it in their `hex` accessor (`Data(repeating: byte, count: N)`); any
other consumer must do the same. The empty string is the empty byte array;
JSON `null` means "encoder returned nil" / "field absent".

## Compression vectors

`compress` cases are compared **byte-for-byte**: they are the output of Apple's
`COMPRESSION_ZLIB` (raw DEFLATE, no zlib header) through
`CompressionUtil.compress`, which has been stable across releases. The test
also asserts the inflate round-trip (`decompress(expected) == payload`), which
is the real interop contract; if a future libcompression changes its DEFLATE
output, relax the byte comparison to that round-trip (the comment on the test
says where) and regenerate the vectors.

## Suggested PR pitch (upstream)

> **Add byte-exact wire-format vectors shared with bitchat-android.** This adds a
> JSON vector file produced by BitFoundation's own encoders at v1.8.0 plus two
> replay tests (one for the BitFoundation package, one for the app target) that
> assert `BinaryProtocol`, `MessagePadding`, `CompressionUtil`, `PeerID`,
> `PeerCapabilities`, `AnnouncementPacket`, `AuthenticatedPeerStatePacket`,
> `PrivateMessagePacket`, `NoisePayload`, `BitchatFilePacket` and
> `BLEOutboundFragmentPlanner` still emit and accept exactly these bytes. The
> same file is replayed by the Android client and by third-party
> implementations (Sonar's Rust core), so the three stay interoperable by
> construction: a change to the wire format now fails a unit test on every
> platform and has to ship with regenerated vectors instead of being discovered
> in the field. The vectors also pin receive-side behaviour that has no other
> test today (trailing bytes accepted after a frame, HAS_ROUTE ignored on v1,
> `PrivateMessagePacket` rejecting unknown TLVs, `BitchatFilePacket` rejecting
> its own encoding of empty content, non-minimal capability encodings rejected
> by `AuthenticatedPeerStatePacket`), which is exactly the behaviour other
> clients need to match.
