package chat.bitchat.sonar

import java.awt.Color
import java.awt.SystemTray
import java.awt.TrayIcon
import java.awt.image.BufferedImage

/**
 * Desktop (JVM) `actual`: incoming-message notifications via the AWT system tray
 * (the desktop twin of Android's notification channel). Falls back to a no-op
 * where the tray is unsupported (e.g. headless or some Linux desktops).
 */
actual object Notifier {
    @Volatile private var trayIcon: TrayIcon? = null

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
            val icon = TrayIcon(trayImage(), "Sonar").apply { isImageAutoSize = true }
            SystemTray.getSystemTray().add(icon)
            trayIcon = icon
        }
    }

    actual fun canNotify(): Boolean = SystemTray.isSupported()

    actual fun onWalletReady() { /* no push webhooks on desktop */ }

    actual fun onPaymentOfferReady(offer: String) { /* no push webhooks on desktop */ }

    actual fun setPushEnabled(enabled: Boolean) { /* no push on desktop */ }

    actual fun notify(id: Int, title: String, body: String) {
        val icon = trayIcon ?: run { ensureChannel(); trayIcon } ?: return
        runCatching { icon.displayMessage(title, body, TrayIcon.MessageType.INFO) }
    }
}
