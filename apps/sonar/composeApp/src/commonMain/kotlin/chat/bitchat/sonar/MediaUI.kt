package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.ImageBitmap

/**
 * Platform photo picker. Returns a lambda that, when invoked, opens the system
 * image picker; the chosen image is delivered as **JPEG** bytes (re-encoded so
 * the Rust core's image encoder — which doesn't take HEIC — always handles it).
 */
@Composable
expect fun rememberPhotoPicker(
    onPicked: (bytes: ByteArray, filename: String, mime: String) -> Unit
): () -> Unit

/** Decode decrypted image bytes into a Compose [ImageBitmap] (null on failure). */
expect fun decodeImageBitmap(bytes: ByteArray): ImageBitmap?

/** Native actions for already-decrypted media bytes. */
class MediaActions(
    val canShare: Boolean = true,
    val share: suspend (bytes: ByteArray, filename: String, mime: String) -> Boolean,
    val save: suspend (bytes: ByteArray, filename: String, mime: String) -> Boolean,
    val open: suspend (bytes: ByteArray, filename: String, mime: String) -> Boolean,
)

/** Platform share/download/open integration for media viewer actions. */
@Composable
expect fun rememberMediaActions(): MediaActions
