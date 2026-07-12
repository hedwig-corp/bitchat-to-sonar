@file:Suppress("DEPRECATION_ERROR")

package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
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
    maxBytes: Long,
    onDropped: (DroppedFiles) -> Unit,
): Modifier {
    if (!enabled) return this
    val scope = rememberCoroutineScope()
    val currentOnDropped = rememberUpdatedState(onDropped)
    return onExternalDrag(enabled = true, onDrop = { value ->
        val uris = (value.dragData as? DragData.FilesList)?.readFiles().orEmpty()
        if (uris.isNotEmpty()) {
            scope.launch {
                val result = withContext(Dispatchers.IO) { readDroppedFiles(uris, maxBytes) }
                currentOnDropped.value(result)
            }
        }
    })
}

internal fun readDroppedFiles(uris: List<String>, maxBytes: Long): DroppedFiles {
    val files = uris.mapNotNull { uri -> readDroppedFile(uri, maxBytes) }
    return DroppedFiles(files, rejectedCount = uris.size - files.size)
}

internal fun readDroppedFile(uri: String, maxBytes: Long): DroppedFile? {
    val file = runCatching { File(URI(uri)) }.getOrNull() ?: return null
    if (!file.isFile || file.length() > maxBytes) return null
    val readLimit = (maxBytes + 1L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
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
