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

    /**
     * Keystore namespace. Overridable ONLY so tests can exercise the real
     * store/delete paths without touching the developer's login keyring: the
     * service name is global, unaffected by any data-dir redirection, so a test
     * calling [clear] against the default would irreversibly delete the real
     * account key. That is the Account Key Durability Rule violated by a test.
     */
    @Volatile
    internal var service: String = SERVICE
        private set

    internal fun useTestService(name: String) { service = name }
    internal fun resetService() { service = SERVICE }
    private val osName = System.getProperty("os.name").lowercase()
    private val isMac = osName.contains("mac")
    private val isLinux = osName.contains("linux")

    /**
     * True once any secret has had to fall back to plaintext [DesktopEnv] prefs
     * because the OS keystore was unavailable.
     *
     * The fallback itself must stay: the Account Key Durability Rule forbids
     * failing to persist the account key, and refusing to write would lose the
     * identity (and the wallet it derives) rather than protect it. What is NOT
     * acceptable is doing it silently, which is what shipped: on a default Linux
     * desktop `secret-tool` is not installed, so the nsec, the SQLCipher DB key
     * and the mesh keys land in cleartext with nothing telling the user.
     *
     * Hosts surface this; see [keystoreUnavailableReason] for what to say.
     */
    @Volatile
    private var fellBackToPlaintext = false

    fun plaintextFallbackInUse(): Boolean = fellBackToPlaintext || storedInPlaintext().isNotEmpty()

    /** Secret keys currently sitting in plaintext prefs, for diagnostics/UI. */
    fun storedInPlaintext(): List<String> =
        MANAGED_KEYS.filter { DesktopEnv.getString(it) != null }

    /**
     * Null when an OS keystore is usable, otherwise a short reason suitable for
     * showing to the user.
     */
    fun keystoreUnavailableReason(): String? = when {
        isMac -> if (keychainProbe()) null else "the macOS Keychain is not responding"
        isLinux ->
            if (!secretToolProbe())
                "secret-tool is not installed (install the libsecret-tools package)"
            else if (fellBackToPlaintext)
                "the system keyring refused to store it (is GNOME Keyring or KDE Wallet running and unlocked?)"
            else null
        else -> "this platform has no supported OS keystore"
    }

    /**
     * Every key this object owns, all identity- or fund-controlling.
     *
     * Internal, and the wipe path must clear exactly this list. When these lived
     * in plain prefs a wipe removed them incidentally via `DesktopEnv.clear()`;
     * moving them into the keystore put them out of that reach, so a wipe left
     * the mesh Ed25519 seed behind and the NEXT account advertised a new npub
     * signed by the OLD key, linking the two for any passive BLE listener.
     */
    internal val MANAGED_KEYS = listOf(
        "nsec",
        "dbKeyHex",
        "mesh.noise.priv",
        "mesh.noise.pub",
        "mesh.ed25519.seed",
    )

    fun get(key: String): String? {
        val osValue = when {
            isMac -> keychainGet(key)
            isLinux -> secretToolGet(key)
            else -> null
        }
        if (osValue != null) {
            val local = DesktopEnv.getString(key)
            if (local == null) return osValue
            if (local == osValue) {
                // Identical copies: the duplicate is safe to drop, and leaving it
                // would keep the banner up telling the user to restart to fix
                // something restarting cannot fix.
                DesktopEnv.remove(key)
                return osValue
            }
            // They DIFFER, so the prefs copy is the newer one: it is only ever
            // written when a keystore write failed, which leaves the older value
            // stranded in the keystore. Deleting it here (as this did) let the
            // stale keystore value win and destroyed the current key. Push the
            // newer value back and only drop the local copy once the keystore
            // confirms it.
            if (osPut(key, local) && osGet(key) == local) {
                DesktopEnv.remove(key)
            } else {
                fellBackToPlaintext = true
            }
            return local
        }
        if (!isMac && !isLinux) return DesktopEnv.getString(key)
        val legacy = DesktopEnv.getString(key) ?: return null
        // Read BACK before dropping the plaintext copy. `osPut` trusts an exit
        // code from a PATH-resolved helper; a shim (or a keystore that reports
        // success without persisting) would otherwise take the only copy of the
        // account key with it. One extra call, migration path only.
        if (osPut(key, legacy) && osGet(key) == legacy) {
            DesktopEnv.remove(key)
        } else {
            fellBackToPlaintext = true
        }
        return legacy
    }

    fun put(key: String, value: String) {
        if (osPut(key, value)) {
            DesktopEnv.remove(key)
            return
        }
        // Persist anyway (never lose the key), but record it and make sure the
        // file is not readable by other local users.
        fellBackToPlaintext = true
        sonarLog(
            "DesktopSecrets",
            "OS keystore unavailable, storing '$key' in local prefs instead: " +
                (keystoreUnavailableReason() ?: "unknown reason"),
        )
        DesktopEnv.putString(key, value)
    }

    /**
     * Whether a null from [get] can be trusted to mean "not stored".
     *
     * It cannot be inferred from the helper's exit status: `secret-tool lookup`
     * exits 1 both when the key is absent AND when the keyring is unreachable
     * (verified empirically; only stderr differs, which is locale-dependent and
     * not worth parsing). So this does an authoritative round trip on a canary
     * key in our own namespace.
     *
     * Callers must consult this BEFORE generating a replacement secret. Treating
     * "unreadable" as "absent" is how an account key, a SQLCipher key or a mesh
     * identity gets silently regenerated and the old one becomes unreachable.
     *
     * Cached: one probe per session, and only the generate paths pay for it.
     */
    fun absenceIsTrustworthy(): Boolean = canaryOk

    private val canaryOk: Boolean by lazy {
        // No OS keystore expected: prefs is the store, and it is always readable,
        // so a null genuinely means absent.
        if (!isMac && !isLinux) return@lazy true
        if (!binaryAvailable()) return@lazy false
        val probe = "__sonar_canary__"
        val token = java.util.UUID.randomUUID().toString()
        val ok = osPut(probe, token) && osGet(probe) == token
        runCatching { if (isMac) keychainDelete(probe) else secretToolDelete(probe) }
        ok
    }

    private fun binaryAvailable(): Boolean = if (isMac) macProbe else linuxProbe

    fun clear(vararg keys: String) {
        keys.forEach { key ->
            when {
                isMac -> keychainDelete(key)
                isLinux -> secretToolDelete(key)
            }
            DesktopEnv.remove(key)
        }
    }

    private fun osGet(key: String): String? = when {
        isMac -> keychainGet(key)
        isLinux -> secretToolGet(key)
        else -> null
    }

    private fun osPut(key: String, value: String): Boolean = when {
        isMac -> keychainPut(key, value)
        isLinux -> secretToolPut(key, value)
        else -> false
    }

    // ---- Availability probes (cached: the answer cannot change mid-session in
    //      any way we can act on, and these fork a process). ----

    /**
     * Whether the helper binary exists, resolved by scanning `PATH` rather than
     * executing anything.
     *
     * Executing was wrong twice over. Exit status is meaningless here
     * (`secret-tool --version` exits 2 even when working, which would report a
     * healthy keystore as missing). And the first probe runs from composition on
     * the AWT event thread, so a helper that hangs (wedged D-Bus, a PATH entry on
     * a stalled network mount) would freeze the UI with no recovery. A lookup has
     * no such failure mode and no side effects.
     */
    private fun onPath(binary: String): Boolean {
        val path = System.getenv("PATH") ?: return false
        // runCatching INSIDE the loop: one malformed entry (InvalidPathException)
        // must skip that entry, not abort the scan and report the keystore
        // missing on a machine where the helper is installed.
        return path.split(java.io.File.pathSeparatorChar).any { dir ->
            dir.isNotEmpty() && runCatching {
                java.nio.file.Files.isExecutable(java.nio.file.Paths.get(dir).resolve(binary))
            }.getOrDefault(false)
        }
    }

    private val macProbe: Boolean by lazy { onPath("security") }
    private val linuxProbe: Boolean by lazy { onPath("secret-tool") }

    private fun keychainProbe(): Boolean = macProbe
    private fun secretToolProbe(): Boolean = linuxProbe

    // ---- macOS Keychain ----

    private fun keychainGet(key: String): String? = runCatching {
        val p = ProcessBuilder("security", "find-generic-password", "-s", service, "-a", key, "-w")
            .redirectErrorStream(false).start()
        val out = p.inputStream.bufferedReader().use { it.readText() }.trimEnd('\n', '\r')
        if (p.waitFor() == 0 && out.isNotEmpty()) out else null
    }.getOrNull()

    private fun keychainPut(key: String, value: String): Boolean = runCatching {
        ProcessBuilder("security", "add-generic-password", "-s", service, "-a", key, "-w", value, "-U")
            .redirectErrorStream(true).start().waitFor() == 0
    }.getOrDefault(false)

    private fun keychainDelete(key: String): Boolean = runCatching {
        ProcessBuilder("security", "delete-generic-password", "-s", service, "-a", key)
            .redirectErrorStream(true).start().waitFor() == 0
    }.getOrDefault(false)

    // ---- Linux Secret Service (via secret-tool CLI) ----

    private fun secretToolGet(key: String): String? = runCatching {
        val p = ProcessBuilder("secret-tool", "lookup", "service", service, "key", key)
            .redirectErrorStream(false).start()
        val out = p.inputStream.bufferedReader().use { it.readText() }.trimEnd('\n', '\r')
        if (p.waitFor() == 0 && out.isNotEmpty()) out else null
    }.getOrNull()

    private fun secretToolPut(key: String, value: String): Boolean = runCatching {
        val p = ProcessBuilder("secret-tool", "store", "--label", "$service/$key", "service", service, "key", key)
            .redirectErrorStream(true).start()
        p.outputStream.bufferedWriter().use { it.write(value) }
        p.waitFor() == 0
    }.getOrDefault(false)

    private fun secretToolDelete(key: String): Boolean = runCatching {
        ProcessBuilder("secret-tool", "clear", "service", service, "key", key)
            .redirectErrorStream(true).start().waitFor() == 0
    }.getOrDefault(false)
}
