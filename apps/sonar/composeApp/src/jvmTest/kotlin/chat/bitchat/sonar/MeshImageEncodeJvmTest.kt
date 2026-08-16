package chat.bitchat.sonar

import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import javax.imageio.ImageIO
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Real-encoder counterpart to `MeshImageBudgetTest`: pins that a phone-sized
 * photo actually comes out of the platform encoder at the mesh edge, not at
 * the 448px/45KB budget mesh images used to ship with.
 */
class MeshImageEncodeJvmTest {

    /** A detailed-but-compressible source, roughly like a 12MP photo. */
    private fun sourcePng(width: Int, height: Int): ByteArray {
        val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
        val rng = Random(7)
        for (y in 0 until height) {
            for (x in 0 until width) {
                val r = (x * 255 / width + rng.nextInt(12)) and 0xFF
                val g = (y * 255 / height + rng.nextInt(12)) and 0xFF
                val b = ((x + y) * 255 / (width + height)) and 0xFF
                image.setRGB(x, y, (r shl 16) or (g shl 8) or b)
            }
        }
        val out = ByteArrayOutputStream()
        ImageIO.write(image, "png", out)
        return out.toByteArray()
    }

    private fun bounds(bytes: ByteArray): Pair<Int, Int> {
        val decoded = assertNotNull(ImageIO.read(ByteArrayInputStream(bytes)))
        return decoded.width to decoded.height
    }

    @Test
    fun a_twelve_megapixel_photo_keeps_the_full_mesh_edge() {
        val encoded = assertNotNull(downscaleJpegForMesh(sourcePng(4032, 3024)))

        val (width, height) = bounds(encoded)
        assertTrue(
            maxOf(width, height) == MESH_IMAGE_MAX_EDGE_PX,
            "expected a ${MESH_IMAGE_MAX_EDGE_PX}px longest edge, got ${width}x$height",
        )
        assertTrue(
            encoded.size <= MAX_MESH_ATTACHMENT_BYTES,
            "mesh photo must fit the file packet (was ${encoded.size} bytes)",
        )
        // Aspect ratio survives the ladder.
        assertTrue(kotlin.math.abs(width.toFloat() / height - 4032f / 3024f) < 0.01f)
    }

    @Test
    fun a_small_photo_is_not_upscaled() {
        val encoded = assertNotNull(downscaleJpegForMesh(sourcePng(800, 600)))

        assertTrue(bounds(encoded) == 800 to 600, "small photos must keep their own size")
    }
}
