# Android to iOS Parity Delivery Plan

Date: 2026-06-18

## Baseline From Recent Commits

Recent work in the last four days already moved Android much closer to iOS:

- Account-level Sonar conversations now merge BLE mesh and White Noise/Marmot rows.
- Voice call plumbing exists on Android through `SonarCore` and encrypted `CALL` control messages.
- Android has app lock, notifications, safety verification, wallet seed derivation from `nsec`, Unify nearby payments, radar/list discovery, message persistence, and erase-all-chats behavior.
- Recent iOS payment work publishes schema-2 Sonar descriptors with optional BOLT12 receive metadata and sends direct descriptor-backed payments.
- iOS still has user-facing account recovery and public Sonar descriptor wiring that Android does not expose yet.

The remaining parity work should ship as small production PRs, not one large cross-platform rewrite.

## Slice 1: Account Recovery + Sonar Descriptor Wiring

Goal: make Android usable as a real account device, and let account-level internet peers advertise Sonar call capability the same way iOS does.

Deliverables:

- Add Android/KMP account restore from an existing `nsec1...` backup during onboarding.
- Add Android settings export for the current `nsec1...` private key.
- Persist restored identity only after FFI validation succeeds.
- Reconnect the core, refresh wallet derivation, mesh identity, profile publishing, and discovery state after restore.
- Add common `SonarDescriptor` APIs and Android/JVM actuals backed by existing UniFFI `publish_sonar_descriptor` and `fetch_sonar_descriptor`.
- Publish the local descriptor at boot with honest account-level signaling routes: `marmot`.
- Publish schema-2 descriptor receive metadata when the Android wallet is ready.
- Cache fetched peer descriptors with iOS-equivalent positive and miss TTLs.
- Let call affordances use public descriptors when a peer is out of BLE range but known by npub.

Verification:

- `./gradlew :composeApp:jvmTest`
- `./gradlew :composeApp:compileDebugKotlinAndroid` or `:composeApp:assembleDebug` when Android SDK/NDK is available.
- Manual Android smoke: fresh onboarding, restore with valid `nsec`, invalid restore rejection, export reveal/copy, out-of-range known npub call button visibility.

## Slice 2: BLE Mesh Media

Goal: match iOS media behavior when two peers are physically nearby.

Deliverables:

- Add mesh file transfer API to `MeshRadio` common expect.
- Implement Android BLE packet type `0x22` using existing Rust interop helpers (`mesh_encode_file_packet`, `mesh_decode_file_packet`, `mesh_fragment`).
- Route images, voice notes, and files over live BLE Noise when available.
- Keep Marmot MIP-04 as fallback for White Noise groups.
- Persist received BLE media metadata and blobs through the existing message store.

Verification:

- Rust interop tests for file packet wire format.
- Android unit tests for packet reassembly boundaries.
- Two-device BLE smoke for image and voice note send/receive.

## Slice 3: Plain Bitchat Out-of-Range Fallback

Goal: bring iOS favorite/NIP-17 delivery to Android for non-Sonar bitchat peers.

Deliverables:

- Add favorite/verified peer persistence and UI affordances.
- Add general NIP-17 one-to-one DM send/receive for favorite peers without requiring a Sonar descriptor.
- Queue sends while offline and flush when relay route is available.
- Keep Sonar peers on the existing White Noise/Marmot route.

Verification:

- Favorite persistence tests.
- NIP-17 send/receive tests across two identities.
- Manual smoke for plain mesh peer leaving range, receiving over relay, then returning to BLE.

## Slice 4: UX and Safety Polish

Goal: close smaller gaps after the account and transport-critical work is in place.

Deliverables:

- Match iOS slash commands (`/nick`, `/clear`, `/help`) on Android.
- Add delivery status text parity.
- Add geohash author block/report affordance if still present on iOS.
- Add Android direct descriptor-backed payment sends and payment activity history to match the latest iOS `sonar.meta.v1` payment UI.
- Review Android private-key storage and replace plain SharedPreferences with an encrypted store before beta distribution.

Verification:

- Focused command tests.
- Manual notification/privacy smoke.
- Security review for restored/exported identity handling.

## Production Rule

Each slice must be independently shippable, verified locally, and reviewed for regressions before moving to the next one. Hardware-gated work must include a manual device test checklist even when CI cannot exercise BLE.
