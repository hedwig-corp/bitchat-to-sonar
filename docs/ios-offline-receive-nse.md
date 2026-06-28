# iOS Offline Receive — Breez Notification Service Extension (issue #65)

## Problem
Paying a Sonar contact's BOLT12 offer requires the recipient **online**, holding its Breez
swap WebSocket open to answer the `invoice_request`. When the recipient app is
backgrounded/killed, the payer's `POST …/v2/lightning/BTC/bolt12/fetch` **times out**
("Could not contact servers"). Verified live 2026-06-23: online recipient (macOS) succeeds;
offline recipients (Conor/Sara) time out.

The Breez NDS push infra exists (`nds.sonar.hedwig.sh`, healthy) but the **consumption side
is a stub**: `SonarPushProcessor.processBreezWakeup` no-ops unless the wallet is already
running, and there is **no Notification Service Extension** (only `bitchatShareExtension`).
So nothing wakes the SDK to answer when the app is closed.

## Reference
`hedwig-corp/unify-wallet` (works). Its `ios/NotificationService/NotificationService.swift`
subclasses Breez's `SDKNotificationService` and overrides `getConnectRequest()`; an App Group
shares creds + the Breez working dir. We port that pattern (Sonar uses a raw **seed**, not a
mnemonic).

## Push-type strategy
| Channel | Server | Push type | UX |
|---|---|---|---|
| Breez wallet (incoming pay / `invoice_request`) | `breez/notify` NDS | `mutable-content` → NSE | **Silent** — NSE answers in background; `InvoiceRequestTask` only notifies on failure |
| Sonar chat/calls | Transponder (Marmot) | visible alert | the Sonar message notification |

iOS constraint: a pure silent (`content-available`) push **cannot** wake a force-quit app;
only `mutable-content` launches the NSE. "Silent for Breez" = the NSE draws no banner on
success (already true for `InvoiceRequestTask`); the "you got paid" notice arrives via the
Sonar ⚡PAY message on the visible Transponder channel. The NDS already runs Breez's official
`github.com/breez/notify` image (`deploy/breez-nds`), which emits the correct `mutable-content`
payload — **no server change needed**.

## Implementation (this change)
1. **Working dir → App Group container.** `SonarWallet.configure()` now uses
   `group.sh.hedwig.sonar` container `/breez-sdk/<mainnet|testnet>` (was per-app
   `Application Support/sonar-wallet`), with one-time migration. App + NSE share Breez state.
2. **Cred mirroring.** On node start the app writes `breez_api_key`, `breez_seed_hex`,
   `breez_mainnet` into App Group `UserDefaults(suiteName: group.sh.hedwig.sonar)` so the NSE
   can connect in its own process. (Seed in App Group defaults matches Unify; hardening to a
   shared Keychain access group is a tracked follow-up.)
3. **NSE target** `SonarNotificationService` (`ios/SonarNotificationService/`): standalone,
   links `BreezSDKLiquid` (0.12.4), subclasses `SDKNotificationService`, builds a
   `ConnectRequest(config:, mnemonic: nil, seed:)`, `config.syncServiceUrl = nil`.
4. **Entitlements/capabilities:** App Group on app + NSE; `aps-environment`. Added to the
   project via the `xcodeproj` gem (objv90-safe round-trip verified).

## Test (iPhone ⇆ macOS)
1. Build/deploy both. Verify online→online still pays (regression).
2. **Kill** the iPhone Sonar app. From the macOS wallet, pay the iPhone's offer.
3. Expect: NSE wakes (logs as process `SonarNotificationService`), `bolt12/fetch` on the payer
   returns an invoice (not `TimedOut`), payment settles, **no Breez banner**, Sonar message
   notification appears.

## Risks / follow-ups
- **Provisioning:** App Group + new NSE need profiles (automatic signing, team ZQB239SHCM,
  `-allowProvisioningUpdates`); the App Group id may need portal registration.
- **NSE memory (~24 MB)** and **~30 s** budget vs the payer's ~36 s `bolt12/fetch` window.
- **Two-process SQLite** (app + NSE on the shared Breez dir) — Breez's `BreezSDKLiquidConnector`
  is designed for it; verify no lock errors; NSE must link the same SQLCipher.
- **Harden seed storage** to a shared Keychain access group (currently App Group UserDefaults).
- **Android/macOS parity** (CLAUDE.md): Android needs the equivalent FCM notification service;
  macOS has no background-APNs NSE → platform gap.
- Upstream bug seen on receive: `Invalid RevSwapState … transaction.direct` (non-fatal).
