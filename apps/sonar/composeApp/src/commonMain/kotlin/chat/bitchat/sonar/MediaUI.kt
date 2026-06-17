package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.ImageBitmap

/**
 * Platform photo picker. Static photos are delivered as JPEG bytes so the Rust
 * core image metadata path sees a format it handles consistently. Animated GIFs
 * are delivered as their original `image/gif` bytes so animation is not lost.
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
