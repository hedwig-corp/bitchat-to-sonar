package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap

/** One picked photo or video delivered by [rememberPhotoPicker], in selection order. */
class PickedPhoto(
    val bytes: ByteArray,
    val filename: String,
    val mime: String,
)

/** Max photos/videos per pick — 2+ send as ONE album message (card deck). */
const val MAX_ALBUM_PHOTOS = 10

/** True when the attachment is a video container (sent as-is, never re-encoded). */
fun isVideoMime(mime: String): Boolean = mime.startsWith("video/")

/** Aggregate cap for the videos in ONE picked album — mirrors the core
 *  `MAX_MEDIA_TOTAL_PLAINTEXT_BYTES` backstop (every album item is memory-
 *  resident at once during the send). */
const val MAX_ALBUM_TOTAL_VIDEO_BYTES = 100L * 1024L * 1024L

/** Video container MIME by filename extension, or null when not a video. */
internal fun videoMimeForExtension(extension: String): String? = when (extension.lowercase()) {
    "mp4", "m4v" -> "video/mp4"
    "mov" -> "video/quicktime"
    "webm" -> "video/webm"
    "mkv" -> "video/x-matroska"
    "avi" -> "video/x-msvideo"
    "3gp" -> "video/3gpp"
    else -> null
}

/** Resolve a picked item's video MIME from provider metadata + filename.
 *  Providers can report null, mixed case, parameters, or `application/mp4`;
 *  missing that here would route a huge video into the unbounded image path. */
internal fun pickedVideoMime(declaredMime: String, filename: String): String? {
    val normalized = declaredMime.substringBefore(';').trim().lowercase()
    if (isVideoMime(normalized)) return normalized
    if (normalized == "application/mp4") return "video/mp4"
    val fromExtension = videoMimeForExtension(filename.substringAfterLast('.', ""))
    if (fromExtension != null && (normalized.isBlank() || normalized == "application/octet-stream")) {
        return fromExtension
    }
    return null
}

/**
 * Platform photo/video picker (multi-select up to [MAX_ALBUM_PHOTOS]). Raw
 * bytes are delivered with the source MIME type so the preview shows
 * full-quality data. JPEG re-encoding is deferred to send confirmation via
 * [reencodeToJpeg]; GIFs and videos are passed through unmodified. Videos over
 * the receiver download cap ([MAX_INTERNET_ATTACHMENT_BYTES]) are rejected at
 * pick time and reported via `rejectedTooLarge` — receivers can never fetch
 * them, so staging one would only fail later at send.
 */
@Composable
expect fun rememberPhotoPicker(
    onPicked: (items: List<PickedPhoto>, rejectedTooLarge: Int) -> Unit
): () -> Unit

/**
 * Platform document picker for arbitrary files. Implementations must copy the
 * selected content immediately while the picker grant is valid and enforce the
 * aggregate [maxTotalBytes] limit before invoking [onPicked].
 */
@Composable
internal expect fun rememberFilePicker(
    maxTotalBytes: Long,
    onPicked: (DroppedFiles) -> Unit,
): () -> Unit

@Composable
expect fun MediaImage(
    bytes: ByteArray,
    isGif: Boolean,
    modifier: Modifier = Modifier
)

/** Decode decrypted image bytes into a Compose [ImageBitmap] (null on failure). */
expect fun decodeImageBitmap(bytes: ByteArray): ImageBitmap?

/**
 * Read an image's pixel dimensions from its header, WITHOUT decoding pixels.
 *
 * Marmot media carries width/height as MIP-04 metadata, which lets a transcript
 * bubble reserve its final box before the bytes decode (Signal pre-sizing). BLE
 * mesh media has no such metadata, so the sender/receiver derives it here at the
 * moment it still holds the bytes — otherwise the bubble reserves the fixed
 * skeleton box and visibly grows when the image decodes. Returns null when the
 * bytes are not a decodable image.
 */
expect fun decodeImageBounds(bytes: ByteArray): Pair<Int, Int>?

/**
 * Extract a poster frame from a local video file for the pre-send preview
 * (null when the platform has no video decoder — callers show a generic video
 * tile instead). Runs a media decode: call from a background dispatcher only.
 */
expect fun decodeVideoPosterFrame(path: String): ImageBitmap?

/** Native actions for an already-decrypted private local file. */
class MediaActions(
    val canShare: Boolean = true,
    val share: suspend (path: String, filename: String, mime: String) -> Boolean,
    val save: suspend (path: String, filename: String, mime: String) -> Boolean,
    val open: suspend (path: String, filename: String, mime: String) -> Boolean,
)

