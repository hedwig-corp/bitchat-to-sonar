# How Notifications Work on Every Supported Device

One-page map of Sonar's notification delivery per platform. For the full
architecture (servers, privacy model, local router, copy rules) see
[`SONAR-NOTIFICATIONS.md`](SONAR-NOTIFICATIONS.md); for the GrapheneOS
specifics see [`GRAPHENEOS.md`](GRAPHENEOS.md).

## The two servers + the local router

- **Transponder** (chat/call wakeups): the sender's device MIP-05-encrypts each
  recipient's push credential and publishes a kind-446 request after every
  send; the transponder decrypts the credential and forwards a plaintext-free
  wake to the platform push network. All user-visible copy is rendered
  **locally** on the receiving device.
- **Breez NDS** (wallet wakeups): a webhook the Boltz swap server calls to wake
  the wallet for BOLT12 receive/swaps. Always silent — the user-visible payment
  notification comes later through the chat path (`⚡PAY`).
- **Local notification router**: while the process is alive (foreground or BLE
  mesh), notifications are entirely local — no server involved.

## Matrix

| Surface | Process alive (local) | Chat/call wake (killed app) | Wallet wake (killed app) | Notes |
| --- | --- | --- | --- | --- |
| **iOS / macOS (`ios/`)** | Local notification router | APNs (visible, `mutable-content: 1`) → NSE renders generic copy; app fetches Marmot messages on open/wake | APNs silent push via Breez NDS (needs `GoogleService-Info.plist` → FCM→APNs bridge for the Breez path) | Two transponder instances: production + sandbox APNs gateways |
| **Android with Play Services (`apps/sonar/`)** | Local notification router | FCM data-only push → `SonarPushProcessingService` (dataSync FG service) drains relays, renders real copy | FCM data push (`notification_type`) → silent Breez wallet sync | Includes **GrapheneOS with sandboxed Play** — FCM works there; exempt Play Services from battery optimization for low latency |
| **Android degoogled / GrapheneOS without Play** | Local notification router | **UnifiedPush**: distributor (e.g. ntfy) endpoint registered as MIP-05 `platform = "unifiedpush"`; wake funnels into the same drain service. *Pending upstream transponder support for platform `0x03` — until deployed, no background chat wakeups.* | **Gap**: Breez NDS speaks FCM only — no offline BOLT12 receive while killed. Candidate fix: register the UnifiedPush endpoint directly as the Boltz webhook | Transport status is visible in Settings → Diagnostics ("Push transport: …") |
| **Android, no Play and no distributor** | Local notification router | None — explicit "none" state in Diagnostics; messages arrive when the app is opened (foreground sync) | None | Honest degrade, never silent |
| **Desktop (JVM)** | Local/tray only (issue #54) | None | None | No remote push by design; `Notifier.pushTransportStatus()` returns null |

## Registration paths (who registers what, when)

- **iOS**: APNs device token → Rust core `register_push_token("apns", …)`;
  Breez webhook = NDS URL + FCM token minted through Firebase (hence the
  `GoogleService-Info.plist` build requirement).
- **Android FCM**: `SonarPushRegistration.ensureRegistered()` (app start,
  post-onboarding, settings toggle) → Firebase token →
  `register_push_token("fcm", …)` + Breez webhook
  `https://<nds>/api/v1/notify?platform=android&token=<fcm>`.
- **Android UnifiedPush**: same entry point; transport chosen by
  `PushTransportPolicy` (FCM preferred whenever Play Services responds, incl.
  sandboxed Play). Distributor endpoint arrives async at
  `SonarUnifiedPushService.onNewEndpoint` → `register_push_token("unifiedpush",
  endpoint)`.

## Platform bytes (MIP-05 wire format — protocol constants, never renumber)

| Platform string | Byte | Token payload |
| --- | --- | --- |
| `apns` | `0x01` | raw APNs device token |
| `fcm` | `0x02` | UTF-8 FCM token string |
| `unifiedpush` | `0x03` | UTF-8 distributor endpoint URL |

Pinned by `core/sonar-core/src/push.rs` test
`platform_byte_accepts_known_platforms_only`.

## Cross-platform gaps (tracked)

1. **Upstream transponder** (`marmot-protocol/transponder`) does not yet POST
   to `unifiedpush` endpoints — required for degoogled chat wakeups.
2. **Breez NDS degoogled path** — evaluate registering the UnifiedPush endpoint
   directly as the Boltz webhook (bypasses NDS; needs a payload experiment).
3. **iOS** is APNs-only by platform design — UnifiedPush does not exist there;
   this is a documented platform limitation, not a missing feature.
4. **Multiple distributors installed, none chosen**: Sonar auto-picks the first
   deterministically; an in-app picker is a follow-up.
