package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

@Composable
internal actual fun Modifier.fileDropTarget(
    enabled: Boolean,
    maxTotalBytes: Long,
    onDropped: (DroppedFiles) -> Unit,
): Modifier = this
