package chat.bitchat.sonar.push

import android.content.Intent
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Receives FCM data-only pushes from two sources:
 *   - Transponder → chat/call wakeup → user-visible notification
 *   - Breez NDS  → wallet wakeup → settle the incoming payment, then one
 *     "Payment received" notification (nothing settled → silent)
 */
class SonarFirebaseMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        SonarPushRegistration.onTokenRefresh(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val keys = data.keys.sorted().joinToString(",").ifEmpty { "<none>" }
        val hasNotification = message.notification != null
        // Priority is decisive for a killed app: only a HIGH-priority data
        // message escapes Doze to start a foreground service. If the NDS/Boltz
        // push arrives NORMAL here, a backgrounded/killed device won't wake — so
        // we log both the requested and delivered priority to make that visible.
        val prio = priorityLabel(message.priority)
        val origPrio = priorityLabel(message.originalPriority)
        Log.d(TAG, "Push received: keys=$keys notification=$hasNotification " +
            "priority=$prio original=$origPrio")

        if (!SonarPushPrefs.effectivePushEnabled(this)) {
            Log.d(TAG, "Push ignored: disabled by user preference")
            return
        }

        // Starting a background FGS is only legal under the high-priority FCM
        // allowlist; a downgraded push would throw ForegroundServiceStart-
        // NotAllowedException. When not high AND we're backgrounded, skip the
        // FGS start (it can't legally run) and surface why.
        val highPriority = message.priority == RemoteMessage.PRIORITY_HIGH

        when {
            isTransponderPush(data, message) -> handleMarmotWakeup(highPriority)
            isBreezPush(data) -> handleBreezWakeup(data, highPriority)
            else -> Log.w(TAG, "Unknown push type, ignoring keys=$keys notification=$hasNotification")
        }
    }

    private fun priorityLabel(p: Int): String = when (p) {
        RemoteMessage.PRIORITY_HIGH -> "high"
        RemoteMessage.PRIORITY_NORMAL -> "normal"
        else -> "unknown"
    }

    private fun isTransponderPush(data: Map<String, String>, message: RemoteMessage): Boolean {
        if (isBreezPush(data)) return false

        val source = data["source"]?.lowercase()
        if (source == "transponder" || source == "marmot") return true

        if (data.containsKey("mip05") ||
            data.containsKey("transponder") ||
            data.containsKey("wn_nse_prototype") ||
            data["kind"] == "446"
        ) return true

        return data.isEmpty() && message.notification != null
    }

    private fun isBreezPush(data: Map<String, String>): Boolean =
        data.containsKey("notification_type")

    private fun handleMarmotWakeup(highPriority: Boolean) {
        Log.d(TAG, "Transponder push — starting Marmot sync (highPriority=$highPriority)")
        val intent = Intent(this, SonarPushProcessingService::class.java).apply {
            putExtra(SonarPushProcessingService.EXTRA_PUSH_TYPE, SonarPushProcessingService.TYPE_MARMOT)
        }
        startWake(intent)
    }

    private fun handleBreezWakeup(data: Map<String, String>, highPriority: Boolean) {
        Log.d(TAG, "Breez NDS push — starting wallet settlement (highPriority=$highPriority)")
        val intent = Intent(this, SonarPushProcessingService::class.java).apply {
            putExtra(SonarPushProcessingService.EXTRA_PUSH_TYPE, SonarPushProcessingService.TYPE_BREEZ)
            putExtra(SonarPushProcessingService.EXTRA_NOTIFICATION_TYPE,
                data["notification_type"] ?: "")
            // Swap id / payment hash payload — forwarded for diagnostics (and a
            // future targeted getPayment) once a real payload shape is captured.
            putExtra(SonarPushProcessingService.EXTRA_NOTIFICATION_PAYLOAD,
                data["notification_payload"] ?: "")
        }
        startWake(intent)
    }

    /** Start the wake service, tolerating the case where the background-FGS
     *  allowlist is unavailable (downgraded push, or a foreground-service-start
     *  restriction). Better to log and drop the wake than crash the FCM service
     *  — the app will still reconcile on next open. */
    private fun startWake(intent: Intent) {
        try {
            startForegroundService(intent)
        } catch (t: Throwable) {
            // Most likely ForegroundServiceStartNotAllowedException: the push
            // was not high-priority (or arrived in a restricted state), so we
            // can't legally start a foreground service from the background.
            Log.w(TAG, "Wake FGS start refused (push likely not high-priority): ${t.message}")
        }
    }

    companion object {
        private const val TAG = "SonarFCM"
    }
}
