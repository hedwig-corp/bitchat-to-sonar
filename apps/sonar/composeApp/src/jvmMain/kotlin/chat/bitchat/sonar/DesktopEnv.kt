package chat.bitchat.sonar

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Properties

/**
 * Desktop (JVM) environment: the per-user data directory and a simple persisted
 * key/value store — the desktop twin of Android's `filesDir` + SharedPreferences
 * (used by the jvm `actual`s of SonarCore, MessageStore, WalletBridge, AppLock,
 * Notifier). Everything lives under an OS-appropriate app-data directory so a
 * desktop install keeps its identity, DB and transcripts across restarts.
 */
object DesktopEnv {

    /** Root data dir, e.g. ~/Library/Application Support/Sonar (macOS),
     *  $XDG_DATA_HOME/Sonar or ~/.local/share/Sonar (Linux),
     *  %APPDATA%\Sonar (Windows). Created on first use. */
    /**
     * Test-only redirection of the data root.
     *
     * Without it, touching any pref from a test initializes the real
     * `~/.local/share/Sonar`, chmods it, and loads the developer's actual nsec
     * into the test JVM. Tests then assert against live machine state and pass
     * vacuously on CI.
     */
    @Volatile
    internal var testRootOverride: File? = null

    /**
     * Point storage at [root], or back at the real dir when null. Test use only.
     *
     * ALWAYS clears the prefs cache. Assigning [testRootOverride] directly left
     * the cache holding the test's Properties while the path reverted to the
     * real data dir, so the next write persisted test state over real prefs.
     */
    internal fun useTestRoot(root: File?) {
        testRootOverride = root?.apply { mkdirs() }
        cachedProps = null
        permissionsUnenforceable = false
    }

    val dataDir: File get() = testRootOverride ?: defaultDataDir

    private val defaultDataDir: File by lazy {
        val home = System.getProperty("user.home")
        val os = System.getProperty("os.name").lowercase()
        val base = when {
            os.contains("mac") -> File(home, "Library/Application Support/Sonar")
            os.contains("win") -> File(System.getenv("APPDATA") ?: "$home/AppData/Roaming", "Sonar")
            else -> File(System.getenv("XDG_DATA_HOME") ?: "$home/.local/share", "Sonar")
        }
        base.apply {
            mkdirs()
            // Owner-only: this directory holds the encrypted Marmot DB, the
            // transcripts, and (when no OS keystore is available) the account
            // key itself. The default umask leaves it group/world readable.
            if (!restrictToOwner(this, ownerExecutable = true)) permissionsUnenforceable = true
        }
    }

    /**
     * Best effort chmod 0700/0600. A failure must not be fatal: losing the data
     * directory would lose the account, which is far worse than permissions
     * that are merely no better than the umask gave us.
     */
    internal fun restrictToOwner(target: File, ownerExecutable: Boolean = false): Boolean =
        runCatching {
            // Each call returns false when the filesystem cannot express the mode
            // (exFAT/NTFS/SMB, or Windows ACLs). Report that rather than claiming
            // protection we did not get: in a change whose whole point is "do not
            // be silent", a silently-failed chmod is the same bug again.
            // Collect, do NOT short-circuit: with `&&` a first failure skipped
            // the remaining clears, leaving group/other write and execute set on
            // a directory whose contents include the account key.
            listOf(
                target.setReadable(false, false),
                target.setWritable(false, false),
                target.setExecutable(false, false),
                target.setReadable(true, true),
                target.setWritable(true, true),
                if (ownerExecutable) target.setExecutable(true, true) else true,
            ).all { it }
        }.getOrDefault(false)

    /** True when the last permission tightening could not be applied. */
    @Volatile
    internal var permissionsUnenforceable: Boolean = false
        private set

    fun file(relative: String): File = File(dataDir, relative)

    // ── Preferences (a flat .properties file; thread-safe enough for the app's
    //    low write rate — every setter persists synchronously). ──
    private val prefsFile: File get() = File(dataDir, "prefs.properties")

    @Volatile
    private var cachedProps: Properties? = null

    private val props: Properties
        get() = cachedProps ?: loadProps().also { cachedProps = it }

