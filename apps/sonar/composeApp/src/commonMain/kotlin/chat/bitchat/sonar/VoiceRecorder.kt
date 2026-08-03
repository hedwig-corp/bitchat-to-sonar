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

    /**
     * Null when voice notes can be played on this host, otherwise a short reason to
     * show the user. Non-null only on desktop, where playback shells out to an
     * external decoder that may not be installed; Android always returns null.
     *
     * The UI must consult this rather than assuming [play] works. A silent no-op is
     * indistinguishable from an empty recording and blames the sender.
     */
    fun unavailableReason(): String?
}

/** What tapping the button on a voice-note bubble should do. */
internal enum class AudioAction { Download, CancelDownload, Play, Stop, Nothing }

/**
 * The voice-note button's decision, extracted from the bubble so it can be pinned.
 *
 * It lived inline in a private composable, where deleting the [unavailable] check
 * restored the silent-playback bug with the whole suite still green. That is the
 * shape `docs/REGRESSIONS.md` calls out: the helper was covered, the call site was
 * not.
 */
internal fun audioClickAction(
    phase: MediaTransferPhase,
    unavailable: String?,
    hasBytes: Boolean,
    playing: Boolean,
): AudioAction = when (phase) {
    MediaTransferPhase.NotDownloaded, MediaTransferPhase.Failed -> AudioAction.Download
    MediaTransferPhase.Downloading -> AudioAction.CancelDownload
    MediaTransferPhase.Available -> when {
        unavailable != null -> AudioAction.Nothing
        playing -> AudioAction.Stop
        hasBytes -> AudioAction.Play
        else -> AudioAction.Nothing
    }
}

/**
 * Why a payload must not be handed to a media decoder, or null when it is fine.
 *
 * This is hygiene, NOT the security boundary. The boundary is the player invocation
 * itself (see `LINUX_PLAYERS`), because sniffing cannot express "this file does not
 * reference the network": a QuickTime reference movie is a structurally valid MP4
 * whose `moov/rmra` names a URL, and VLC fetched it and exited 0 while the app
 * reported a normal play. A 12-byte prefix check said that file was fine, because it
 * genuinely is an MP4.
 *
 * What this does buy: a playlist or arbitrary junk never reaches a decoder at all,
 * and the rejection is shared by every platform rather than living beside one player.
 */
internal fun audioPayloadRejection(bytes: ByteArray): String? = when {
    sniffAudioContainer(bytes) == null -> "unrecognized audio container"
    // Defense in depth for the one platform that cannot be constrained the way
    // ffplay is: macOS spawns the system `afplay`, which takes no protocol
    // whitelist. Whether afplay resolves reference movies at all is UNVERIFIED (no
    // mac to test on), so this refuses the known redirect rather than assuming.
    hasReferenceMovie(bytes) -> "MP4 reference movie (names an external URL)"
    else -> null
}

/**
 * The audio containers the app actually accepts, recognized by magic bytes.
 *
 * It has to be the whole set, not just M4A. Every attachment with an audio mime routes to the
 * voice-note bubble, and drag-and-drop accepts mpeg/wav/ogg/flac/aac/webm/matroska,
 * so an MP4-only check silently killed all of them, including on macOS where they
 * play today.
 */
internal fun sniffAudioContainer(b: ByteArray): String? {
    if (b.size < 12) return null
    fun at(off: Int, tag: String) = tag.indices.all { b[off + it] == tag[it].code.toByte() }
    fun u(i: Int) = b[i].toInt() and 0xFF
    return when {
        at(4, "ftyp") -> "mp4"
        at(0, "ID3") -> "mpeg"
        // MPEG audio frame sync, which also covers raw ADTS AAC (0xFFF1/0xFFF9).
        u(0) == 0xFF && (u(1) and 0xE0) == 0xE0 -> "mpeg"
        at(0, "RIFF") && at(8, "WAVE") -> "wav"
        at(0, "OggS") -> "ogg"
        at(0, "fLaC") -> "flac"
        at(0, "FORM") && (at(8, "AIFF") || at(8, "AIFC")) -> "aiff"
        u(0) == 0x1A && u(1) == 0x45 && u(2) == 0xDF && u(3) == 0xA3 -> "matroska"
        else -> null
    }
}

/**
 * True when this MP4 carries a `moov/rmra` reference-movie box, i.e. it points at
 * something else instead of containing audio.
 *
 * Walks the box tree rather than scanning for the tag, so audio payload bytes that
 * happen to spell `rmra` cannot trip it.
 */
internal fun hasReferenceMovie(b: ByteArray): Boolean {
    fun u32(i: Int): Long =
        ((b[i].toLong() and 0xFF) shl 24) or ((b[i + 1].toLong() and 0xFF) shl 16) or
            ((b[i + 2].toLong() and 0xFF) shl 8) or (b[i + 3].toLong() and 0xFF)
    fun tag(i: Int, t: String) = t.indices.all { i + it < b.size && b[i + it] == t[it].code.toByte() }

    var off = 0
    while (off + 8 <= b.size) {
        val size = u32(off)
        // 0 means "to end of file"; 1 means a 64-bit size follows. Neither can be
        // walked past safely here, so stop rather than guess.
        if (size < 8 || off + size > b.size) return false
        if (tag(off + 4, "moov")) {
            var child = off + 8
            val end = (off + size).toInt()
            while (child + 8 <= end) {
                val cs = u32(child)
                if (cs < 8 || child + cs > end) return false
                if (tag(child + 4, "rmra")) return true
                child += cs.toInt()
            }
            return false
        }
        off += size.toInt()
    }
    return false
}
