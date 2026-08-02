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

    /**
     * External players that can decode AAC-in-MP4 and exit on their own at the end
     * of the clip, most-preferred first.
     *
     * Every property in that sentence is load-bearing, and each one eliminated a
     * candidate:
     *
     * - **The JDK cannot do it.** `javax.sound` ships no AAC decoder, and JavaFX
     *   (which has one) is not in the runtime image the `linux { }` jpackage target
     *   builds, so this has to shell out.
     * - **Must decode AAC without a separately-packaged plugin.** `gst-play-1.0`
     *   was here and was removed: on a stock desktop the AAC plugin lives in
     *   `gstreamer1.0-plugins-bad`, and without it `gst-play-1.0` prints a plug-in
     *   error and **still exits 0**, in ~50ms for a 2s clip. Being on `PATH` does
     *   not imply being able to play, and its failure is indistinguishable from
     *   success, which is exactly the silent no-op this whole change exists to kill.
     *   Both entries below bundle their own decoder.
     * - **Must exit at end of clip**, since that is what fires [onComplete] and
     *   resets the bubble. `paplay`/`aplay` are excluded for being PCM-only, and
     *   each flag list makes termination explicit rather than leaning on a default
     *   a user config could flip.
     *
     * Both entries were run against a real 2s AAC `.m4a` before being added here:
     * `ffplay` 2242ms/exit 0, `cvlc` 2132ms/exit 0. `mpv` is a reasonable third
     * candidate and is deliberately NOT in the list, because it could not be
     * installed on the machine this was developed on and an entry whose flags have
     * never been executed is the same gamble `gst-play-1.0` just lost. Add it with
     * a timing run, not from the man page.
     */
    private val LINUX_PLAYERS = listOf(
        "ffplay" to listOf("-nodisp", "-autoexit", "-loglevel", "quiet"),
        "cvlc" to listOf("--intf", "dummy", "--play-and-exit", "--quiet"),
    )

    private val osName = System.getProperty("os.name").lowercase()
    private val isMac = osName.contains("mac")
    private val isLinux = osName.contains("linux")

    // Resolved `[binary] + flags` for this host, or null if nothing can play.
    // A resettable cache rather than `by lazy`: an object-scoped lazy resolves once
    // per JVM, so a test could never re-resolve after pointing PATH somewhere else,
    // and would silently assert against whatever the first caller happened to see.
    @Volatile private var commandCache: List<String>? = null
    @Volatile private var commandResolved = false

    internal fun resetPlayerCacheForTest() {
        synchronized(lock) { commandCache = null; commandResolved = false }
    }

    private val playerCommand: List<String>?
        get() = synchronized(lock) {
            if (!commandResolved) {
                commandCache = resolvePlayer()
                commandResolved = true
            }
            commandCache
        }

    private fun resolvePlayer(): List<String>? = when {
        isMac -> DesktopExec.which("afplay")?.let { listOf(it) }
        isLinux -> LINUX_PLAYERS.firstNotNullOfOrNull { (bin, flags) ->
            DesktopExec.which(bin)?.let { listOf(it) + flags }
        }
        else -> null
    }

    /**
     * Null when voice notes are playable here, otherwise why they are not.
     *
     * Callers MUST check this and mark the note unplayable. What shipped instead
     * was `if (!mac) { onComplete(); return }`, which on Linux rendered a working
     * play button that completed instantly in silence, indistinguishable from a
     * zero-length recording, so the sender looks broken rather than the player.
     */
    actual fun unavailableReason(): String? = when {
        playerCommand != null -> null
        isLinux -> "no audio player found; install ffmpeg or vlc"
        isMac -> "afplay is missing from this macOS install"
        else -> "voice-note playback is not supported on this platform yet"
    }

    actual fun play(bytes: ByteArray, onComplete: () -> Unit) {
        val command = playerCommand
        if (command == null) {
            // No player: fire the completion so the bubble does not hang on Pause.
            // The UI is expected to have disabled this path via unavailableReason();
            // this is the belt-and-braces arm, not the way the user finds out.
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
                ProcessBuilder(command + file.absolutePath)
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
                    val rc = afplay.waitFor()
                    // A player can exit non-zero on a codec it cannot handle. There
                    // is no per-note error channel in the bubble yet, so this at
                    // least makes "pressed play, heard nothing" diagnosable instead
                    // of leaving no trace at all.
                    if (rc != 0) sonarLog("AudioNotePlayer", "${command.first()} exited $rc")
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