    private fun loadProps(): Properties =
        Properties().apply {
            if (prefsFile.exists()) {
                // An install that upgrades into this build may still have the
                // world-readable file the bug shipped, and would never be
                // tightened if it performs no write this session.
                if (!restrictToOwner(prefsFile)) permissionsUnenforceable = true
                prefsFile.inputStream().use { load(it) }
            }
        }

    @Synchronized
    fun getString(key: String, default: String? = null): String? =
        props.getProperty(key) ?: default

    @Synchronized
    fun putString(key: String, value: String) {
        props.setProperty(key, value)
        persist()
    }

    @Synchronized
    fun getBoolean(key: String, default: Boolean): Boolean =
        props.getProperty(key)?.toBooleanStrictOrNull() ?: default

    @Synchronized
    fun putBoolean(key: String, value: Boolean) {
        props.setProperty(key, value.toString())
        persist()
    }

    @Synchronized
    fun remove(key: String) {
        props.remove(key)
        persist()
    }

    @Synchronized
    fun clear() {
        props.clear()
        persist()
    }

    // Atomic write: serialize to a sibling temp file, then move it into place.
    // A plain truncating write would, on a crash mid-store(), leave prefs.properties
    // empty — losing the nsec identity AND the SQLCipher DB key (an undecryptable
    // chat DB). Android's SharedPreferences writes atomically; match that.
    private fun persist() {
        runCatching {
            // Create EMPTY, tighten, then write. Tightening after the write left
            // a window where a tmp file containing the nsec sat at umask perms.
            // A unique name per call also stops two processes interleaving into
            // one staging path.
            val tmp = File.createTempFile("prefs", ".tmp", dataDir)
            if (!restrictToOwner(tmp)) permissionsUnenforceable = true
            runCatching {
                tmp.outputStream().use { props.store(it, "Sonar desktop preferences") }
            }.onFailure {
                // A partial secrets file must not be left behind at umask perms.
                tmp.delete()
                throw it
            }
            // Any staging file that survived a crash or a failed move is a full
            // plaintext copy of the prefs, including the nsec. Sweep them.
            dataDir.listFiles { f -> f.name.startsWith("prefs") && f.name.endsWith(".tmp") }
                ?.forEach { if (it != tmp) it.delete() }
            try {
                Files.move(
                    tmp.toPath(), prefsFile.toPath(),
                    StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: Throwable) {
                // Some filesystems don't support ATOMIC_MOVE; fall back to a plain
                // replace (still far better than a truncating in-place write).
                Files.move(tmp.toPath(), prefsFile.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        }
    }
}

/**
 * Extracts the bundled Rust-core dynamic library (libsonar_ffi.<ext>) from the
 * classpath resources (jvmMain/resources/<jna-prefix>/…) to a temp file and
 * points UniFFI's JNA loader at it. Setting `uniffi.component.sonar_ffi.libraryOverride`
 * makes the generated bindings load this exact file by absolute path, which is
 * far more robust than relying on JNA's default search across packaging modes
 * (run from Gradle, a fat jar, or a native distribution).
 */
object SonarNativeLoader {
    @Volatile private var loaded = false

    fun ensureLoaded() {
        if (loaded) return
        synchronized(this) {
            if (loaded) return
            val mapped = System.mapLibraryName("sonar_ffi") // libsonar_ffi.dylib / .so / sonar_ffi.dll
            val prefix = runCatching { com.sun.jna.Platform.RESOURCE_PREFIX }.getOrNull() // e.g. darwin-aarch64
            val candidates = buildList {
                if (prefix != null) add("/$prefix/$mapped")
                // Fallbacks for the un-suffixed darwin folder build-desktop.sh also emits.
                add("/darwin/$mapped")
            }
            val stream = candidates.firstNotNullOfOrNull { javaClass.getResourceAsStream(it) }
            if (stream == null) {
                // Not bundled (e.g. running on an OS we didn't build the core for).
                // Leave loaded=false so SonarCore.start() surfaces a clear error.
                return
            }
            val tmpDir = Files.createTempDirectory("sonar-native")
            val out = tmpDir.resolve(mapped)
            stream.use { Files.copy(it, out) }
            out.toFile().deleteOnExit()
            System.setProperty(
                "uniffi.component.sonar_ffi.libraryOverride",
                out.toAbsolutePath().toString(),
            )
            loaded = true
        }
    }
}
