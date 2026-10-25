# Proposed upstream changes

Material Sonar prepares for the reference clients, kept here until it lands
upstream so the compatibility matrix in `../SPEC.md` has concrete artifacts to
point at.

**Status (2026-10-24):** both opened from `vincenzopalazzo`'s forks.

| Upstream PR | Contents | Verified before opening |
|---|---|---|
| [permissionlesstech/bitchat#1805](https://github.com/permissionlesstech/bitchat/pull/1805) | the wire-payload patch + `bitchat-ios/` replay tests + `vectors/bitchat-ios.json` (two copies) | `swift test` 206/206 in BitFoundation, `xcodebuild test` 7 tests / 80 cases in the app target plus the gossip-store and relay-spool budget suites, SwiftLint `--strict` clean (upstream's lint job is blocking). Review round 1 (Codex): stores now charge `retainedPayloadBytes` |
| [permissionlesstech/bitchat-android#994](https://github.com/permissionlesstech/bitchat-android/pull/994) | `bitchat-android/BitchatVectorReplayTest.kt` + `vectors/bitchat-android.json` as `app/src/test/resources/contracts/bitchat-wire-protocol-v1-v2.json` | 91/91 on upstream `d1da9716` (app and wear); mutation check fails per corrupted field |

When either lands, drop the corresponding copy here and have
`scripts/check-bitchat-upstream-drift.sh` cover the upstream test file instead.

## Vector replay tests (`bitchat-ios/`, `bitchat-android/`)

Drop-in tests for each upstream repository that replay `../vectors/*.json`
against that repository's own codec, so upstream guards the exact bytes
Sonar and the other platform depend on. Each directory's README says where
the file goes, how to run it, and carries the one-paragraph PR pitch. Both
were run green against the pinned revisions before being committed here.

## bitchat-ios-verify-over-wire-payload.patch

bitchat iOS (1.8.0) rebuilds a packet's signature preimage with
`BinaryProtocol.encode` over the *decoded* payload, which re-runs
`CompressionUtil` with Apple's DEFLATE encoder. Any signed frame whose
compressible payload (≥100 bytes, <90% distinct byte values) was produced by
another encoder — bitchat-android's `java.util.zip`, Sonar's miniz — or was
sent uncompressed fails verification there, although the signature is valid
over the bytes actually sent. bitchat-android fixed its side in #863 by
keeping the received payload bytes and reusing them on re-encode; this patch
is the same change for the Swift codec (`WirePayload` on `BitchatPacket`,
honoured by `BinaryProtocol.encode` and `toBinaryDataForSigning`). The patch
is a `git diff` against upstream `30c58eee` (v1.8.0) at upstream paths
(`localPackages/BitFoundation/Sources/BitFoundation/BinaryProtocol.swift`,
`.../BitchatPacket.swift`, plus `bitchat/Sync/GossipSyncManager.swift` and
`bitchat/Services/BLE/BLEDirectedRelaySpool.swift`, whose byte budgets now
charge `BitchatPacket.retainedPayloadBytes` — the larger of the decoded
payload and the retained wire bytes — because a valid DEFLATE stream can be
far larger than what it inflates to and a store that charged `payload.count`
would let a few-byte message pin a frame-sized stream) and adds
`localPackages/BitFoundation/Tests/BitFoundationTests/BinaryProtocolWirePayloadTests.swift`
(Swift Testing, 7 tests: foreign stored-block DEFLATE re-encodes byte-identical
and its preimage is the padded ttl-0 original frame, v2 4-byte original size,
a Curve25519 signature over an uncompressed-but-compressible 120-byte frame
verifies after decode and relay while a fresh packet yields a different
preimage, a changed payload is compressed afresh, `wirePayload` is excluded
from `Codable`, a stored-block stream is charged at its wire size) and one
budget test each to the gossip-store and relay-spool suites. Every public
signature is unchanged. Verified on a clean
detached worktree of upstream with Xcode 27 / Swift 6.4: `git apply --check`
succeeds, the whole BitFoundation suite passes (194 tests in 15 suites, up
from 188), and the vector replay in `bitchat-ios/` still passes against
`../vectors/bitchat-ios.json` (11 Swift Testing + 7 XCTest tests, 179 cases,
0 failures), as expected since the change only affects re-encoding of
*decoded* packets. Sonar's own copy of the fix is tested by
`ios/bitchatTests/Protocol/BinaryProtocolWirePayloadTests.swift`.
