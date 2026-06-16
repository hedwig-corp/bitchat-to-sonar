package chat.bitchat.sonar

/**
 * OS-backed store for the identity-controlling secrets — the Nostr `nsec` and the
 * SQLCipher DB key — so they don't sit in plaintext in `prefs.properties` (which
 * also derives the Lightning wallet seed, i.e. it controls real funds). The mobile
 * apps keep these in the iOS Keychain / Android Keystore; this is the desktop twin.
 *
 * - **macOS**: the login Keychain (`security` generic-password), encrypted at rest
 *   and gated by the OS. Verified to round-trip headlessly (the `security` binary
 *   is the accessor, so reads don't prompt).
 * - **Other platforms**: falls back to [DesktopEnv] prefs for now (tracked
 *   follow-up: Windows Credential Manager / Linux Secret Service).
 *
 * Fail-safe by construction: a Keychain miss or error falls through to the prefs
 * value, so a user is NEVER locked out of their identity. Legacy plaintext secrets
 * are migrated into the Keychain transparently on first read and then removed from
 * prefs.
 */
object DesktopSecrets {
    private const val SERVICE = "chat.bitchat.sonar"
    private val isMac = System.getProperty("os.name").lowercase().contains("mac")

    /** Read [key] from the OS keystore; on macOS, transparently migrate a legacy
     *  plaintext prefs value into the Keychain (then drop it from prefs). */
    fun get(key: String): String? {
        if (!isMac) return DesktopEnv.getString(key)
        keychainGet(key)?.let { return it }
        // Legacy plaintext (pre-keystore build): migrate it in, then forget it.
        val legacy = DesktopEnv.getString(key) ?: return null
        if (keychainPut(key, legacy)) DesktopEnv.remove(key)
        return legacy
    }

    /** Persist [key] in the OS keystore (macOS) or prefs (fallback). On macOS a
     *  successful keystore write also clears any plaintext copy from prefs. */
    fun put(key: String, value: String) {
        if (isMac && keychainPut(key, value)) {
            DesktopEnv.remove(key)
            return
        }
        DesktopEnv.putString(key, value)
    }

    private fun keychainGet(key: String): String? = runCatching {
        val p = ProcessBuilder("security", "find-generic-password", "-s", SERVICE, "-a", key, "-w")
            .redirectErrorStream(false).start()
        val out = p.inputStream.bufferedReader().use { it.readText() }.trimEnd('\n', '\r')
        if (p.waitFor() == 0 && out.isNotEmpty()) out else null
    }.getOrNull()

    private fun keychainPut(key: String, value: String): Boolean = runCatching {
        // -U updates an existing item. The secret rides in argv; on a single-user
        // desktop that brief, local window is acceptable versus plaintext-at-rest
        // (tracked: move to stdin / Security.framework to remove even that).
        ProcessBuilder("security", "add-generic-password", "-s", SERVICE, "-a", key, "-w", value, "-U")
            .redirectErrorStream(true).start().waitFor() == 0
    }.getOrDefault(false)
}
