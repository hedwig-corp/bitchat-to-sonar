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
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build

/** Android `actual`: transport-specific channels with sound, vibration, and badges. */
actual object Notifier {
    private const val MESSAGE_CHANNEL = "messages_v8"
    private const val BLE_CHANNEL = "ble_notifications_v6"
    private const val TRILL_CHANNEL = "trill_v1"
    private const val PAYMENT_CHANNEL = "payments_v1"
    /** Keeps payments out of the chat notification bundle. */
    private const val PAYMENT_GROUP = "sonar.payments"
    private val LEGACY_CHANNELS = listOf(
        "messages",
        "messages_v2",
        "messages_v3",
        "messages_v4",
        "messages_v5",
        "messages_v6",
        "messages_v7",
        "ble_notifications_v1",
        "ble_notifications_v2",
        "ble_notifications_v3",
        "ble_notifications_v4",
        "ble_notifications_v5",
    )

    private val ctx: Context get() = AppContextHolder.ctx
    private fun manager() = ctx.getSystemService(NotificationManager::class.java)

    /** Stable type/name URI so a persisted channel survives resource-ID renumbering. */
    private fun soundUri(resourceId: Int): Uri {
        val resourceType = ctx.resources.getResourceTypeName(resourceId)
        val resourceName = ctx.resources.getResourceEntryName(resourceId)
        return Uri.parse(
            "${ContentResolver.SCHEME_ANDROID_RESOURCE}://${ctx.packageName}/$resourceType/$resourceName"
        )
    }

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
            ensureChannel(
                nm = nm,
                id = TRILL_CHANNEL,
                name = "Nudges",
                description = "MSN-style nudges that buzz your screen",
                soundResourceId = R.raw.sonar_trill,
                // Match the in-app buzz: [40ms buzz, 60ms pause, 40ms buzz].
                vibrationPattern = longArrayOf(0, 40, 60, 40),
            )
            ensureChannel(
                nm = nm,
                id = PAYMENT_CHANNEL,
                name = "Payments",
                description = "Money you receive in Sonar",
                // TODO(assets): ships with the message tone until a dedicated
                // `sonar_payment` master exists (assets/notifications/README.md
                // documents the mastering + ffmpeg step). The channel is the
                // load-bearing part — it already lets the user pick their own
                // sound for money in system settings, which was impossible
                // while payments rode the messages channel. Swapping the sound
                // later requires bumping this id to `payments_v2`, since
                // Android freezes channel sound after creation.
                soundResourceId = R.raw.sonar_notification,
                // Between the message buzz [0,250,200,250] and the trill's
                // [0,40,60,40]: short double-tap, distinct from both.
                vibrationPattern = longArrayOf(0, 60, 80, 60),
            )
        }
    }

    private fun ensureChannel(
        nm: NotificationManager,
        id: String,
        name: String,
        description: String,
        soundResourceId: Int,
        vibrationPattern: LongArray = longArrayOf(0, 250, 200, 250),
    ) {
        if (nm.getNotificationChannel(id) != null) return
        val uri = soundUri(soundResourceId)
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        if (RingtoneManager.getRingtone(ctx, uri) == null) {
            sonarLog("Notifier", "Notification sound unreadable for $id uri=$uri")
        }
        nm.createNotificationChannel(
            NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH).apply {
                this.description = description
                enableVibration(true)
                this.vibrationPattern = vibrationPattern
                setSound(uri, audioAttributes)
                setShowBadge(true)
            }
        )
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

    actual suspend fun prepareForAccountReplacement() {
        chat.bitchat.sonar.push.SonarPushRegistration.prepareForAccountReplacement()
    }

    actual fun setPushEnabled(enabled: Boolean) {
        if (enabled) {
            chat.bitchat.sonar.push.SonarPushRegistration.ensureRegistered()
        } else {
            chat.bitchat.sonar.push.SonarPushRegistration.unregister()
        }
    }

    actual fun notify(
        id: Int,
        title: String,
        body: String,
        sound: SonarNotificationSound,
        conversationId: String?,
        messageId: String?,
    ) {
        if (!canNotify()) return
        val open = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            if (!conversationId.isNullOrBlank()) {
                putExtra(SonarNotificationHandoff.EXTRA_CONVERSATION_ID, conversationId)
            }
            SonarNotificationHandoff.normalizeJumpMessageId(messageId)?.let {
                putExtra(SonarNotificationHandoff.EXTRA_MESSAGE_ID, it)
            }
        }
        val pi = PendingIntent.getActivity(
            ctx, id, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val channel = when (sound) {
            SonarNotificationSound.Default -> MESSAGE_CHANNEL
            SonarNotificationSound.Ble -> BLE_CHANNEL
            SonarNotificationSound.Trill -> TRILL_CHANNEL
            SonarNotificationSound.Payment -> PAYMENT_CHANNEL
        }
        val isPayment = sound == SonarNotificationSound.Payment
        val n = Notification.Builder(ctx, channel)
            .setSmallIcon(
                if (isPayment) R.drawable.ic_notify_payment
                else android.R.drawable.stat_notify_chat
            )
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setNumber(1)
            // CATEGORY_EVENT, not CATEGORY_MESSAGE: there is no money category,
            // and MESSAGE is what makes Android treat this as chat and bundle
            // it into the conversation — the exact merge we are breaking.
            .setCategory(
                if (isPayment) Notification.CATEGORY_EVENT
                else Notification.CATEGORY_MESSAGE
            )
            .apply {
                if (isPayment) {
                    setGroup(PAYMENT_GROUP)
                    // Gold, matching the in-app PayBubble. Colorized only
                    // applies to foreground-service notifications on most
                    // versions; harmless elsewhere and correct where honoured.
                    setColor(0xFFD4A017.toInt())
                }
            }
            .setContentIntent(pi)
            .build()
        manager().notify(id, n)
    }

    actual fun clearConversations(conversationIds: Collection<String>) {
        val nm = manager()
        for (id in SonarNotificationHandoff.notificationIdsToClear(conversationIds)) {
            nm.cancel(id)
        }
    }
}
