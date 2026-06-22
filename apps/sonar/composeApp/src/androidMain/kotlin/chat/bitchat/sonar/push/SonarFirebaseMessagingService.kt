package chat.bitchat.sonar.push

import android.content.Intent
import android.util.Log
import chat.bitchat.sonar.Notifier
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Receives FCM data-only pushes from two sources:
 *   - Transponder → chat/call wakeup → user-visible notification
 *   - Breez NDS  → wallet wakeup   → silent (no user-visible notification)
 */
class SonarFirebaseMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        SonarPushRegistration.onTokenRefresh(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        Log.d(TAG, "Push received: keys=${data.keys}")

        when {
            isTransponderPush(data) -> handleMarmotWakeup(data)
            isBreezPush(data) -> handleBreezWakeup(data)
            else -> Log.w(TAG, "Unknown push type, ignoring")
        }
    }

    private fun isTransponderPush(data: Map<String, String>): Boolean =
        data.containsKey("mip05") || data.containsKey("transponder")

    private fun isBreezPush(data: Map<String, String>): Boolean =
        data.containsKey("notification_type")

    private fun handleMarmotWakeup(data: Map<String, String>) {
        Log.d(TAG, "Transponder push — starting Marmot sync")
        val intent = Intent(this, SonarPushProcessingService::class.java).apply {
            putExtra(SonarPushProcessingService.EXTRA_PUSH_TYPE, SonarPushProcessingService.TYPE_MARMOT)
        }
        startForegroundService(intent)
    }

    private fun handleBreezWakeup(data: Map<String, String>) {
        Log.d(TAG, "Breez NDS push — starting wallet sync (silent)")
        val intent = Intent(this, SonarPushProcessingService::class.java).apply {
            putExtra(SonarPushProcessingService.EXTRA_PUSH_TYPE, SonarPushProcessingService.TYPE_BREEZ)
            putExtra(SonarPushProcessingService.EXTRA_NOTIFICATION_TYPE,
                data["notification_type"] ?: "")
        }
        startForegroundService(intent)
    }

    companion object {
        private const val TAG = "SonarFCM"
    }
}
