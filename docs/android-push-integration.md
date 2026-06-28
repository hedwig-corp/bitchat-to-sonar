# Android Remote Push Integration Guide

> **Note:** This was a planning document written before implementation. The
> actual code differs — MIP-05 crypto and token registration are handled
> entirely in Rust core via FFI, not in Kotlin. Code blocks with `// TODO`
> comments reflect the original plan, not the shipped implementation. See the
> actual source in `apps/sonar/composeApp/src/androidMain/` for current code.

Step-by-step guide for wiring the Compose Multiplatform Sonar app to both
notification servers (transponder for chat/calls, Breez NDS for wallet
wakeups).

## Prerequisites

- Sonar notification servers deployed and running (see `deploy/README.md`)
- The transponder's **npub** (Nostr public key) — generated during server setup
- A Firebase project with FCM enabled
- Compose app: `apps/sonar/`

## 1. Add Firebase Messaging Dependency

### gradle/libs.versions.toml

Add the Firebase BOM and messaging library:

```toml
[versions]
# ... existing versions ...
firebase-bom = "33.7.0"
google-services = "4.4.2"

[libraries]
# ... existing libraries ...
firebase-bom = { module = "com.google.firebase:firebase-bom", version.ref = "firebase-bom" }
firebase-messaging = { module = "com.google.firebase:firebase-messaging" }

[plugins]
# ... existing plugins ...
google-services = { id = "com.google.gms.google-services", version.ref = "google-services" }
```

### apps/sonar/build.gradle.kts (root)

```kotlin
plugins {
    // ... existing plugins ...
    alias(libs.plugins.google.services) apply false
}
```

### apps/sonar/composeApp/build.gradle.kts

```kotlin
plugins {
    // ... existing plugins ...
    alias(libs.plugins.google.services)
}

// In the android { } block's dependencies:
dependencies {
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.messaging)
}
```

### google-services.json

Download from the Firebase Console (Project Settings > General > Your Apps)
and place at `apps/sonar/composeApp/google-services.json`.

**Add to .gitignore** — this file contains the Firebase project ID and API
key. Use CI secrets or local config to provide it per environment.

## 2. Android Manifest Changes

Add the FCM service and `FOREGROUND_SERVICE` permission to
`apps/sonar/composeApp/src/androidMain/AndroidManifest.xml`:

```xml
<!-- Inside <manifest>, alongside existing permissions: -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.WAKE_LOCK" />

<!-- Inside <application>: -->

<!-- FCM message handler -->
<service
    android:name=".SonarFirebaseMessagingService"
    android:exported="false">
    <intent-filter>
        <action android:name="com.google.firebase.MESSAGING_EVENT" />
    </intent-filter>
</service>

<!-- Foreground service for processing pushes when the app is killed -->
<service
    android:name=".SonarPushProcessingService"
    android:exported="false"
    android:foregroundServiceType="dataSync" />
```

## 3. FCM Token Collection and Registration

Create `SonarFirebaseMessagingService.kt` in the Android source set
(`apps/sonar/composeApp/src/androidMain/kotlin/chat/bitchat/sonar/`):

```kotlin
package chat.bitchat.sonar

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class SonarFirebaseMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        // FCM token refreshed — re-register with both servers.
        SonarPushRegistration.onTokenRefresh(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data

        when {
            isTransponderPush(data) -> handleMarmotWakeup(data)
            isBreezPush(data) -> handleBreezWakeup(data)
        }
    }

    private fun isTransponderPush(data: Map<String, String>): Boolean {
        // Transponder pushes contain an MIP-05 marker.
        return data.containsKey("mip05") || data.containsKey("transponder")
    }

    private fun isBreezPush(data: Map<String, String>): Boolean {
        // Breez NDS pushes contain a notification_type field.
        return data.containsKey("notification_type")
    }

    // -- Transponder: chat/call wakeup — USER-VISIBLE notification --

    private fun handleMarmotWakeup(data: Map<String, String>) {
        // 1. Start foreground service to get execution time
        // 2. Connect to Marmot, fetch pending messages from relays
        // 3. Decrypt and process new messages
        // 4. Classify via SonarNotificationRouter
        // 5. Render user-visible notification via Notifier

        // TODO: Start SonarPushProcessingService as foreground service.
        //       Process pending Marmot messages.
        //       Call SonarNotificationRouter.build() for each new message.
        //       Fire notification via Notifier.notify().

        // Fallback: show generic notification immediately
        Notifier.ensureChannel()
        Notifier.notify(
            id = data.hashCode(),
            title = "New Sonar message",
            body = "Open Sonar to read it."
        )
    }

    // -- Breez NDS: wallet wakeup — SILENT, no user-visible notification --

    private fun handleBreezWakeup(data: Map<String, String>) {
        // Start the Breez SDK Notification Plugin to complete the BOLT12
        // receive or process the swap update.
        //
        // IMPORTANT: Do NOT show a user-visible notification here.
        // The Breez NDS wakeup is infrastructure only. The user-visible
        // payment amount notification fires when the sender's ⚡PAY control
        // line arrives through the transponder/chat path.

        // TODO: Start SonarPushProcessingService as foreground service.
        //       Initialize Breez SDK Notification Plugin.
        //       breezSDK.handleNotification(data)
        //       Complete silently — no Notifier.notify() call.
    }
}
```

