package chat.bitchat.sonar

import org.jetbrains.skia.EncodedImageFormat
import org.jetbrains.skia.Paint
import org.jetbrains.skia.Rect
import org.jetbrains.skia.Surface
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Pins the `decodeThumbnail` contract shared by both Compose targets: a
 * transcript image must decode bounded (never at capture resolution) and hand
 * back re-encodable bytes so the next cold open skips the full-size decode.
 *
 * This covers the jvm/Skia actual. The Android actual (BitmapFactory
 * `inSampleSize`) needs an instrumented runner and is not exercised here — a
 * tracked gap, same as every other androidMain path in this module.
 */
class MediaThumbnailDecodeTest {

    /** An encoded PNG of [w]x[h] with some structure, so it does not compress
     *  to nothing and a downscale is measurable. */
    private fun encodedImage(w: Int, h: Int): ByteArray {
        val surface = Surface.makeRasterN32Premul(w, h)
        val canvas = surface.canvas
        canvas.clear(0xFF102030.toInt())
        val paint = Paint().apply { color = 0xFFEE5522.toInt() }
        var x = 0
        while (x < w) {
            canvas.drawRect(Rect.makeXYWH(x.toFloat(), 0f, 8f, h.toFloat()), paint)
            x += 16
        }
        return surface.makeImageSnapshot().encodeToData(EncodedImageFormat.PNG)!!.bytes
    }

    @Test
    fun oversizedImageIsBoundedAndReencoded() {
        val source = encodedImage(3000, 2000)

        val thumb = assertNotNull(decodeThumbnail(source, TRANSCRIPT_THUMB_MAX_EDGE_PX))

        assertEquals(
            TRANSCRIPT_THUMB_MAX_EDGE_PX,
            maxOf(thumb.bitmap.width, thumb.bitmap.height),
            "longest edge must be bounded to the thumbnail budget",
        )
        // 3000x2000 -> aspect ratio preserved.
        assertEquals(1024, thumb.bitmap.width)
        assertEquals(682, thumb.bitmap.height)

        val encoded = assertNotNull(thumb.encoded, "a downscaled image must produce disk bytes")
        assertTrue(
            encoded.size < source.size,
            "thumbnail (${encoded.size}B) must be smaller than the original (${source.size}B)",
        )
        // The persisted bytes must themselves decode, or the disk tier is dead weight.
        val roundTrip = assertNotNull(decodeThumbnail(encoded, TRANSCRIPT_THUMB_MAX_EDGE_PX))
        assertEquals(1024, roundTrip.bitmap.width)
    }

    @Test
    fun alreadySmallImageIsNotReencoded() {
        val source = encodedImage(320, 240)

        val thumb = assertNotNull(decodeThumbnail(source, TRANSCRIPT_THUMB_MAX_EDGE_PX))

        assertEquals(320, thumb.bitmap.width)
        assertEquals(240, thumb.bitmap.height)
        assertNull(
            thumb.encoded,
            "an image already under the bound must not be re-encoded: lossy for no decode saved",
        )
    }

    @Test
    fun nonImageBytesDecodeToNull() {
        assertNull(decodeThumbnail("not an image".encodeToByteArray(), TRANSCRIPT_THUMB_MAX_EDGE_PX))
        assertNull(decodeThumbnail(ByteArray(0), TRANSCRIPT_THUMB_MAX_EDGE_PX))
    }

    @Test
    fun pathDecodeMatchesByteDecodeBound() {
        // Signal-Android list path samples from a file URI; desktop actual reads
        // then reuses decodeThumbnail — pin the same bound contract.
        val source = encodedImage(2400, 1600)
        val file = kotlin.io.path.createTempFile(prefix = "sonar-thumb-", suffix = ".png").toFile()
        try {
            file.writeBytes(source)
            val fromPath = assertNotNull(
                decodeThumbnailFromPath(file.absolutePath, TRANSCRIPT_THUMB_MAX_EDGE_PX),
            )
            assertEquals(TRANSCRIPT_THUMB_MAX_EDGE_PX, maxOf(fromPath.bitmap.width, fromPath.bitmap.height))
        } finally {
            file.delete()
        }
    }
}
