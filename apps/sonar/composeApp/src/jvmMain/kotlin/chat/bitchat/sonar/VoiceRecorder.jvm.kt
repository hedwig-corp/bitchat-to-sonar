package chat.bitchat.sonar

/**
 * Desktop (JVM) `actual`: voice notes are not wired on desktop yet (the JVM has
 * no MediaRecorder/AAC encoder). [start] returns false so the composer's
 * hold-to-record mic degrades gracefully (no recording offered), mirroring how
 * the wallet/voice-only features no-op on desktop. Wiring a desktop capture path
 * (javax.sound + an AAC encoder, or the Rust core) is the documented follow-up.
 */
actual class VoiceRecorder {
    actual suspend fun start(): Boolean = false
    actual fun elapsed(): Int = 0
    actual fun level(): Float = 0f
    actual fun finish(): ByteArray? = null
    actual fun cancel() {}
}

/** Desktop `actual`: no native m4a/AAC playback on the JVM — completes
 *  immediately so the audio bubble resets its icon and nothing hangs. */
actual object AudioNotePlayer {
    actual fun play(bytes: ByteArray, onComplete: () -> Unit) { onComplete() }
    actual fun stop() {}
}
