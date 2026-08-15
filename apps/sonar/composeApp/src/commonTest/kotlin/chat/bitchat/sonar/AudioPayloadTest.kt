package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * What may be handed to a media decoder.
 *
 * Two separate bugs live here, and an earlier `ftyp`-only check caused both:
 *
 * 1. It did not stop the attack. A QuickTime reference movie is a valid MP4 whose
 *    `moov/rmra` names a URL, so it passed the check, and VLC fetched that URL and
 *    exited 0 while the app reported a normal play.
 * 2. It broke legitimate audio. Every attachment with an audio mime reaches the
 *    player, and drag-and-drop accepts mpeg/wav/ogg/flac/aac/webm/matroska, none of which start
 *    with `ftyp`, so all of them became silent no-ops, macOS included.
 */
class AudioPayloadTest {

    private fun box(type: String, payload: ByteArray): ByteArray {
        val size = 8 + payload.size
        return byteArrayOf(
            (size ushr 24).toByte(), (size ushr 16).toByte(),
            (size ushr 8).toByte(), size.toByte(),
        ) + type.encodeToByteArray() + payload
    }

    private fun referenceMovie(): ByteArray {
        val url = "http://attacker.example/beacon ".encodeToByteArray()
        val rdrf = box(
            "rdrf",
            byteArrayOf(0, 0, 0, 0) + "url ".encodeToByteArray() +
                byteArrayOf(
                    (url.size ushr 24).toByte(), (url.size ushr 16).toByte(),
                    (url.size ushr 8).toByte(), url.size.toByte(),
                ) + url,
        )
        val moov = box("moov", box("mvhd", ByteArray(100)) + box("rmra", box("rmda", rdrf)))
        return box("ftyp", "qt  ".encodeToByteArray() + ByteArray(8)) + moov
    }

    private fun withHeader(vararg head: Int): ByteArray =
        ByteArray(64).also { head.forEachIndexed { i, v -> it[i] = v.toByte() } }

    @Test
    fun aReferenceMovieIsRejectedEvenThoughItIsAValidMp4() {
        val payload = referenceMovie()
        assertEquals("mp4", sniffAudioContainer(payload), "it really is an MP4; that was the problem")
        assertNotNull(
            audioPayloadRejection(payload),
            "a moov/rmra box names an external URL and must never reach a decoder",
        )
    }

    @Test
    fun aPlaylistIsRejected() {
        assertNotNull(
            audioPayloadRejection("#EXTM3U\nhttp://attacker.example/beacon\n".encodeToByteArray()),
        )
    }

    @Test
    fun everyAudioFormatTheAppAcceptsIsAllowed() {
        // Real magic bytes, taken from files ffmpeg actually produced.
        val cases = mapOf(
            "m4a" to (box("ftyp", "M4A ".encodeToByteArray() + ByteArray(8)) +
                box("moov", box("mvhd", ByteArray(100))) + box("mdat", ByteArray(32))),
            "mp3 (ID3)" to withHeader(0x49, 0x44, 0x33, 0x04),
            "mp3 (bare frame sync)" to withHeader(0xFF, 0xFB),
            "wav" to withHeader(0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45),
            "ogg" to withHeader(0x4F, 0x67, 0x67, 0x53),
            "flac" to withHeader(0x66, 0x4C, 0x61, 0x43),
            "raw AAC (ADTS)" to withHeader(0xFF, 0xF1, 0x50, 0x40),
            "aiff" to withHeader(0x46, 0x4F, 0x52, 0x4D, 0, 0, 0, 0, 0x41, 0x49, 0x46, 0x46),
            "matroska/webm" to withHeader(0x1A, 0x45, 0xDF, 0xA3),
        )
        for ((name, bytes) in cases) {
            assertNull(
                audioPayloadRejection(bytes),
                "$name is an audio format the app accepts and must still play",
            )
        }
    }

