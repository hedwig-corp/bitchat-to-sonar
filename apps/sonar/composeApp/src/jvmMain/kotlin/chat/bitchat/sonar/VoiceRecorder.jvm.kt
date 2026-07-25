package chat.bitchat.sonar

/**
 * Desktop (JVM) `actual`: recording is not wired yet (no JVM AAC encoder).
 * Voice-note playback lives in `VoiceMessagePlayback.jvm.kt` (OpenJFX Media —
 * no user-installed executable, no decrypted temp-file copy).
 */
actual class VoiceRecorder {
    actual suspend fun start(): Boolean = false
    actual fun elapsed(): Int = 0
    actual fun level(): Float = 0f
    actual fun finish(): ByteArray? = null
    actual fun cancel() {}
}
