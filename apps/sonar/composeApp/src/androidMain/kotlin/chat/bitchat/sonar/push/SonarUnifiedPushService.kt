package chat.bitchat.sonar.push

import android.util.Log
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

/**
 * Receives UnifiedPush events from the user's distributor (e.g. ntfy) on
 * degoogled devices — GrapheneOS without sandboxed Play Services.
 *
 * The distributor-issued endpoint URL plays the role of the FCM token: it is
 * MIP-05-encrypted to the transponder (`platform = "unifiedpush"`), which
 * POSTs the wake to it. The push body is plaintext-free (same as FCM): any
 * message on this channel just means "wake up and drain the relays", so all
 * messages funnel into the same [SonarPushWake] → [SonarPushProcessingService]
 * path the FCM service uses.
 *
 * Wallet wakeups (Breez NDS) remain FCM-only for now — tracked gap, see
 * docs/GRAPHENEOS.md.
 */
class SonarUnifiedPushService : PushService() {

    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        Log.d(TAG, "UnifiedPush endpoint received (temporary=${endpoint.temporary})")
        // Temporary endpoints can rotate moments later; registering them
        // anyway keeps wakeups working in the gap, and the follow-up
        // onNewEndpoint re-registers the stable one (same self-heal shape as
        // an FCM token refresh).
        SonarPushRegistration.onUnifiedPushEndpoint(endpoint.url)
    }

    override fun onMessage(message: PushMessage, instance: String) {
        Log.d(TAG, "UnifiedPush wake received (${message.content.size} bytes)")
        if (!SonarPushPrefs.effectivePushEnabled(this)) {
            Log.d(TAG, "UnifiedPush wake ignored: disabled by user preference")
            return
        }
        SonarPushWake.startMarmotSync(this)
    }

    override fun onRegistrationFailed(reason: FailedReason, instance: String) {
        Log.w(TAG, "UnifiedPush registration failed: $reason")
        SonarPushRegistration.onUnifiedPushRegistrationFailed(reason.toString())
    }

    override fun onUnregistered(instance: String) {
        Log.d(TAG, "UnifiedPush distributor unregistered this app")
        SonarPushRegistration.onUnifiedPushUnregistered()
    }

    companion object {
        private const val TAG = "SonarUnifiedPush"
    }
}
