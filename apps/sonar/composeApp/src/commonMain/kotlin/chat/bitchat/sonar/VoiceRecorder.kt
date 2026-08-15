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
internal fun audioPayloadRejection(bytes: ByteArray): String? = when (sniffAudioContainer(bytes)) {
    null -> "unrecognized audio container"
    // Defense in depth for the one platform that cannot be constrained the way
    // ffplay is: macOS spawns the system `afplay`, which takes no protocol
    // whitelist. Whether afplay resolves reference movies at all is UNVERIFIED (no
    // mac to test on), so this refuses the known redirect rather than assuming.
    // Only MP4 gets the box walk. It fails closed on a structure it cannot parse,
    // and mp3/wav/ogg/flac bytes are not boxes, so running it on them would reject
    // every non-MP4 format -- the exact regression this rejection was widened to fix.
    "mp4" -> if (hasReferenceMovie(bytes)) "MP4 reference movie (names an external URL)" else null
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
 * True when this MP4 carries a `moov/rmra` reference-movie box, i.e. it names
 * something else instead of holding audio, OR when its box structure cannot be
 * walked well enough to rule that out.
 *
 * Fails CLOSED, and the first version did not. It gave up on any box whose size
 * field it did not understand and answered "no reference movie", so putting one
 * 64-bit-sized box (`size == 1`, real length in the following 8 bytes) in front of
 * `moov` hid the redirect completely:
 *
 *     240 bytes; hasReferenceMovie() -> False   (rmra IS present)
 *     cvlc -> BEACON HIT x2, rc=0
 *
 * "I could not parse this" is not evidence of safety, so an unwalkable structure is
 * refused. Real files are unaffected: 64-bit sizes and the `size == 0` (runs to end
 * of file) form are both handled, and a well-formed MP4 walks cleanly.
 *
 * It walks the box tree rather than scanning for the tag, so audio payload bytes
 * that happen to spell `rmra` do not trip it.
 */
internal fun hasReferenceMovie(b: ByteArray): Boolean {
    fun u32(i: Int): Long =
        ((b[i].toLong() and 0xFF) shl 24) or ((b[i + 1].toLong() and 0xFF) shl 16) or
            ((b[i + 2].toLong() and 0xFF) shl 8) or (b[i + 3].toLong() and 0xFF)
    fun u64(i: Int): Long {
        var v = 0L
        for (k in 0 until 8) v = (v shl 8) or (b[i + k].toLong() and 0xFF)
        return v
    }
    fun tag(i: Int, t: String) = t.indices.all { i + it < b.size && b[i + it] == t[it].code.toByte() }

    // Box end offset, or null when the header cannot be trusted.
    fun endOf(off: Int, limit: Int): Int? {
        if (off + 8 > limit) return null
        val declared = u32(off)
        val size = when {
            // 1 => the real size is the 64-bit value following the type.
            declared == 1L -> {
                if (off + 16 > limit) return null
                u64(off + 8)
            }
            // 0 => this box runs to the end of the file.
            declared == 0L -> (limit - off).toLong()
            else -> declared
        }
        // `size > limit - off`, NOT `off + size > limit`. The latter is Long
        // arithmetic that WRAPS: a 64-bit largesize near Long.MAX_VALUE makes the
        // sum negative, so the guard passes, and `.toInt()` then truncates to the
        // low 32 bits and yields an offset BEHIND `off`. Measured on a 64-byte
        // payload: the walk stepped 0 -> 24 -> 8, backwards, and with the right two
        // boxes that is a cycle the loop never leaves. `limit - off` is a
        // non-negative Int here, cannot wrap, and guarantees the walk advances.
        if (size < 8 || size > limit - off) return null
        return (off + size).toInt()
    }

    fun contentStart(off: Int): Int = if (u32(off) == 1L) off + 16 else off + 8

    // Recurses, and keeps going after the first `moov`. Matching only a direct child
    // of the first `moov` missed an `rmra` nested under `moov/udta`, and missed one
    // in a SECOND `moov` hidden behind a clean first. Standard reference movies use
    // neither shape, but "the malformed variant is probably not resolved either" is
    // an assumption, and this check exists precisely for the player whose behaviour
    // could not be verified.
    fun scan(start: Int, limit: Int, depth: Int): Boolean {
        if (depth > 8) return true // pathological nesting: refuse rather than recurse
        var off = start
        while (off + 8 <= limit) {
            if (tag(off + 4, "rmra")) return true
            val end = endOf(off, limit) ?: return true
            // Only descend into containers; a leaf's payload is not boxes.
            if (CONTAINER_BOXES.any { tag(off + 4, it) } &&
                scan(contentStart(off), end, depth + 1)
            ) {
                return true
            }
            off = end
        }
        return false
    }
    return scan(0, b.size, 0)
}

/** Box types whose payload is more boxes, so the walk may descend into them. */
private val CONTAINER_BOXES = listOf("moov", "udta", "trak", "mdia", "minf", "dinf", "rmra", "rmda")
