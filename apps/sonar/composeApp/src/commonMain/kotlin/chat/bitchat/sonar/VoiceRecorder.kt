package chat.bitchat.sonar

/**
 * Records a voice note to an AAC `.m4a` file for the composer's hold-to-record
 * mic (design: components.jsx VoiceRecorder). Sent over the SAME media path as
 * photos (mime `audio/mp4`) — a voice note is just media with an audio mime, so
 * no core/wire change. expect/actual: Android = `MediaRecorder`.
 */
expect class VoiceRecorder() {
    /** Begin recording. Returns false if the mic permission is denied or setup fails. */
    suspend fun start(): Boolean
    /** Seconds elapsed since [start] (polled by the UI). */
    fun elapsed(): Int
    /** Current input level 0..1 for the live waveform. */
    fun level(): Float
    /** Stop + return the recorded AAC bytes (null if nothing useful was recorded). */
    fun finish(): ByteArray?
    /** Stop + discard the file. */
    fun cancel()
}

/** Plays a single voice-note's decrypted bytes (audio bubble play button). One
 *  note at a time — [play] stops any previous one. [onComplete] fires when this
 *  note stops for ANY reason (finished, [stop], or another note stole the player),
 *  so the owning bubble can reset its play/pause icon. Android = `MediaPlayer`. */
expect object AudioNotePlayer {
    fun play(bytes: ByteArray, onComplete: () -> Unit = {})
    fun stop()
}
