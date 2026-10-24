# bitchat BLE mesh protocol — as implemented by `bitchat-protocol`

This is the wire specification the crate implements and the tests pin. It is
written from the two reference clients, not from their documentation:

| Reference | Revision | Codec files |
|---|---|---|
| permissionlesstech/bitchat (iOS/macOS) | `30c58eee` (1.8.0, 2026‑10‑23) | `localPackages/BitFoundation/Sources/BitFoundation/{BinaryProtocol,BitchatPacket,MessagePadding,CompressionUtil,PeerCapabilities,PeerID,MessageType,PacketPayloadLimits}.swift`, `bitchat/Protocols/{Packets,BitchatFilePacket,BitchatProtocol}.swift`, `bitchat/Noise/NoiseProtocol.swift` |
| permissionlesstech/bitchat-android | `dfc67dad` (2.0.3, 2026‑10‑22) | `app/src/main/java/com/bitchat/android/{protocol/BinaryProtocol,protocol/MessagePadding,protocol/CompressionUtil,model/IdentityAnnouncement,model/PeerCapabilities,model/NoiseEncrypted,model/BitchatFilePacket,model/FragmentPayload,noise/NoiseSession,noise/NoisePeerIdentity}.kt` |

Where the two disagree, §12 says which one this crate follows and why.
Byte-exact vectors produced by running those codecs live in `vectors/` and are
replayed by `tests/vectors.rs`; §13 says how to regenerate them.

Conventions: all multi-byte integers are big-endian unless stated; "MUST" and
"MUST NOT" describe what this crate does and what a peer has to do to
interoperate with it.

## 1. Packet frame

```
offset  size  field
0       1     version         1 or 2
1       1     type            see §7
2       1     ttl             hop budget; decremented by relays
3       8     timestamp       sender wall clock, Unix milliseconds
11      1     flags           see below
12      2|4   payloadLength   u16 (v1) / u32 (v2): payload bytes + original-size field if compressed
        8     senderID
        8     recipientID     if flags.HAS_RECIPIENT
        1+8n  route           v2 only, if flags.HAS_ROUTE: count n, then n × 8-byte hop ids
        2|4   originalSize    if flags.IS_COMPRESSED: decompressed payload length
        var   payload         raw bytes, or the DEFLATE stream when compressed
        64    signature       if flags.HAS_SIGNATURE: Ed25519 over §5
```

Flags: `0x01 HAS_RECIPIENT`, `0x02 HAS_SIGNATURE`, `0x04 IS_COMPRESSED`,
`0x08 HAS_ROUTE` (meaningful only for `version >= 2`; a v1 frame with the bit
set is decoded as if it were clear and consumes no route bytes), `0x10 IS_RSR`
("relayed via source route", mutable, excluded from signatures). Other bits
are reserved and ignored on decode.

Recipient `ff ff ff ff ff ff ff ff` is the broadcast sentinel; an absent
recipient is an undirected broadcast. Sender and recipient ids shorter than 8
bytes are zero-padded, longer ones truncated, on encode.

Decoders MUST accept trailing bytes after a complete frame (padding, §4) and
MUST try the frame as-is before stripping padding. Decoders MUST enforce the
per-type payload ceilings of §11 and the compression ratio bound of §3 before
allocating for the payload.

v1 cannot carry a payload whose *decompressed* length exceeds 65 535 bytes:
the reference encoders refuse rather than silently compress it, so this crate
does too. v2 is used for routes and for file transfers above that size.

## 2. Encoding is deterministic per implementation, not across implementations

Given the same fields, one implementation always produces the same bytes. Two
implementations do not: DEFLATE output is encoder-specific (§3). Every rule
about relays and signatures below follows from that single fact.

## 3. Compression

A payload is compressed when **both** hold:

1. `payload.len() >= 100`;
2. `distinct byte values / min(payload.len(), 256) < 0.9`.

