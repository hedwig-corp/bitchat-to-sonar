package chat.bitchat.sonar

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

/** Android `actual`: a single "Messages" channel + tap-to-open notifications. */
actual object Notifier {
    private const val CHANNEL = "messages"

    private val ctx: Context get() = AppContextHolder.ctx
    private fun manager() = ctx.getSystemService(NotificationManager::class.java)

    actual fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = manager()
            if (nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL, "Messages", NotificationManager.IMPORTANCE_HIGH)
                        .apply { description = "Incoming Sonar messages" }
                )
            }
        }
    }

    actual fun canNotify(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return ctx.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        }
        return true
    }

    actual fun notify(id: Int, title: String, body: String) {
        if (!canNotify()) return
        val open = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?.apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP }
        val pi = open?.let {
            PendingIntent.getActivity(
                ctx, id, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        val n = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .apply { if (pi != null) setContentIntent(pi) }
            .build()
        manager().notify(id, n)
    }
}
