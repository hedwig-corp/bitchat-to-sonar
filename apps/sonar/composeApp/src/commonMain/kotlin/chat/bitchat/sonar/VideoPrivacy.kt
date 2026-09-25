package chat.bitchat.sonar

/** What the picker send path may do with a picked video. */
internal sealed class VideoSendDecision {
    class Send(val bytes: ByteArray) : VideoSendDecision()

    /** MP4/MOV whose boxes cannot be verified clean. */
    data object Unverifiable : VideoSendDecision()

    /** WebM/MKV/AVI…: containers this sanitizer cannot read, so cannot vouch for. */
    data object UnsupportedContainer : VideoSendDecision()
}

/**
 * Fail closed for everything the sanitizer cannot verify: only an MP4/MOV it
 * parsed (and cleaned) is sent as a video. Other containers can carry
 * arbitrary tags or embedded XMP, so "we don't read this format" must never
 * mean "send it as-is" — the user can still send such a file through
 * "Send file", which transfers files byte-exact on both apps.
 */
internal fun videoBytesForSend(raw: ByteArray): VideoSendDecision =
    when (val result = stripVideoLocationMetadata(raw)) {
        is VideoPrivacyResult.Clean -> VideoSendDecision.Send(result.bytes)
        VideoPrivacyResult.Malformed -> VideoSendDecision.Unverifiable
        VideoPrivacyResult.NotIsoBmff -> VideoSendDecision.UnsupportedContainer
    }

/**
 * Remove location metadata from an ISO-BMFF / QuickTime video (MP4, MOV, 3GP)
 * before it leaves the device — the Compose counterpart of iOS
 * `SonarAppStore.finalizeVideoForSend`, which remuxes with
 * `AVMetadataItemFilter.forSharing()`.
 *
 * Cameras put the place a clip was shot in metadata boxes: `udta/©xyz`
 * (Android, QuickTime), `udta/loci` (3GPP), `meta` keys/ilst
 * `com.apple.quicktime.location.ISO6709` (iPhone) and XMP `uuid` boxes. Every
 * `udta` and `meta` box under `moov` and each `trak`, and every XMP `uuid`
 * box, is turned into a zero-filled `free` box of the SAME size. No byte
 * moves, so the sample offsets in `stco`/`co64` stay valid and nothing is
 * re-encoded; players skip `free` boxes by definition.
 *
 * Fails closed: a file that looks like ISO-BMFF but whose boxes do not parse
 * (or whose movie header is compressed, `cmov`) is [VideoPrivacyResult.Malformed].
 * Non-ISO-BMFF containers (WebM/Matroska/AVI) are [VideoPrivacyResult.NotIsoBmff]:
 * this sanitizer does not read them, so [videoBytesForSend] refuses both.
 */
internal sealed class VideoPrivacyResult {
    /** Safe to send; [stripped] is true when at least one box was neutralized. */
    class Clean(val bytes: ByteArray, val stripped: Boolean) : VideoPrivacyResult()

    /** Not an ISO-BMFF / QuickTime file. */
    data object NotIsoBmff : VideoPrivacyResult()

    /** Looks like ISO-BMFF but cannot be verified clean: refuse, never guess. */
    data object Malformed : VideoPrivacyResult()
}

internal fun stripVideoLocationMetadata(input: ByteArray): VideoPrivacyResult {
    if (input.size < 8) return VideoPrivacyResult.NotIsoBmff
    val firstType = fourcc(input, 4)
    if (firstType == null || firstType !in TOP_LEVEL_TYPES) return VideoPrivacyResult.NotIsoBmff

    val out = input.copyOf()
    val top = readBoxes(out, 0, out.size) ?: return VideoPrivacyResult.Malformed
    if (top.none { it.type == "moov" }) return VideoPrivacyResult.Malformed
    var stripped = false

    fun neutralize(box: Box) {
        FREE.copyInto(out, box.start + 4)
        out.fill(0, box.start + box.headerSize, box.end)
        stripped = true
    }

    // moov and trak are the only containers whose metadata children we
    // rewrite; sample tables (mdia/minf/stbl) are never touched.
    fun sanitize(container: Box): Boolean {
        val children = readBoxes(out, container.start + container.headerSize, container.end) ?: return false
        for (child in children) {
            when (child.type) {
                "cmov" -> return false
                "udta", "meta" -> neutralize(child)
                "uuid" -> if (isXmpUuid(out, child)) neutralize(child)
                "trak" -> if (!sanitize(child)) return false
            }
        }
        return true
    }

    for (box in top) {
        when (box.type) {
            "moov" -> if (!sanitize(box)) return VideoPrivacyResult.Malformed
            "udta", "meta" -> neutralize(box)
            "uuid" -> if (isXmpUuid(out, box)) neutralize(box)
        }
    }
    return VideoPrivacyResult.Clean(out, stripped)
}

private class Box(val start: Int, val headerSize: Int, val end: Int, val type: String)

private val TOP_LEVEL_TYPES = setOf(
    "ftyp", "moov", "mdat", "free", "skip", "wide", "uuid", "pnot",
    "meta", "moof", "mfra", "sidx", "styp", "pdin", "junk",
)

private val FREE = byteArrayOf('f'.code.toByte(), 'r'.code.toByte(), 'e'.code.toByte(), 'e'.code.toByte())

/** XMP packet usertype BE7ACFCB-97A9-42E8-9C71-999491E3AFAC. */
private val XMP_UUID = intArrayOf(
    0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8,
    0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
)

/** Consecutive boxes filling exactly [from, to), or null if they do not. */
private fun readBoxes(b: ByteArray, from: Int, to: Int): List<Box>? {
    val out = ArrayList<Box>()
    var pos = from
    while (pos < to) {
        if (to - pos < 8) return null
        var size = u32(b, pos)
        val type = fourcc(b, pos + 4) ?: return null
        var header = 8
        when (size) {
            1L -> {
                if (to - pos < 16) return null
                size = u64(b, pos + 8)
                header = 16
            }
            0L -> size = (to - pos).toLong()   // "extends to the end"
        }
        if (size < header || size > (to - pos).toLong()) return null
        out += Box(pos, header, pos + size.toInt(), type)
        pos += size.toInt()
    }
    return out
}

private fun isXmpUuid(b: ByteArray, box: Box): Boolean {
    val at = box.start + box.headerSize
    if (box.end - at < 16) return false
    return XMP_UUID.indices.all { (b[at + it].toInt() and 0xFF) == XMP_UUID[it] }
}

/** Four printable characters (QuickTime also uses 0xA9, "©"), else null. */
private fun fourcc(b: ByteArray, at: Int): String? {
    if (at + 4 > b.size) return null
    val chars = CharArray(4)
    for (i in 0 until 4) {
        val c = b[at + i].toInt() and 0xFF
        if (c != 0xA9 && c !in 0x20..0x7E) return null
        chars[i] = c.toChar()
    }
    return chars.concatToString()
}

private fun u32(b: ByteArray, at: Int): Long =
    ((b[at].toLong() and 0xFF) shl 24) or ((b[at + 1].toLong() and 0xFF) shl 16) or
        ((b[at + 2].toLong() and 0xFF) shl 8) or (b[at + 3].toLong() and 0xFF)

private fun u64(b: ByteArray, at: Int): Long = (u32(b, at) shl 32) or u32(b, at + 4)
