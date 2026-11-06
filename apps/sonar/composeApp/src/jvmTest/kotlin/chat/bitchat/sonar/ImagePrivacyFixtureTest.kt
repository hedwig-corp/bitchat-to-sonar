package chat.bitchat.sonar

import java.io.ByteArrayInputStream
import java.io.File
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * The real send path on desktop: [imageBytesForSend] over the Rust core and the
 * JVM re-encoder, fed the core crate's fixtures (`core/sonar-media-privacy/
 * tests/fixtures`, every metadata field marked `LEAK`). QA-190.
 */
class ImagePrivacyFixtureTest {
    private val fixtures: File = generateSequence(File("").absoluteFile) { it.parentFile }
        .map { File(it, "core/sonar-media-privacy/tests/fixtures") }
        .first { it.isDirectory }

    private fun fixture(name: String) = File(fixtures, name).readBytes()

    private fun ByteArray.contains(text: String): Boolean {
        val needle = text.encodeToByteArray()
        return (0..size - needle.size).any { at -> needle.indices.all { this[at + it] == needle[it] } }
    }

    private fun send(name: String, mime: String): ImageSendDecision.Send {
        val raw = fixture(name)
        assertTrue(raw.contains("LEAK"), "$name lost its metadata")
        val send = assertIs<ImageSendDecision.Send>(imageBytesForSend(raw, name, mime))
        assertFalse(send.bytes.contains("LEAK"), "$name: metadata survived")
        return send
    }

    @Test
    fun aLocatedJpegLosesEverythingButItsOrientation() {
        val send = send("located.jpg", "image/jpeg")
        assertEquals("located.jpg", send.filename)
        assertEquals(6, SonarCore.imageExifOrientation(send.bytes))
        assertNotNull(ImageIO.read(ByteArrayInputStream(send.bytes)), "no longer decodes")
    }

    @Test
    fun aGifStaysAGif() {
        val send = send("located.gif", "image/gif")
        assertEquals("image/gif", send.mime)
        assertTrue(send.bytes.copyOfRange(0, 6).decodeToString() == "GIF89a")
    }

    @Test
    fun aTiffIsReencodedUpright() {
        val send = send("located.tiff", "image/tiff")
        assertEquals("located.jpg", send.filename)
        assertEquals("image/jpeg", send.mime)
        val image = assertNotNull(ImageIO.read(ByteArrayInputStream(send.bytes)))
        // The fixture is 24×16 with Orientation 6: upright it is 16×24.
        assertEquals(16, image.width)
        assertEquals(24, image.height)
    }

    /**
     * An iPhone photo. Desktop ImageIO cannot decode HEIC, so it used to be
     * refused; the core now cleans HEIC and AVIF in place, so it is sent as it
     * came, minus its metadata. The iOS suite checks the pixels decode the same.
     */
    @Test
    fun aHeicIsSentAsAHeic() {
        val raw = fixture("located.heic")
        val send = send("located.heic", "image/heic")
        assertEquals("located.heic", send.filename)
        assertEquals("image/heic", send.mime)
        assertCleanedInPlace(raw, send.bytes)
    }

    @Test
    fun anAvifIsSentAsAnAvif() {
        val raw = fixture("located.avif")
        val send = send("located.avif", "image/avif")
        assertEquals("located.avif", send.filename)
        assertEquals("image/avif", send.mime)
        assertCleanedInPlace(raw, send.bytes)
    }

    /** Same size, same boxes: only item data was overwritten. */
    private fun assertCleanedInPlace(raw: ByteArray, sent: ByteArray) {
        assertEquals(raw.size, sent.size, "a byte moved")
        assertEquals("ftyp", sent.copyOfRange(4, 8).decodeToString())
        assertFalse(sent.contains("xmpmeta"), "XMP survived")
        // Top-level boxes up to mdat: ftyp and meta, with every iloc offset.
        val mdat = generateSequence(0) { at -> at + u32(raw, at) }
            .first { at -> raw.copyOfRange(at + 4, at + 8).decodeToString() == "mdat" }
        assertTrue(raw.copyOfRange(0, mdat).contentEquals(sent.copyOfRange(0, mdat)), "ftyp or meta changed")
    }

    private fun u32(bytes: ByteArray, at: Int): Int =
        (0 until 4).fold(0) { value, i -> (value shl 8) or (bytes[at + i].toInt() and 0xFF) }

    @Test
    fun otherFilesAreUntouched() {
        val pdf = "%PDF-1.7\n%LEAK\n".encodeToByteArray()
        val send = assertIs<ImageSendDecision.Send>(imageBytesForSend(pdf, "a.pdf", "application/pdf"))
        assertSame(pdf, send.bytes)
    }
}
