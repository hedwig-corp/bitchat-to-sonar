package chat.bitchat.sonar

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes as PlatformAudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Android file-backed voice engine (issue #320). Plays [VoicePlaybackItem.localFile]
 * directly via the ONE ExoPlayer that [VoiceMessagePlaybackService] owns — no
 * full-file byte load — so playback keeps running on the service's process
 * lifetime, not this adapter's. Audio focus is managed manually (ExoPlayer's
 * built-in focus handling is disabled) so it stays a single source of truth
 * with `ACTION_AUDIO_BECOMING_NOISY` pause, matching Signal's interruption
 * policy.
 *
 * [VoiceMessagePlaybackController] dispatches on [kotlinx.coroutines.Dispatchers.Default],
 * but every ExoPlayer/`Player` call must happen on its application thread
 * (the main thread here). [runOnMain] marshals each call synchronously via a
 * `Handler` + latch — the same pattern the desktop OpenJFX engine uses for
 * the FX Application Thread.
 */
actual fun createVoicePlaybackEngine(host: VoicePlaybackEngineHost): VoicePlaybackEngine =
    AndroidVoicePlaybackEngine(host)

private class AndroidVoicePlaybackEngine(
    private val host: VoicePlaybackEngineHost,
) : VoicePlaybackEngine {
    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var player: ExoPlayer? = null
    private var listener: Player.Listener? = null
    private var generation = AtomicLong(0)
    private var focusRequest: AudioFocusRequest? = null
    private var noisyRegistered = false
    private var serviceStarted = false

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) return
            val gen = generation.get()
            runOnMain { synchronized(lock) { player?.pause() } }
            host.onSystemPaused(gen)
        }
    }

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { change ->
        val gen = generation.get()
        when (change) {
            // Permanent loss (another app took media) — pause, no auto-resume.
            AudioManager.AUDIOFOCUS_LOSS -> {
                runOnMain { synchronized(lock) { player?.pause() } }
                host.onSystemPaused(gen)
            }
            // Transient duck/interrupt (notification, nav prompt) — pause and
            // allow auto-resume when focus returns, matching Signal.
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                runOnMain { synchronized(lock) { player?.pause() } }
                host.onTransientInterruptionBegan(gen)
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> Unit
            AudioManager.AUDIOFOCUS_GAIN -> host.onTransientInterruptionEnded(gen)
        }
    }

    override suspend fun prepare(item: VoicePlaybackItem, generation: Long) {
        val file = File(item.localFile)
        if (!file.isFile) error("missing local voice file")
        runOnMain {
            val exoPlayer = ensureServiceStartedOnMain()
            synchronized(lock) {
                releaseListenerLocked(exoPlayer)
                this.generation.set(generation)
                exoPlayer.stop()
                exoPlayer.clearMediaItems()
                // Privacy-safe metadata only — never a sender name, chat title, or path.
                exoPlayer.setMediaItem(
                    MediaItem.Builder()
                        .setUri(file.toURI().toString())
                        .setMediaMetadata(
                            MediaMetadata.Builder()
                                .setTitle("Voice message")
                                .build()
                        )
                        .build()
                )
                val playerListener = object : Player.Listener {
                    override fun onPlaybackStateChanged(playbackState: Int) {
                        if (playbackState == Player.STATE_ENDED) {
                            host.onEnded(this@AndroidVoicePlaybackEngine.generation.get())
                        }
                    }
                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        // Lock-screen / notification / BT can pause/play the
                        // ExoPlayer without going through the controller. The
                        // host must only apply these when they diverge from
                        // controller state (see SonarAppState wiring).
                        val gen = this@AndroidVoicePlaybackEngine.generation.get()
                        if (!isPlaying) {
                            val reason = synchronized(lock) { player?.playbackState }
                            if (reason == Player.STATE_ENDED || reason == Player.STATE_IDLE) return
                            host.onExternalPaused(gen)
                        } else {
                            host.onExternalResumed(gen)
                        }
                    }
                    override fun onPlayerError(error: PlaybackException) {
                        host.onFailed(this@AndroidVoicePlaybackEngine.generation.get())
                    }
                }
                exoPlayer.addListener(playerListener)
                listener = playerListener
                player = exoPlayer
                exoPlayer.prepare()
                requestFocus()
                registerNoisy()
            }
        }
    }

    override fun play() {
        runOnMain { synchronized(lock) { runCatching { player?.play() } } }
    }

    override fun pause() {
        runOnMain { synchronized(lock) { runCatching { player?.pause() } } }
    }

    override fun seekTo(positionMs: Long) {
        runOnMain {
            synchronized(lock) {
                val p = player ?: return@synchronized
                val clamped = if (p.duration > 0) {
                    positionMs.coerceIn(0, p.duration)
                } else {
                    maxOf(0L, positionMs)
                }
                p.seekTo(clamped)
            }
        }
    }

    override fun setRate(rate: Float) {
        runOnMain {
            synchronized(lock) {
                val p = player ?: return@synchronized
                runCatching { p.playbackParameters = PlaybackParameters(rate, 1.0f) }
            }
        }
    }

    override fun release() {
        runOnMain {
            synchronized(lock) {
                player?.let { releaseListenerLocked(it) }
                runCatching { player?.stop() }
                runCatching { player?.clearMediaItems() }
                player = null
            }
            abandonFocus()
        }
        unregisterNoisy()
    }

    override fun currentPositionMs(): Long {
        var result = 0L
        runOnMain { result = synchronized(lock) { runCatching { player?.currentPosition }.getOrNull() ?: 0L } }
        return result
    }

    override fun durationMs(): Long {
        var result = 0L
        runOnMain { result = synchronized(lock) { runCatching { player?.duration?.coerceAtLeast(0L) }.getOrNull() ?: 0L } }
        return result
    }

    private fun releaseListenerLocked(exoPlayer: ExoPlayer) {
        listener?.let { exoPlayer.removeListener(it) }
        listener = null
    }

    /** Starts (or reuses) [VoiceMessagePlaybackService] and returns the ONE
     *  ExoPlayer it owns. Must be called from [runOnMain] — `ExoPlayer.Builder`
     *  requires a thread with a prepared `Looper`. Uses a plain (non-
     *  foreground) `startService`: Media3's own notification manager is
     *  responsible for the `startForegroundService`/`startForeground` pairing
     *  once playback actually begins; doing that pairing ourselves here
     *  (before `play()`) risks `ForegroundServiceDidNotStartInTimeException`
     *  if the user pauses before ever hitting play. */
    private fun ensureServiceStartedOnMain(): ExoPlayer {
        val ctx = AppContextHolder.ctx
        VoicePlaybackSessionHolder.player?.let {
            if (!serviceStarted) {
                runCatching { ctx.startService(Intent(ctx, VoiceMessagePlaybackService::class.java)) }
                serviceStarted = true
            }
            return it
        }
        // First-ever call: publish the instance the service will adopt in its
        // own onCreate, so both sides converge on the same player.
        val created = ExoPlayer.Builder(ctx).build().also {
            it.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
                    .build(),
                false,
            )
        }
        VoicePlaybackSessionHolder.player = created
        runCatching { ctx.startService(Intent(ctx, VoiceMessagePlaybackService::class.java)) }
        serviceStarted = true
        return created
    }

    private fun requestFocus() {
        val am = AppContextHolder.ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    PlatformAudioAttributes.Builder()
                        .setUsage(PlatformAudioAttributes.USAGE_MEDIA)
                        .setContentType(PlatformAudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setOnAudioFocusChangeListener(focusChangeListener)
                .build()
            focusRequest = req
            am.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                focusChangeListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            )
        }
    }

    private fun abandonFocus() {
        val am = AppContextHolder.ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(focusChangeListener)
        }
    }

    private fun registerNoisy() {
        if (noisyRegistered) return
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        AppContextHolder.ctx.registerReceiver(noisyReceiver, filter)
        noisyRegistered = true
    }

    private fun unregisterNoisy() {
        if (!noisyRegistered) return
        runCatching { AppContextHolder.ctx.unregisterReceiver(noisyReceiver) }
        noisyRegistered = false
    }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
            return
        }
        val latch = CountDownLatch(1)
        mainHandler.post {
            try {
                block()
            } finally {
                latch.countDown()
            }
        }
        latch.await(5, TimeUnit.SECONDS)
    }
}