## 4. Push Registration

Create `SonarPushRegistration.kt` in the Android source set:

```kotlin
package chat.bitchat.sonar

import com.google.firebase.messaging.FirebaseMessaging

object SonarPushRegistration {

    // Transponder's secp256k1 public key (npub), embedded at build time.
    // Read from BuildConfig or local.properties.
    private val transponderNpub: String
        get() = BuildConfig.SONAR_TRANSPONDER_NPUB

    private val ndsUrl: String
        get() = BuildConfig.SONAR_NDS_URL

    /** Called on app startup to ensure registration is current. */
    fun ensureRegistered() {
        FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
            registerTransponder(token)
            registerBreezWebhook(token)
        }
    }

    /** Called by FirebaseMessagingService.onNewToken when FCM refreshes the token. */
    fun onTokenRefresh(token: String) {
        registerTransponder(token)
        registerBreezWebhook(token)
    }

    /** Encrypt FCM token via MIP-05 and publish as NIP-59 gift wrap. */
    private fun registerTransponder(fcmToken: String) {
        // MIP-05 plaintext: platform(1) + tokenLen(2) + token + padding = 1024 bytes
        val tokenBytes = fcmToken.toByteArray(Charsets.UTF_8)
        val plaintext = ByteArray(1024)
        plaintext[0] = 0x02 // FCM
        plaintext[1] = (tokenBytes.size shr 8).toByte()
        plaintext[2] = (tokenBytes.size and 0xFF).toByte()
        System.arraycopy(tokenBytes, 0, plaintext, 3, tokenBytes.size)
        // Fill remaining bytes with random padding
        java.security.SecureRandom().nextBytes(
            plaintext.sliceArray(3 + tokenBytes.size until 1024)
        )

        // ECDH + HKDF-SHA256 (salt=mip05-v1, info=mip05-token-encryption) + ChaCha20-Poly1305
        //
        // TODO: Implement using a secp256k1 library.
        //       The encrypted blob is 1084 bytes (1024 + 12 nonce + 16 tag + 32 ephemeral pubkey).
        //
        // val encrypted = MIP05.encrypt(plaintext, transponderNpub)
        // NostrPublisher.publishGiftWrap(to = transponderNpub, content = encrypted)
    }

    /** Register webhook with Breez SDK. */
    private fun registerBreezWebhook(fcmToken: String) {
        val webhookURL = "$ndsUrl/api/v1/notify?platform=android&token=$fcmToken"

        // TODO: Call Breez SDK registerWebhook
        // breezSDK.registerWebhook(webhookURL)
    }

    /** Unregister from both servers. */
    fun unregister() {
        // TODO: Delete the NIP-59 gift wrap from relays (or publish a deletion event).
        // TODO: Call breezSDK.unregisterWebhook()
    }
}
```

## 5. Build Configuration

Add the transponder npub and NDS URL to the Android build without
committing secrets.

### local.properties (gitignored)

```properties
sonar.transponder.npub=npub1...
sonar.nds.url=https://notify.sonar.example.com
```

### composeApp/build.gradle.kts

