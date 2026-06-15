package chat.bitchat.sonar

/**
 * Optional app lock — gate the app behind the device credential / biometric on
 * launch and when returning from background, mirroring the iOS "App lock"
 * setting. Backed by the platform secure lock; no separate PIN is stored.
 */
expect object AppLock {
    /** User preference. */
    fun isEnabled(): Boolean
    fun setEnabled(value: Boolean)

    /** True only if the device actually has a secure lock set (else the toggle
     *  is meaningless and is hidden, like iOS hides un-backed settings). */
    fun isAvailable(): Boolean

    /** Prompt for the device credential; [onResult] gets true on success. */
    fun authenticate(onResult: (Boolean) -> Unit)
}
