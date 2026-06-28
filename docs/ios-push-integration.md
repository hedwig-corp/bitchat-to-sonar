# iOS Remote Push Integration Guide

> **Note:** This was a planning document written before implementation. The
> actual code differs — MIP-05 crypto and token registration are handled
> entirely in Rust core via FFI, not in Swift. Code blocks with `// TODO`
> comments reflect the original plan, not the shipped implementation. See the
> actual source in `ios/bitchat/Services/` for current code.

Step-by-step guide for wiring the iOS Sonar app to both notification servers
(transponder for chat/calls, Breez NDS for wallet wakeups).

## Prerequisites

- Sonar notification servers deployed and running (see `deploy/README.md`)
- The transponder's **npub** (Nostr public key) — generated during server setup
- APNS credentials configured on the transponder
- Xcode project: `ios/bitchat.xcodeproj`

## 1. Enable Entitlements

Add push notification and background mode entitlements to the main app target.

**ios/bitchat/bitchat.entitlements** — add:

```xml
<key>aps-environment</key>
<string>production</string>
```

**Xcode Capabilities** (main target):
- Enable **Push Notifications**
- Enable **Background Modes** → check **Remote notifications**

The app already has `com.apple.security.application-groups` configured
with `$(APP_GROUP_ID)`. The Notification Service Extension will share this
group.

## 2. Create the Notification Service Extension

Add a new target: **File > New > Target > Notification Service Extension**.
Name it `SonarNotificationService`.

Configure the extension:
- Same **App Group** as the main app (`group.chat.bitchat.sonar` or
  whatever `$(APP_GROUP_ID)` resolves to)
- Same **Keychain Access Group** as the main app (needed for Breez wallet
  keys)
- Set `SONAR_TRANSPONDER_NPUB` in the extension's build settings or
  `Info.plist` so it knows which public key to validate pushes against

**Extension entitlements** (`SonarNotificationService.entitlements`):

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>$(APP_GROUP_ID)</string>
</array>
<key>keychain-access-groups</key>
<array>
    <string>$(AppIdentifierPrefix)chat.bitchat.sonar</string>
</array>
```

## 3. Register for APNS

In `AppDelegate` (or create one if using SwiftUI lifecycle):

```swift
import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()

        // 1. Register with transponder (MIP-05 encrypted token share)
        SonarPushRegistration.registerTransponder(apnsToken: deviceToken)

        // 2. Register with Breez NDS (webhook URL with token in query)
        SonarPushRegistration.registerBreezWebhook(apnsToken: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[Push] APNS registration failed: \(error)")
    }
}
```

Wire into the SwiftUI lifecycle (in `BitchatApp.swift`):

```swift
@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
```

## 4. Implement MIP-05 Token Encryption

Create `SonarPushRegistration.swift`. The shipped app delegates MIP-05
encryption to Rust core via UniFFI. Registration encrypts the APNS device
token to the transponder's secp256k1 public key, caches it locally, and shares
the encrypted blob with peers. It does not publish a `kind:446` request during
registration; senders publish `kind:446` only when waking recipients.

```swift
import CryptoKit
import Foundation

enum SonarPushRegistration {

    // Transponder's secp256k1 public key (npub), embedded at build time.
    // NEVER hardcode — use a build setting or Info.plist key.
    private static var transponderNpub: String {
        Bundle.main.infoDictionary?["SONAR_TRANSPONDER_NPUB"] as? String ?? ""
    }

    /// Encrypt APNS token in Rust core and share it with peers.
    static func registerTransponder(apnsToken: Data) {
        // MIP-05 plaintext: platform(1) + tokenLen(2) + token + padding = 1024 bytes
        var plaintext = Data(capacity: 1024)
        plaintext.append(0x01) // APNS
        let tokenLen = UInt16(apnsToken.count)
        plaintext.append(UInt8(tokenLen >> 8))
        plaintext.append(UInt8(tokenLen & 0xFF))
        plaintext.append(apnsToken)

        // Pad to 1024 bytes
        let padLen = 1024 - plaintext.count
        if padLen > 0 {
            var pad = Data(count: padLen)
            _ = pad.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, padLen, $0.baseAddress!) }
            plaintext.append(pad)
        }

        // ECDH + HKDF-SHA256 (salt=mip05-v1, info=mip05-token-encryption) + ChaCha20-Poly1305
        // Use the transponder's secp256k1 public key for ECDH.
        //
        // TODO: Implement using secp256k1 library (e.g. secp256k1.swift).
        //       CryptoKit P256 is NOT compatible with secp256k1.
        //       The encrypted blob is 1084 bytes (1024 + 12 nonce + 16 tag + 32 ephemeral pubkey).
        //
        // let encrypted = MIP05.encrypt(plaintext, to: transponderNpub)

        // TODO: Call the existing SonarNode.registerPushToken FFI path.
        //       Rust core stores the encrypted token and shares it with peers.
        //       Do not publish kind-446 here; the transponder treats kind-446 as
        //       an immediate wakeup request.
    }

    /// Register webhook with Breez SDK so the NDS can push wallet events.
    static func registerBreezWebhook(apnsToken: String) {
        // The NDS host URL comes from build config, NOT from the transponder.
        guard let ndsHost = Bundle.main.infoDictionary?["SONAR_NDS_URL"] as? String else {
            print("[Push] SONAR_NDS_URL not set in build config")
            return
        }
        let webhookURL = "\(ndsHost)/api/v1/notify?platform=ios&token=\(apnsToken)"

        // TODO: Call Breez SDK registerWebhook
        // breezSDK.registerWebhook(webhookURL: webhookURL)
    }

    /// Unregister from both servers (called when user disables push in settings).
    static func unregister() {
        // TODO: Clear cached token-share state and notify peers on rotation/disable.
        //       There is no transponder-side registration to delete.
        // TODO: Call breezSDK.unregisterWebhook()
    }
}
```

### Build configuration

Add to `ios/Configs/Local.xcconfig` (gitignored):

```
SONAR_TRANSPONDER_NPUB = npub1...
SONAR_NDS_URL = https://notify.sonar.example.com
```

Wire into `Info.plist`:

```xml
<key>SONAR_TRANSPONDER_NPUB</key>
<string>$(SONAR_TRANSPONDER_NPUB)</string>
<key>SONAR_NDS_URL</key>
<string>$(SONAR_NDS_URL)</string>
```

## 5. Notification Service Extension

The extension handles two push classes and decides what to do with each.
Transponder pushes must be visible APNS notifications with `mutable-content: 1`
so iOS invokes the extension after the app has been force-quit. Breez NDS pushes
remain infrastructure-only and should not produce user-visible copy.

```swift
import UserNotifications

