# Upstream drop-in: `BitchatVectorReplayTest`

A JUnit test for `permissionlesstech/bitchat-android` that replays the shared
wire-format vectors in `core/bitchat-protocol/vectors/bitchat-android.json`
against the upstream Kotlin codec, so upstream guards its own bytes with the
same file other clients check against. Verified green on upstream `dfc67dad`
(release 2.0.3): 93/93 cases byte-exact, JBR 17.0.12, Gradle 9.6.1, AGP 9.3.1.

## Pitch for the upstream PR

bitchat's binary protocol is implemented three times (Android/Kotlin, iOS/Swift,
and Sonar's Rust core) and today each client only round-trips its own encoder,
so a change that still round-trips locally can silently break the other two
(`WirePayload` exists because DEFLATE output already differs between
`java.util.zip` and Apple's `compression_encode_buffer`). This test pins the
exact bytes the Android codec emits and accepts for every wire structure
(`BinaryProtocol` v1/v2 incl. route, compression and padding, the announce TLV
with capabilities and unknown-TLV preservation, `PrivateMessagePacket`,
`NoisePayload` incl. the 0x09 alias, `BitchatFilePacket` incl. unknown-TLV skip,
`FragmentPayload`, and the SHA-256 peer-id derivation) in a JSON file that is
language-neutral and shared with bitchat iOS and Sonar. A failing case means
the wire format moved and names the structure and field; a format change
becomes a deliberate vector update that every client picks up together.

## Where to drop it upstream

```
app/src/test/java/com/bitchat/android/protocol/BitchatVectorReplayTest.kt   <- this file
app/src/test/resources/contracts/bitchat-wire-protocol-v1-v2.json          <- copy of the vector file
```

The `wear` module re-runs the app's `protocol/**` tests from a synced mirror of
`app/src/test/java` but, as of `d1da9716`, mirrors no test resources, so the
test fails there with "vector file not found" unless `wear/build.gradle.kts`
also syncs `../app/src/test/resources` into a directory on the wear test
source set (the upstream PR adds `syncSharedAppTestResources` for that).

It uses only what the `app` module already has on the JVM unit-test classpath:
JUnit 4, Gson (`libs.gson`, an `implementation` dependency), and upstream's own
`android.util.Log` stub in `app/src/test/kotlin/android/util/Log.kt`. No
Robolectric, no `returnDefaultValues`.

## Where the JSON is found at runtime

1. `SONAR_VECTOR_FILE` environment variable, if set: an absolute path to the
   vector file. Use this to replay a file outside the repo (e.g. this repo's
   `core/bitchat-protocol/vectors/bitchat-android.json`) without copying it.
2. Otherwise the classpath resource `/contracts/bitchat-wire-protocol-v1-v2.json`,
   i.e. `app/src/test/resources/contracts/bitchat-wire-protocol-v1-v2.json`
   (upstream's `docs/testing-conventions.md` puts interoperability fixtures
   under `contracts/` with protocol and version in the name). This is the form
   the upstream PR ships so CI needs no environment.

If neither exists the test fails with a message naming both locations.

## How to run

```sh
# in a bitchat-android checkout, JDK 17, Android SDK present (local.properties sdk.dir=...)
ANDROID_HOME=~/Library/Android/sdk \
SONAR_VECTOR_FILE=/path/to/bitchat-to-sonar/core/bitchat-protocol/vectors/bitchat-android.json \
./gradlew :app:testDebugUnitTest --tests 'com.bitchat.android.protocol.BitchatVectorReplayTest'
```

Gradle does not treat `SONAR_VECTOR_FILE` as a task input, so a second run
against a different file is reported UP-TO-DATE with the previous result:
pass `--rerun` (or `--rerun-tasks`) whenever you change the variable.

Drop `SONAR_VECTOR_FILE` once the JSON is under `app/src/test/resources/`. The
test prints `replayed N cases` with a per-kind count to the test stdout
(`app/build/test-results/testDebugUnitTest/TEST-…BitchatVectorReplayTest.xml`).
All mismatches are collected and reported together in one assertion message as
`kind:name / field: expected … but got …`; an unknown `kind` is a failure, so
every case in the file is exercised.

### DEFLATE byte-exactness

`compress` cases are byte-exact by default: `java.util.zip.Deflater` output is
deterministic for the zlib the JDK bundles. If a JDK upgrade changes the stream,
run with `SONAR_VECTOR_DEFLATE_LENIENT=1`: the test then requires only that the
recorded stream and the locally produced one both inflate to the payload. The
inflate direction (`CompressionUtil.decompress(recorded) == payload`) is always
asserted, because that is what every peer must accept regardless of encoder.

## Vector file format

```json
{"source": "permissionlesstech/bitchat-android@dfc67dad",
 "generator": "...", 
 "cases": [{"name": "...", "kind": "...", "input": {...}, "expected": {...}}]}
```

- All byte fields are lowercase hex strings. A hex string that is one byte
  repeated 1024 or more times is written compactly as `"repeat:xx*N"` (e.g.
  `"repeat:00*65535"`); the test's `unhex()` expands it.
- `null` means the upstream call returned null (e.g. `encode` refusing an
  oversized v1 payload, `compress` declining to compress).
- Expected keys that are absent are "not recorded"; the test asserts a field
  only when its key is present (null-valued keys are asserted as null).
- Kinds and what is asserted: `should_compress`, `compress`, `padding`,
  `optimal_block_size`, `unpad`, `packet_encode` (padded / unpadded /
  `signing_preimage` = `toBinaryDataForSigning()`, which upstream encodes WITH
  padding and TTL=0; decoded payload, flags byte, `wirePayload` bytes and
  compressed flag, route, recipient, signature, ttl, timestamp),
  `packet_reencode_preserves_wire` (decode then re-encode must reproduce the
  originator's bytes; also the fresh re-compression — one case carries the
  codec's own stream, one a zlib level-1 stream it never emits by default, so
  preservation is distinguishable from recompression), `packet_decode_reject`,
  `announce_tlv` (encode shape when `input.nickname` is present; decode /
  re-encode shape with `unknown_tlvs` when `input.encoded` is present),
  `capabilities` (encode when `input.raw`, decode when `input.encoded`),
  `private_message_tlv` (incl. unknown TLV type 0x04 → `decodes: false`),
  `noise_payload` (incl. 0x09 → `FILE_TRANSFER`/0x20), `file_packet_tlv` (incl.
  unknown TLV 0x05 skipped → `decodes: true`), `fragment_payload`, `peer_id`.

The generator that produced the file lives in
`core/bitchat-protocol/vectors/generators/bitchat-android-kotlin/`.