The stream is **raw DEFLATE** (no zlib header, no checksum): Apple
`COMPRESSION_ZLIB`, `java.util.zip.Deflater(nowrap = true)`, `flate2` raw
`DeflateEncoder` here. If the stream is not strictly shorter than the payload
the frame is sent uncompressed. Decoders MUST inflate raw DEFLATE and MAY also
accept a zlib-wrapped stream (bitchat-android and this crate do; iOS does
not — never emit zlib).

Decode checks, in order: `payloadLength >= sizeof(originalSize)`;
`1 <= originalSize <= ceiling(type)`; stream length `> 0`;
`originalSize <= streamLength × 1032`; inflated length `== originalSize`.

## 4. Padding

PKCS#7-style: pad to the smallest of {256, 512, 1024, 2048} that fits
`frameLength + 16`, writing `n` bytes of value `n`; refuse to pad when
`n > 255` or when no bucket fits (the frame travels at natural length). `unpad`
strips a tail of `n` bytes of value `n` when `1 <= n <= length`, else returns
the input. Padding is decode-transparent on every implementation.

What gets padded is policy, not protocol. The reference clients today pad only
`0x10` and `0x11` (Noise) frames (`BLEOutboundPacketPolicy.padsBLEFrame`).
This crate exposes that as `PaddingPolicy::NoiseOnly` and Sonar's engine uses
it; `PaddingPolicy::Always` is the historical Sonar behaviour and remains the
form the signature preimage is computed over (§5).

## 5. Signatures

Ed25519 (RFC 8032, cofactorless verification) with the sender's **announce
signing key** (§8.1), over the *canonical preimage*: the frame re-encoded with
`ttl = 0`, no signature (flag clear, no trailing 64 bytes), `IS_RSR` clear,
and **padded** per §4 `Always`. Everything else — including the compressed
payload bytes and the original-size field — is covered.

