package chat.bitchat.sonar

import java.awt.Color
import java.awt.SystemTray
import java.awt.TrayIcon
import java.awt.event.ActionListener
import java.awt.image.BufferedImage
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import javax.sound.sampled.AudioSystem

/**
 * Desktop (JVM) `actual`: incoming-message notifications via the AWT system tray
 * (the desktop twin of Android's notification channel). Falls back to a no-op
 * where the tray is unsupported (e.g. headless or some Linux desktops).
 *
 * Platform gap vs Android/iOS: AWT `displayMessage` balloons cannot carry a
 * per-notification PendingIntent. Tap handoff is best-effort — clicking the
 * tray icon opens the most recent notified conversation via
 * [SonarLifecycle.submitOpenConversation]. Balloons themselves are ephemeral,
 * so [clearConversations] is a no-op.
 */
actual object Notifier {
    @Volatile private var trayIcon: TrayIcon? = null
    private val lastConversationId = AtomicReference<String?>(null)
    private val soundGeneration = AtomicLong()
    private val soundExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "sonar-notification-sound").apply { isDaemon = true }
    }

    /** A small accent dot for the tray slot (we only use the tray for
     *  displayMessage balloons, not as a primary, persistent UI surface). */
    private fun trayImage(): BufferedImage {
        val size = 16
        val img = BufferedImage(size, size, BufferedImage.TYPE_INT_ARGB)
        val g = img.createGraphics()
        g.color = Color(0x22, 0xD3, 0xEE) // Sonar cyan accent
        g.fillOval(2, 2, size - 4, size - 4)
        g.dispose()
        return img
    }

    @Synchronized
    actual fun ensureChannel() {
        if (trayIcon != null || !SystemTray.isSupported()) return
        runCatching {
            val icon = TrayIcon(trayImage(), "Sonar").apply {
                isImageAutoSize = true
                addActionListener(
                    ActionListener {
                        lastConversationId.get()?.let(SonarLifecycle::submitOpenConversation)
                    },
                )
            }
            SystemTray.getSystemTray().add(icon)
            trayIcon = icon
        }
    }

    actual fun canNotify(): Boolean = SystemTray.isSupported()

    actual fun onWalletReady() { /* no push webhooks on desktop */ }

    actual fun onPaymentOfferReady(offer: String) { /* no push webhooks on desktop */ }

    actual suspend fun prepareForAccountReplacement() { /* no push on desktop */ }

    actual fun setPushEnabled(enabled: Boolean) { /* no push on desktop */ }

    actual fun notify(
        id: Int,
        title: String,
        body: String,
        sound: SonarNotificationSound,
        conversationId: String?,
    ) {
        if (!conversationId.isNullOrBlank()) {
            lastConversationId.set(conversationId)
        }
        val icon = trayIcon ?: run { ensureChannel(); trayIcon } ?: return
        runCatching { icon.displayMessage(title, body, TrayIcon.MessageType.INFO) }
            .onFailure { sonarLog("Notifier", "Failed to display desktop notification: ${it.message}") }
        playNotificationSound(sound)
    }

    actual fun clearConversations(conversationIds: Collection<String>) {
        // AWT balloons are ephemeral — nothing durable to dismiss. Drop the
        // last-tap target when every related id is cleared so a later tray
        // click cannot reopen a just-read conversation by accident.
        val cleared = conversationIds.filter { it.isNotBlank() }.toSet()
        if (cleared.isEmpty()) return
        val last = lastConversationId.get()
        if (last != null && last in cleared) lastConversationId.compareAndSet(last, null)
    }

    private fun playNotificationSound(sound: SonarNotificationSound) {
        val generation = soundGeneration.incrementAndGet()
        soundExecutor.execute {
            if (generation != soundGeneration.get()) return@execute
            val resource = when (sound) {
                SonarNotificationSound.Default -> "/sonar_notification.wav"
                SonarNotificationSound.Ble -> "/sonar_ble_notification.wav"
                SonarNotificationSound.Trill -> "/sonar_trill.wav"
            }
            val bytes = Notifier::class.java
                .getResourceAsStream(resource)
                ?.buffered()
                ?: run {
                    sonarLog("Notifier", "Missing desktop notification sound: $resource")
                    return@execute
                }
            runCatching {
                bytes.use { input ->
                    AudioSystem.getAudioInputStream(input).use { audio ->
                        AudioSystem.getClip().use { clip ->
                            clip.open(audio)
                            clip.start()
                            val deadlineNanos = System.nanoTime() +
                                TimeUnit.MICROSECONDS.toNanos(clip.microsecondLength) +
                                TimeUnit.SECONDS.toNanos(1)
                            while (
                                generation == soundGeneration.get() &&
                                clip.microsecondPosition < clip.microsecondLength &&
                                System.nanoTime() < deadlineNanos
                            ) {
                                Thread.sleep(25)
                            }
                            if (clip.isRunning) clip.stop()
                        }
                    }
                }
            }.onFailure {
                sonarLog("Notifier", "Failed to play desktop notification sound $resource: ${it.message}")
            }
        }
    }
}
