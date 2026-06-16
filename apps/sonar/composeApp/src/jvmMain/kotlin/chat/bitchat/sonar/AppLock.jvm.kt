package chat.bitchat.sonar

/**
 * Desktop (JVM) `actual`: there is no portable device-credential gate on desktop
 * the way Android/iOS expose one, so app lock is reported unavailable. The
 * Settings toggle hides itself when [isAvailable] is false (same rule as iOS
 * hiding un-backed settings), and [authenticate] succeeds immediately so the app
 * is never wedged behind a lock it can't satisfy.
 */
actual object AppLock {
    actual fun isEnabled(): Boolean = false
    actual fun setEnabled(value: Boolean) { /* no-op: unavailable on desktop */ }
    actual fun isAvailable(): Boolean = false
    actual fun authenticate(onResult: (Boolean) -> Unit) { onResult(true) }
}