```kotlin
android {
    defaultConfig {
        // Read from local.properties
        val localProps = java.util.Properties().apply {
            val f = rootProject.file("local.properties")
            if (f.exists()) load(f.inputStream())
        }
        buildConfigField("String", "SONAR_TRANSPONDER_NPUB",
            "\"${localProps.getProperty("sonar.transponder.npub", "")}\"")
        buildConfigField("String", "SONAR_NDS_URL",
            "\"${localProps.getProperty("sonar.nds.url", "")}\"")
    }
    buildFeatures {
        buildConfig = true
    }
}
```

## 6. Foreground Service for Push Processing

Create `SonarPushProcessingService.kt`:

```kotlin
package chat.bitchat.sonar

import android.app.Notification
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Short-lived foreground service that processes Marmot messages or Breez
 * wallet events triggered by a push wakeup. Stops itself when done.
 */
class SonarPushProcessingService : Service() {

    override fun onCreate() {
        super.onCreate()
        Notifier.ensureChannel()
        val notification = Notification.Builder(this, "messages")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Sonar")
            .setContentText("Processing incoming data...")
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(FOREGROUND_ID, notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(FOREGROUND_ID, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val type = intent?.getStringExtra(EXTRA_PUSH_TYPE) ?: return START_NOT_STICKY

        when (type) {
            TYPE_MARMOT -> processMarmotMessages()
            TYPE_BREEZ -> processBreezEvent(intent)
        }

        stopSelf(startId)
        return START_NOT_STICKY
    }

    private fun processMarmotMessages() {
        // TODO: Connect to Marmot, fetch pending messages from relays,
        //       decrypt, classify via SonarNotificationRouter, fire notifications.
    }

    private fun processBreezEvent(intent: Intent) {
        // TODO: Initialize Breez SDK Notification Plugin, handle the event.
        //       Do NOT fire a user-visible notification.
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val FOREGROUND_ID = 9001
        const val EXTRA_PUSH_TYPE = "push_type"
        const val TYPE_MARMOT = "marmot"
        const val TYPE_BREEZ = "breez"
    }
}
```

## 7. Wire Registration into App Startup

In the existing `SonarApp.kt` (or wherever the Android `Application`
subclass is):

```kotlin
override fun onCreate() {
    super.onCreate()
    // ... existing init ...

    // Register for push notifications
    SonarPushRegistration.ensureRegistered()
}
```

## 8. Notification Channels

The existing `Notifier.android.kt` has a single "messages" channel. For
remote push, consider adding a dedicated channel for wallet sync to give
Android the correct importance level:

```kotlin
// In Notifier.ensureChannel():
if (nm.getNotificationChannel("wallet_sync") == null) {
    nm.createNotificationChannel(
        NotificationChannel("wallet_sync", "Wallet Sync",
            NotificationManager.IMPORTANCE_MIN)
            .apply { description = "Background wallet processing" }
    )
}
```

The foreground service notification (processing indicator) should use the
low-importance channel so it doesn't buzz the user.

## 9. POST_NOTIFICATIONS Permission

The manifest already declares `POST_NOTIFICATIONS`. The runtime permission
request should happen before the first notification is shown. The existing
Compose code should already handle this — verify that it's requested during
onboarding or first message receipt.

## 10. Testing Checklist

- [ ] FCM token is collected on app startup.
- [ ] MIP-05 encrypted gift wrap is published to relays.
- [ ] Breez webhook is registered with correct URL and token.
- [ ] Token refresh re-registers with both servers.
- [ ] Transponder push wakes the service and shows user-visible notification.
- [ ] Breez NDS push wakes the service and completes BOLT12 receive silently.
- [ ] No user-visible notification from the Breez NDS path.
- [ ] Foreground service starts and stops cleanly.
- [ ] `POST_NOTIFICATIONS` permission is requested on Android 13+.
- [ ] Disabling push in settings unregisters from both servers.
- [ ] Notification copy matches the local router output.
- [ ] Provider payload privacy holds: FCM payloads contain no names, amounts,
      or previews. Local rendering may show sender/group names and payment
      amounts; message previews remain opt-in.
- [ ] Android remote push group labels are enabled once the core conversation
      summary exposes group/direct metadata; until then remote push shows the
      latest sender and avoids guessing whether the summary name is a group.
- [ ] App killed → DM sent → device wakes → notification appears.
- [ ] App killed → BOLT12 payment sent → device wakes → wallet settles → no
      notification until `⚡PAY` arrives via transponder.
