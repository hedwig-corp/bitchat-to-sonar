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
    val dataDir: File by lazy {
        val home = System.getProperty("user.home")
        val os = System.getProperty("os.name").lowercase()
        val base = when {
            os.contains("mac") -> File(home, "Library/Application Support/Sonar")
            os.contains("win") -> File(System.getenv("APPDATA") ?: "$home/AppData/Roaming", "Sonar")
            else -> File(System.getenv("XDG_DATA_HOME") ?: "$home/.local/share", "Sonar")
        }
        base.apply { mkdirs() }
    }

    fun file(relative: String): File = File(dataDir, relative)

    // ── Preferences (a flat .properties file; thread-safe enough for the app's
    //    low write rate — every setter persists synchronously). ──
    private val prefsFile: File by lazy { File(dataDir, "prefs.properties") }
    private val props: Properties by lazy {
        Properties().apply {
            if (prefsFile.exists()) prefsFile.inputStream().use { load(it) }
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
            val tmp = File(prefsFile.absolutePath + ".tmp")
            tmp.outputStream().use { props.store(it, "Sonar desktop preferences") }
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
