package chat.bitchat.sonar

internal sealed interface DesktopSecretLookup {
    data class Found(val value: String) : DesktopSecretLookup
    data object Absent : DesktopSecretLookup
    data object Unavailable : DesktopSecretLookup
}

internal interface DesktopSecretBackend {
    fun lookup(key: String): DesktopSecretLookup
    fun proveAbsent(key: String): DesktopSecretLookup = lookup(key)
    fun put(key: String, value: String): Boolean
    fun delete(key: String): Boolean
}

/** Deletion success is not evidence of absence: Secret Service may leave a
 * locked duplicate inaccessible. A panic wipe commits only after a fresh,
 * authoritative lookup positively reports no matching item. */
internal fun deleteAndProveSecretAbsent(backend: DesktopSecretBackend, key: String): Boolean =
    when (backend.proveAbsent(key)) {
        DesktopSecretLookup.Absent -> true
        DesktopSecretLookup.Unavailable -> false
        is DesktopSecretLookup.Found ->
            backend.delete(key) && backend.proveAbsent(key) == DesktopSecretLookup.Absent
    }

/** Classify `secret-tool search --all --unlock` without confusing an empty,
 * successful search with a command failure. Unlike `lookup`, `search` returns
 * status 0 when no items match and distinguishes that case by producing no
 * output. Any non-zero status or diagnostic error remains fail-closed. */
internal fun classifySecretToolSearch(
    status: Int,
    stdout: String,
    stderr: String,
): DesktopSecretLookup = when {
    status != 0 || stderr.isNotEmpty() -> DesktopSecretLookup.Unavailable
    stdout.isEmpty() -> DesktopSecretLookup.Absent
    else -> DesktopSecretLookup.Found("<redacted>")
}

/**
 * OS-backed store for identity-controlling secrets. Linux deliberately fails
 * closed when Secret Service is locked/unavailable: an empty-looking lookup is
 * considered `Absent` only for the CLI's explicit no-match exit with no error.
 * The durable panic marker therefore survives until the keyring is unlocked and
 * every duplicate can be proven absent.
 */
object DesktopSecrets {
    private const val SERVICE = "chat.bitchat.sonar"
    private val osName = System.getProperty("os.name").lowercase()
    private val isMac = osName.contains("mac")
    private val isLinux = osName.contains("linux")
    private val backend: DesktopSecretBackend? by lazy {
        when {
            isMac -> MacKeychainBackend
            isLinux -> LinuxSecretServiceBackend
            else -> null
        }
    }

    fun get(key: String): String? {
        val store = backend
        val lookup = store?.lookup(key)
        if (lookup is DesktopSecretLookup.Found) return lookup.value
        if (store == null) return DesktopEnv.getString(key)
        val legacy = DesktopEnv.getString(key) ?: return null
        if (store.put(key, legacy) && store.lookup(key) == DesktopSecretLookup.Found(legacy)) {
            DesktopEnv.removeDurable(key)
        }
        return legacy
    }

    fun put(key: String, value: String) {
        if (backend?.put(key, value) == true) {
            DesktopEnv.remove(key)
        } else {
            DesktopEnv.putString(key, value)
        }
    }

    /** Atomically replace a secret and positively verify the stored value. */
    fun putDurable(key: String, value: String): Boolean {
        val store = backend
        if (store != null && store.put(key, value) && store.lookup(key) == DesktopSecretLookup.Found(value)) {
            return DesktopEnv.removeDurable(key)
        }
        return runCatching { DesktopEnv.putStringDurable(key, value); true }.getOrDefault(false)
    }

    /** True only when every OS-backed secret is positively proven absent. */
    fun clear(vararg keys: String): Boolean =
        backend?.let { store -> keys.all { deleteAndProveSecretAbsent(store, it) } } ?: true

    private data class CommandResult(val status: Int, val stdout: String, val stderr: String)

    private fun command(vararg args: String, stdin: String? = null): CommandResult? = runCatching {
        val process = ProcessBuilder(*args).redirectErrorStream(false).start()
        if (stdin != null) process.outputStream.bufferedWriter().use { it.write(stdin) }
        val stdout = process.inputStream.bufferedReader().use { it.readText() }.trimEnd('\n', '\r')
        val stderr = process.errorStream.bufferedReader().use { it.readText() }.trim()
        CommandResult(process.waitFor(), stdout, stderr)
    }.getOrNull()

    private object MacKeychainBackend : DesktopSecretBackend {
        override fun lookup(key: String): DesktopSecretLookup {
            val result = command("security", "find-generic-password", "-s", SERVICE, "-a", key, "-w")
                ?: return DesktopSecretLookup.Unavailable
            return when {
                result.status == 0 && result.stdout.isNotEmpty() -> DesktopSecretLookup.Found(result.stdout)
                result.status == 44 -> DesktopSecretLookup.Absent
                else -> DesktopSecretLookup.Unavailable
            }
        }

        override fun put(key: String, value: String): Boolean =
            command("security", "add-generic-password", "-s", SERVICE, "-a", key, "-w", value, "-U")?.status == 0

        override fun delete(key: String): Boolean =
            command("security", "delete-generic-password", "-s", SERVICE, "-a", key)?.status == 0
    }

    private object LinuxSecretServiceBackend : DesktopSecretBackend {
        override fun lookup(key: String): DesktopSecretLookup {
            val result = command("secret-tool", "lookup", "service", SERVICE, "key", key)
                ?: return DesktopSecretLookup.Unavailable
            return when {
                result.status == 0 && result.stdout.isNotEmpty() -> DesktopSecretLookup.Found(result.stdout)
                // `secret-tool lookup` uses 1/no stderr for an authoritative
                // no-match. A locked collection/session emits an error instead.
                result.status == 1 && result.stderr.isEmpty() -> DesktopSecretLookup.Absent
                else -> DesktopSecretLookup.Unavailable
            }
        }

        /**
         * `lookup` can miss a duplicate in a locked collection. `search --all
         * --unlock` is the Secret Service operation that can positively rule
         * out every matching item. Cancellation, a locked collection, and an
         * unavailable session all remain `Unavailable`, keeping the durable
         * panic marker armed for a later retry.
         */
        override fun proveAbsent(key: String): DesktopSecretLookup {
            val result = command(
                "secret-tool", "search", "--all", "--unlock",
                "service", SERVICE, "key", key,
            ) ?: return DesktopSecretLookup.Unavailable
            return classifySecretToolSearch(result.status, result.stdout, result.stderr)
        }

        override fun put(key: String, value: String): Boolean =
            command(
                "secret-tool", "store", "--label", "$SERVICE/$key",
                "service", SERVICE, "key", key,
                stdin = value,
            )?.status == 0

        override fun delete(key: String): Boolean =
            command("secret-tool", "clear", "service", SERVICE, "key", key)?.status == 0
    }
}
