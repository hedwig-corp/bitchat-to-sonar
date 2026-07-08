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
    private var process: Process? = null
    private var tempFile: File? = null
    private var onDone: (() -> Unit)? = null
    private var waiter: Thread? = null

    actual fun play(bytes: ByteArray, onComplete: () -> Unit) {
        stop()
        val os = System.getProperty("os.name").lowercase()
        if (!os.contains("mac")) {
            // Linux/Windows desktop: no built-in AAC player yet (follow-up: ffplay/JavaFX).
            onComplete()
            return
        }
        val file = File.createTempFile("sonar-vn-", ".m4a", DesktopEnv.dataDir)
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
        tempFile = file
        onDone = onComplete
        process = afplay
        waiter = Thread {
            try {
                afplay.waitFor()
            } catch (_: InterruptedException) {
                runCatching { afplay.destroy() }
            } finally {
                finishPlayback()
            }
        }.apply {
            isDaemon = true
            name = "sonar-afplay"
            start()
        }
    }

    actual fun stop() {
        process?.let { p ->
            runCatching { p.destroy() }
            runCatching { p.waitFor() }
        }
        process = null
        waiter?.interrupt()
        waiter = null
        finishPlayback()
    }

    private fun finishPlayback() {
        tempFile?.let { runCatching { it.delete() } }
        tempFile = null
        val cb = onDone
        onDone = null
        cb?.invoke()
    }
}