package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Compose parity with iOS finalizeVideoForSend: a picked video must not carry
 * the place it was recorded. Location lives in `udta`/`meta`/XMP boxes; the
 * sanitizer blanks them in place so sample offsets and the encode survive.
 */
class VideoPrivacyTest {
    private fun box(type: String, vararg payload: ByteArray): ByteArray {
        val body = payload.fold(ByteArray(0)) { acc, p -> acc + p }
        val size = 8 + body.size
        return byteArrayOf(
            (size ushr 24).toByte(), (size ushr 16).toByte(), (size ushr 8).toByte(), size.toByte(),
        ) + type.encodeToByteArray().let { if (type.startsWith("©")) byteArrayOf(0xA9.toByte()) + type.drop(1).encodeToByteArray() else it } + body
    }

    private fun bytes(text: String) = text.encodeToByteArray()

    private val location = "+46.0037+008.9511+273.000/"
    private val mdatPayload = ByteArray(64) { (it * 7).toByte() }

    /** Android/QuickTime-style located file: ©xyz, 3GPP loci, Apple keys meta. */
    private fun locatedMp4(): ByteArray = box("ftyp", bytes("isom"), ByteArray(4), bytes("isomiso2mp41")) +
        box("mdat", mdatPayload) +
        box(
            "moov",
            box("mvhd", ByteArray(100) { 1 }),
            box(
                "trak",
                box("tkhd", ByteArray(84) { 2 }),
                box("udta", box("loci", ByteArray(4), bytes(location))),
                box("mdia", box("mdhd", ByteArray(24) { 3 })),
            ),
            box("udta", box("©xyz", ByteArray(4), bytes(location))),
            box("meta", ByteArray(4), box("keys", bytes("mdtacom.apple.quicktime.location.ISO6709")), box("ilst", bytes(location))),
        )

    private fun ByteArray.indexOf(needle: ByteArray): Int {
        outer@ for (i in 0..size - needle.size) {
            for (j in needle.indices) if (this[i + j] != needle[j]) continue@outer
            return i
        }
        return -1
    }

    @Test
    fun locationBoxesAreBlankedInPlace() {
        val input = locatedMp4()
        assertTrue(input.indexOf(bytes(location)) >= 0, "fixture must carry a location")

        val result = stripVideoLocationMetadata(input)

        assertIs<VideoPrivacyResult.Clean>(result)
        assertTrue(result.stripped)
        val out = result.bytes
        assertEquals(input.size, out.size, "no byte may move: stco/co64 offsets must stay valid")
        assertEquals(-1, out.indexOf(bytes(location)))
        assertEquals(-1, out.indexOf(bytes("ISO6709")))
        assertEquals(-1, out.indexOf(bytes("loci")))
        // Samples, movie header and track header are untouched.
        val mdatAt = input.indexOf(mdatPayload)
        assertContentEquals(mdatPayload, out.copyOfRange(mdatAt, mdatAt + mdatPayload.size))
        val mvhdAt = input.indexOf(bytes("mvhd"))
        assertContentEquals(input.copyOfRange(mvhdAt, mvhdAt + 104), out.copyOfRange(mvhdAt, mvhdAt + 104))
        val tkhdAt = input.indexOf(bytes("tkhd"))
        assertContentEquals(input.copyOfRange(tkhdAt, tkhdAt + 88), out.copyOfRange(tkhdAt, tkhdAt + 88))
        // Still a well-formed file: a second pass finds nothing left to strip.
        val again = stripVideoLocationMetadata(out)
        assertIs<VideoPrivacyResult.Clean>(again)
        assertFalse(again.stripped)
    }

    @Test
    fun aVideoWithoutMetadataIsReturnedUnchanged() {
        val input = box("ftyp", bytes("isom"), ByteArray(4)) + box("mdat", mdatPayload) +
            box("moov", box("mvhd", ByteArray(100)), box("trak", box("tkhd", ByteArray(84))))
        val result = stripVideoLocationMetadata(input)
        assertIs<VideoPrivacyResult.Clean>(result)
        assertFalse(result.stripped)
        assertContentEquals(input, result.bytes)
    }

