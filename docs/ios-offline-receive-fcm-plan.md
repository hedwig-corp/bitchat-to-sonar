# iOS Offline Receive — switch Breez push to FCM (the official path)

## Why
Breez's reference NDS (`breez/notify`, what `sonar-breez-nds` runs) is **FCM-only** (confirmed in
Breez docs + source). The official flow for **both** platforms is:

```
app (Firebase FCM token) → registerWebhook(.../api/v1/notify?platform=ios&token=<FCM>)
  → Breez swap server POSTs the webhook when the wallet is offline
  → breez/notify sends an FCM message
  → Firebase delivers to iOS via APNs (using the .p8 uploaded to the Firebase Console)
  → iOS launches the Notification Service Extension → answers the invoice_request
```

Sonar **Android** and **Unify (iOS)** both do exactly this. Sonar **iOS** is the only outlier:
it has no Firebase and registers a **raw APNs token**, which `breez/notify` (FCM) cannot deliver.
Result: the offline-wake push never reaches the device, the NSE never fires, the payer's
`bolt12/fetch` times out.

**The server (`breez-nds`) is correct as-is.** The fix is entirely client-side: make Sonar iOS
use Firebase/FCM for the Breez webhook, like Unify. The NSE + App Group we already built stay.

## Reference (proven working)
- Unify iOS: `ios/Wallet/UnifyWalletApp.swift` (FirebaseApp.configure, `Messaging.apnsToken`,
  `didReceiveRegistrationToken` → register FCM token), `ios/project.yml` (FirebaseMessaging pkg).
- Sonar Android: `apps/sonar/.../push/SonarPushRegistration.kt` (`FirebaseMessaging.getInstance().token`).

---

## Part A — Firebase Console (prerequisite; needs project owner)
The Sonar Firebase project already exists (Android uses it; `deploy/secrets/firebase.json` is its
service account). Add iOS to it:

1. Firebase Console → the **Sonar** project → **Add app → iOS**.
2. iOS bundle ID: **`sh.hedwig.sonar`**. Register it.
3. Download the generated **`GoogleService-Info.plist`** → hand it to me (it goes in `ios/bitchat/`,
   gitignored like the other secrets).
4. Project Settings → **Cloud Messaging** → under the iOS app → **APNs Authentication Key**:
   upload **`deploy/secrets/apns.p8`**, Key ID **`PX84KR34WH`**, Team ID **`ZQB239SHCM`**.

Without step 3 the app can't initialize Firebase; without step 4 FCM can't reach iOS.

---

## Part B — iOS code (I implement; 1:1 with Unify)
1. **Add the Firebase SPM package** to `ios/bitchat.xcodeproj`: `firebase-ios-sdk` (majorVersion 11),
   link product **`FirebaseMessaging`** to the `bitchat_iOS` target. (Same gem-script approach used
   to add BreezSDKLiquid; `FirebaseMessaging` pulls `FirebaseCore`.)
2. **Add `GoogleService-Info.plist`** to the `bitchat_iOS` target (from Part A.3), and add it to
   `.gitignore`.
3. **AppDelegate** (`ios/bitchat/BitchatApp.swift:242`):
   - `import FirebaseCore`, `import FirebaseMessaging`; conform to `MessagingDelegate`.
   - On launch: `FirebaseApp.configure()` + `Messaging.messaging().delegate = self`.
   - In `didRegisterForRemoteNotificationsWithDeviceToken` (line 251): add
     `Messaging.messaging().apnsToken = deviceToken` **and keep** the existing
     `SonarPushRegistration.shared.didRegisterForRemoteNotifications(...)` (Transponder still uses
     the raw APNs token).
   - Add `messaging(_:didReceiveRegistrationToken:)` → forward the **FCM token** to
     `SonarPushRegistration`.
4. **`SonarPushRegistration.swift`**:
   - Split the two channels: **Transponder** keeps the **APNs** token (unchanged);
     **Breez NDS** uses the **FCM** token.
   - Change `registerBreezWebhook` to take the FCM token string and build
     `\(ndsUrl)/api/v1/notify?platform=ios&token=<FCM_TOKEN>`; trigger it from the new FCM-token
     callback (and on wallet-ready, like today via `retryBreezWebhookIfNeeded`).
5. **Disable Firebase method swizzling** to avoid it hijacking the Transponder's APNs push handling:
   set `FirebaseAppDelegateProxyEnabled = NO` in `ios/bitchat/Info.plist`, and keep forwarding
   pushes through the existing `didReceiveRemoteNotification` → `SonarPushProcessor` routing
   (already branches breez vs marmot).
