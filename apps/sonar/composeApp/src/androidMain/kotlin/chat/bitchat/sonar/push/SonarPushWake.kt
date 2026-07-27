package chat.bitchat.sonar.push

import android.content.Context
import android.content.Intent
import android.util.Log
import chat.bitchat.sonar.Notifier
import chat.bitchat.sonar.SonarNotificationKind
import chat.bitchat.sonar.SonarNotificationRouter

/**
 * Transport-neutral entry for a chat/call wakeup: both the FCM service and the
 * UnifiedPush service funnel here so the drain path (and its
 * ForegroundServiceStartNotAllowedException fallback) can never diverge
 * between transports.
 */
internal object SonarPushWake {

    private const val TAG = "SonarPushWake"

    fun startMarmotSync(ctx: Context) {
        val intent = Intent(ctx, SonarPushProcessingService::class.java).apply {
            putExtra(
                SonarPushProcessingService.EXTRA_PUSH_TYPE,
                SonarPushProcessingService.TYPE_MARMOT,
            )
        }
        try {
            ctx.startForegroundService(intent)
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException: background-start
            // restriction or the Android 15 dataSync 6h/day budget. We are
            // still inside the push execution window, so surface a generic
            // notification instead of dropping the wake silently.
            Log.w(TAG, "Push service start rejected, showing generic notification", e)
            val prefs = SonarPushPrefs.notificationPrefs(ctx)
            Notifier.ensureChannel()
            SonarNotificationRouter.build(
                idKey = "marmot-push",
                kind = SonarNotificationKind.Message,
                unreadCount = 1,
                prefs = prefs.copy(showPreview = false),
            )?.let { Notifier.notify(it.id, it.title, it.body) }
        }
    }
}
