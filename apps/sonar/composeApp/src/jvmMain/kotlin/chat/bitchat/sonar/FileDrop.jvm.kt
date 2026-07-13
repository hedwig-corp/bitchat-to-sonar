@file:Suppress("DEPRECATION_ERROR")

package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.DragData
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.onExternalDrag
import java.io.File
import java.net.URI
import java.nio.file.Files
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Compose Desktop 1.7.3 deprecates onExternalDrag but does not expose the
// replacement Modifier.dragAndDropTarget bridge in its JVM artifact.
@OptIn(ExperimentalComposeUiApi::class)
@Composable
internal actual fun Modifier.fileDropTarget(
    enabled: Boolean,
    maxTotalBytes: Long,
    onDropped: (DroppedFiles) -> Unit,
): Modifier {
    if (!enabled) return this
    val scope = rememberCoroutineScope()
    val currentOnDropped = rememberUpdatedState(onDropped)
    var readInProgress by remember { mutableStateOf(false) }
    return onExternalDrag(enabled = true, onDrop = { value ->
        val uris = (value.dragData as? DragData.FilesList)?.readFiles().orEmpty()
        if (uris.isNotEmpty() && !readInProgress) {
            readInProgress = true
            scope.launch {
                try {
                    val result = withContext(Dispatchers.IO) {
                        readDroppedFiles(uris, maxTotalBytes)
                    }
                    currentOnDropped.value(result)
                } finally {
                    readInProgress = false
                }
            }
        }
    })
}

internal fun readDroppedFiles(uris: List<String>, maxTotalBytes: Long): DroppedFiles {
    if (maxTotalBytes <= 0L) return DroppedFiles(emptyList(), rejectedCount = uris.size)

    val files = mutableListOf<DroppedFile>()
    var rejectedCount = (uris.size - MAX_DROPPED_FILES).coerceAtLeast(0)
    var remainingBytes = maxTotalBytes
    for (uri in uris.take(MAX_DROPPED_FILES)) {
        val file = readDroppedFile(uri, remainingBytes)
        if (file == null) {
            rejectedCount += 1
        } else {
            files += file
            remainingBytes -= file.bytes.size.toLong()
        }
    }
    return DroppedFiles(files, rejectedCount)
}

internal fun readDroppedFile(uri: String, maxBytes: Long): DroppedFile? {
    if (maxBytes <= 0L) return null
    val file = runCatching { File(URI(uri)) }.getOrNull() ?: return null
    if (!file.isFile || file.length() > maxBytes) return null
    val readLimit = maxBytes.coerceAtMost(Int.MAX_VALUE.toLong() - 1L).toInt() + 1
    val bytes = runCatching {
        file.inputStream().use { input -> input.readNBytes(readLimit) }
    }.getOrNull() ?: return null
    if (bytes.size.toLong() > maxBytes) return null
    val filename = file.name.ifBlank { "attachment" }
    val mime = runCatching { Files.probeContentType(file.toPath()) }
        .getOrNull()
        .orEmpty()
        .ifBlank { "application/octet-stream" }
    return DroppedFile(bytes, filename, mime)
}