**Verifiers MUST build the preimage from the payload bytes exactly as
received** (compressed stream or raw), never by re-running their own
compressor on the decoded payload. A decoded `Packet` therefore keeps
`wire_payload = { bytes, compressed, sha256(payload) }`, and `encode()` reuses
those bytes while `payload` is unchanged. This also makes relay re-encoding
(TTL decrement) byte-preserving. bitchat-android implements the same rule
(#863); bitchat iOS 1.8.0 does not (see §12 ★).

**Signers MUST sign the bytes they put on the wire.** Signing a freshly built
packet and then encoding it is consistent because the compression decision is
deterministic within one implementation.

## 6. Peer identity

`peerID = SHA-256(noiseStaticPublicKey)[0..8]`, written as 16 lowercase hex
characters. This is a binding, not a convention. Receivers MUST reject:

* an announce (§8.1) whose `senderID` ≠ `peerID(announce.noisePublicKey)`;
* a Noise handshake whose authenticated remote static key does not derive to
  the sender id the handshake was addressed from.

The announce is self-signed (the signing key is inside the signed payload), so
it proves consistency, not identity: trust-on-first-use pins the signing key
per sender id, and a later announce for a pinned id with a different signing
key is an impersonation attempt and MUST be dropped. Only state carried inside
a completed Noise session (§8.5) proves possession of the Noise key.

## 7. Packet types

| byte | name | payload | padded | notes |
|---|---|---|---|---|
| `0x01` | announce | §8.1 TLV | no | signed; every 4–30 s and on subscribe |
| `0x02` | message | raw UTF‑8 | no | public chat; signed by the reference clients |
| `0x03` | leave | — | no | |
| `0x04` | courierEnvelope | iOS 1.7 store‑and‑forward | no | not implemented here |
| `0x10` | noiseHandshake | Noise XX message | yes | directed |
| `0x11` | noiseEncrypted | §9 transport frame | yes | directed; plaintext = `[NoisePayloadType][body]` |
| `0x20` | fragment | §8.4 | no | carries any other type |
| `0x21` | requestSync | GCS filter | no | neighbour only, never relayed; not implemented here |
| `0x22` | fileTransfer | §8.3 TLV | no | directed & signed (legacy private media) or broadcast |
| `0x23`–`0x29`, `0x2C` | boardPost, prekeyBundle, groupMessage, ping, pong, nostrCarrier, voiceFrame, announceV2 | iOS 1.7+ | no | decoded as opaque; ignored |
| `0x53` | Sonar announce | §8.6 TLV | no | signed; unknown to stock clients, relayed by TTL |

Unknown types MUST be decoded (frame level), relayed by TTL where relaying
applies, and otherwise ignored.

## 8. Payloads

TLVs in this protocol are `type(1) length(1) value` unless a row says
otherwise. "Tolerant" means unknown types are skipped; "strict" means they
cause rejection.

### 8.1 Announce (`0x01`) — tolerant

| TLV | value | required |
|---|---|---|
| `0x01` | nickname, UTF‑8, ≤255 B | yes |
| `0x02` | Noise static public key (32 B) | yes |
| `0x03` | Ed25519 signing public key (32 B) | yes |
| `0x04` | direct neighbours: 8 B ids, ≤10, length multiple of 8 (else dropped) | no |
| `0x05` | capabilities: minimal little‑endian `u64` bitfield, ≥1 byte | no (absent = legacy client) |
| `0x06` | bridge geohash, UTF‑8, ≤12 B (else dropped) | no |

Encode order is the table order; unknown TLVs seen on decode are preserved and
re‑emitted after the known ones (bitchat-android behaviour). Capability bits:
`1<<0 prekeys, 1<<1 wifiBulk, 1<<2 gateway, 1<<3 groups, 1<<4 board,
1<<5 vouch, 1<<6 meshDiagnostics, 1<<7 bridge, 1<<8 privateMedia,
1<<9 privateMediaReceipts, 1<<10 nonDestructiveNoiseReplacement (reserved)`.
A client MUST advertise only what it implements. Sonar advertises
`privateMedia | privateMediaReceipts`.

### 8.2 Private message (Noise payload `0x01`)

Reference TLV, one‑byte lengths: `0x00 messageID`, `0x01 content` (both UTF‑8,
≤255 B, both required). **Both reference decoders reject any other TLV type**
and the reference encoders refuse fields over 255 bytes. Consequences:

* a stock peer can receive at most 255 bytes of content per message;
* Sonar's extensions — `0x02 messageID` / `0x03 content` with a **two‑byte**
  length for fields over 255 B, and `0x04`/`0x05 replyTo` (parent message id)
  — MUST only be sent to a peer that has proven it is Sonar (a verified §8.6
  announce). To any other peer the reply parent is omitted and long content
  is split on UTF‑8 boundaries into ≤255‑byte legacy messages with ids
  `id`, `id#2`, `id#3`, … (the first keeps the caller's id so its delivery
  receipt still maps to the original).

This crate's decoder is tolerant (skips unknown one‑byte‑length TLVs; a
trailing lone byte is ignored like the reference).

Receipts: Noise payload `0x02` (read) and `0x03` (delivered) carry the raw
UTF‑8 message id, no TLV.

### 8.3 File packet (`0x22` payload, or Noise payload `0x20`) — tolerant

Two‑byte big‑endian lengths except where noted:

| TLV | value |
|---|---|
| `0x01` | fileName, UTF‑8 |
| `0x02` | fileSize, length 4 (u32) — decoders also accept the legacy length 8 |
| `0x03` | mimeType, UTF‑8 |
| `0x04` | content, **four‑byte** length — decoders also accept a legacy two‑byte length; repeated content TLVs concatenate |
| `0x05` | Sonar extension: chat message id for delivery receipts (UTF‑8, non‑empty) |

