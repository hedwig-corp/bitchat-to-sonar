package chat.bitchat.sonar

/**
 * OS-backed store for the identity-controlling secrets — the Nostr `nsec` and the
 * SQLCipher DB key — so they don't sit in plaintext in `prefs.properties` (which
 * also derives the Lightning wallet seed, i.e. it controls real funds). The mobile
 * apps keep these in the iOS Keychain / Android Keystore; this is the desktop twin.
 *
 * - **macOS**: the login Keychain (`security` generic-password), encrypted at rest
 *   and gated by the OS.
 * - **Linux**: the Secret Service D-Bus API via `secret-tool` (GNOME Keyring,
 *   KDE Wallet, or any compliant backend), encrypted at rest and gated by the
 *   user session.
 * - **Other platforms**: falls back to [DesktopEnv] prefs (tracked follow-up:
 *   Windows Credential Manager).
 *
 * Fail-safe by construction: a keystore miss or error falls through to the prefs
 * value, so a user is NEVER locked out of their identity. Legacy plaintext secrets
 * are migrated into the OS keystore transparently on first read and then removed
 * from prefs.
 */
object DesktopSecrets {
    private const val SERVICE = "chat.bitchat.sonar"
    private val osName = System.getProperty("os.name").lowercase()
    private val isMac = osName.contains("mac")
    private val isLinux = osName.contains("linux")

    fun get(key: String): String? {
        val osValue = when {
            isMac -> keychainGet(key)
            isLinux -> secretToolGet(key)
            else -> null
        }
        if (osValue != null) return osValue
        if (!isMac && !isLinux) return DesktopEnv.getString(key)
        val legacy = DesktopEnv.getString(key) ?: return null
        if (osPut(key, legacy)) DesktopEnv.remove(key)
        return legacy
    }

    fun put(key: String, value: String) {
        if (osPut(key, value)) {
            DesktopEnv.remove(key)
            return
        }
        DesktopEnv.putString(key, value)
    }

    private fun osPut(key: String, value: String): Boolean = when {
        isMac -> keychainPut(key, value)
        isLinux -> secretToolPut(key, value)
        else -> false
    }

    // ---- macOS Keychain ----

    private fun keychainGet(key: String): String? = runCatching {
        val p = ProcessBuilder("security", "find-generic-password", "-s", SERVICE, "-a", key, "-w")
            .redirectErrorStream(false).start()
        val out = p.inputStream.bufferedReader().use { it.readText() }.trimEnd('\n', '\r')
        if (p.waitFor() == 0 && out.isNotEmpty()) out else null
    }.getOrNull()

    private fun keychainPut(key: String, value: String): Boolean = runCatching {
        ProcessBuilder("security", "add-generic-password", "-s", SERVICE, "-a", key, "-w", value, "-U")
            .redirectErrorStream(true).start().waitFor() == 0
    }.getOrDefault(false)

    // ---- Linux Secret Service (via secret-tool CLI) ----

    private fun secretToolGet(key: String): String? = runCatching {
        val p = ProcessBuilder("secret-tool", "lookup", "service", SERVICE, "key", key)
            .redirectErrorStream(false).start()
        val out = p.inputStream.bufferedReader().use { it.readText() }.trimEnd('\n', '\r')
        if (p.waitFor() == 0 && out.isNotEmpty()) out else null
    }.getOrNull()

    private fun secretToolPut(key: String, value: String): Boolean = runCatching {
        val p = ProcessBuilder("secret-tool", "store", "--label", "$SERVICE/$key", "service", SERVICE, "key", key)
            .redirectErrorStream(true).start()
        p.outputStream.bufferedWriter().use { it.write(value) }
        p.waitFor() == 0
    }.getOrDefault(false)
}
