package chat.bitchat.sonar.push

import android.content.Intent
import android.util.Log
import chat.bitchat.sonar.Notifier
import chat.bitchat.sonar.SonarNotificationKind
import chat.bitchat.sonar.SonarNotificationRouter
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
        // allowlist; a downgraded push throws ForegroundServiceStartNotAllowed-
        // Exception, which the handlers below catch and log.
        //
        // Deliberately NOT used as a guard: this is diagnostic only. We still
        // attempt the start on a NORMAL-priority push because the app may be
        // visible (also exempt), and a wrong skip loses a real wake — worse
        // than a caught exception. Do not turn this into a branch without
        // also checking visibility.
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
            // Upstream marmot-protocol/transponder sends the Android wake as a
            // data-only FCM message whose only key is content_available=true
            // (src/push/fcm.rs build_message). The alert/wn_nse_prototype shape
            // is APNs-only, so this key IS the transponder marker on FCM.
            data.containsKey("content_available") ||
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
        try {
            startForegroundService(intent)
        } catch (t: Throwable) {
            // ForegroundServiceStartNotAllowedException: the push was not
            // high-priority (or arrived in a restricted state), or the Android
            // 15 dataSync budget is exhausted. We are still inside the FCM
            // execution window, so run the bounded inline fallback — a real
            // (budgeted) sync + titled notifications, degrading to the generic
            // banner only when nothing landed — instead of dropping the wake
            // or degrading straight to the contentless banner (#203).
            Log.w(TAG, "Push service start rejected (highPriority=$highPriority), " +
                "running inline fallback: ${t.message}")
            Notifier.ensureChannel()
            runCatching {
                SonarPushInlineFallback.run(
                    this,
                    SonarPushProcessingService.TYPE_MARMOT,
                    notificationType = "",
                    payload = "",
                )
            }.onFailure { e ->
                Log.e(TAG, "Inline Marmot fallback failed", e)
                val prefs = SonarPushPrefs.notificationPrefs(this)
                SonarNotificationRouter.build(
                    idKey = "marmot-push",
                    kind = SonarNotificationKind.Message,
                    unreadCount = 1,
                    prefs = prefs.copy(showPreview = false),
                )?.let { Notifier.notify(it.id, it.title, it.body) }
            }
        }
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
        try {
            startForegroundService(intent)
        } catch (t: Throwable) {
            // Most likely ForegroundServiceStartNotAllowedException: the push
            // was not high-priority (or arrived in a restricted state), so we
            // can't legally start a foreground service from the background.
            // For an invoice_request a payer is blocked on the NDS's 60s
            // window — answer (or error-reply) inline within the FCM window
            // rather than letting them time out; other Breez wakes reconcile
            // silently on the next open (#203).
            Log.w(TAG, "Breez push service start refused (highPriority=$highPriority), " +
                "running inline fallback: ${t.message}")
            runCatching {
                SonarPushInlineFallback.run(
                    this,
                    SonarPushProcessingService.TYPE_BREEZ,
                    notificationType = data["notification_type"] ?: "",
                    payload = data["notification_payload"] ?: "",
                )
            }.onFailure { e ->
                Log.w(TAG, "Inline Breez fallback failed (silent)", e)
            }
        }
    }

    companion object {
        private const val TAG = "SonarFCM"
    }
}
