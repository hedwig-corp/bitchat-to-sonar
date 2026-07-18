package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/** File-backed mobile video-note recorder. Implementations emit an ordinary
 * H.264/AAC MP4 and must release camera/microphone resources on cancel. */
expect class VideoNoteRecorder() {
    suspend fun start(): Boolean
    fun elapsed(): Int
    suspend fun finish(): ByteArray?
    fun cancel()
    fun flipCamera()
}

/** Live circular camera preview. It also binds the mobile camera lifecycle so
 * recording starts without a camera warm-up race. Desktop renders a fallback. */
@Composable
expect fun VideoNoteCameraPreview(
    recorder: VideoNoteRecorder,
    modifier: Modifier = Modifier,
)

/** Local-only inline playback. Callers guarantee [path] is a complete private
 * cache file; implementations must pause/release when the row leaves composition. */
@Composable
expect fun InlineVideoNotePlayer(
    path: String,
    muted: Boolean,
    onProgress: (Float) -> Unit = {},
    modifier: Modifier = Modifier,
)
