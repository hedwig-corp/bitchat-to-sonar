package chat.bitchat.sonar

/** What a send path may do with a file that may be an image. */
internal sealed class ImageSendDecision {
    /** Send these bytes under this name and MIME type. */
    class Send(val bytes: ByteArray, val filename: String, val mime: String) : ImageSendDecision()

    /** An image whose metadata could not be removed: it is never sent. */
    data object Refused : ImageSendDecision()
}

/**
 * Remove location, device and time metadata from a file before it leaves the
 * device — the Compose counterpart of iOS `snImageBytesForSend`. Called where
 * bytes enter a send path (picker GIFs, Send file, drag-drop, share), so the
 * local echo, the mesh retry queue and the outbox all hold the clean copy.
 *
 * The core recognizes images by their bytes, so a photo sent as `notes.bin` is
 * cleaned too and every other file passes through untouched. JPEG, PNG, GIF and
 * WebP are cleaned in place: pixels and animation stay as they were. What the
 * core cannot rewrite (HEIC, AVIF, TIFF) or parse is re-encoded to an upright
 * JPEG; if it cannot be decoded either, it is refused rather than sent as-is.
 */
internal fun imageBytesForSend(
    raw: ByteArray,
    filename: String,
    mime: String,
    scrub: (ByteArray) -> SonarImageScrub = SonarCore::scrubImageMetadata,
    reencode: (ByteArray) -> ByteArray? = ::reencodeToJpeg,
): ImageSendDecision = when (val result = scrub(raw)) {
    SonarImageScrub.NotImage, SonarImageScrub.Clean -> ImageSendDecision.Send(raw, filename, mime)
    is SonarImageScrub.Stripped -> ImageSendDecision.Send(result.bytes, filename, mime)
    SonarImageScrub.Reencode -> {
        // Our encoders write no metadata, but the guarantee is the scrub, not
        // the encoder: check the re-encoded copy too.
        val jpeg = reencode(raw)?.let { encoded ->
            when (val again = scrub(encoded)) {
                SonarImageScrub.Clean -> encoded
                is SonarImageScrub.Stripped -> again.bytes
                SonarImageScrub.NotImage, SonarImageScrub.Reencode -> null
            }
        }
        if (jpeg == null) {
            ImageSendDecision.Refused
        } else {
            ImageSendDecision.Send(jpeg, jpegFilename(filename), "image/jpeg")
        }
    }
}

/** `IMG_0001.HEIC` → `IMG_0001.jpg`; a name without an extension gains one. */
internal fun jpegFilename(filename: String): String {
    val dot = filename.lastIndexOf('.')
    val stem = if (dot > 0) filename.substring(0, dot) else filename
    return "${stem.ifBlank { "photo" }}.jpg"
}

/**
 * Rotate or mirror row-major pixels by EXIF [orientation] (1–8), so a
 * re-encoded JPEG — which carries no Orientation tag — shows upright. Returns
 * the new width, height and pixels; orientations 5–8 swap the axes.
 */
internal fun orientPixels(
    pixels: IntArray,
    width: Int,
    height: Int,
    orientation: Int,
): Triple<Int, Int, IntArray> {
    if (orientation !in 2..8) return Triple(width, height, pixels)
    val swap = orientation >= 5
    val outWidth = if (swap) height else width
    val out = IntArray(pixels.size)
    for (y in 0 until height) {
        for (x in 0 until width) {
            val (dx, dy) = when (orientation) {
                2 -> (width - 1 - x) to y // mirror horizontal
                3 -> (width - 1 - x) to (height - 1 - y) // rotate 180
                4 -> x to (height - 1 - y) // mirror vertical
                5 -> y to x // transpose
                6 -> (height - 1 - y) to x // rotate 90 clockwise
                7 -> (height - 1 - y) to (width - 1 - x) // transverse
                else -> y to (width - 1 - x) // 8: rotate 90 counter-clockwise
            }
            out[dy * outWidth + dx] = pixels[y * width + x]
        }
    }
    return Triple(outWidth, if (swap) width else height, out)
}
