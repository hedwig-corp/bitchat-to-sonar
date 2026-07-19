package chat.bitchat.sonar

/** Desktop (JVM) `actual`: no-op. There is no haptic hardware, and desktop
 *  alert audio already flows through the tray-notification sound path
 *  ([Notifier.notify] with [SonarNotificationSound.Trill]). */
actual object TrillEffects {
    actual fun buzz() { /* no in-app buzz on desktop */ }

    actual fun reduceMotionEnabled(): Boolean = false
}