/** Write [data] to a platform temp file, returning its absolute path. */
expect fun writeTempMediaFile(data: ByteArray, suffix: String): String

/** Read a temp file written by [writeTempMediaFile] back into memory. */
expect fun readTempMediaFile(path: String): ByteArray?

/** Delete a temp file. Safe to call if the file doesn't exist. */
expect fun deleteTempMediaFile(path: String)

/**
 * Re-encode raw image bytes to JPEG for an internet (Blossom) send, or null if
 * decoding fails. The re-encode is what strips EXIF/GPS, so already-JPEG bytes
 * are normalized here too rather than passed through. Quality is high
 * ([INTERNET_IMAGE_JPEG_QUALITY]) because the receiver cap is 25 MiB — the
 * bandwidth saved by a lossier encode is not worth the visible ringing on
 * screenshots and text.
 */
expect fun reencodeToJpeg(data: ByteArray): ByteArray?

/** JPEG quality for an internet-routed photo (0-100). */
const val INTERNET_IMAGE_JPEG_QUALITY = 92

/**
 * Re-encode raw image bytes to a JPEG that fits the BLE mesh file packet, or
 * null if decoding fails. Mesh media has no Blossom upload: the bytes travel
 * as fire-and-forget BLE fragments capped at [MAX_MESH_ATTACHMENT_BYTES], so a
 * full-resolution photo is either rejected outright or a very long fragment
 * train. Downscaling here is what makes a mesh photo both deliverable and
 * legible.
 */
expect fun downscaleJpegForMesh(data: ByteArray): ByteArray?

/**
 * Longest edge for a mesh-routed image. 1600 px still reads as a photo (and
 * keeps screenshot text legible) in a 3x phone bubble, and the transcript
 * decodes thumbnails at [TRANSCRIPT_THUMB_MAX_EDGE_PX] anyway, so this leaves
 * headroom for the viewer without paying for pixels nobody sees.
 */
const val MESH_IMAGE_MAX_EDGE_PX = 1600

/** Floor for the mesh downscale ladder. */
const val MESH_IMAGE_MIN_EDGE_PX = 640

/**
 * Soft byte budget for a mesh image: stop compressing once the JPEG fits.
 * Well under [MAX_MESH_ATTACHMENT_BYTES] because BLE fragments are
 * fire-and-forget (no retransmit), so a shorter train is a likelier delivery.
 */
const val MESH_IMAGE_TARGET_BYTES = 320 * 1024

const val MESH_IMAGE_MAX_QUALITY = 85
const val MESH_IMAGE_MIN_QUALITY = 60
private const val MESH_IMAGE_QUALITY_STEP = 5

/**
 * Pick the largest edge and quality that fit the mesh budget: drop quality
 * first (cheap, keeps detail), and only then halve the edge. [encode] renders
 * the source at the given longest edge and JPEG quality.
 *
 * Returns the smallest JPEG produced when nothing fits the hard limit — the
 * caller still enforces [MAX_MESH_ATTACHMENT_BYTES] and can fall back to the
 * White Noise route, which is strictly better than dropping the send.
 */
internal fun compressToMeshBudget(
    sourceLongestEdgePx: Int,
    hardLimitBytes: Int = MAX_MESH_ATTACHMENT_BYTES.toInt(),
    encode: (edgePx: Int, quality: Int) -> ByteArray?,
): ByteArray? {
    var edgePx = minOf(sourceLongestEdgePx, MESH_IMAGE_MAX_EDGE_PX)
        .coerceAtLeast(MESH_IMAGE_MIN_EDGE_PX)
    var best: ByteArray? = null
    while (true) {
        var quality = MESH_IMAGE_MAX_QUALITY
        while (true) {
            val encoded = encode(edgePx, quality) ?: break
            best = encoded
            if (encoded.size <= MESH_IMAGE_TARGET_BYTES) return encoded
            if (quality <= MESH_IMAGE_MIN_QUALITY) break
            quality = maxOf(MESH_IMAGE_MIN_QUALITY, quality - MESH_IMAGE_QUALITY_STEP)
        }
        val candidate = best
        if (candidate != null && candidate.size <= hardLimitBytes) return candidate
        if (edgePx <= MESH_IMAGE_MIN_EDGE_PX) return best
        edgePx = maxOf(MESH_IMAGE_MIN_EDGE_PX, edgePx / 2)
    }
}

/** Platform share/download/open integration for media viewer actions. */
@Composable
expect fun rememberMediaActions(): MediaActions
