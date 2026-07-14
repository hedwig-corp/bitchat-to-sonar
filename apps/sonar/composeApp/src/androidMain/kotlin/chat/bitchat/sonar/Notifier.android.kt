package chat.bitchat.sonar

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build

/** Android `actual`: transport-specific channels with sound, vibration, and badges. */
actual object Notifier {
    private const val MESSAGE_CHANNEL = "messages_v3"
    private const val BLE_CHANNEL = "ble_notifications_v1"
    private val LEGACY_CHANNELS = listOf("messages", "messages_v2")

    private val ctx: Context get() = AppContextHolder.ctx
    private fun manager() = ctx.getSystemService(NotificationManager::class.java)
    private fun soundUri(resourceId: Int): Uri = Uri.parse(
        "${ContentResolver.SCHEME_ANDROID_RESOURCE}://${ctx.packageName}/$resourceId"
    )

    actual fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = manager()
            LEGACY_CHANNELS.forEach(nm::deleteNotificationChannel)
            ensureChannel(
                nm = nm,
                id = MESSAGE_CHANNEL,
                name = "Messages",
                description = "Incoming Sonar messages",
                soundResourceId = R.raw.sonar_notification,
            )
            ensureChannel(
                nm = nm,
                id = BLE_CHANNEL,
                name = "Bluetooth notifications",
                description = "Notifications received over Bluetooth",
                soundResourceId = R.raw.sonar_ble_notification,
            )
        }
    }

    private fun ensureChannel(
        nm: NotificationManager,
        id: String,
        name: String,
        description: String,
        soundResourceId: Int,
    ) {
        if (nm.getNotificationChannel(id) == null) {
            nm.createNotificationChannel(
                NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH).apply {
                    this.description = description
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 250, 200, 250)
                    setSound(
                        soundUri(soundResourceId),
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                    )
                    setShowBadge(true)
                }
            )
        }
    }

    actual fun canNotify(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return ctx.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        }
        return true
    }

    actual fun onWalletReady() {
        chat.bitchat.sonar.push.SonarPushRegistration.retryBreezWebhookIfNeeded()
    }

    actual fun onPaymentOfferReady(offer: String) {
        chat.bitchat.sonar.push.SonarPushRegistration.ensureBreezWebhook(offer)
    }

    actual fun setPushEnabled(enabled: Boolean) {
        if (enabled) {
            chat.bitchat.sonar.push.SonarPushRegistration.ensureRegistered()
        } else {
            chat.bitchat.sonar.push.SonarPushRegistration.unregister()
        }
    }

    actual fun notify(id: Int, title: String, body: String, sound: SonarNotificationSound) {
        if (!canNotify()) return
        val open = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?.apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP }
        val pi = open?.let {
            PendingIntent.getActivity(
                ctx, id, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        val channel = when (sound) {
            SonarNotificationSound.Default -> MESSAGE_CHANNEL
            SonarNotificationSound.Ble -> BLE_CHANNEL
        }
        val n = Notification.Builder(ctx, channel)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setNumber(1)
            .apply { if (pi != null) setContentIntent(pi) }
            .build()
        manager().notify(id, n)
    }
}
