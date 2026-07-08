package chat.bitchat.sonar

import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

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

    // Single control thread. All spawn/teardown work — the temp-file write, the
    // afplay fork/exec, and destroy()/waitFor() — runs here, never on the Compose
    // main thread (per the Signal-comparable perf rule). FIFO ordering guarantees a
    // play() that follows a stop() always observes the teardown first.
    private val control: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "sonar-afplay-ctl").apply { isDaemon = true }
    }

    private val lock = Any()
    private var process: Process? = null
    private var tempFile: File? = null
    private var onDone: (() -> Unit)? = null
    // Monotonic playback id. Every play()/stop() bumps it; the waiter thread
    // captures its value and only finalizes if it is still current, so a stale
    // waiter from a previous note can never clobber a newly-started one.
    private var generation = 0

    private val shutdownHookInstalled = AtomicBoolean(false)

    /**
     * Delete decrypted voice-note temp files orphaned by a prior hard kill (playback
     * that never reached teardown). Call once from the desktop entry point ([main]):
     * this object's `init` would be lazy (first play/stop), so leaving the sweep
     * implicit would skip it in a session that never plays a note. Also installs a
     * one-time shutdown hook so a graceful quit mid-playback deletes the live file
     * (kill -9 is covered by the next launch's sweep).
     */
    fun sweepOrphans() {
        if (shutdownHookInstalled.compareAndSet(false, true)) {
            runCatching {
                Runtime.getRuntime().addShutdownHook(Thread {
                    synchronized(lock) {
                        runCatching { process?.destroy() }
                        tempFile?.let { runCatching { it.delete() } }
                    }
                })
            }
        }
        runCatching {
            System.getProperty("java.io.tmpdir")?.let { dir ->
                File(dir).listFiles { f ->
                    f.name.startsWith(TMP_PREFIX) && f.name.endsWith(TMP_SUFFIX)
                }?.forEach { runCatching { it.delete() } }
            }
        }
    }

    actual fun play(bytes: ByteArray, onComplete: () -> Unit) {
        val os = System.getProperty("os.name").lowercase()
        if (!os.contains("mac")) {
            // Linux/Windows desktop: no built-in AAC player yet (follow-up: ffplay/JavaFX).
            onComplete()
            return
        }
        control.execute {
            // Tear down any in-flight playback first (fires its completion, resets the
            // previous bubble) before adopting the new note.
            teardown()
            // OS temp dir (swept by the OS), never persistent app data — plus the
            // startup sweep — so an interrupted play cannot leave decrypted E2EE audio.
            val file = runCatching {
                File.createTempFile(TMP_PREFIX, TMP_SUFFIX)
            }.getOrElse { onComplete(); return@execute }
            try {
                file.writeBytes(bytes)
            } catch (_: Exception) {
                file.delete()
                onComplete()
                return@execute
            }
            val afplay = runCatching {
                ProcessBuilder("/usr/bin/afplay", file.absolutePath)
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                    .redirectError(ProcessBuilder.Redirect.DISCARD)
                    .start()
            }.getOrElse {
                file.delete()
                onComplete()
                return@execute
            }
            val gen: Int
            synchronized(lock) {
                gen = ++generation
                process = afplay
                tempFile = file
                onDone = onComplete
            }
            Thread({
                try {
                    afplay.waitFor()
                } catch (_: InterruptedException) {
                    runCatching { afplay.destroy() }
                } finally {
                    finishPlayback(gen)
                }
            }, "sonar-afplay").apply {
                isDaemon = true
                start()
            }
        }
    }

    actual fun stop() {
        control.execute { teardown() }
    }

    // Runs on the control thread. Destroys the current process, deletes its temp
    // file, fires the pending completion, and orphans the in-flight waiter so its
    // finishPlayback() no-ops. waitFor() is intentionally outside the lock so the
    // waiter can acquire it and bail immediately once the process dies.
    private fun teardown() {
        val p: Process?
        val f: File?
        val cb: (() -> Unit)?
        synchronized(lock) {
            p = process
            f = tempFile
            cb = onDone
            generation++
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
