# Android ↔ iOS 1:1 Parity — Completion Plan

**Date:** 2026-06-13
**Author:** Sonar agent (brainstorm, `--write`)
**Goal directive (Vincenzo):** "Make the Android Compose app exactly equal to the
iOS Sonar app — every feature, every UX detail. Same look at the UI/UX level,
same functionality."

---

## Clarified Problem Statement

**Goal:** Bring the Android Compose Multiplatform app to full functional and
visual parity with the iOS SwiftUI Sonar app, closing every gap found in the
deep gap analysis, so the two apps are interoperable on the wire AND
indistinguishable in UX.

**Constraints (must-have / can't-break):**
- The 7 screens are already 1:1 — do NOT restyle or regress them; only *add*
  the missing surfaces (sheets, banners, badges, rows).
- Wire-compat is sacred: BLE mesh service UUID `…4B5C` (mainnet), BitchatPacket
  v1 framing, Noise XX, NIP-17/Marmot/geohash kinds must match iOS byte-for-byte
  (much is already e2e/unit-tested in the shared Rust core).
- Reuse the shared Rust core (`sonar-core` / `sonar-ffi`) for all protocol
  logic — never re-implement crypto/protocol in Kotlin. Kotlin holds UI + radio
  I/O + platform services only (the Approach-B split).
- The Breez API key is the SAME one as iOS, living in a **gitignored** secret —
  never commit it, never print it.
- Money display rule (from `2026-06-12-money-display-fiat-toggle.md`): fiat only
  when a live rate exists, else sats. Currency picker.
- Wallet seed derivation must match the iOS decision
  (`2026-06-12-wallet-derived-from-identity.md`): deterministic from the Nostr
  identity, so the same identity reconstructs the same wallet.
- Honest reporting: anything needing 2 BLE phones or real Lightning funds is
  marked NOT autonomously verifiable and must not be claimed "done" off a build.

**Non-goals (explicitly out of scope for this parity push):**
- Retiring the SwiftUI iOS layer / shifting iOS to CMP (that's the later M-phase
  convergence, tracked in issue #6 — NOT this push).
- New features that don't exist on iOS. Parity means matching iOS, not exceeding.
- NIP-46 remote signing; multi-device KeyPackage fan-out — neither is in iOS v1.
- Production Play Store hardening (R8/proguard rules, release signing) — dev
  build parity is the target.

**Success criteria:**
- Every iOS feature in the gap list has a working Android equivalent behind the
  same UX affordance.
- Side-by-side, a user cannot tell which OS they're on: same sheets, banners,
  badges, copy, transport colors, radar, settings rows.
- Autonomously-verifiable parts: green `cargo test` (core), green Kotlin
  `commonTest`, app builds + installs + launches, screen-by-screen screenshot
  match against the iOS reference.
- Hardware/Lightning parts: implemented + unit-tested + a written on-device test
  plan; explicitly flagged as needing 2 phones / funded wallet to *fully* verify.

---

## Current verified state (baseline, do not re-do)

| Area | State |
|---|---|
| 7/7 screens (Onboarding, Home, Channel, DM, Radar, Settings, Profile) | **1:1, built, screenshot-verified** |
| Internet transports: White Noise (Marmot), geohash channels, geohash DMs | **e2e-tested in core** (13 green) |
| BLE mesh: Noise XX crypto, BitchatPacket v1 framing, GATT scaffold | **implemented, unit-tested** (crypto + framing); live link NOT verified (needs 2 phones) |
| ⚡PAY ledger state machine | **ported + unit-tested** (4 green); NOT wired to a wallet |
| Unify nearby: BIP321 parse + framing | **ported + unit-tested** (10 green); NO BLE GATT fetch yet |
| Breez SDK Liquid dependency | **added, resolves** to `-android`; NO bridge code yet |
| Generic blob persistence (`loadBlob`/`saveBlob`) | **in FFI**, used by nothing yet |

---

## The gap inventory (what's left)

### Functional gaps
1. **Real Breez wallet** — balance / send / createOffer (BOLT12) / incoming;
   money display (fiat+sats, exchange rate, currency picker); deterministic seed
   from identity.
2. **⚡PAY ↔ wallet wiring** — auto-claim flow drives `wallet.send(offer)` then
   `⚡PAYDONE`; ledger already done, just needs the wallet calls + transcript scan.
3. **Sonar Discovery 0x53** — announce npub + BIP-353 + capabilities over mesh;
   parse peers' announces; surface in radar.
4. **Message persistence** — encrypted-at-rest, survive restart (mesh privateChats
   + channel timelines + pay ledger).
5. **Notifications** — incoming DM / mention / payment local notifications.
6. **Unify nearby payments BLE** — payer (central fetch offer) + receiver
   (peripheral serve offer); parsing/framing already done.
7. **BLE mesh live GATT link bring-up** — discovery + Noise handshake + framed
   record exchange over the air (scaffold exists; needs on-air debugging).
8. **App lock** — biometric/passcode gate on launch.

### UX gaps
9. Verify-safety-number sheet (12×5 digits, order-independent).
10. Out-of-range routing banners (Sonar→White Noise; favorite→internet; plain→wait).
11. Radar **list view** toggle + peer card + Sonar/Unify badges + signal bars/RSSI.
12. Status chip + connectivity sheet (relay count + mesh count).
13. Settings **wallet section** + currency picker.
14. Profile **BIP-353** field.
15. Channel author **block** sheet.
16. Slash commands (`/nick`, `/clear`, …) in composer.
17. Message **delivery state** (sent/delivered indicators).
18. Triple-tap **wipe** (title triple-tap → wipe sheet).

---

## Approaches Considered

### Approach A: Vertical slices (feature-by-feature, full stack each)
- **Sketch:** Take one feature at a time (e.g. "wallet"), build core→FFI→Kotlin
  bridge→store→UI→test, ship it, move on. Each PR is one user-visible capability.
- **Affected files:** rotates per slice — `core/sonar-ffi/src/lib.rs`,
  `android/.../WalletBridge.android.kt`, `SonarAppState.kt`, `App.kt`, a screen.
- **Tradeoffs:** + Each PR is independently shippable & demoable; easy to mark
  verified vs hardware-blocked per slice. − Some cross-cutting plumbing (money
  formatting, notification channel) gets touched repeatedly.
- **Effort:** L overall, but each slice is S/M.

### Approach B: Horizontal layers (all-core, then all-FFI, then all-UI)
- **Sketch:** Land every core/FFI change first, then every Kotlin bridge, then
  every screen.
- **Tradeoffs:** + Batches the Rust rebuilds (one `build-android.sh` per layer).
  − Nothing is demoable until the last layer; hard to verify incrementally; a
  core mistake surfaces late. Violates the "each milestone ships" rule.
- **Effort:** L, with a long un-verifiable middle.

### Approach C: Risk-first (hardware-blocked items first, to de-risk the demo)
- **Sketch:** Tackle BLE mesh live link + Unify BLE first since they're the
  riskiest and need physical devices.
- **Tradeoffs:** + Surfaces the hardest unknowns early. − Front-loads exactly
  the work that CANNOT be autonomously verified, so progress stalls waiting on 2
  phones; the autonomously-completable 80% gets delayed.
- **Effort:** L, poorly sequenced for an agent working without hardware.

## Recommendation

**Approach A (vertical slices), ordered by dependency × autonomous-verifiability.**
It matches the repo's "each milestone ships" rule, lets each slice be marked
honestly (verified-on-build vs needs-hardware), and front-loads the work an agent
CAN fully verify (wallet, persistence, discovery, all UI sheets) while deferring
the 2-phone/funded-Lightning items to clearly-labeled final slices with on-device
test plans. The money-formatting and notification plumbing touched repeatedly is
cheap and gets a tiny shared helper on first use.

---

## Phased plan (dependency-ordered, each phase = one or more /ship tasks)

Legend: **[AV]** autonomously verifiable on this machine (build + unit/e2e +
screenshot). **[HW]** needs 2 BLE phones. **[⚡]** needs real Lightning funds to
*fully* verify (logic + unit tests still AV).

### Phase 1 — Wallet foundation **[AV for balance/offer; ⚡ for send]**
The API key unblocks this and ⚡PAY depends on it. Highest value.
- 1a. Inspect Breez SDK Liquid KMP API (`BindingLiquidSdk`, `connect`,
  `ConnectRequest`, `defaultConfig`, `getInfo`, `prepareSendPayment`/`sendPayment`,
  `receivePayment`/BOLT12 offer, `fetchFiatRates`). Pin the exact 0.11.13 surface.
- 1b. `WalletBridge` (`androidMain`): `expect`/`actual` façade —
  `setupIfNeeded()`, `state` (NotConfigured/SettingUp/Ready(balanceSats)),
  `createOffer(): String`, `send(destination, amountSats, note)`,
  `observeBalance()`. Seed = deterministic from the Nostr identity (mirror iOS
  `entropyProvider`; see `2026-06-12-wallet-derived-from-identity.md`). API key
  read from a gitignored `local.properties` / BuildConfig field — never committed.
- 1c. Money display helper (shared `commonMain`): fiat only when a live rate
  exists, else sats (`2026-06-12-money-display-fiat-toggle.md`); currency picker
  state.
- 1d. Settings **wallet section** + currency picker UI (gap 13). Profile stays.
- **Verify:** unit-test seed determinism + money formatter [AV]; on-device
  `getInfo` balance + `createOffer` BOLT12 [AV with key, no funds needed];
  `send` is **[⚡]** — logic unit-tested, real settlement needs funds. On-device
  test plan written.

### Phase 2 — ⚡PAY wired to wallet **[AV logic; ⚡ settlement]**
Depends on Phase 1.
- Scan both transcript stores (Marmot + geohash/mesh) for `⚡PAY`/`⚡PAYCLAIM`/
  `⚡PAYDONE` lines, idempotent via the in-memory scanned-id set + durable ledger.
- `⚡PAYCLAIM` auto-triggers `wallet.send(offer)` → `⚡PAYDONE`. PAY lines render
  as pay bubbles (already have `PayBubble`); claim/done hidden; home preview
  "₿ Payment".
- **Verify:** ledger state-machine transitions on synthetic transcripts [AV];
  end-to-end settle is **[⚡]**.

### Phase 3 — Message persistence **[AV]**
Independent; high value (chats survive restart). Uses existing `loadBlob`/
`saveBlob` FFI (SQLCipher-backed, already cross-builds for Android).
- Hydrate mesh `privateChats` + channel timelines + pay ledger from the store on
  launch; write-through on change. Mirror the iOS `MessageStore` envelope/caps.
- Wipe erases the store (wire into triple-tap wipe, Phase 9).
- **Verify:** round-trip + survives-new-instance + wipe unit tests [AV].

### Phase 4 — Sonar Discovery 0x53 **[AV codec; HW on-air]**
- Port `SonarAnnouncePacket` TLV codec (0x01 version, 0x02 npub, 0x03 bip353,
  0x04 capabilities) to `commonMain`; sign/verify with the Ed25519 announce key
  via FFI. Ride on mesh announce; parse peers; surface `SNPeerItem.sonar` flag +
  "· Sonar" + indigo dot in radar; BIP-353 field on Profile (gap 14).
- **Verify:** TLV encode/decode + signature unit tests [AV]; real peer discovery
  is **[HW]** (rides the mesh link, Phase 8).

### Phase 5 — Radar list view + peer card + badges + signal **[AV]**
Pure UI on data the store already has (mesh peers, RSSI from scan).
- List/radar toggle; peer card sheet; Sonar (indigo) / Unify (gold) badges;
  signal bars from RSSI; "Send sats" gating by capability.
- **Verify:** screenshot match vs iOS [AV].

### Phase 6 — Remaining UX sheets/banners **[AV]**
All pure UI/store, no new transport.
- Verify-safety-number sheet (12×5, order-independent `snHash` over both
  fingerprints/npubs) — gap 9.
- Out-of-range routing banners (gap 10): Sonar→"continuing over White Noise";
  favorite→"delivering over the internet"; plain→"messages will wait" + Favorite
  button.
- Status chip + connectivity sheet (relay + mesh counts) — gap 12.
- Channel author block sheet (gap 15). Slash commands (gap 16). Message delivery
  state indicators (gap 17). Plain-language network labels (mirror iOS copy).
- **Verify:** screenshot + small unit tests for safety-number determinism [AV].

### Phase 7 — Notifications + App lock + Triple-tap wipe **[AV]**
- Local notifications (Android notification channel) for incoming DM / mention /
  payment (gap 5).
- App lock: BiometricPrompt gate on launch (gap 8).
- Triple-tap "sonar" title → wipe sheet → full wipe (identity, Marmot DB,
  message store, ledger, onboarding flag) — gap 18.
- **Verify:** wipe clears all stores (unit) [AV]; notification + biometric flows
  verified on emulator/device [AV, no second phone].

### Phase 8 — BLE mesh live GATT link **[HW]**
Scaffold (discovery, Noise handshake, framed records) exists + crypto/framing
unit-tested. This phase is on-air debugging.
- Bring up central↔peripheral Noise XX handshake over the characteristic;
  exchange BitchatPacket records; relay/flood with bloom dedup; verify against a
  stock bitchat client (compat oracle: bitchat-android or the Swift app).
- **Verify:** **[HW]** — requires 2 BLE phones (Pixel 8 + iPhone, or two
  Androids). Written on-device test plan; cannot be claimed done off a build.

### Phase 9 — Unify nearby payments BLE **[HW]**
Parsing/framing already ported + unit-tested.
- Payer: central connect → discover → READ/subscribe → reassemble offer → BIP321
  parse → `wallet.send`. Receiver: peripheral advertise service + serve framed
  `bitcoin:?lno=<offer>` via long-read; foreground-only.
- **Verify:** **[HW]** — needs a Unify device or a second Sonar phone. Framing/
  parse already [AV]; the BLE leg needs hardware. On-device test plan.

---

## Concrete /ship-able task sequence

Run in order; each is one PR. Bracketed tag = how far it can be verified here.

1. `/ship --write-plan implement Breez wallet bridge on Android (WalletBridge expect/actual, deterministic seed from Nostr identity, getInfo balance, BOLT12 createOffer, send, fiat rates), gitignored API key, money-display helper, Settings wallet section + currency picker` **[AV+⚡]**
2. `/ship wire ⚡PAY ledger to the Breez wallet on Android: scan Marmot+geohash transcripts, auto-claim → wallet.send → ⚡PAYDONE, render pay bubbles` **[AV+⚡]**
3. `/ship add encrypted message persistence on Android (hydrate+write-through mesh privateChats, channel timelines, pay ledger via SQLCipher blob store; survive restart; wipe clears it)` **[AV]**
4. `/ship implement Sonar Discovery 0x53 on Android (TLV announce codec npub+BIP-353+capabilities, Ed25519 sign/verify via FFI, radar Sonar badge, Profile BIP-353 field)` **[AV codec / HW on-air]**
5. `/ship add radar list-view toggle + peer card sheet + Sonar/Unify badges + RSSI signal bars on Android` **[AV]**
6. `/ship add Android UX sheets to match iOS: verify-safety-number, out-of-range routing banners, status chip + connectivity sheet, channel author block, slash commands, message delivery state` **[AV]**
7. `/ship add Android notifications (DM/mention/payment), app lock (BiometricPrompt), triple-tap title wipe` **[AV]**
8. `/ship --no-ci-wait bring up the live BLE mesh GATT link on Android (Noise XX over the characteristic, BitchatPacket relay+bloom dedup, verify vs stock bitchat)` **[HW]**
9. `/ship --no-ci-wait implement Unify nearby payments BLE on Android (payer central fetch + receiver peripheral serve)` **[HW]**

Tasks 1–7 are fully or substantially autonomously verifiable (build + unit/e2e +
screenshots; only the *settlement* leg of 1–2 needs funds). Tasks 8–9 are the
hardware-gated tail — implement + unit-test + write the on-device test plan, then
hand off for the 2-phone session.

## Open questions

- Breez seed: derive from the Nostr secret via a fixed HKDF (matching iOS
  `entropyProvider`) or persist an independent random seed linked to identity?
  iOS already chose derive-from-identity — confirm the exact KDF/salt so the same
  identity yields the same wallet on both platforms. (Non-blocking; default to
  mirroring iOS.)
- Notification backend: plain Android `NotificationManager` is enough for parity
  (iOS uses local notifications, no push) — confirm no FCM is expected.
- App lock: BiometricPrompt with device-credential fallback — confirm parity with
  iOS Face ID / passcode behavior (timeout, when re-prompted).

---

Next: `/ship --from-brainstorm docs/brainstorms/2026-06-13-android-ios-parity.md`
(starts at task 1 — the Breez wallet bridge).
