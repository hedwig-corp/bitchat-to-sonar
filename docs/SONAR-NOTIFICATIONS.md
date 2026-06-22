# Sonar Notifications Plan

## Scope

Complete notification support for Sonar, covering both local (process-alive)
and remote (killed-app) delivery on the native Apple app (`ios/`) and the
Compose Multiplatform app (`apps/sonar/`). Desktop remains local/tray-only
(issue #54).

## Architecture Overview

Sonar uses **two** notification servers plus local processing:

| Layer | Server | Events | User-visible? |
| --- | --- | --- | --- |
| Chat/call wakeup | Transponder | DMs, groups, invites, calls, `⚡PAY` receipts | Yes -- local router renders all user-facing copy |
| Wallet wakeup | Breez NDS | BOLT12 receive, swap updates, LNURL-pay | No -- silent infrastructure only |
| Process-alive | (none) | BLE mesh, foreground events | Yes -- local router renders copy |

Both servers send silent/data-only pushes. The client wakes and processes
the event locally. The two servers have **different notification roles**:

- **Transponder** wakes are both infrastructure AND user-visible: the app
  fetches Marmot messages, and the local notification router renders
  "New Sonar message", "Payment received", "Incoming Sonar call", etc.
- **Breez NDS** wakes are **infrastructure only**: the push wakes the wallet
  to complete a BOLT12 receive or swap, but does NOT show a user-visible
  notification. The user-visible "Payment received" notification fires
  later, when the sender's `⚡PAY` control line arrives through the chat
  path (via transponder) and the local notification router processes it.

This avoids duplicate notifications: a single payment produces one
user-visible "Payment received", not two. The local notification router
owns all user-facing copy.

## Implementation Phases

### Phase 1: Local Notification Router (DONE)

Cross-platform notification policy for process-alive delivery.

- [x] Notification router on Compose that maps Sonar events to kinds:
      message, payment, call, invite, mention, geohash, network.
- [x] Mirror router on iOS (`SonarLocalNotificationRouter`).
- [x] Privacy-first defaults: names and previews hidden by default.
- [x] Distinct generic copy for payments and calls.
- [x] Foreground suppression: no OS notifications while app is active.
- [x] Unit tests for router classification and formatting.

Files:
- `apps/sonar/.../SonarNotificationRouter.kt` (Compose)
- `apps/sonar/.../SonarNotificationRouterTest.kt` (tests)
- `ios/bitchat/Views/Sonar/SonarAppStore.swift` (iOS mirror)
- `ios/bitchat/Services/NotificationService.swift` (generic copy)
- `apps/sonar/.../SonarAppState.kt` (integration)
- `apps/sonar/.../screens/SonarSettingsScreen.kt` (privacy defaults)

### Phase 2: Server Deployment

Deploy both notification servers. Full setup guide: [`deploy/README.md`](../deploy/README.md).

- [ ] Provision APNS credentials (Apple Developer portal): `.p8` key,
      key ID, team ID, bundle ID.
- [ ] Provision FCM credentials (Firebase Console): service account JSON.
      Shared by both servers.
- [ ] Generate transponder server keypair; publish npub in Sonar build
      config so clients can encrypt tokens to it.
- [ ] Fill `deploy/transponder/config/production.toml` with APNS/FCM fields.
- [ ] Fill `deploy/.env` with `NOTIFY_EXTERNAL_URL`.
- [ ] Place secrets in `deploy/secrets/`.
- [ ] `cd deploy && docker compose up -d` — starts both servers.
- [ ] Verify transponder subscribes to Sonar's Nostr relays and dispatches
      silent pushes.
- [ ] Verify NDS receives webhook POSTs and dispatches silent pushes.

### Phase 3: iOS Remote Push

Wire the iOS app to both servers. Full guide: [`docs/ios-push-integration.md`](ios-push-integration.md).

- [x] Enable Push Notifications and Background Modes (remote-notification)
      entitlements in the app target. Added `aps-environment` to entitlements,
      `remote-notification` to UIBackgroundModes in Info.plist.
- [ ] Add a Notification Service Extension target that shares an App Group
      and keychain access group with the main app. **Deferred**: requires
      Xcode target creation; current implementation uses AppDelegate
      `didReceiveRemoteNotification` with background fetch for the 30s window.
- [ ] Move encrypted Marmot data needed by the extension into the App Group
      container without destructive migrations.
- [x] Register for APNS in `AppDelegate`, collect the raw device token.
      `SonarPushRegistration` receives and caches the APNS token.
- [ ] Implement MIP-05 token encryption: ECDH + HKDF-SHA256
      (`salt=mip05-v1`, `info=mip05-token-encryption`) + ChaCha20-Poly1305.
      **Blocked on core FFI** (same as Android).
- [x] Register Breez SDK webhook on startup. Added `registerWebhook(url:)`
      and `unregisterWebhook()` to `SonarWallet` and `WalletBridgeService`.
      `SonarPushRegistration` registers the webhook, `SonarAppStore` retries
      when wallet reaches `.ready`.
- [x] Push processing: `SonarPushProcessor` handles Marmot and Breez pushes
      from AppDelegate's background fetch handler. Marmot path calls
      `MarmotChatModel.refresh()` with 20s timeout and falls back to
      generic notification. Breez path is silent.
- [x] Provider payloads are plaintext-free. The app, not the push server,
      decides user-visible copy.
- [ ] Support push registration disable and token deletion in settings.
      **Depends on iOS settings screen rework** (current settings screen
      is hidden/incomplete).

### Phase 4: Android Remote Push

Wire the Compose app to both servers. Full guide: [`docs/android-push-integration.md`](android-push-integration.md).

- [x] Add `firebase-messaging` dependency (token collection and wakeup only).
      Add `google-services.json` to gitignore; use CI secret or local config.
- [x] `POST_NOTIFICATIONS` permission already declared (Android 13+).
- [x] FCM token collection and push registration wired into app startup
      (`SonarPushRegistration`).
- [x] FCM service dispatches transponder vs Breez pushes
      (`SonarFirebaseMessagingService`).
- [x] Foreground service for processing push wakeups
      (`SonarPushProcessingService`). Transponder path renders user-visible
      notification; Breez path is silent.
- [x] Build config reads `TRANSPONDER_NPUB` and `NDS_URL` from
      `local.properties` (gitignored).
- [x] Breez SDK `registerWebhook()` wired into `SonarPushRegistration`
      via new `WalletBridge.registerWebhook(url)` expect/actual method.
- [x] Marmot message sync wired into `SonarPushProcessingService`: starts
      SonarCore, syncs relays, reads unread conversation summaries,
      classifies each via `SonarNotificationRouter`, fires user-visible
      notifications. Falls back to generic notification on error.
- [x] Breez wakeup path starts wallet SDK if needed, refreshes balance,
      stays silent (no user-visible notification).
- [ ] Implement MIP-05 token encryption for transponder registration.
      **Blocked on core FFI**: needs `SonarNode::register_push_token(token,
      server_npub)` exposed via UniFFI — the ECDH + NIP-59 gift-wrap is
      best done in Rust where the Nostr crypto already lives.
- [x] Push registration disable in settings: "Background push" toggle in
      Compose NotifSheet calls `Notifier.setPushEnabled()` which
      registers/unregisters push tokens via `SonarPushRegistration`.

### Phase 5: End-to-End Verification

- [ ] Verify killed-app DM wakeup on both platforms (transponder path).
- [ ] Verify killed-app BOLT12 receive on both platforms (Breez NDS path).
- [ ] Verify one payment = one user-visible notification (no duplicates).
- [ ] Verify privacy defaults: no names or previews leak through push.
- [ ] Verify foreground suppression still works with remote pushes.
- [ ] Verify token rotation: unregister old token, register new one.
- [ ] Load test transponder with concurrent gift wraps.

## Transponder Details

Sonar deploys its own instance of
[transponder](https://github.com/marmot-protocol/transponder), the open-source
MIP-05 push notification server from the Marmot project. White Noise cannot
run Sonar's bundle ID on their server -- Apple requires each app to use its own
APNS credentials -- so Sonar must own the deployment and keys.

Transponder is stateless: no database, no stored tokens or user data. It
subscribes to Nostr relays for `kind:1059` gift-wrapped events addressed to
its public key, unwraps them to extract `kind:446` notification requests
containing encrypted provider tokens (MIP-05 spec), and dispatches silent
pushes to APNS/FCM. Push payloads are plaintext-free -- the client wakes,
fetches messages from relays, and builds notifications locally through the
notification router.

### MIP-05 Token Encryption

Clients encrypt their APNS/FCM device tokens to the transponder's secp256k1
public key using ECDH + HKDF-SHA256 (`salt=mip05-v1`, `info=mip05-token-encryption`)
+ ChaCha20-Poly1305. The 1024-byte plaintext is: platform byte (`0x01` APNS,
`0x02` FCM) + 2-byte token length + token bytes + random padding. The
encrypted 1084-byte blobs are concatenated, base64-encoded, and published
inside a NIP-59 gift wrap addressed to the server's npub.

### Deployment

See [`deploy/README.md`](../deploy/README.md) for the full setup guide.
Both servers are managed by a single `deploy/compose.yml`.

Transponder includes built-in rate limiting (per encrypted token and per device
token), NIP-59 replay protection, and structured logging. Production sizing:
2 vCPU / 4 GB RAM.

### Relay Configuration

The transponder subscribes to the same relays Sonar clients publish to. Start
with the relays already trusted for Marmot traffic. Add operational fallback
relays if needed. Tor relay support is available via the `--features tor`
build flag.

### Key Rotation

A server key rotation requires:
1. Generate a new keypair.
2. Roll the new public key into Sonar's build configuration.
3. Ship a client update so new token registrations encrypt to the new key.
4. Run both old and new transponder instances in parallel until existing
   token registrations expire or are re-shared.
5. Decommission the old instance.

## Breez NDS Details

Sonar deploys its own instance of [breez/notify](https://github.com/breez/notify)
to handle payment wakeups. This is a Go HTTP service that receives webhook
POSTs from Breez swap/LNURL services and forwards them as FCM/APNS pushes.

### How it works

1. The Sonar app registers a webhook URL with the Breez SDK on startup:
   `sdk.registerWebhook("https://<nds-host>/api/v1/notify?platform=<ios|android>&token=<FCM_TOKEN>")`
2. When a payment event occurs (BOLT12 offer received, swap status change,
   LNURL-pay invoice), the Breez service POSTs to the registered webhook URL.
3. The NDS parses `platform` and `token` from query params, builds a push
   from the event template, and dispatches via FCM.
4. The app wakes, the Breez SDK Notification Plugin processes the event
   (starts the wallet, completes the BOLT12 receive). **No user-visible
   notification is shown.** The user-visible "Payment received" comes
   later when the sender's `⚡PAY` control line arrives through the
   transponder/chat path.

### NDS event templates

| Template | Trigger |
| --- | --- |
| `payment_received` | Incoming payment completed |
| `swap_updated` | Swap status changed (pending, confirmed, etc.) |
| `tx_confirmed` | On-chain transaction confirmed |
| `lnurlpay_invoice` | LNURL-pay invoice received |
| `invoice_request` | BOLT12 invoice request (offer flow) |

### Deployment

See [`deploy/README.md`](../deploy/README.md) for the full setup guide.
Both servers are managed by a single `deploy/compose.yml`. The NDS is
stateless and shares the same Firebase project as the transponder.
Production sizing: 1 vCPU / 512 MB RAM.

## What Stays Local-Only

- BLE mesh DMs, calls, and payments -- no server visibility.
- Unify nearby payments -- Bluetooth-only.
- Geohash public channels -- needs a separate privacy/noise design.
- Desktop -- tracked by issue #54.

## Alternative: Backend Wallet (Lexe)

A backend wallet such as Lexe can receive BOLT12 payments without a device
wakeup since the wallet runs server-side. If Sonar supports Lexe as an
alternative backend, the Breez NDS becomes optional for users who choose
that configuration. Track this alternative under issue #65.

## Complete Notification Matrix

| Feature | Server | User-visible? | Platform |
| --- | --- | --- | --- |
| Marmot DMs/groups/invites | Transponder | Yes -- "New Sonar message" | iOS, Android |
| Marmot call offer | Transponder | Yes -- "Incoming Sonar call" | iOS, Android |
| Marmot payment receipt (`⚡PAY`) | Transponder | Yes -- "Payment received" | iOS, Android |
| BOLT12 receive (wallet settle) | Breez NDS | No -- silent wakeup | iOS, Android |
| Swap updates | Breez NDS | No -- silent wakeup | iOS, Android |
| LNURL-pay invoice | Breez NDS | No -- silent wakeup | iOS, Android |
| BLE mesh DMs/calls/payments | None | Yes -- local router | iOS, Android, Desktop |
| Geohash public channels | None | Yes -- local router | iOS, Android, Desktop |
| Desktop background | None | Local tray only | Desktop (issue #54) |

## Production Readiness Gates

- [ ] Local router behavior is covered by unit tests on Compose common code.
- [ ] Apple and Compose use equivalent copy and default privacy behavior.
- [ ] No plaintext message content is sent through provider push.
- [ ] Mobile push registration can be disabled and token deletion is supported.
- [ ] Remote push is observable without logging message contents or raw tokens.
- [ ] BOLT12 receive flow works within the iOS extension timeout (issue #65).
- [ ] One payment = one user-visible notification (dedup verified).
- [ ] Each platform limitation is linked to a tracked issue before merge.