    @Test
    fun onlyXmpUuidBoxesAreBlanked() {
        val xmp = byteArrayOf(
            0xBE.toByte(), 0x7A, 0xCF.toByte(), 0xCB.toByte(), 0x97.toByte(), 0xA9.toByte(), 0x42, 0xE8.toByte(),
            0x9C.toByte(), 0x71, 0x99.toByte(), 0x94.toByte(), 0x91.toByte(), 0xE3.toByte(), 0xAF.toByte(), 0xAC.toByte(),
        )
        val other = ByteArray(16) { 0x11 }
        val input = box("ftyp", bytes("isom"), ByteArray(4)) +
            box("uuid", xmp, bytes("<x:xmpmeta exif:GPSLatitude='46,0.2N'/>")) +
            box("uuid", other, bytes("vendor-data")) +
            box("moov", box("mvhd", ByteArray(100))) + box("mdat", mdatPayload)
        val result = stripVideoLocationMetadata(input)
        assertIs<VideoPrivacyResult.Clean>(result)
        assertEquals(-1, result.bytes.indexOf(bytes("GPSLatitude")))
        assertTrue(result.bytes.indexOf(bytes("vendor-data")) >= 0, "non-XMP uuid boxes are left alone")
    }

    @Test
    fun a64BitMdatStillParses() {
        val largeMdat = byteArrayOf(0, 0, 0, 1) + bytes("mdat") +
            byteArrayOf(0, 0, 0, 0, 0, 0, 0, (16 + mdatPayload.size).toByte()) + mdatPayload
        val input = box("ftyp", bytes("isom"), ByteArray(4)) + largeMdat +
            box("moov", box("mvhd", ByteArray(100)), box("udta", box("©xyz", bytes(location))))
        val result = stripVideoLocationMetadata(input)
        assertIs<VideoPrivacyResult.Clean>(result)
        assertTrue(result.stripped)
        assertEquals(-1, result.bytes.indexOf(bytes(location)))
    }

    @Test
    fun unverifiableIsoFilesFailClosed() {
        val valid = locatedMp4()
        // Truncated mid-moov: the box sizes no longer add up.
        assertIs<VideoPrivacyResult.Malformed>(stripVideoLocationMetadata(valid.copyOf(valid.size - 10)))
        // No movie header at all.
        assertIs<VideoPrivacyResult.Malformed>(
            stripVideoLocationMetadata(box("ftyp", bytes("isom"), ByteArray(4)) + box("mdat", mdatPayload))
        )
        // Compressed movie header: its metadata cannot be inspected.
        assertIs<VideoPrivacyResult.Malformed>(
            stripVideoLocationMetadata(box("ftyp", bytes("qt  "), ByteArray(4)) + box("moov", box("cmov", ByteArray(32))))
        )
    }

    @Test
    fun nonIsoContainersAreNotParsed() {
        val webm = byteArrayOf(0x1A, 0x45, 0xDF.toByte(), 0xA3.toByte()) + ByteArray(60)
        assertIs<VideoPrivacyResult.NotIsoBmff>(stripVideoLocationMetadata(webm))
        assertIs<VideoPrivacyResult.NotIsoBmff>(stripVideoLocationMetadata(ByteArray(3)))
    }

    @Test
    fun theSendPathOnlyAcceptsVerifiedMp4s() {
        // The picker path fails closed: unverifiable MP4/MOV and containers the
        // sanitizer cannot read (WebM/MKV/AVI) are refused, never sent as-is.
        val sent = videoBytesForSend(locatedMp4())
        assertIs<VideoSendDecision.Send>(sent)
        assertEquals(-1, sent.bytes.indexOf(bytes(location)))
        val valid = locatedMp4()
        assertIs<VideoSendDecision.Unverifiable>(videoBytesForSend(valid.copyOf(valid.size - 10)))
        val webmWithXmp = byteArrayOf(0x1A, 0x45, 0xDF.toByte(), 0xA3.toByte()) + bytes("<x:xmpmeta GPSLatitude='46'/>")
        assertIs<VideoSendDecision.UnsupportedContainer>(videoBytesForSend(webmWithXmp))
    }
}