class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        let userInfo = request.content.userInfo

        if isTransponderPush(userInfo) {
            handleMarmotWakeup(contentHandler: contentHandler)
        } else if isBreezPush(userInfo) {
            handleBreezWakeup(contentHandler: contentHandler)
        } else {
            // Unknown push — suppress
            contentHandler(UNNotificationContent())
        }
    }

    // MARK: - Transponder (chat/call) — user-visible

    private func handleMarmotWakeup(
        contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        // Privacy-first killed-app fallback. Precise copy is rendered locally
        // when Sonar opens and can fetch/decrypt Marmot state.
        let content = UNMutableNotificationContent()
        content.title = "New Sonar message"
        content.body = "Open Sonar to read it."
        content.sound = .default
        contentHandler(content)
    }

    // MARK: - Breez NDS (wallet) — SILENT, no user-visible notification

    private func handleBreezWakeup(
        contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        // Start the Breez SDK Notification Plugin to complete the BOLT12
        // receive or swap. The wallet keychain must be accessible via the
        // shared keychain access group.
        //
        // IMPORTANT: Do NOT render a user-visible notification here.
        // The Breez NDS wakeup is infrastructure only. The user-visible
        // payment amount notification fires when the sender's ⚡PAY control
        // line arrives through the transponder/chat path.
        //
        // The extension has ~30 seconds to complete.

        // TODO: Initialize Breez SDK Notification Plugin with shared keychain.
        // breezSDK.handleNotification(...)

        // Return empty content — silent handling.
        contentHandler(UNNotificationContent())
    }

    // MARK: - Push type detection

    private func isTransponderPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        // Transponder pushes contain an MIP-05 marker.
        // Exact key depends on transponder's push payload format.
        return userInfo["mip05"] != nil || userInfo["transponder"] != nil
    }

    private func isBreezPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        // Breez NDS pushes contain a notification_type field.
        return userInfo["notification_type"] != nil
    }

    override func serviceExtensionTimeWillExpire() {
        // Last chance — send whatever we have.
        if let contentHandler = contentHandler,
           let content = bestAttemptContent {
            contentHandler(content)
        }
    }
}
```

## 6. App Group Data Migration

The Notification Service Extension runs in a separate process and cannot
access the main app's sandbox. Data the extension needs must be in the
shared App Group container.

What to move to App Group:
- Nostr relay URLs and connection config
- The user's Nostr identity (for relay authentication)
- Marmot decryption keys needed to process incoming messages
- The notification router preferences (enabled, showNames, showPreview,
  showPaymentAmount)

What NOT to move:
- Wallet private keys (use shared Keychain instead)
- Full message history (extension only needs recent unprocessed messages)

The existing `UserDefaults(suiteName: BitchatApp.groupID)` at
`ios/bitchat/BitchatApp.swift:184` already uses the App Group for some
data. Extend this to include the notification-relevant state.

Migration must be non-destructive — existing users upgrading should not
lose data. Write-then-switch: copy data to App Group, verify, then update
the read path.

## 7. Settings Integration

Add push registration controls to the existing notification settings
(alongside the local notification preferences that already exist).

The user should be able to:
- Enable/disable remote push registration
- Trigger token deletion (unregister from both servers)

When push is disabled:
1. Call `SonarPushRegistration.unregister()` to remove tokens from both
   servers.
2. Local notifications continue to work while the app is running.
3. Killed-app notifications stop.

## 8. Testing Checklist

- [ ] APNS token is collected on first launch after permission grant.
- [ ] MIP-05 encrypted token share is cached and shared with peers.
- [ ] Breez webhook is registered with correct URL and token.
- [ ] Transponder APNS payload includes an alert, `mutable-content: 1`, and a
      marker (`wn_nse_prototype`, `source=transponder`, `source=marmot`,
      `mip05`, `transponder`, or `kind=446`). With upstream Transponder, set
      `[apns].payload_mode = "nse_prototype_alert"`.
- [ ] Transponder push wakes extension and shows generic user-visible
      notification while Sonar is force-quit.
- [ ] Breez NDS push wakes extension and completes BOLT12 receive silently.
- [ ] No user-visible notification from the Breez NDS path.
- [ ] App Group data is accessible from the extension.
- [ ] Wallet keychain is accessible from the extension.
- [ ] Extension completes within the 30-second timeout.
- [ ] Disabling push in settings unregisters from both servers.
- [ ] Token refresh re-registers with both servers.
- [ ] Notification copy matches the local router output.
- [ ] Provider payload privacy holds: APNS/FCM payloads contain no names,
      amounts, or previews. Local rendering may show sender/group names and
      payment amounts; message previews remain opt-in.
