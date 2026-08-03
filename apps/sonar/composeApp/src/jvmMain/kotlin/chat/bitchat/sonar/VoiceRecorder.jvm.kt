package chat.bitchat.sonar

import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Desktop (JVM) `actual`: recording is not wired yet (no JVM AAC encoder).
 * Playback shells out to an installed decoder over a temp `.m4a`; see
 * [AudioNotePlayer.LINUX_PLAYERS] for which ones and why.
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
     * Only `ffplay` is here, and the flags are the security boundary, not a
     * convenience.
     *
     * `-protocol_whitelist file` is the load-bearing one. The payload is chosen by
     * whoever sent the message, and a media container can name a URL: a QuickTime
     * reference movie (`moov/rmra`) is a structurally valid MP4 that points
     * somewhere else. Fed one of those, `cvlc` fetched the attacker's URL twice and
     * exited 0, so the app reported a normal play; on a relay-mediated transport
     * where the sender otherwise never learns the recipient's IP, one tap yields the
     * IP, an exact read-receipt oracle, and a blind SSRF probe into the LAN.
     * Reproduced against a local listener, and the same payload passes any
     * magic-byte check because it really is an MP4. That is why the player is
     * constrained instead of the bytes being trusted.
     *
     * `cvlc` was here and is gone: it follows both the m3u and the reference-movie
     * redirect, and no invocation was found that provably stops it (`--demux=mp4
     * --no-playlist-autostart` suppressed the fetch but then hung on the same
     * input). A player that cannot be constrained is not a fallback worth having.
     *
     * ffplay refuses both payloads even without the flag, because libavformat's
     * file-protocol default whitelist is `file,crypto,data`. It is passed
     * explicitly anyway: a build-time default is not a guarantee, and this is the
     * one line standing between a remote peer and an outbound request.
     *
     * Verified against real clips with these exact flags: m4a 2215ms, mp3 1194ms,
     * wav 1191ms, ogg 1174ms, flac 1152ms, raw AAC 1234ms, all exit 0; and against
     * both attack payloads, no request reached the listener.
     *
     * The other requirement is that it exits at end of clip, since that is what
     * fires [onComplete] and resets the bubble. `gst-play-1.0` was rejected for
     * failing that honestly: without `gstreamer1.0-plugins-bad` it prints a plug-in
     * error and still exits 0, in ~50ms for a 2s clip. `paplay`/`aplay` are PCM-only.
     */
    private val LINUX_PLAYERS = listOf(
        "ffplay" to listOf("-protocol_whitelist", "file", "-nodisp", "-autoexit", "-loglevel", "quiet"),
    )

    private val osName = System.getProperty("os.name").lowercase()
    private val isMac = osName.contains("mac")
    private val isLinux = osName.contains("linux")

    /** `PATH` for player lookup. Tests point this at a directory of stubs. */
    @Volatile
    internal var searchPath: String? = null

    // Deliberately NOT cached. The scan is ~10 stat calls with no fork, and caching
    // it cost more than it saved: it needed a reset hatch purely so tests could
    // re-resolve, it put that scan on the Compose thread under the playback lock,
    // and it meant a user who followed the "install ffmpeg" message kept seeing that
    // message until they restarted the app. Re-probing makes the fix take effect.
    private val playerCommand: List<String>?
        get() = when {
            // macOS keeps the absolute path first. `afplay` ships with the OS at a
            // SIP-protected location and does not move, so resolving it through
            // `PATH` would only add a way for an earlier entry to win.
            isMac -> listOf("/usr/bin/afplay").takeIf { File(it[0]).canExecute() }
                ?: DesktopExec.which("afplay", pathOrDefault())?.let { listOf(it) }
            isLinux -> LINUX_PLAYERS.firstNotNullOfOrNull { (bin, flags) ->
                DesktopExec.which(bin, pathOrDefault())?.let { listOf(it) + flags }
            }
            else -> null
        }

    private fun pathOrDefault(): String? = searchPath ?: System.getenv("PATH")

    actual fun unavailableReason(): String? = when {
        playerCommand != null -> null
        isLinux -> "no audio player found; install ffmpeg"
        isMac -> "afplay is missing from this macOS install"
        else -> "voice-note playback is not supported on this platform yet"
    }

    actual fun play(bytes: ByteArray, onComplete: () -> Unit) {
        audioPayloadRejection(bytes)?.let { why ->
            sonarLog("AudioNotePlayer", "refusing to play: $why")
            onComplete()
            return
        }
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
            }.getOrElse {
                sonarLog("AudioNotePlayer", "could not create the temp note file")
                onComplete()
                return@execute
            }
            // Tighten BEFORE the bytes land, never after. `File.createTempFile`
            // honors the umask, so under a common 0002 it yields rw-rw-r-- and this
            // note is decrypted end-to-end-encrypted audio sitting readable by every
            // local user in a shared /tmp. Ordering matters as much as the mode: a
            // chmod after the write leaves a window in which the plaintext is
            // world-readable, so only the empty file is ever exposed.
            if (!DesktopEnv.restrictToOwner(file)) {
                // A filesystem that cannot express the mode (exFAT/SMB tmpdir).
                // Playback continues rather than dying on an exotic mount, but it
                // does not get to be silent about handing out plaintext.
                sonarLog("AudioNotePlayer", "could not restrict $TMP_SUFFIX temp file to owner-only")
            }
            try {
                file.writeBytes(bytes)
            } catch (e: Exception) {
                sonarLog("AudioNotePlayer", "could not write the temp note file: $e")
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
                // Resolution and spawn are not atomic: a package upgrade between
                // them, or a PATH entry that is not actually runnable, lands here.
                sonarLog("AudioNotePlayer", "could not spawn ${command.first()}: $it")
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
            // Bounded, then SIGKILL. `waitFor()` with no timeout ran on the single
            // control thread, so a child that ignores SIGTERM wedged it forever: the
            // decrypted note below was never deleted, the bubble stayed on Pause,
            // and every later play()/stop() queued behind it for the rest of the
            // session. A player fed an endless attacker-controlled stream is exactly
            // such a child.
            runCatching {
                if (!p.waitFor(2, TimeUnit.SECONDS)) p.destroyForcibly()
            }.onFailure { runCatching { p.destroyForcibly() } }
        }
        // Outside the `p != null` branch and after the kill: dropping the plaintext
        // must not be reachable only on paths where the child cooperated.
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