Encode order: fileName?, fileSize, mimeType?, [messageId?], content.
`fileSize` is not checked against the content length. Content must be
non‑empty and ≤1 MiB (`FileTransferLimits.maxPayloadBytes`). A malformed
`0x05` costs the receipt, never the file. `0x05` MUST only be sent to a peer
that proved it is Sonar: bitchat-android builds before its #826 drop the whole
file on an unknown tag.

### 8.4 Fragment (`0x20`)

```
fragmentID(8) | index(u16) | total(u16) | originalType(1) | chunk
```

Fragments carry slices of the **encoded original frame** (padded or not, as it
would have gone on the air) and inherit its sender, recipient, ttl and
timestamp; they are themselves unsigned. The receiver reassembles by
`(sender, fragmentID)` and decodes the whole. Bounds in this crate:
`total <= 8192`, 256 concurrent streams, 30 s idle / 5 min absolute lifetime,
per‑stream and global byte budgets, 2 s eviction protection for a live
stream. Reference receiver ceilings: iOS 10 000 fragments; bitchat-android
**256 fragments** per reassembly for the legacy raw‑file path (≈ 110–120 KiB
at BLE chunk sizes) — a sender MUST NOT assume a stock Android peer can
reassemble more than that over `0x22`.

### 8.5 Authenticated peer state (Noise payload `0x21`) — strict

```
version(1) = 0x01
TLV 0x01   capabilities, minimal little‑endian, 1..8 bytes (non‑minimal → reject)
TLV 0x02   Ed25519 signing public key, exactly 32 bytes
```

Duplicates, bad lengths, missing fields and unknown versions → reject; unknown
TLV types → skip. Sent once after every completed (or rekeyed) handshake and
echoed at most once when the peer's state arrives first. Because it is
encrypted by the session, it proves possession of the Noise static key the
announce only claimed; a receiver pins the proven capabilities to the
authenticated fingerprint. The public announce's `privateMedia` bit is a
discovery hint only and MUST NOT select the encrypted media path by itself.

### 8.6 Sonar announce (`0x53`) — tolerant

| TLV | value | required |
|---|---|---|
| `0x01` | version, 1 byte = `1` | yes |
| `0x02` | x‑only Nostr public key, 32 B | yes |
| `0x03` | BIP‑353 address, UTF‑8, ≤255 B | no |
| `0x04` | capabilities, 1 byte: `0x01 marmotDM`, `0x02 payments`, `0x04 calls` | yes |
| `0x05` | BOLT12 offer, **two‑byte** length (Compose only) | no |

Signed with the §8.1 signing key and verified against the key learned from
that peer's `0x01`; a `0x53` that arrives first is held until the announce
does. The signed v1 frame MUST fit one 512‑byte BLE attribute (payload ≤426 B),
so the offer is dropped from the mesh copy when it would not.

## 9. Noise

Handshake: `Noise_XX_25519_ChaChaPoly_SHA256`, three messages with empty
payloads carried in `0x10` frames. Both sides MUST check §6 against the
authenticated static key before using the session.

Transport (`0x11` payloads) is **not** plain Noise:

```
[ nonce: u32 BE ][ ChaCha20‑Poly1305( key, nonce12 = 00000000 || LE64(nonce), aad = ∅ ) || tag(16) ]
```

The sender's nonce counts from 0 per direction and MUST NOT exceed
`2^32 − 2` (rekey instead). The receiver decrypts with the **extracted**
nonce and keeps a 1024‑entry sliding window: a nonce greater than the highest
seen is always accepted (gaps allowed — BLE loses frames), one inside the
window is accepted once, one older than the window is rejected. Window and
counter state move only after a successful decryption. The split keys are the
standard Noise ones (`k1` initiator→responder). There is no 65 535‑byte
message bound: private files up to 1 MiB are one transport message.

## 10. Private media negotiation

| peer state | Sonar sends |
|---|---|
| proved `privateMedia` in `0x21` | `0x11` frame whose plaintext is `[0x20][file TLV]`, fragmented as needed |
| no proof (older client, or stock client that never sent `0x21`) | signed, directed, plaintext `0x22` (receivers MUST require a valid signature) |

