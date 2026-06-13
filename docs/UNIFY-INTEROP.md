# Unify nearby-payments interop (bidirectional)

Ad-hoc **Unify Wallet** payments over Bluetooth, payments-only (no chat).
Sonar plays BOTH Unify roles, so payments flow in both directions with no
changes on Unify's side:

- **Payer** (GATT central) — Sonar scans for Unify receivers and pays them.
  See "Payer flow" below.
- **Receiver** (GATT peripheral) — Sonar advertises the Unify service and
  serves a framed BIP321 offer so a **Unify user can pay a Sonar user**. See
  "Receiver flow" below.

After this feature, Sonar's radar shows three kinds of nearby people:

- **bitchat** — chat only, no badge.
- **Sonar** — chat + payments, indigo Sonar badge.
- **Unify** — payments only, gold Unify badge. Tapping offers ONLY "Send sats".

This is the near-term ad-hoc precursor to the long-term unified discovery
protocol tracked in **issue #2**. We do NOT converge protocols here: Unify
detection runs on its own BLE stack, completely isolated from the wire-critical
mesh `BLEService`, and never touches chat.

## Source of truth

The wire contract is owned by Unify and mirrored here byte-for-byte. The
canonical Kotlin is in the unify-wallet repo:

- `libs/nearby-payments/.../NearbyPaymentContract.kt` — UUIDs, sizes, name rules.
- `libs/nearby-payments/.../NearbyPaymentFraming.kt` — the chunk framing.

If Unify bumps `PROTOCOL_VERSION` (currently **2**) or changes the framing,
re-mirror `UnifyNearbyContract` / `UnifyNearbyFraming` in
`bitchat/Services/UnifyNearbyService.swift`.

## Roles

Unify models the person **getting paid** as the GATT **peripheral** (the
*receiver*): it advertises the service and serves a BIP321 `bitcoin:` URI from a
payload characteristic. The **payer** is the GATT **central**: it scans, connects,
reads the chunked payload, reassembles the URI, and pays it.

Sonar plays BOTH roles (two separate, isolated services — see "Receiver flow"),
and never chats with Unify peers in either direction.

## UUIDs and sizes (UnifyNearbyContract)

| Constant | Value |
| --- | --- |
| Service UUID | `b1f7e2a0-9c3d-4e8a-bf21-3a1c0de54f10` |
| Payload characteristic | `b1f7e2a1-9c3d-4e8a-bf21-3a1c0de54f10` (READ + NOTIFY) |
| Default max chunk size | 180 bytes |
| Max payload | 8 KB (bounds the reassembly buffer) |
| Protocol version | 2 |
| Default display name | "Unify user" |
| Name manufacturer id | `0xFFFF` (SIG "no registered company") |

## Display name

v2 receivers advertise a human display name in the scan response:

- **iOS receiver:** in the BLE local name (`CBAdvertisementDataLocalNameKey`).
- **Android receiver:** in manufacturer-specific data under company id `0xFFFF`
  (2-byte little-endian company id followed by the UTF-8 name bytes).

Our payer resolves the name in this precedence: **local name, then manufacturer
0xFFFF data, then the default "Unify user"** (`UnifyNearbyService.advertisedName`).
Both candidates pass through `UnifyNearbyContract.sanitizeAdvertisedName`
(replace control chars with spaces, collapse whitespace, trim, truncate to 20
UTF-8 bytes on a codepoint boundary) so they look identical to the value the
receiver put on the air.

When Sonar is the **receiver**, it advertises its name in the BLE local name
(`CBAdvertisementDataLocalNameKey`), like any iOS receiver — see below.

## Framing (UnifyNearbyFraming — mirror of NearbyPaymentFraming.kt)

A single UTF-8 payload is sent length-prefixed:

```
[ 4-byte big-endian length ][ UTF-8 payload bytes ]
```

The stream is then split into ≤180-byte chunks for the NOTIFY transport; chunk
boundaries carry no meaning. The `Reassembler` concatenates incoming chunks and
is done once it has `4 + length` bytes. The same framed blob is also returned by
a GATT long READ (CoreBluetooth coalesces offset reads into one value delivery),
so the same reassembler decodes both transports.

Safety: the reassembler caps the buffer at `4 + 8 KB` and rejects a declared
length out of range or a stream that overruns the declared length, so a
malicious peer cannot exhaust memory or desync us.

## BIP321 parse (UnifyBIP321)

BIP321 is the successor to BIP21; the `lightning=` query param carries a BOLT11
invoice or a BOLT12 offer. Sonar is Lightning-first (no on-chain send path), so
we extract a payable Lightning destination in this order:

1. A bare Lightning string with no scheme — `lno1…` (BOLT12) or
   `lnbc…`/`lntb…`/`lnbcrt…`/`lnsb…` (BOLT11), case-insensitive.
2. `lightning:lno1…` — bare Lightning scheme.
3. `bitcoin:<addr>?...&lightning=<bolt11|lno…>&amount=<btc>` — BIP321 URI. We
   read the `lightning` param (tolerating `lno`/`b12` aliases). If `amount=`
   (decimal BTC) is present we convert it to sats and pay directly; otherwise we
   prompt for an amount on the keypad.

An on-chain-only `bitcoin:<addr>` with no Lightning leg returns `nil` (we cannot
pay it), and the user sees "No Lightning payment was offered."

## Payer flow (UnifyNearbyService)

`UnifyNearbyService` is a `@MainActor ObservableObject`, **no singleton**
(constructed by `SonarAppStore`), owning its **own `CBCentralManager`** on a
dedicated queue — fully isolated from the mesh `BLEService` central.

