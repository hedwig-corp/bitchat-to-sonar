package chat.bitchat.sonar

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color

/** Desktop capture is intentionally unavailable; received notes retain the MP4
 * poster/native-open fallback through the shared attachment viewer. */
actual class VideoNoteRecorder {
    actual suspend fun start(): Boolean = false
    actual fun elapsed(): Int = 0
    actual suspend fun finish(): ByteArray? = null
    actual fun cancel() = Unit
    actual fun flipCamera() = Unit
}

@Composable
actual fun VideoNoteCameraPreview(recorder: VideoNoteRecorder, modifier: Modifier) {
    Box(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        Text("Video notes require a phone", color = Color.White)
    }
}

@Composable
actual fun InlineVideoNotePlayer(
    path: String,
    muted: Boolean,
    onProgress: (Float) -> Unit,
    modifier: Modifier,
) {
    LaunchedEffect(path) { onProgress(0f) }
    Box(
        modifier.background(Color.Black).clickable {
            runCatching { java.awt.Desktop.getDesktop().open(java.io.File(path)) }
        },
        contentAlignment = Alignment.Center,
    ) {
        Text("▶", color = Color.White)
    }
}
