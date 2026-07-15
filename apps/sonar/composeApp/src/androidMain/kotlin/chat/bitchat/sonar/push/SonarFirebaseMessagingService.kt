package chat.bitchat.sonar.push

import android.content.Intent
import android.os.SystemClock
import android.util.Log
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
        val keys = data.keys.sorted().joinToString(",").ifEmpty { "<none>" }
        val hasNotification = message.notification != null
        Log.d(TAG, "Push received: keys=$keys notification=$hasNotification")

        if (!SonarPushPrefs.effectivePushEnabled(this)) {
            Log.d(TAG, "Push ignored: disabled by user preference")
            return
        }

        when {
            isTransponderPush(data, message) -> handleMarmotWakeup()
            isBreezPush(data) -> handleBreezWakeup(data)
            else -> Log.w(TAG, "Unknown push type, ignoring keys=$keys notification=$hasNotification")
        }
    }

    override fun onDeletedMessages() {
        if (!SonarPushPrefs.effectivePushEnabled(this)) return
        Log.w(TAG, "FCM deleted pending messages; scheduling durable bounded notification recovery")
        SonarNotificationWorkScheduler.scheduleDeletedMessages(this)
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

    private fun handleMarmotWakeup() {
        Log.d(TAG, "Transponder push — starting Marmot sync")
        // Own the obligation before entering the foreground-service path. If
        // Android kills this process after delivery, WorkManager resumes it.
        val admission = try {
            SonarNotificationWorkScheduler.scheduleBackup(this)
        } catch (error: Exception) {
            Log.e(TAG, "Could not persist Marmot wake obligation", error)
            // Admission itself was synchronously committed before WorkManager.
            // Still use the FCM execution window; the next process start will
            // repair any request that did not reach WorkManager.
            val state = SonarNotificationAdmission.current(this)
            state.takeIf {
                SonarNotificationAdmission.currentForWork(
                    context = this,
                    expectedOwnerId = it.ownerId,
                    currentOwnerId = SonarPushPrefs.accountOwnerId(),
                ) != null
            } ?: return
        }
        val deadline = SystemClock.elapsedRealtime() +
            SonarPushProcessingService.TOTAL_PUSH_DEADLINE_MS
        val intent = Intent(this, SonarPushProcessingService::class.java).apply {
            putExtra(SonarPushProcessingService.EXTRA_PUSH_TYPE, SonarPushProcessingService.TYPE_MARMOT)
            putExtra(SonarPushProcessingService.EXTRA_DEADLINE_ELAPSED_MS, deadline)
            putExtra(
                SonarPushProcessingService.EXTRA_ADMISSION_GENERATION,
                admission.generation,
            )
            putExtra(SonarPushProcessingService.EXTRA_ADMISSION_OWNER_ID, admission.ownerId)
        }
        try {
            startForegroundService(intent)
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException: background-start
            // restriction or the Android 15 dataSync 6h/day budget. We are
            // still inside the high-priority FCM execution window, so surface
            // a generic notification instead of dropping the wake silently.
            Log.w(TAG, "Push service start rejected; durable worker owns recovery/fallback", e)
            SonarNotificationWorkScheduler.scheduleContinuation(this)
            // The durable worker owns fallback/precise rendering. Rendering
            // here would race it and could create a second generic alert.
        }
    }

    private fun handleBreezWakeup(data: Map<String, String>) {
        Log.d(TAG, "Breez NDS push — starting wallet sync (silent)")
        val intent = Intent(this, SonarPushProcessingService::class.java).apply {
            putExtra(SonarPushProcessingService.EXTRA_PUSH_TYPE, SonarPushProcessingService.TYPE_BREEZ)
            putExtra(SonarPushProcessingService.EXTRA_NOTIFICATION_TYPE,
                data["notification_type"] ?: "")
            putExtra(
                SonarPushProcessingService.EXTRA_DEADLINE_ELAPSED_MS,
                SystemClock.elapsedRealtime() + SonarPushProcessingService.TOTAL_PUSH_DEADLINE_MS,
            )
        }
        try {
            startForegroundService(intent)
        } catch (e: Exception) {
            // Breez wakeups are silent infrastructure; nothing to render, but
            // the failure must not be invisible in diagnostics.
            Log.w(TAG, "Breez push service start rejected", e)
        }
    }

    companion object {
        private const val TAG = "SonarFCM"
    }
}
