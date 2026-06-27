# Android to iOS Parity Delivery Plan

Date: 2026-06-27

## Current HEAD Baseline

Android/Compose is no longer at the 2026-06-13 parity baseline. The current
branch already includes several items that older parity docs listed as missing:

- Account restore from `nsec1...` during onboarding and private-key export from
  Settings.
- Android Keystore-backed local secret storage for the imported/generated
  identity and Marmot database key.
- Sonar descriptor publish/fetch actuals, descriptor cache TTLs, descriptor
  call gating, and descriptor-backed direct payment lookup.
- Wallet seed derivation from the identity `nsec`, Breez-backed wallet setup,
  currency display, direct payment activity, and BOLT12 offer publication.
- App lock, notification routing, remote push wake processing, radar/list
  discovery, safety-number verification, message persistence, and erase-all
  chats.
- Account-level conversation folding between BLE mesh and White Noise/Marmot
  rows.

The parity work should stay sliced. Do not restart the old full-parity push; use
this document as the current source of truth and ship each remaining gap as a
small production PR.

## Slice 1: Compose Slash Commands and UX Safety

Status: implemented in the 2026-06-27 command parity slice; manual device smoke
still recommended before release.

Goal: make Compose recognize the same command surface exposed by the iOS command
autocomplete, without leaking unsupported safety commands as plain chat text.

Deliverables:

- Share one Compose command registry for hints and parsing.
- Recognize iOS command aliases: `/msg`/`/m`, `/who`/`/w`, `/clear`, `/hug`,
  `/slap`, `/fav`, `/unfav`, `/block`, and `/unblock`.
- Consume commands from both DM and public-channel composers.
- Implement safe existing behavior:
  - `/who` opens Nearby.
  - `/msg @peer [text]` opens a visible mesh peer, sends optional text, or starts
    a pasted npub/hex secure chat.
  - `/clear` clears local mesh/channel timelines where Compose owns the local
    store; White Noise history stays behind Delete chat.
  - `/hug` and `/slap` send emote text to the active channel or DM.
- Return explicit toasts for `/block`, `/unblock`, `/fav`, and `/unfav` until
  those backing models exist on Compose.

Verification:

- `cd apps/sonar && ./gradlew :composeApp:allTests`
- `cd apps/sonar && ./gradlew :composeApp:compileKotlinMetadata`
- Manual smoke: type `/` in a DM and in a channel, pick each command hint, verify
  unsupported safety/favorite commands do not send plaintext.

## Slice 2: Contact Safety and Favorites

Status: implemented in the 2026-06-27 contact safety/favorites slice; manual
two-device smoke is still recommended before release.

Goal: match iOS block/unblock and favorite/unfavorite behavior for mesh peers and
geohash authors.

Deliverables:

- Add Compose favorite persistence keyed by stable mesh fingerprint and optional
  npub link.
- Add mutual favorite state and the UI affordance currently missing from contact
  profile/radar.
- Add block/unblock persistence for mesh fingerprints and geohash Nostr pubkeys.
- Wire contact-profile actions and slash commands to the same backing store.
- Suppress blocked geohash authors and blocked mesh contacts in local UI.
- Send and consume hidden mesh favorite/unfavorite notifications so mutual
  favorite state can be observed when peers are in Bluetooth range.
- Preserve the current outbox/White Noise behavior for known Sonar peers.

Verification:

- Focused persistence tests for favorite/block stores.
- Unit tests for blocked geohash filtering.
- Manual two-device smoke for favorite notification/interoperability when the BLE
  route is available.
- Full out-of-range NIP-17 delivery remains Slice 4.

## Slice 3: BLE Mesh Media

Status: implemented in the 2026-06-27 mesh media slice for Android source:
Android can send and receive private BLE `0x22` file-transfer packets, persist
local mesh media blobs, and render them through the existing media bubble path.
Hardware smoke remains required for Android/iOS image and voice-note exchange
after rebuilding native FFI artifacts from the updated Rust core.

Goal: match iOS media behavior when two peers are physically nearby.

Deliverables:

- Add a mesh file-transfer API to the common `MeshRadio` expect surface.
- Implement Android BLE packet type `0x22` using the existing Rust interop
  helpers: `mesh_encode_file_packet`, `mesh_decode_file_packet`, and
  `mesh_fragment`.
- Route images, voice notes, and files over live BLE Noise when available.
- Keep Marmot MIP-04 as the fallback for White Noise groups and out-of-range
  Sonar peers.
- Persist received BLE media metadata and blobs through the existing message
  store.

Tracked gap:

- Android emits large file-transfer frames as directed v2 packets from Kotlin
  because the currently generated FFI exposes only the v1 signed packet builder.
  The next native-FFI regeneration should add a signed v2 builder so large
  outbound media has the same signature shape as iOS.

Verification:

- Rust/FFI tests for file-packet wire format.
- Compose unit tests for packet reassembly boundaries and local store round-trip.
- Hardware-gated smoke: two Android devices and Android/iOS interop for image and
  voice-note send/receive.

## Slice 4: Plain Bitchat Out-of-Range Fallback

Status: implemented in this PR, pending manual device smoke. The Android path now
has a shared-core account-identity direct NIP-17 send/drain API for
mutual-favorite plain bitchat peers. The payload is iOS-compatible `bitchat1:`
private-message content inside a NIP-17 gift wrap, not raw Marmot text.

Goal: bring iOS favorite/NIP-17 delivery to Android for non-Sonar bitchat peers.

Deliverables:

- Use the Slice 2 favorite store as the trust gate.
- Add general NIP-17 one-to-one DM send/receive for favorite peers without
  requiring a Sonar descriptor.
- Queue sends while offline and flush when a relay route is available.
- Keep Sonar peers on the existing White Noise/Marmot route.
- Persist direct NIP-17 messages through the same bounded local mesh transcript
  store so opening a conversation paints from local storage first.

Verification:

- Favorite persistence tests.
- NIP-17 send/receive tests across two identities.
- Kotlin MessageStore round-trip test for the internet transport marker used by
  direct NIP-17 local transcript persistence.
- Manual smoke for a plain mesh peer leaving range, receiving over relay, then
  returning to BLE.

## Slice 5: Remaining UX and Safety Polish

Status: partially implemented in the 2026-06-27 parity polish slice. Delivery
state text is normalized through a shared helper with tests. Report/moderation
actions remain product/backend-gated because neither platform has a completed
report backend to call.

Goal: close smaller parity gaps after command, safety, and transport-critical work.

Deliverables:

- Keep geohash author block parity; do not add a fake report action until a
  product/backend report path exists on both app surfaces.
- Tighten delivery status copy where Compose still differs from
  `SonarAppStore.stateText`.
- Add Android instrumentation smoke coverage for secure-store migration when
  device CI is available; this remains device-CI gated.

Verification:

- Focused UI tests or screenshot smoke where practical.
- Manual notification/privacy smoke.
- Security review for restored/exported identity handling.

## Production Rule

Each slice must be independently shippable, verified locally, and reviewed for
regressions before moving to the next one. Hardware-gated work must include a
manual device test checklist even when CI cannot exercise BLE.