Receivers accept both, plus the prerelease `0x09` alias, and surface them
identically. Upstream iOS additionally asks the user for per‑send consent
before the plaintext fallback; Sonar does not (tracked in §12).

## 11. Limits (decode ceilings, iOS `PacketPayloadLimits`)

| type | max decoded payload |
|---|---|
| `0x22`, `0x11` | 1 MiB + 2 × 65 535 + 18 + 96 (framed file) |
| `0x02`, `0x25` | 128 KiB |
| `0x04`, `0x28` | 64 KiB |
| `0x21` | 8 KiB |
| `0x20` | 1 280 B |
| `0x01`, `0x2C`, `0x03`, `0x23`, `0x24`, `0x29`, `0x10`, `0x26`, `0x27` | 4 KiB |
| anything else (incl. `0x53`) | 128 KiB |

bitchat-android uses one 10 MiB frame cap and a 50 000:1 ratio bound; the
stricter iOS set above is what this crate enforces, so nothing a conforming
sender emits is lost.

## 12. Compatibility matrix

Behaviour as of the revisions in the header. ★ marks an upstream defect this
crate works around; ✗ a Sonar gap that this crate closes on the Rust side.

| aspect | bitchat iOS 1.8.0 | bitchat-android 2.0.3 | Sonar Android (this crate) | Sonar iOS (Swift copy) |
|---|---|---|---|---|
| decodes compressed payloads | yes | yes | yes (was ✗: returned `None`) | yes |
| compresses on encode | yes | yes | yes (was never) | yes |
| signature preimage from received bytes | **no ★** (re‑compresses) | yes (#863) | yes | yes (`WirePayload`, this change) |
| pads | Noise frames only | Noise frames only | Noise frames only (was all) | all (harmless; airtime only) |
| Noise replay window | 1024 sliding | 1024 sliding | 1024 sliding (was ✗: strict counter, one lost frame killed the session) | 1024 sliding |
| private message unknown TLV | reject | reject | skip | skip |
| sends extended PM TLVs to stock peers | n/a | n/a | never (gated on verified `0x53`; was ✗) | never (gated, this change) |
| Noise `0x20` private file | send+recv | send+recv | send+recv (was ✗) | send+recv (this change) |
| Noise `0x21` peer state | yes | yes | yes (was ✗) | yes (this change) |
| `0x09` alias | decode only | decode only | decode only | decode only (this change) |
| file TLV `0x05` (Sonar) | skipped | skipped (≥ #826; older builds drop the file) | sent to Sonar peers only | sent to Sonar peers only (this change) |
| Noise message over 64 KiB | only `0x20` (private-file budget) | yes | yes (no ceiling; 0x11 frame cap applies) | only `0x20` (private-file budget, this change) |
| `0x53` Sonar announce | ignored | ignored | yes | yes |
| legacy `0x22` consent prompt | yes | n/a | no (gap) | no (gap) |
| `announceV2` / groups / board / couriers / PTT | yes | partial | decode as opaque, ignore | ignore |

★ **bitchat iOS re‑compresses for verification.** It rebuilds the signature
preimage with `BinaryProtocol.encode` over the decoded payload, so a signed
frame whose compressible (≥100 B, low‑entropy) payload was produced by any
other DEFLATE encoder — or sent uncompressed — fails verification there.
Nothing a sender can do fixes this except keeping such payloads under 100 B or
high‑entropy; it needs the §5 rule upstream (as bitchat-android already has).
The fix is proposed upstream as permissionlesstech/bitchat#1805
(`upstream/bitchat-ios-verify-over-wire-payload.patch`); until it ships, stock
iOS builds keep the defect.
In practice: Noise frames are high‑entropy (unaffected); announces with
nicknames under ~30 bytes stay under 100 B (unaffected); long signed public
messages and `0x53` announces with a BIP‑353 address are affected.

**Follow-ups this change leaves open** (tracked here so they are not lost):

* The Swift copy on iOS is hand-mirrored. The change was compiled as the
  full iOS app and test bundle (`build-for-testing`) and the protocol suites
  ran on a simulator (75 cases, 0 failures), but only after borrowing the
  vendored Breez Swift package from the unmerged `claude/upgrade-breez-sdk-0.12.4`
  branch: on `main` the project still points at the deleted
  `breez-sdk-liquid-swift` repository and cannot resolve packages on a fresh
  machine. `BLEServicePrivateMediaTests` drives the real `BLEService` through
  the packet seams: XX handshake, unprompted 0x21, a Noise 0x20 file surfacing
  as a private image, our media leaving as 0x20 once the peer proved the
  capability, and the signed 0x22 fallback when it did not.
* Both platforms record a peer's proven capabilities from `0x21` without
  requiring its signing key to equal the announce-pinned key (a mismatch is
  logged). Upstream iOS treats that mismatch as a downgrade signal.
* Neither platform implements upstream iOS's per-send consent prompt before
  the plaintext `0x22` fallback.
* Sonar Android still pads nothing but Noise frames while Sonar iOS pads
  every frame; both decode either shape, so this costs airtime, not
  compatibility.

## 13. Test vectors

`vectors/bitchat-ios.json` (179 cases) and `vectors/bitchat-android.json`
(90 cases) were produced by running the reference codecs themselves — a Swift
Testing case dropped into `localPackages/BitFoundation/Tests` plus copies of
the app‑target TLV files, and a JUnit test run through the upstream Gradle
unit‑test harness. The generator sources are in `vectors/generators/`. Two
multi‑hundred‑KB cases were dropped and single‑byte repeats are written
`repeat:xx*N`; `tests/vectors.rs` expands them.

The harness asserts byte equality for everything except DEFLATE streams,
where it asserts that the upstream stream inflates to the payload, that the
compression *decision* agrees, and that decoding upstream bytes and
re‑encoding reproduces them exactly (the §5 rule). Deliberate divergences
(§12: tolerant PM decode; the union `NoisePayloadType` registry) are listed in
`DIVERGENCES` and asserted the other way round, so they can never drift into
silent agreement or disagreement.

Regenerate with `scripts/bitchat-vectors/regenerate.sh` (`--only ios|android`,
`--ios-rev`/`--android-rev`, `--write`): it clones the upstream repository,
drops the generator into its test target, runs it there, normalizes the dump
(`normalize.py`) and diffs it case by case against the committed file
(`diff.py`), naming every case whose bytes moved, appeared or vanished. CI runs
exactly this against both upstream HEADs weekly and on every PR that touches
the crate (`.github/workflows/bitchat-upstream-drift.yml`), so an upstream
wire change shows up as a failing diff with the case names, not as a field
report. When it fails: update the header revisions here and the pins in
`scripts/check-bitchat-upstream-drift.sh`, and decide — a changed expected
value is a wire change, not a test update. The generators cover the codecs
listed in the header; a NEW upstream codec or TLV does not change the
vectors, which is what the file-level drift check below is for. `scripts/check-bitchat-upstream-drift.sh` (weekly and on every PR that
touches the crate, `.github/workflows/bitchat-upstream-drift.yml`) compares
upstream HEAD against the pinned revisions for exactly those files and fails
on drift, so "compatible with upstream" is re-verified rather than assumed.

## 14. Change control

A wire‑format change to Sonar is complete only when: the crate implements it,
a vector pins it (hand‑derived if no reference produces it yet), this document
records it, both app surfaces consume it (Android via the crate, iOS via the
Swift copy until it moves onto the crate), and stock bitchat's behaviour on
receiving it is stated (ignored / skipped / rejected) with the gate that keeps
it away from clients that reject it.
