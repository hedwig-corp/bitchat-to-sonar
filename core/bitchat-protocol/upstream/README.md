# Proposed upstream changes

Material Sonar prepares for the reference clients, kept here until it lands
upstream so the compatibility matrix in `../SPEC.md` has concrete artifacts to
point at.

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
honoured by `BinaryProtocol.encode` and `toBinaryDataForSigning`). It was
written against Sonar's copy of `BinaryProtocol.swift` / `BitchatPacket.swift`,
which track upstream's `localPackages/BitFoundation` closely; the hunks apply
with path adjustment. Tests for it live in
`ios/bitchatTests/Protocol/BinaryProtocolWirePayloadTests.swift`.
