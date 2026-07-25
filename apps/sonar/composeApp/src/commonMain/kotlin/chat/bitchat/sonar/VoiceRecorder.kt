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

/**
 * Async engine → controller bridge for events a [VoicePlaybackEngine] cannot
 * report synchronously from [VoicePlaybackEngine.prepare] — natural
 * end-of-track, a playback error discovered after prepare succeeded, or an
 * engine-pushed progress tick (e.g. a platform player's own position
 * listener). All callbacks carry the generation the engine observed them
 * under; [VoiceMessagePlaybackController] drops anything from a stale
 * generation, so implementations do not need to track staleness themselves.
 *
 * Every callback may be invoked from a platform callback/listener thread; the
 * controller re-enters its own reducer under its mutex on its own dispatcher,
 * so implementations do not need extra synchronization here.
 */
interface VoicePlaybackEngineHost {
    fun onEnded(generation: Long)
    fun onFailed(generation: Long)
    fun onProgress(generation: Long, positionMs: Long, durationMs: Long) {}
    /**
     * Route-lost / becoming-noisy / permanent audio-focus loss — pause and do
     * **not** auto-resume ([VoiceMessagePlaybackController.onSystemPaused]).
     */
    fun onSystemPaused(generation: Long) {}
    /**
     * Optional: focus regained after route-lost. Default is a no-op — Sonar
     * never auto-resumes after becoming-noisy.
     */
    fun onSystemResumed(generation: Long) {}
    /**
     * Transient audio-focus loss (notification, nav prompt) — pause and allow
     * auto-resume when [onTransientInterruptionEnded] fires, but never after a
     * user pause/call/recording/wipe.
     */
    fun onTransientInterruptionBegan(generation: Long) {}
    fun onTransientInterruptionEnded(generation: Long) {}
    /**
     * MediaSession / BT / notification toggled the platform player while the
     * controller still thinks the item is Playing. Host should pause the
     * session without treating it as becoming-noisy auto-resume policy.
     */
    fun onExternalPaused(generation: Long) {}
    /** MediaSession / BT resumed the platform player while controller is Paused. */
    fun onExternalResumed(generation: Long) {}
}

/**
 * Builds the platform-native, single app-scoped playback engine (Signal-parity
 * voice-note playback). The engine plays an already-local, private file
 * ([VoicePlaybackItem.localFile]) directly — it never receives raw bytes and
 * never reads a full attachment into memory. One instance is owned by
 * [SonarAppState] for the process lifetime; rows never construct or hold an
 * engine. Android = Media3 `ExoPlayer` behind a `MediaSessionService`;
 * desktop (JVM) = OpenJFX Media (see `VoiceMessagePlayback.jvm.kt` for the
 * license note).
 */
expect fun createVoicePlaybackEngine(host: VoicePlaybackEngineHost): VoicePlaybackEngine
