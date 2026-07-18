package chat.bitchat.sonar

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import java.io.File
import java.util.concurrent.CompletableFuture
import kotlin.coroutines.resume
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine

actual class VideoNoteRecorder {
    private val context get() = AppContextHolder.ctx
    private var owner: ComponentActivity? = null
    private var previewView: PreviewView? = null
    private var provider: ProcessCameraProvider? = null
    private var preview: Preview? = null
    private var capture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var outputFile: File? = null
    private var completion: CompletableFuture<Boolean>? = null
    private var recordingGeneration = 0L
    private var discard = false
    private var startedAtMs = 0L
    private var front = true

    internal fun attach(owner: ComponentActivity, view: PreviewView) {
        if (this.owner === owner && previewView === view && provider != null && capture != null) return
        this.owner = owner
        previewView = view
        view.scaleType = PreviewView.ScaleType.FILL_CENTER
        val future = ProcessCameraProvider.getInstance(owner)
        future.addListener({
            if (this.owner === owner && previewView === view) {
                provider = runCatching { future.get() }.getOrNull()
                bindNow()
            }
        }, ContextCompat.getMainExecutor(owner))
    }

    internal fun detach() {
        cancel()
        provider?.unbindAll()
        owner = null
        provider = null
        previewView = null
        preview = null
        capture = null
    }

    @SuppressLint("MissingPermission")
    actual suspend fun start(): Boolean {
        // CameraX emits Finalize asynchronously after stop(). Wait before
        // reusing the Recorder so a rapid cancel → record gesture cannot make
        // the previous capture invalidate the new one.
        completion?.let { previous ->
            if (!previous.isDone) awaitCompletion(previous)
            if (completion === previous) completion = null
        }
        if (context.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) return false
        if (!awaitBound()) return false
        val videoCapture = capture ?: return false

        val file = File(context.cacheDir, "video-note-${System.currentTimeMillis()}.mp4")
        file.delete()
        val done = CompletableFuture<Boolean>()
        val generation = ++recordingGeneration
        discard = false
        outputFile = file
        completion = done
        startedAtMs = System.currentTimeMillis()
        return runCatching {
            recording = videoCapture.output
                .prepareRecording(
                    context,
                    FileOutputOptions.Builder(file)
                        .setFileSizeLimit(25L * 1024L * 1024L)
                        .build(),
                )
                .withAudioEnabled()
                .start(ContextCompat.getMainExecutor(context)) { event ->
                    if (event is VideoRecordEvent.Finalize) {
                        if (recordingGeneration == generation) recording = null
                        done.complete(event.error == VideoRecordEvent.Finalize.ERROR_NONE)
                    }
                }
            true
        }.getOrElse {
            file.delete()
            outputFile = null
            completion = null
            false
        }
    }

    actual fun elapsed(): Int =
        if (startedAtMs == 0L) 0 else ((System.currentTimeMillis() - startedAtMs) / 1000).toInt()

    actual suspend fun finish(): ByteArray? {
        val file = outputFile ?: return null
        recording?.stop()
        val ok = awaitCompletion()
        startedAtMs = 0L
        outputFile = null
        completion = null
        val bytes = if (ok && !discard && file.length() > 2_000L) {
            runCatching { file.readBytes() }.getOrNull()
        } else null
        file.delete()
        return bytes
    }

    actual fun cancel() {
        discard = true
        recordingGeneration += 1
        val activeRecording = recording
        recording = null
        activeRecording?.stop()
        startedAtMs = 0L
        outputFile?.delete()
        outputFile = null
    }

    actual fun flipCamera() {
        if (recording != null) return
        front = !front
        owner?.let { ContextCompat.getMainExecutor(it).execute { bindNow() } }
    }

    private suspend fun awaitBound(): Boolean {
        if (provider != null && capture != null) return true
        val activity = owner ?: return false
        return suspendCancellableCoroutine { continuation ->
            val future = ProcessCameraProvider.getInstance(activity)
            future.addListener({
                val ok = runCatching {
                    if (owner !== activity) return@runCatching false
                    provider = future.get()
                    bindNow()
                }.getOrDefault(false)
                if (continuation.isActive) continuation.resume(ok)
            }, ContextCompat.getMainExecutor(activity))
        }
    }

    private fun bindNow(): Boolean {
        val activity = owner ?: return false
        val cameraProvider = provider ?: return false

        val recorder = Recorder.Builder()
            .setQualitySelector(QualitySelector.from(Quality.LOWEST))
            .setTargetVideoEncodingBitRate(96_000)
            .build()
        val nextCapture = VideoCapture.withOutput(recorder)
        val nextPreview = Preview.Builder().build().also {
            previewView?.surfaceProvider?.let(it::setSurfaceProvider)
        }
        val preferred = if (front) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        val fallback = if (front) CameraSelector.DEFAULT_BACK_CAMERA else CameraSelector.DEFAULT_FRONT_CAMERA
        val (selector, selectedFront) = runCatching {
            when {
                cameraProvider.hasCamera(preferred) -> preferred to front
                cameraProvider.hasCamera(fallback) -> fallback to !front
                else -> return false
            }
        }.getOrElse { return false }
        front = selectedFront
        return runCatching {
            cameraProvider.unbindAll()
            cameraProvider.bindToLifecycle(activity, selector, nextPreview, nextCapture)
            preview = nextPreview
            capture = nextCapture
            true
        }.getOrDefault(false)
    }

    private suspend fun awaitCompletion(): Boolean {
        val future = completion ?: return false
        return awaitCompletion(future)
    }

    private suspend fun awaitCompletion(future: CompletableFuture<Boolean>): Boolean {
        return suspendCancellableCoroutine { continuation ->
            future.whenComplete { value, _ ->
                if (continuation.isActive) continuation.resume(value == true)
            }
        }
    }
}

@Composable
actual fun VideoNoteCameraPreview(recorder: VideoNoteRecorder, modifier: Modifier) {
    val activity = LocalContext.current as ComponentActivity
    DisposableEffect(recorder) { onDispose { recorder.detach() } }
    AndroidView(
        factory = { context ->
            PreviewView(context).also { recorder.attach(activity, it) }
        },
        update = { recorder.attach(activity, it) },
        modifier = modifier,
    )
}

@Composable
actual fun InlineVideoNotePlayer(
    path: String,
    muted: Boolean,
    onProgress: (Float) -> Unit,
    modifier: Modifier,
) {
    val context = LocalContext.current
    val activity = context as ComponentActivity
    val player = remember(path) {
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(Uri.fromFile(File(path))))
            repeatMode = Player.REPEAT_MODE_ONE
            volume = if (muted) 0f else 1f
            playWhenReady = true
            prepare()
        }
    }
    LaunchedEffect(muted) { player.volume = if (muted) 0f else 1f }
    LaunchedEffect(player) {
        while (true) {
            val duration = player.duration
            onProgress(
                if (duration > 0) (player.currentPosition.toFloat() / duration.toFloat()).coerceIn(0f, 1f)
                else 0f
            )
            delay(100)
        }
    }
    DisposableEffect(player, activity) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> player.play()
                Lifecycle.Event.ON_STOP -> player.pause()
                else -> Unit
            }
        }
        activity.lifecycle.addObserver(observer)
        if (!activity.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) player.pause()
        onDispose {
            activity.lifecycle.removeObserver(observer)
            player.release()
        }
    }
    AndroidView(
        factory = { ctx ->
            PlayerView(ctx).apply {
                useController = false
                resizeMode = AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                this.player = player
            }
        },
        update = { it.player = player },
        modifier = modifier,
    )
}
