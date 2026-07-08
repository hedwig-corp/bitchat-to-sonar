package chat.bitchat.sonar

import java.io.File

/**
 * Desktop (JVM) `actual`: recording is not wired yet (no JVM AAC encoder).
 * Playback: macOS uses `afplay` on a temp `.m4a` so received voice notes (including
 * Hermes/agent AAC) are audible in Compose Desktop / Sonar.app.
 */
actual class VoiceRecorder {
    actual suspend fun start(): Boolean = false
    actual fun elapsed(): Int = 0
    actual fun level(): Float = 0f
    actual fun finish(): ByteArray? = null
    actual fun cancel() {}
}

actual object AudioNotePlayer {
    private const val TMP_PREFIX = "sonar-vn-"
    private const val TMP_SUFFIX = ".m4a"

    private val lock = Any()
    private var process: Process? = null
    private var tempFile: File? = null
    private var onDone: (() -> Unit)? = null
    // Monotonic playback id. Every play()/stop() bumps it; the waiter thread
    // captures its value and only finalizes if it is still current, so a stale
    // waiter from a previous note can never clobber a newly-started one.
    private var generation = 0

    init {
        // Sweep decrypted voice-note temp files orphaned by a prior hard kill
        // (playback that never reached finishPlayback()). deleteOnExit() covers
        // graceful exits; this covers crashes/kill -9 on the next launch.
        runCatching {
            System.getProperty("java.io.tmpdir")?.let { dir ->
                File(dir).listFiles { f ->
                    f.name.startsWith(TMP_PREFIX) && f.name.endsWith(TMP_SUFFIX)
                }?.forEach { runCatching { it.delete() } }
            }
        }
    }

    actual fun play(bytes: ByteArray, onComplete: () -> Unit) {
        // Tear down any in-flight playback first (fires its completion, resets the
        // previous bubble) before adopting the new note.
        stop()
        val os = System.getProperty("os.name").lowercase()
        if (!os.contains("mac")) {
            // Linux/Windows desktop: no built-in AAC player yet (follow-up: ffplay/JavaFX).
            onComplete()
            return
        }
        // Write to the OS temp dir (swept by the OS), never persistent app data, with
        // deleteOnExit() as a backstop so an interrupted play cannot leave decrypted
        // E2EE audio behind.
        val file = runCatching {
            File.createTempFile(TMP_PREFIX, TMP_SUFFIX).apply { deleteOnExit() }
        }.getOrElse { onComplete(); return }
        try {
            file.writeBytes(bytes)
        } catch (_: Exception) {
            file.delete()
            onComplete()
            return
        }
        val afplay = runCatching {
            ProcessBuilder("afplay", file.absolutePath)
                .redirectErrorStream(true)
                .start()
        }.getOrElse {
            file.delete()
            onComplete()
            return
        }
        val gen: Int
        synchronized(lock) {
            gen = ++generation
            process = afplay
            tempFile = file
            onDone = onComplete
        }
        Thread {
            try {
                afplay.waitFor()
            } catch (_: InterruptedException) {
                runCatching { afplay.destroy() }
            } finally {
                finishPlayback(gen)
            }
        }.apply {
            isDaemon = true
            name = "sonar-afplay"
            start()
        }
    }

    actual fun stop() {
        val p: Process?
        val f: File?
        val cb: (() -> Unit)?
        synchronized(lock) {
            p = process
            f = tempFile
            cb = onDone
            generation++ // orphan the in-flight waiter so its finishPlayback() no-ops
            process = null
            tempFile = null
            onDone = null
        }
        if (p != null) {
            runCatching { p.destroy() }
            runCatching { p.waitFor() }
        }
        f?.let { runCatching { it.delete() } }
        cb?.invoke()
    }

    // Runs on the waiter thread when afplay exits on its own. Only finalizes if this
    // is still the current generation; a newer play()/stop() already cleaned up.
    private fun finishPlayback(gen: Int) {
        val cb: (() -> Unit)?
        synchronized(lock) {
            if (gen != generation) return // superseded — the newer call owns the state
            tempFile?.let { runCatching { it.delete() } }
            tempFile = null
            process = null
            cb = onDone
            onDone = null
            generation++ // consume this generation
        }
        cb?.invoke()
    }
}
