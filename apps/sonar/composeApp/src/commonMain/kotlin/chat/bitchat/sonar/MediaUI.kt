package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap

/**
 * Platform photo picker. Raw bytes are delivered with the source MIME type so
 * the preview shows full-quality data. JPEG re-encoding is deferred to send
 * confirmation via [reencodeToJpeg]. GIFs are passed through unmodified.
 */
@Composable
expect fun rememberPhotoPicker(
    onPicked: (bytes: ByteArray, filename: String, mime: String) -> Unit
): () -> Unit

@Composable
expect fun MediaImage(
    bytes: ByteArray,
    isGif: Boolean,
    modifier: Modifier = Modifier
)

/** Decode decrypted image bytes into a Compose [ImageBitmap] (null on failure). */
expect fun decodeImageBitmap(bytes: ByteArray): ImageBitmap?

/** Native actions for already-decrypted media bytes. */
class MediaActions(
    val canShare: Boolean = true,
    val share: suspend (bytes: ByteArray, filename: String, mime: String) -> Boolean,
    val save: suspend (bytes: ByteArray, filename: String, mime: String) -> Boolean,
    val open: suspend (bytes: ByteArray, filename: String, mime: String) -> Boolean,
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
