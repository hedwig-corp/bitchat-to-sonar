# Brainstorm: Android discovery-protocol parity with iOS

**Date:** 2026-06-13
**Branch:** `android-ios-parity` (PR #7), phased per-gap commits, one PR.

## Clarified Problem Statement

**Goal:** Close all four discovery-protocol gaps so the Android Compose app
discovers and is discovered by the exact same peer universe as the iOS Sonar
app: typed mesh dispatch, Sonar 0x53 announce, Nostr geohash presence, and
Unify nearby BLE.

**Constraints (must-have / can't-break):**
- Wire-compatible with bitchat + iOS Sonar — byte-for-byte on every packet/event
  (mesh `BitchatPacket` type bytes, 0x53 TLV, Nostr kinds 20000/20001, Unify
  `b1f7e2a0…` framing). The codecs are already ported + unit-tested; do not
  alter their wire output.
- Stay in Compose Multiplatform shape: protocol/logic in `commonMain`, BLE/
  radio/relay I/O behind `androidMain` `actual`. No new singletons.
- Mainnet mesh UUID always (`F47B5E2D…4B5C`); testnet opt-in only.
- 0x53 must NOT be a typed mesh `MessageType` case — handle it as a raw byte that
  falls through to relay, exactly like iOS (stock bitchat clients ignore+relay).
- Don't regress the 7/7 1:1 screens or the internet transports already e2e-tested.

**Non-goals:**
- No new discovery protocol or convergence — Unify stays fully isolated from the
  mesh `BLEService` (its own scanner/GATT server), mirroring iOS.
- No NIP-46, no profile/identity changes beyond what 0x53 already carries.
- Not redesigning UI — only feeding real discovered data into existing radar/
  badge/participant-count surfaces.

**Success criteria:**
- #1 Typed dispatch: `MeshGatt` routes decoded packets by `packet.type`
  (announce / message / 0x53 / fragment) instead of treating every payload as
  chat text; unit test asserts an announce packet does NOT surface as a chat
  message and a 0x53 packet reaches the Sonar handler.
- #2 Sonar 0x53: local announce rides the announce path (Ed25519-signed),
  incoming 0x53 is verified against the peer's announce signing key and populates
  a peer profile (npub + BIP-353 + capability badges). Round-trip unit test.
- #3 Presence: joining a geohash channel publishes kind 20001 and subscribes to
  others; "N here now" reflects live presence; kind 20000 ephemeral msgs flow.
  Verified against an in-process / mock relay with no network.
- #4 Unify: an `androidMain` service scans the Unify UUID (payer) and advertises
  a GATT read char serving a BOLT12 offer (receiver); peers appear on the radar
  outer ring with the gold "pay only" badge. Framing round-trips in unit tests;
  live link verified on 2 phones.
- `cd android && ./gradlew :composeApp:testDebugUnitTest` green; debug APK
  installs on the Pixel 8.

**Verifiability split:**
- Autonomous (CI/unit + mock relay): #1 dispatch logic, #2 0x53 codec+sign/verify,
  #3 presence publish/subscribe, #4 framing/offer codec.
- Hardware (2 BLE phones): #1 live announce exchange, #2 live 0x53 on air,
  #4 live Unify payer↔receiver link.

## Approaches Considered

### Approach A: Typed dispatch refactor first, then layer 0x53 + presence + Unify
- Sketch: Refactor `MeshGatt.android.kt` `onText` → a typed `onPacket(packet)`
  sink that switches on `packet.type` (announce, message, fragment, 0x53-raw).
  Commit 1 = dispatch + announce/identity handling. Commit 2 = 0x53 sign/verify
  + peer profile wiring (depends on commit 1's raw-byte fallthrough). Commit 3 =
  presence (independent, Nostr side). Commit 4 = Unify BLE service (independent,
  own radio).
- Affected files: `MeshGatt.android.kt`, `mesh/BitchatPacket.kt`,
  `SonarDiscovery.kt` + `SonarAppState.kt` (0x53 sign/verify, peer profiles),
  new `androidMain` `GeohashPresence.android.kt` + commonMain presence model,
  new `androidMain/.../unify/UnifyNearby.android.kt` (scanner + GATT server).
- Tradeoffs: Correct dependency order; each commit independently reviewable and
  3 of 4 land verifiable now. Slightly more upfront work refactoring the GATT
  read path. Doesn't solve live-mesh proof (hardware-gated regardless).
- Effort: L

### Approach B: Presence + Unify now (parallel, independent), mesh/0x53 last
- Sketch: Do the two radio-independent gaps first (#3 Nostr presence, #4 Unify
  on its own BLE stack) since neither touches the fragile mesh GATT path, then
  tackle the mesh dispatch refactor + 0x53.
- Affected files: same set, reordered.
- Tradeoffs: Front-loads the fully-autonomous + cleanly-isolated work, delivers
  visible wins (participant counts, Unify badges) fast. But 0x53 — the most
  bitchat-interop-relevant gap — lands last, and the mesh refactor it depends on
  is the riskiest piece left to the end.
- Effort: L

### Approach C: Big-bang single typed pipeline
- Sketch: Rewrite the whole Android receive path into one packet pipeline that
  unifies mesh-typed, 0x53, and presence event handling under a shared
  dispatcher, then add Unify.
- Affected files: heavy rewrite of `MeshGatt.android.kt` + `SonarAppState`
  event handling.
- Tradeoffs: Cleanest end-state architecture; but it's one giant change,
  conflicts with "phased per-gap commits", and makes regression bisection hard.
  Over-engineers relative to iOS's additive approach.
- Effort: XL

## Recommendation

**Approach A.** It matches the user's "phased per-gap commits, one PR" choice
exactly, respects the real dependency (0x53 fallthrough needs typed dispatch
first), and lets 3 of 4 gaps land with autonomous verification while only the
genuinely hardware-gated legs wait for two phones. Commit order:
1. Typed mesh dispatch (announce/message/fragment + 0x53 raw fallthrough)
2. Sonar 0x53 sign/verify + peer profile/badges
3. Geohash presence (kind 20001/20000)
4. Unify nearby BLE service (payer + receiver)

## Open questions

- Does the Android mesh path already announce identity at all, or only open a
  GATT link and stream chat? (Audit says only chat text streams — confirm the
  announce-send path exists before #1 can route it.)
- iOS signs 0x53 with the Ed25519 announce signing key verified from the peer's
  bitchat announce. Android needs that same signing key available in `sonar-ffi`
  / identity — confirm it's exposed before #2.
- Presence: reuse the existing Nostr relay client (the one already e2e-tested for
  White Noise / geohash DMs) for kind 20001, or a dedicated subscription? Prefer
  reuse.
