package chat.bitchat.sonar.ui

import android.Manifest
import android.content.pm.PackageManager
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import chat.bitchat.sonar.AppContextHolder
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * CameraX preview + zxing decode. The decoder runs on a single background
 * executor with `STRATEGY_KEEP_ONLY_LATEST`, so a slow frame is dropped rather
 * than queued — the analyzer must never become the reason the UI stutters
 * (Performance rule: no work like this on the render path).
 */
@Composable
actual fun SonarQrScanner(
    onCode: (String) -> Unit,
    onUnavailable: (String) -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val currentOnCode by rememberUpdatedState(onCode)
    val currentOnUnavailable by rememberUpdatedState(onUnavailable)

    var granted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        )
    }
    var asked by remember { mutableStateOf(false) }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { ok ->
        granted = ok
        if (!ok) currentOnUnavailable("Camera access is off — turn it on in Settings, or type the code instead.")
    }

    LaunchedEffect(Unit) {
        if (!granted && !asked) {
            asked = true
            permissionLauncher.launch(Manifest.permission.CAMERA)
        }
    }

    if (!granted) return

    val executor: ExecutorService = remember { Executors.newSingleThreadExecutor() }
    // One payload only: the sheet tears the scanner down on the first hit, but
    // frames already in flight would otherwise fire onCode again.
    val delivered = remember { AtomicBoolean(false) }
    // Held so teardown can unbind without blocking: `ProcessCameraProvider
    // .getInstance(ctx).get()` waits on a ListenableFuture, and onDispose runs
    // on the main thread.
    val boundProvider = remember { AtomicReference<ProcessCameraProvider?>(null) }
    DisposableEffect(Unit) { onDispose { executor.shutdown() } }

    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { ctx ->
            val previewView = PreviewView(ctx).apply {
                scaleType = PreviewView.ScaleType.FILL_CENTER
                implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            }
            val providerFuture = ProcessCameraProvider.getInstance(ctx)
            providerFuture.addListener({
                val provider = runCatching { providerFuture.get() }.getOrNull()
                if (provider == null) {
                    currentOnUnavailable("Couldn't start the camera — type the code instead.")
                    return@addListener
                }
                val preview = Preview.Builder().build().also {
                    it.surfaceProvider = previewView.surfaceProvider
                }
                val analysis = ImageAnalysis.Builder()
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER)
                            )
                            .build()
                    )
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                    .also { it.setAnalyzer(executor, QrAnalyzer { code ->
                        if (delivered.compareAndSet(false, true)) currentOnCode(code)
                    }) }
                boundProvider.set(provider)
                runCatching {
                    provider.unbindAll()
                    provider.bindToLifecycle(
                        lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis
                    )
                }.onFailure {
                    currentOnUnavailable("Couldn't start the camera — type the code instead.")
                }
            }, ContextCompat.getMainExecutor(ctx))
            previewView
        },
    )

    DisposableEffect(lifecycleOwner) {
        onDispose {
            // Never block the main thread here — use the provider we already
            // resolved rather than awaiting the future again.
            runCatching { boundProvider.getAndSet(null)?.unbindAll() }
        }
    }
}

/** Decodes the Y plane of each frame; zxing only needs luminance. */
private class QrAnalyzer(private val onCode: (String) -> Unit) : ImageAnalysis.Analyzer {
    private val reader = MultiFormatReader().apply {
        setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(com.google.zxing.BarcodeFormat.QR_CODE)))
    }

    override fun analyze(image: ImageProxy) {
        try {
            val plane = image.planes.firstOrNull() ?: return
            val buffer = plane.buffer
            val bytes = ByteArray(buffer.remaining())
            buffer.get(bytes)
            val source = PlanarYUVLuminanceSource(
                bytes, plane.rowStride, image.height,
                0, 0, image.width, image.height, false,
            )
            val result = runCatching {
                reader.decodeWithState(BinaryBitmap(HybridBinarizer(source)))
            }.getOrNull()
            reader.reset()
            val text = result?.text?.trim()
            if (!text.isNullOrEmpty()) onCode(text)
        } catch (t: Throwable) {
            // A malformed frame must never kill the analyzer thread.
        } finally {
            image.close()
        }
    }
}

actual fun sonarQrScanSupported(): Boolean =
    AppContextHolder.ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
