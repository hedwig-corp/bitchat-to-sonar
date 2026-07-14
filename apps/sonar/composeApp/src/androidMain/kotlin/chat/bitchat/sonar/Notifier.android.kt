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
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import java.util.concurrent.Executors

/** Android `actual`: transport-specific channels with sound, vibration, and badges. */
actual object Notifier {
    private const val MESSAGE_CHANNEL = "messages_v6"
    private const val BLE_CHANNEL = "ble_notifications_v4"
    private val LEGACY_CHANNELS = listOf(
        "messages",
        "messages_v2",
        "messages_v3",
        "messages_v4",
        "messages_v5",
        "ble_notifications_v1",
        "ble_notifications_v2",
        "ble_notifications_v3",
    )

    private val ctx: Context get() = AppContextHolder.ctx
    private fun manager() = ctx.getSystemService(NotificationManager::class.java)
    private val soundExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "sonar-notification-sound").apply { isDaemon = true }
    }

    /**
     * Numeric resource URI — Discord/Snapchat style. Kept on the channel so
     * Settings can preview the tone; local posts play via [playSound] so we can
     * force the builtin speaker when USB-dock invents a silent wired route.
     */
    private fun soundUri(resourceId: Int): Uri =
        Uri.parse("${ContentResolver.SCHEME_ANDROID_RESOURCE}://${ctx.packageName}/$resourceId")

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
                vibrationPattern = longArrayOf(0, 250, 200, 250)
                // Channel sound is disabled: NotificationPlayer on this device was
                // routing to a phantom TYPE_WIRED_HEADPHONES sink (silent) while
                // USB-debugging. We play via MediaPlayer in [playSound] instead.
                // URI is still validated above so packaging regressions stay visible.
                setSound(null, null)
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
            .setCategory(Notification.CATEGORY_MESSAGE)
            .apply { if (pi != null) setContentIntent(pi) }
            .build()
        manager().notify(id, n)
        playSound(sound)
    }

    private fun playSound(sound: SonarNotificationSound) {
        val resourceId = when (sound) {
            SonarNotificationSound.Default -> R.raw.sonar_notification
            SonarNotificationSound.Ble -> R.raw.sonar_ble_notification
        }
        soundExecutor.execute {
            var player: MediaPlayer? = null
            try {
                val afd = ctx.resources.openRawResourceFd(resourceId) ?: run {
                    sonarLog("Notifier", "Missing notification sound resource $resourceId")
                    return@execute
                }
                val am = ctx.getSystemService(AudioManager::class.java)
                val outputs = am?.getDevices(AudioManager.GET_DEVICES_OUTPUTS).orEmpty()
                val speaker = outputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                val hasExternalAudio = am?.isBluetoothA2dpOn == true ||
                    outputs.any {
                        it.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                            it.type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                            it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                            it.type == AudioDeviceInfo.TYPE_BLE_SPEAKER
                    }
                // Pixel USB-dock / adb often registers a silent TYPE_WIRED_HEADPHONES
                // sink with no real headset. Prefer the builtin speaker unless a
                // real external audio device (BT / USB headset) is active.
                val forceSpeaker = speaker != null && !hasExternalAudio
                player = MediaPlayer().apply {
                    setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
                    afd.close()
                    setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                    )
                    if (forceSpeaker) setPreferredDevice(speaker)
                    setOnCompletionListener { it.release() }
                    setOnErrorListener { mp, what, extra ->
                        sonarLog("Notifier", "MediaPlayer error what=$what extra=$extra")
                        mp.release()
                        true
                    }
                    prepare()
                    start()
                }
                sonarLog(
                    "Notifier",
                    "Playing notification sound res=$resourceId forceSpeaker=$forceSpeaker",
                )
            } catch (t: Throwable) {
                sonarLog("Notifier", "Failed to play notification sound: ${t.message}")
                player?.release()
            }
        }
    }
}