    @Test
    fun aReferenceMovieHiddenBehindA64BitBoxIsStillRejected() {
        // size == 1 means the real length is the 64-bit value after the type. The
        // first walk gave up on any size it did not understand and answered "no
        // reference movie", so one such box in front of moov hid the redirect
        // entirely while cvlc still fetched the URL.
        val big = byteArrayOf(0, 0, 0, 1) + "free".encodeToByteArray() +
            byteArrayOf(0, 0, 0, 0, 0, 0, 0, 24) + ByteArray(8)
        val payload = box("ftyp", "qt  ".encodeToByteArray() + ByteArray(8)) + big +
            box("moov", box("mvhd", ByteArray(100)) + box("rmra", box("rmda", ByteArray(8))))
        assertNotNull(
            audioPayloadRejection(payload),
            "a 64-bit box before moov must not hide the reference movie behind it",
        )
    }

    @Test
    fun aStructureThatCannotBeWalkedIsRefusedRatherThanAssumedSafe() {
        // Truncated: the declared box size runs past the end of the data. Being
        // unable to parse it is not evidence that it holds no redirect.
        val truncated = byteArrayOf(0, 0, 0x40, 0) + "ftyp".encodeToByteArray() + ByteArray(32)
        assertNotNull(audioPayloadRejection(truncated), "unwalkable must fail closed")
    }

    @Test
    fun aBoxSizeThatOverflowsIsRefusedInsteadOfWalkingBackwards() {
        // A 64-bit largesize near Long.MAX_VALUE. `off + size` wraps negative, so a
        // `off + size > limit` guard passes it, and the truncated result points
        // BEHIND the current offset: the walk stepped 0 -> 24 -> 8. Two boxes
        // arranged that way is a cycle, on a payload a peer chooses, evaluated on
        // the click path.
        fun b32(v: Int) = byteArrayOf(
            (v ushr 24).toByte(), (v ushr 16).toByte(), (v ushr 8).toByte(), v.toByte(),
        )
        val hostile = b32(24) + "ftyp".encodeToByteArray() + ByteArray(16) +
            b32(1) + "free".encodeToByteArray() +
            byteArrayOf(0x7F, -1, -1, -1, -1, -1, -1, -0x10) + ByteArray(16)
        assertNotNull(
            audioPayloadRejection(hostile),
            "an overflowing box size must fail closed, not send the walk backwards",
        )
    }

    @Test
    fun aReferenceMovieIsFoundWhereverItHides() {
        val rmra = box("rmra", box("rmda", ByteArray(8)))
        val cases = mapOf(
            // Not a direct child of moov.
            "nested under moov/udta" to box("ftyp", "qt  ".encodeToByteArray() + ByteArray(8)) +
                box("moov", box("mvhd", ByteArray(100)) + box("udta", rmra)),
            // Behind a clean first moov, which the walk used to stop at.
            "in a second moov" to box("ftyp", "qt  ".encodeToByteArray() + ByteArray(8)) +
                box("moov", box("mvhd", ByteArray(100))) +
                box("moov", box("mvhd", ByteArray(100)) + rmra),
        )
        for ((where, payload) in cases) {
            assertNotNull(audioPayloadRejection(payload), "a reference movie $where must be found")
        }
    }

    @Test
    fun junkIsRejected() {
        assertNotNull(audioPayloadRejection("not audio at all, just text".encodeToByteArray()))
        assertNotNull(audioPayloadRejection(ByteArray(4)), "too short to identify")
    }

    @Test
    fun audioBytesThatHappenToSpellRmraAreNotMistakenForAReferenceMovie() {
        // Scanning for the tag instead of walking the box tree would reject this.
        val payload = box("ftyp", "M4A ".encodeToByteArray() + ByteArray(8)) +
            box("mdat", "....rmra....".encodeToByteArray())
        assertNull(audioPayloadRejection(payload), "a tag inside payload bytes is not a box")
    }
}
