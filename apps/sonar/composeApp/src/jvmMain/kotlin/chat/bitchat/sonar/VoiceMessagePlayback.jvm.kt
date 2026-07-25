package chat.bitchat.sonar

import javafx.application.Platform
import javafx.scene.media.Media
import javafx.scene.media.MediaPlayer
import javafx.util.Duration
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Desktop voice-note engine using OpenJFX Media.
 *
 * License: OpenJFX is GPL v2 with the Classpath Exception — linking from this
 * Unlicense app does not infect application code. No user-installed executable
 * (afplay/ffplay/VLC) is required; natives ship with the javafx-media artifact.
 *
 * Plays [VoicePlaybackItem.localFile] in place (private MediaCache path). No
 * secondary decrypted temp copy is created.
 */
actual fun createVoicePlaybackEngine(host: VoicePlaybackEngineHost): VoicePlaybackEngine =
    JavaFxVoicePlaybackEngine(host)

private class JavaFxVoicePlaybackEngine(
    private val host: VoicePlaybackEngineHost,
) : VoicePlaybackEngine {
    private val lock = Any()
    private var player: MediaPlayer? = null
    private val generation = AtomicLong(0)
    private val toolkitReady = AtomicBoolean(false)

    override suspend fun prepare(item: VoicePlaybackItem, generation: Long) {
        ensureToolkit()
        val file = File(item.localFile)
        if (!file.isFile) error("missing local voice file")
        val uri = file.toURI().toString()
        val ready = CountDownLatch(1)
        var prepareError: Throwable? = null
        runOnFx {
            synchronized(lock) {
                releaseLocked()
                this.generation.set(generation)
                try {
                    val media = Media(uri)
                    val mp = MediaPlayer(media)
                    // Capture prepare generation so a disposed player's end/error
                    // cannot be reported against a newer item after switch.
                    val callbackGeneration = generation
                    mp.setOnReady {
                        ready.countDown()
                    }
                    mp.setOnError {
                        // During prepare, fail the latch. After ready, forward
                        // to the host so the UI leaves Playing on decode errors.
                        if (ready.count > 0L) {
                            prepareError = mp.error ?: IllegalStateException("javafx media error")
                            ready.countDown()
                        } else {
                            host.onFailed(callbackGeneration)
                        }
                    }
                    mp.setOnEndOfMedia {
                        host.onEnded(callbackGeneration)
                    }
                    mp.setOnPlaying {
                        // no-op; controller drives phase
                    }
                    player = mp
                } catch (t: Throwable) {
                    prepareError = t
                    ready.countDown()
                }
            }
        }
        if (!ready.await(8, TimeUnit.SECONDS)) {
            error("javafx media prepare timeout")
        }
        prepareError?.let { throw it }
    }

    override fun play() {
        runOnFx {
            synchronized(lock) { player?.play() }
        }
    }

    override fun pause() {
        runOnFx {
            synchronized(lock) { player?.pause() }
        }
    }

    override fun seekTo(positionMs: Long) {
        runOnFx {
            synchronized(lock) {
                player?.seek(Duration.millis(positionMs.toDouble().coerceAtLeast(0.0)))
            }
        }
    }

    override fun setRate(rate: Float) {
        runOnFx {
            synchronized(lock) {
                player?.rate = rate.toDouble()
            }
        }
    }

    override fun release() {
        runOnFx {
            synchronized(lock) { releaseLocked() }
        }
    }

    override fun currentPositionMs(): Long = synchronized(lock) {
        player?.currentTime?.toMillis()?.toLong()?.coerceAtLeast(0L) ?: 0L
    }

    override fun durationMs(): Long = synchronized(lock) {
        val d = player?.totalDuration
        if (d == null || d.isUnknown || d.isIndefinite) 0L
        else d.toMillis().toLong().coerceAtLeast(0L)
    }

    private fun releaseLocked() {
        player?.let { mp ->
            // Drop handlers before dispose so a late FX callback cannot race
            // against the next prepare()'s generation.
            runCatching { mp.setOnError(null) }
            runCatching { mp.setOnEndOfMedia(null) }
            runCatching { mp.setOnReady(null) }
            runCatching { mp.setOnPlaying(null) }
            runCatching { mp.stop() }
            runCatching { mp.dispose() }
        }
        player = null
    }

    private fun ensureToolkit() {
        if (toolkitReady.get()) return
        synchronized(toolkitReady) {
            if (toolkitReady.get()) return
            // Headless-friendly init: start FX toolkit without showing a Stage.
            val latch = CountDownLatch(1)
            try {
                Platform.startup { latch.countDown() }
            } catch (_: IllegalStateException) {
                // Already started by Compose Desktop.
                latch.countDown()
            }
            latch.await(5, TimeUnit.SECONDS)
            Platform.setImplicitExit(false)
            toolkitReady.set(true)
        }
    }

    private fun runOnFx(block: () -> Unit) {
        if (Platform.isFxApplicationThread()) {
            block()
        } else {
            val latch = CountDownLatch(1)
            Platform.runLater {
                try {
                    block()
                } finally {
                    latch.countDown()
                }
            }
            latch.await(5, TimeUnit.SECONDS)
        }
    }
}