- **Scan:** `start()` scans for `[serviceUUID]` (allowing duplicates so RSSI and
  liveness refresh). On `didDiscover` it records a `UnifyPeer { id, name, rssi,
  lastSeen }` and publishes `@Published var peers`. Stale peers (not seen for
  20 s) are pruned by a timer. **It never connects on discovery — presence only.**
- **Fetch:** `fetchPaymentURI(_:) async throws -> String` connects to the chosen
  peripheral, discovers the service + payload characteristic, subscribes to
  NOTIFY and issues a READ, feeds each value to the reassembler until the framed
  payload is complete (or `MAX_PAYLOAD_BYTES`), disconnects, and returns the URI.
  Robust 15 s timeout; one fetch at a time; the peripheral is retained while
  connected and `didDisconnect`/`didFailToConnect` resolve the in-flight fetch.
- **Permission:** reuses the app's existing Bluetooth permission (already granted
  for the mesh); the central is created with `ShowPowerAlert=false`. Scanning
  starts when the central powers on.

## Pay path (SonarAppStore)

Unify peers merge into the radar/nearby model as `SNPeerItem`s flagged
`unify: true` (alongside the existing `sonar` flag), id = `unify:<peripheralId>`.
They sit on the radar's outer ring (out-of-mesh) with a gold badge and a
"Unify · pay only" label; they never appear in Messages/DM.

Tap → `sendSatsToUnify(id)`:
1. Gate on a ready wallet (`WalletBridgeService` via `BridgedWallet`). If the
   wallet isn't ready, the peer still shows but the sheet says to set it up.
2. `unify.fetchPaymentURI` → `UnifyBIP321.parse`.
3. If the URI carried an amount, pay directly; else show the amount keypad.
4. `WalletBridgeService.send(destination: <extracted offer>, amountSats:, note:)`.

This is a **direct Lightning send** to the receiver's served offer — NOT the
⚡PAY sealed-coin / Marmot chat path (that is chat-bound and Unify peers don't
chat).

## Receiver flow (UnifyReceiverService) — a Unify user pays a Sonar user

`UnifyReceiverService` is the mirror of `UnifyNearbyService`: a `@MainActor
ObservableObject`, **no singleton** (constructed by `SonarAppStore`), owning its
**own `CBPeripheralManager`** on a dedicated queue — isolated from the mesh
`BLEService` AND from the payer's central.

- **GATT service:** it builds service `b1f7e2a0…` with a single READ
  characteristic `b1f7e2a1…` (`CBMutableCharacteristic`, `.read`, permission
  `.readable`, dynamic value). The service is added exactly once, after the
  peripheral manager powers on.
- **Served value:** `frame("bitcoin:?lno=<offer>")` — the exact inverse of the
  payer's `Reassembler` (4-byte big-endian length + UTF-8 body). The offer is
  **amountless** (`bitcoin:?lno=<offer>` with no `amount=`); the Unify payer
  enters the sats. The framed blob is cached and rebuilt only when the offer
  changes.
- **Long reads:** `peripheralManager(_:didReceiveRead:)` returns
  `framedPayload.subdata(in: request.offset..<count)` with `.success`.
  CoreBluetooth chunks the response by the negotiated ATT MTU and calls us once
  per chunk with an increasing `request.offset`; the payer's central
  concatenates the slices back into the full framed blob. An offset past the end
  returns `.invalidOffset`.
- **Offer source:** injected `offerProvider: () async -> String?` →
  `SonarWalletProviding.createOffer()` (the iOS Breez wallet behind
  `WalletBridgeService`). The offer is fetched lazily when advertising starts
  (it can be slow/async); if no offer is available yet (wallet not ready) we do
  not advertise.
- **Advertised name:** injected `nameProvider: () -> String?` →
  `ChatViewModel.nickname`, sanitized + 20-byte-capped, fallback **"Sonar
  user"**. Carried in `CBAdvertisementDataLocalNameKey`.
- **Lifecycle (always payable, foreground-only):** `SonarAppStore` starts the
  receiver iff the wallet is `.ready` AND the app is foreground, and stops it
  otherwise (`updateReceiverAdvertising()`), driven by the wallet state sink and
  `setForeground(_:)` from `BitchatApp`'s `scenePhase` (`.active` → resume,
  `.background` → stop). It also stops on panic wipe.

### iOS background-advertising caveat

iOS **strips the BLE local name and restricts service-UUID advertising while the
app is backgrounded** (service UUIDs move to a special "overflow" area only
discoverable by another iOS device explicitly scanning for them, and the local
name is dropped entirely). A Unify payer scanning by service UUID would not see
our name (and on Android may not see us at all). So receiver advertising is
**foreground-only by design** — it stops on `.background` and resumes on
`.active`. This is an accepted limitation for the demo (brainstorm 2026-06-12).

## Avatar distinctness (multiple Unify peers)

`SonarAvatar` gained an optional `seed:` parameter (defaults to the display
name). Unify `SNPeerItem`s set `avatarSeed` to the stable Unify peripheral id,
so two Unify users that share a display name (both "Unify user") still get a
distinct hue + identicon grid. The gold Unify badge and "Send sats"-only
behavior are unchanged.

## Platform note

CoreBluetooth central scanning is available on both iOS and macOS, so the real
implementation compiles on both. The feature is targeted at iOS (where the mesh
already holds the Bluetooth permission); on macOS it links and is harmless. A
no-op stub is provided for any future platform without CoreBluetooth.

## Panic wipe

`SonarAppStore.wipe()` calls `unify.stop()` (stops scanning + clears the
discovered-peer list) and `unifyReceiver.stop()` (stops advertising + drops the
cached framed offer). No secrets are stored by either service, but the
discovered list must not survive a wipe and the served offer is derived from the
wallet seed being wiped.
