# Bidirectional Unify <-> Sonar payments (Sonar as Unify receiver)

Date: 2026-06-12
Status: clarified (brainstorm output, no code changes). Builds on PR #1 (commits on top).

## Context findings (verified)

- Unify nearby-payments contract
  (`unify-wallet/libs/nearby-payments/public/.../NearbyPaymentContract.kt`,
  `NearbyPaymentFraming.kt`):
  - Service UUID `b1f7e2a0-9c3d-4e8a-bf21-3a1c0de54f10`; payload characteristic
    `b1f7e2a1-9c3d-4e8a-bf21-3a1c0de54f10`.
  - RECEIVER (getting paid) = GATT peripheral advertising the service + serving
    the payment payload from the characteristic. PAYER = GATT central that scans,
    connects, reads.
  - Framing: 4-byte big-endian length prefix + UTF-8 payload; chunk boundaries
    are meaningless (reassembler reads `prefix + length` bytes). MAX 8 KB.
  - Payload = a BIP321 `bitcoin:` URI; Unify uses `bitcoin:?lno=<BOLT12 offer>`
    (the `lno=` query param; test fixtures: `bitcoin:?lno=lno1...`).
  - v2 receivers advertise a display name (iOS: BLE local name; Android:
    manufacturer data id `0xFFFF` — inferred layout).
- Sonar already ships the PAYER side: `bitchat/Services/UnifyNearbyService.swift`
  (CBCentralManager scan, GATT read, BIP321 parse, pay via WalletBridgeService),
  `UnifyPeer`, gold Unify badge on the radar, `SNPeerItem.unify`.
- `WalletBridgeService.createOffer()` yields a reusable BOLT12 offer; the wallet
  is derived from the chat identity (configured, mainnet, BREEZ_API_KEY set).
- `SonarAvatar` already does deterministic hash->hue coloring (reuse for the
  per-peer Unify color).

## Decisions taken (user, 2026-06-12)

- Receiver advertising: **always payable** while the wallet is ready AND the app
  is in foreground (zero-tap; chosen over an explicit "Receive" screen). Stop
  advertising in background (iOS restriction) and on panic wipe.
- Offer: **amountless** (`bitcoin:?lno=<offer>`); the Unify payer enters the sats.

## Clarified Problem Statement

**Goal:** Bidirectional Unify <-> Sonar payment demo: Unify sends sats into Sonar
(Sonar acts as a Unify-protocol receiver, no changes on Unify's side) and Sonar
pays Unify (already shipped); plus distinct name/color for multiple Unify peers.

**Constraints:**
- Mirror Unify's contract exactly (service/characteristic UUIDs, 4-byte BE length
  + UTF-8 framing, `bitcoin:?lno=<offer>`, v2 name in BLE local name). Unify
  unchanged.
- Amountless offer; payer chooses sats.
- Always payable when wallet ready + foreground; stop in background.
- Commits on top of PR #1; do not touch the mesh `BLEService`; gate on configured
  wallet.

**Non-goals:**
- The unified discovery profile (issue #2 — tomorrow).
- Reliable background advertising (iOS limit).
- Any change to Unify.

**Success criteria:**
- Unify (Mac) in pay mode sees a peer with our name and pays real sats -> they
  land in the Sonar wallet.
- Two different Unify peers on the Sonar radar show distinct name + color/avatar
  (not all "Unify user").
- Sonar -> Unify still works; no mesh regression.

## Approaches Considered

### Approach A: separate `UnifyReceiverService` (peripheral) alongside `UnifyNearbyService` (central)
- Sketch: new CBPeripheralManager publishing service `b1f7e2a0…` + a read
  characteristic returning `frame("bitcoin:?lno=<createOffer()>")`. Advertising
  driven by wallet-ready + foreground. Name/color fix goes in the payer model.
- Affected files: new `bitchat/Services/UnifyReceiverService.swift`;
  `SonarAppStore` (owns/starts the receiver, foreground lifecycle);
  `UnifyNearbyService`/`UnifyPeer` + `SonarRadarScreen` (real name + deterministic
  avatar/color like `SonarAvatar`); `BitchatApp` (start/stop on scenePhase).
- Tradeoffs: clean separation, independent lifecycles (scan-on-radar vs
  advertise-on-foreground), easy to reason about. One extra file.
- Effort: M.

### Approach B: one `UnifyNearbyService` hosting both roles (central + peripheral)
- Sketch: extend the existing service to also host the CBPeripheralManager.
- Affected files: `UnifyNearbyService.swift` (grows) + the name/color fix.
- Tradeoffs: all Unify code in one place, but mixes two different lifecycles in
  one class — harder to follow.
- Effort: M.

## Recommendation

**Approach A.** The two Unify roles have different lifecycles (scan while the
radar is visible; advertise while the app is foreground and the wallet is ready),
so two distinct services keep the code clear and the behavior predictable, and
mirror the payer/receiver split of the Unify contract. Cost is one extra file.
The name+color fix is orthogonal and applies in both.

## Open questions — RESOLVED (user, 2026-06-12)

- Advertised name as receiver: **the user's nickname**, fallback **"Sonar
  user"**.
- Cross-platform name parity: the payer side must read BOTH the BLE local name
  (iOS Unify peers) AND manufacturer-data `0xFFFF` (Android Unify peers) so a
  Unify user's name shows correctly regardless of their platform. iOS/Android
  must stay 1:1 on UI + behavior.
- Foreground-only advertising: **accepted** for now (iOS background limits) —
  advertise on `scenePhase .active`, stop in background.
