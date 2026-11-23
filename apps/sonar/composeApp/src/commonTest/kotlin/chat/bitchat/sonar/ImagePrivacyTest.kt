package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertSame

/**
 * The send-path decision on top of the core scrubber (iOS parity:
 * `snImageBytesForSend`). The scrubber itself is pinned by the
 * `sonar-media-privacy` crate tests and `ImagePrivacyFixtureTest` on the JVM.
 */
class ImagePrivacyTest {
    private val raw = byteArrayOf(1, 2, 3)
    private val clean = byteArrayOf(4, 5)
    private val jpeg = byteArrayOf(6, 7, 8)

    private fun decide(
        scrub: (ByteArray) -> SonarImageScrub,
        reencode: (ByteArray) -> ByteArray? = { error("must not re-encode") },
    ) = imageBytesForSend(raw, "IMG_0001.HEIC", "image/heic", scrub, reencode)

    @Test
    fun nonImagesAndCleanImagesPassThroughUntouched() {
        for (result in listOf(SonarImageScrub.NotImage, SonarImageScrub.Clean)) {
            val send = assertIs<ImageSendDecision.Send>(decide({ result }))
            assertSame(raw, send.bytes)
            assertEquals("IMG_0001.HEIC", send.filename)
            assertEquals("image/heic", send.mime)
        }
    }

    @Test
    fun strippedImagesKeepTheirNameAndType() {
        val send = assertIs<ImageSendDecision.Send>(decide({ SonarImageScrub.Stripped(clean) }))
        assertContentEquals(clean, send.bytes)
        assertEquals("IMG_0001.HEIC", send.filename)
        assertEquals("image/heic", send.mime)
    }

    @Test
    fun reencodedImagesBecomeJpegs() {
        val send = assertIs<ImageSendDecision.Send>(
            decide({ if (it === raw) SonarImageScrub.Reencode else SonarImageScrub.Clean }, { jpeg }),
        )
        assertContentEquals(jpeg, send.bytes)
        assertEquals("IMG_0001.jpg", send.filename)
        assertEquals("image/jpeg", send.mime)
    }

    @Test
    fun theReencodedCopyIsScrubbedToo() {
        val send = assertIs<ImageSendDecision.Send>(
            decide({ if (it === raw) SonarImageScrub.Reencode else SonarImageScrub.Stripped(clean) }, { jpeg }),
        )
        assertContentEquals(clean, send.bytes)
    }

    @Test
    fun anImageThatCannotBeCleanedIsNeverSent() {
        assertEquals(ImageSendDecision.Refused, decide({ SonarImageScrub.Reencode }, { null }))
        // An encoder that produced something the core cannot vouch for.
        assertEquals(
            ImageSendDecision.Refused,
            decide({ if (it === raw) SonarImageScrub.Reencode else SonarImageScrub.NotImage }, { jpeg }),
        )
        assertEquals(ImageSendDecision.Refused, decide({ SonarImageScrub.Reencode }, { jpeg }))
    }

    @Test
    fun jpegNames() {
        assertEquals("IMG_0001.jpg", jpegFilename("IMG_0001.HEIC"))
        assertEquals("scan.page.jpg", jpegFilename("scan.page.tiff"))
        assertEquals("photo.jpg", jpegFilename("photo"))
        assertEquals(".hidden.jpg", jpegFilename(".hidden"))
        assertEquals("photo.jpg", jpegFilename(""))
    }

    /** 3×2 pixels numbered row by row:
     *  ```
     *  1 2 3
     *  4 5 6
     *  ```
     */
    private val pixels = intArrayOf(1, 2, 3, 4, 5, 6)

    private fun orient(orientation: Int): Triple<Int, Int, List<Int>> =
        orientPixels(pixels, 3, 2, orientation).let { (w, h, p) -> Triple(w, h, p.toList()) }

    @Test
    fun everyExifOrientation() {
        assertEquals(Triple(3, 2, listOf(1, 2, 3, 4, 5, 6)), orient(1))
        assertEquals(Triple(3, 2, listOf(3, 2, 1, 6, 5, 4)), orient(2)) // mirror horizontal
        assertEquals(Triple(3, 2, listOf(6, 5, 4, 3, 2, 1)), orient(3)) // rotate 180
        assertEquals(Triple(3, 2, listOf(4, 5, 6, 1, 2, 3)), orient(4)) // mirror vertical
        assertEquals(Triple(2, 3, listOf(1, 4, 2, 5, 3, 6)), orient(5)) // transpose
        assertEquals(Triple(2, 3, listOf(4, 1, 5, 2, 6, 3)), orient(6)) // rotate 90 clockwise
        assertEquals(Triple(2, 3, listOf(6, 3, 5, 2, 4, 1)), orient(7)) // transverse
        assertEquals(Triple(2, 3, listOf(3, 6, 2, 5, 1, 4)), orient(8)) // rotate 90 counter-clockwise
        assertEquals(Triple(3, 2, listOf(1, 2, 3, 4, 5, 6)), orient(9))
    }
}
