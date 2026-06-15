# Brainstorm: Android radar-peer chat transport model

Date: 2026-06-14
Topic: How a Sonar Android user starts/holds a 1:1 chat with a peer found in
the radar, when that peer is a **bitchat** user vs a **Sonar** user. (The
**Unify** case is payment-only and already handled — "Send sats", no chat.)

## Decisions (confirmed by Vincenzo, 2026-06-14) — mirror iOS 1:1

1. **Transport model = auto-pick (mirror iOS).** The app chooses the transport;
   the user just types. The DM header shows the current transport. No manual
   transport switch.
2. **bitchat peer, out of Bluetooth range = Favorite → Nostr (NIP-17).** Offer
   "Favorite"; once mutual, deliver over the internet via a 1:1 gift-wrapped
   NIP-17 DM. Until favorited, the message waits for range. (iOS/bitchat exact.)
3. **Sonar peer, out of Bluetooth range = White Noise, merged.** Continue over
   White Noise (Marmot/MLS) as ONE conversation, merged chronologically with the
   mesh transcript; the White Noise leg renders as internet (indigo). (iOS exact.)
4. **Radar-tap UX = single "Message" button.** Transport is auto-picked and shown
   in the DM header. "Send sats" stays a separate button for pay-capable peers.
   Matches the design's `sn-peercard` 1:1.

## Goal

Bring Android's radar-peer → 1:1 chat to behavioural parity with the iOS Sonar
app: tap a peer, hit **Message**, and the app routes over BLE mesh when the peer
is in range and over the peer's best internet path when it isn't — White Noise
for Sonar peers, NIP-17 for favorited bitchat peers — all rendered as one
conversation.

## Constraints / must-not-break

- 1:1 with the iOS `SonarAppStore` DM model and the design `sn-peercard`.
- Mesh BLE I/O stays in `androidMain` (`MeshGatt`/`MeshRadio`); the Rust core
  has no BLE radio access on Android.
- Wire-compat: mesh Noise DMs and NIP-17 gift-wrap must match bitchat exactly
  (interop oracle = the iOS app + stock bitchat).
- Bubble colour follows transport (cyan = Bluetooth, indigo = internet).

## Non-goals

- Unify chat (Unify stays payment-only).
- Group chat / multi-party (1:1 only here).
- Per-message historical transport accuracy on the mesh leg (v1 colours by
  *current* reachability, same approximation iOS ships).
- NIP-46 / remote signing.

## Success criteria

- Tap a **Sonar** peer in range → mesh DM (cyan); walk out of range → the same
  thread keeps sending over White Noise (indigo), one merged transcript, on both
  Android and iOS.
- Tap a **bitchat** peer in range → mesh DM. Out of range, un-favorited → a clear
  "will wait until you meet again" banner + a Favorite action. After mutual
  favorite → messages deliver over Nostr (NIP-17) and arrive on the iOS/bitchat
  peer.
- Radar peer card shows exactly one **Message** button (+ **Send sats** when
  pay-capable); DM header names the live transport.

## Key technical finding (the gap that shapes the plan)

The Android core (`sonar-ffi`) Nostr DM surface is **geohash-scoped only**:
`start_dm` (Marmot/White Noise), `send_geo_dm`/`geo_dm_messages` (geohash DMs).
There is **no general 1:1 NIP-17 DM** to an arbitrary npub.

- Sonar-peer leg (mesh ↔ White Noise): **buildable today** with existing surface
  (`MeshRadio.sendMeshDm` + `SonarCore.startChat/send`).
- bitchat-favorite leg (mesh ↔ NIP-17 internet): **needs new core work** — a
  `send_nip17_dm(recipient_npub, text)` + an inbox/subscription + a favorites
  store in `sonar-core`/`sonar-ffi`. iOS gets this from `MessageRouter`, which
  has no Android equivalent yet.

## Approaches Considered

### Approach A: Kotlin parity port (all-at-once)
- Sketch: Replicate the iOS `SonarAppStore` DM model in `SonarAppState.kt` —
  `dmTransport(id)`, `sendDm(id,text)`, merged `dmMsgs` (mesh privateChats +
  Marmot group by npub), favorites, `pendingMarmotSends` queue. Add the missing
  NIP-17 1:1 path to the core in the same pass.
- Affected: `SonarAppState.kt`, `SonarRadarScreen.kt` (single Message btn),
  `SonarDMScreen` (header transport + banners), `core/sonar-ffi` + `sonar-core`
  (new `send_nip17_dm` + inbox), `SonarCore.kt` expect/actual.
- Tradeoffs: full parity in one shot; but large surface, and the NIP-17 core
  work blocks the whole thing from landing/verifying.
- Effort: L.

### Approach B: Sequence it — Sonar leg now, bitchat-favorite leg next (RECOMMENDED)
- Sketch: Ship the fully-buildable, highest-value half first — Sonar-peer
  merged auto-pick (mesh ↔ White Noise) + single Message button + DM-header
  transport + out-of-range banner. Then a second step adds the core
  `send_nip17_dm` surface + favorites and wires the bitchat-favorite→internet
  leg.
- Affected: step 1 — `SonarAppState.kt`, `SonarRadarScreen.kt`, `SonarDMScreen`;
  step 2 — `core/sonar-core` + `sonar-ffi` (NIP-17 1:1 + inbox), favorites store,
  then the bitchat-peer branch of `sendDm`.
- Tradeoffs: same end state as A, staged so each step is independently
  shippable + on-device verifiable (two phones already test the Sonar leg). The
  bitchat-favorite leg is honestly isolated as the part that needs new core work.
  Slightly more glue churn across two PRs.
- Effort: M now + M later.

### Approach C: Thick Rust router (`DirectChat` in sonar-core)
- Sketch: A `DirectChat`/conversation abstraction in `sonar-core` owns transport
  selection + the merged message stream; Kotlin feeds it reachability and a mesh
  send callback, and only renders.
- Affected: large new `sonar-core` module + FFI; `SonarAppState` becomes a thin
  renderer.
- Tradeoffs: architecturally aligned with the long-term "thick Rust core"
  (Approach B in CLAUDE.md / the M4 strangle), but premature: mesh I/O is
  Kotlin-side, so the router straddles the FFI with callbacks now; biggest cost,
  least incremental value at the current M2/UI-parity phase.
- Effort: XL.

## Recommendation

**Approach B (sequence it).** It delivers exactly the iOS behaviour you chose,
but stages the work so the part that's fully buildable and verifiable on the two
test phones today — the Sonar peer mesh↔White Noise merged thread + single
Message button — ships and gets confirmed first, while the one leg that genuinely
needs new core surface (1:1 NIP-17 for favorited bitchat peers) is isolated into
its own step instead of blocking everything. Approach C is the right *eventual*
shape but premature while mesh I/O lives in Kotlin.

## Open questions

- NIP-17 1:1 in the core: new `send_nip17_dm` + a gift-wrap inbox/subscription +
  favorites persistence — confirm the rust-nostr `nip59` surface already vendored
  for Marmot covers this (likely yes; Marmot already gift-wraps welcomes).
- Favorites source of truth on Android: is there an existing favorites store, or
  is it new? (iOS uses `ChatViewModel.toggleFavorite` + mutualFavorites.)
- "Reachable but not connected" — does Android have an `isPeerReachable`
  equivalent (recently-seen announce) distinct from a live Noise link, to match
  iOS `dmTransport`?