6. **NSE: no change** — `SonarNotificationService` already connects Breez from the App Group and
   answers the invoice_request; the FCM→APNs push is what triggers it.

## Part C — build, deploy, verify
1. Build `bitchat (iOS)` (resolves Firebase), install on the iPhone.
2. Confirm at launch: Firebase configures, an **FCM token** is obtained, and
   `Breez NDS webhook registered` now uses `token=<FCM token>` (not the APNs hex).
3. **Offline test:** force-quit the iPhone app → pay it from macOS → expect on the iPhone:
   `apsd` push for `sh.hedwig.sonar` → `NSE: didReceive` → `getConnectRequest -> creds OK` →
   Breez answers the invoice → macOS `bolt12/fetch` returns an invoice (no `TimedOut`).
4. Cross-check `sonar-breez-nds` logs on the `65` box: a real `POST /api/v1/notify` arrives and a
   push is sent (no more 400 / no more idle).

## Gotchas / risks
- **FCM token vs APNs token**: the Breez webhook MUST get the FCM token; the Transponder MUST keep
  the APNs token. Don't cross them.
- **Swizzling**: Firebase swizzles the app delegate by default; disabling it (step B.5) keeps the
  Transponder path intact — verify chat pushes still work after the change.
- **mutable-content**: the NSE only fires for `mutable-content` pushes. `breez/notify`'s FCM message
  for iOS must set the APNs `mutable-content` flag — Unify proves it does; verify in the test.
- **Build size**: Firebase is a large dependency; acceptable, Android already ships it.
- **`breez-nds` health check** is cosmetically failing (HEAD probe → 404); not functional, but worth
  fixing the healthcheck to a POST or `/` 200 separately.

## Already done (no change needed)
- NSE target + App Group + Breez working-dir move (shipped).
- `breez-nds` (FCM) on the `65` box — correct; just needs real traffic once iOS sends FCM tokens.

---

## ROOT CAUSE of "swap server never POSTs the webhook" (found 2026-06-24)
Even after the FCM client fix landed and the iOS app registered the Breez webhook with the FCM
token, **`breez-nds` received zero `POST /api/v1/notify`** — the Boltz/Breez swap server never
called the webhook. Verified on the box: only health-check GETs; `firebase.json` is the right
project (`sonarchat-11566`); `NOTIFY_EXTERNAL_URL=https://nds.sonar.hedwig.sh`.

**Why (sourced from breez-sdk-liquid):** the webhook is bound to **each BOLT12 offer**, captured at
**offer-creation time** on the Boltz server (`sdk.rs create_bolt12_offer` snapshots
`get_webhook_url()` and POSTs the offer to Boltz `POST /v2/lightning/BTC/bolt12` with `url=`).
Boltz then delivers an `invoice.request` to the offer owner over **one of two transports**:
WebSocket (online) **or** the per-offer webhook (offline). `registerWebhook()` alone is NOT enough —
it only re-PATCHes offers already in the SDK's **local `bolt12_offers` DB** whose stored URL differs
(`sdk.rs register_webhook`). Boltz requires **HTTPS** webhook URLs (ours is).

So for Sonar the offer the payer hits has **`url=None` (or stale)** on Boltz → Boltz only tries the
dead WS path when the wallet is offline → no POST → `bolt12/fetch` times out. Confirmed by the iPhone
SDK logs showing the offer being *prepared/subscribed* but **no `update_bolt12_offer` / PATCH** to
write our webhook onto it. (SDK version 0.11.13 has the feature — BOLT12-receive commit #882 predates
it — so this is not a version gap; `createBolt12Offer` is internal, reached via
`receivePayment(.bolt12Offer)`.)

**Fix applied (hypothesis — needs a device retest):** after `registerWebhook(FCM)` succeeds, re-create
the stable receive offer once per webhook URL (`SonarPushRegistration.registerBreezWebhook` →
`wallet.createOffer()`), so Boltz captures the current webhook on the offer.

**If that doesn't take:** (a) verify the offer's `url` on Boltz / the SDK's local `bolt12_offers.webhook_url`
(my App-Group working-dir migration could have dropped the local offer row → `registerWebhook` can't
PATCH it); (b) ensure `registerWebhook` runs *before* the offer is created; (c) consider bumping the
SDK 0.11.13 → 0.12.4 (cross-platform — Android/desktop KMP pin must move too) for BOLT12 fixes.
