package chat.bitchat.sonar

import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * A transcript media bubble reserves its final box from the stored dimensions
 * so the decoded image never reflows the transcript. Marmot media carries them
 * as MIP-04 metadata; BLE mesh media has none, so the send/receive path derives
 * them with [decodeImageBounds]. If this returns null for real images, mesh
 * bubbles silently fall back to the fixed skeleton box and grow on decode —
 * shifting everything below them on every open.
 */
class ImageBoundsTest {

    private fun png(width: Int, height: Int): ByteArray {
        val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
        val out = ByteArrayOutputStream()
        ImageIO.write(image, "png", out)
        return out.toByteArray()
    }

    @Test
    fun readsDimensionsFromAnImageHeader() {
        assertEquals(120 to 80, decodeImageBounds(png(120, 80)))
    }

    @Test
    fun readsNonSquareDimensionsInTheRightOrder() {
        // width/height must not be transposed: a portrait photo reserved as
        // landscape would be as wrong as no reservation at all.
        assertEquals(64 to 256, decodeImageBounds(png(64, 256)))
    }

    @Test
    fun returnsNullForBytesThatAreNotAnImage() {
        assertNull(decodeImageBounds("not an image".encodeToByteArray()))
        assertNull(decodeImageBounds(ByteArray(0)))
    }

    @Test
    fun pendingUploadEchoCarriesTheImageDimensions() {
        // QA-A11: the Marmot "Uploading" echo had null width/height, so a
        // 500x230 photo reserved the 240x300dp max box and then collapsed to
        // its real height when the canonical MIP-04 row replaced it.
        val media = localMediaFor("pending-media-x", "image/jpeg", "photo.jpg", png(500, 230))
        assertEquals(500, media.width)
        assertEquals(230, media.height)
    }

    @Test
    fun nonImageLocalMediaHasNoDimensions() {
        val media = localMediaFor("pending-media-x", "audio/mp4", "vn.m4a", png(10, 10))
        assertNull(media.width)
        assertNull(media.height)
    }
}
