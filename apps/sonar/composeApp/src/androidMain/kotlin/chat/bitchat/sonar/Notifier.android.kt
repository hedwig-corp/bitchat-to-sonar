package chat.bitchat.sonar

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.os.Build
import android.provider.Settings

/** Android `actual`: "Messages" channel with sound, vibration, and badges — parity with iOS. */
actual object Notifier {
    private const val CHANNEL = "messages"

    private val ctx: Context get() = AppContextHolder.ctx
    private fun manager() = ctx.getSystemService(NotificationManager::class.java)

    actual fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = manager()
            val existing = nm.getNotificationChannel(CHANNEL)
            if (existing == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL, "Messages", NotificationManager.IMPORTANCE_HIGH).apply {
                        description = "Incoming Sonar messages"
                        enableVibration(true)
                        vibrationPattern = longArrayOf(0, 250, 200, 250)
                        setSound(
                            Settings.System.DEFAULT_NOTIFICATION_URI,
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_NOTIFICATION_COMMUNICATION_INSTANT)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .build()
                        )
                        setShowBadge(true)
                    }
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
            .setDefaults(Notification.DEFAULT_ALL)
            .setNumber(1)
            .apply { if (pi != null) setContentIntent(pi) }
            .build()
        manager().notify(id, n)
    }
}
