package chat.bitchat.sonar

import android.content.Intent
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * Signal-parity app-scoped voice-note playback (issue #320): background/lock-
 * screen ownership, the system notification, and remote play/pause/seek
 * commands (notification, lock screen, Bluetooth/headset buttons) all route
 * through this ONE `MediaSessionService` — never through an Activity or a
 * composable row, so playback survives Activity recreation, backgrounding,
 * and screen lock.
 *
 * The single [ExoPlayer] instance is created by [AndroidVoicePlaybackEngine]
 * (same process, no IPC needed) and published into [VoicePlaybackSessionHolder]
 * BEFORE this service is started, so `onCreate` never has to wait for it.
 *
 * Privacy-safe: [MediaSession] metadata is set per item by the engine to the
 * generic "Voice message" title only — never a sender name, chat title, or
 * file path (see [AndroidVoicePlaybackEngine.prepare]).
 */
class VoiceMessagePlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val player = VoicePlaybackSessionHolder.player ?: ExoPlayer.Builder(this).build().also {
            it.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
                    .build(),
                // Audio-focus arbitration is owned by [AndroidVoicePlaybackEngine]
                // (matches the manual `AudioManager` policy already used for the
                // becoming-noisy pause) — ExoPlayer must not double-manage focus.
                false,
            )
            VoicePlaybackSessionHolder.player = it
        }
        session = MediaSession.Builder(this, player).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    /** Never linger as a silent foreground service once the task is swiped
     *  away with nothing playing — mirrors the "never leave a mode/lock held"
     *  invariant [CallAudioRoute] already follows for call audio. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = VoicePlaybackSessionHolder.player
        if (player == null || !player.isPlaying) stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        session?.release()
        session = null
        VoicePlaybackSessionHolder.player?.release()
        VoicePlaybackSessionHolder.player = null
        super.onDestroy()
    }
}

/** In-process publication point for the one ExoPlayer this app ever creates
 *  for voice-note playback. Avoids a `MediaController`/binder round trip for
 *  a same-process singleton engine <-> service pair. */
object VoicePlaybackSessionHolder {
    @Volatile var player: ExoPlayer? = null
}
