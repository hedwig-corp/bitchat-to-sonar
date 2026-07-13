package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

internal data class DroppedFile(
    val bytes: ByteArray,
    val filename: String,
    val mime: String,
)

internal data class DroppedFiles(
    val files: List<DroppedFile>,
    val rejectedCount: Int,
)

internal const val MAX_INTERNET_ATTACHMENT_BYTES = 25L * 1024L * 1024L
internal const val MAX_MESH_ATTACHMENT_BYTES = 1L * 1024L * 1024L
internal const val MAX_DROPPED_FILES = MAX_ALBUM_PHOTOS

/** Desktop file-drop target. Mobile actuals are a no-op. */
@Composable
internal expect fun Modifier.fileDropTarget(
    enabled: Boolean,
    maxTotalBytes: Long,
    onDropped: (DroppedFiles) -> Unit,
): Modifier
