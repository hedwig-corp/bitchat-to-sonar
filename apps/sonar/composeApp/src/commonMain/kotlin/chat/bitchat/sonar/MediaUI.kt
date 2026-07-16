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

/** Re-encode raw image bytes to JPEG at quality 0.85, or null if decoding fails. */
expect fun reencodeToJpeg(data: ByteArray): ByteArray?

/** Platform share/download/open integration for media viewer actions. */
@Composable
expect fun rememberMediaActions(): MediaActions
