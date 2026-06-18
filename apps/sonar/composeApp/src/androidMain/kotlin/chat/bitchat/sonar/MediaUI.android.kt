package chat.bitchat.sonar

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.drawable.AnimatedImageDrawable
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.widget.ImageView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.FileProvider
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID
import kotlin.coroutines.resume

private const val MEDIA_SHARE_CACHE_MAX_AGE_MS = 24L * 60L * 60L * 1000L

@Composable
actual fun rememberPhotoPicker(
    onPicked: (bytes: ByteArray, filename: String, mime: String) -> Unit
): () -> Unit {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch(Dispatchers.IO) {
            val raw = ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return@launch
            val sourceMime = ctx.contentResolver.getType(uri).orEmpty()
            val sourceName = ctx.displayNameForUri(uri) ?: "photo"
            if (sourceMime.equals("image/gif", ignoreCase = true) || raw.isGifBytes()) {
                val filename = sourceName.takeIf { it.endsWith(".gif", ignoreCase = true) } ?: "animation.gif"
                withContext(Dispatchers.Main) { onPicked(raw, filename, "image/gif") }
                return@launch
            }
            // Re-encode still images to JPEG: guarantees a format the core image
            // metadata path handles (HEIC isn't) and keeps the upload small.
            val bmp = BitmapFactory.decodeByteArray(raw, 0, raw.size) ?: return@launch
            val out = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 85, out)
            val jpeg = out.toByteArray()
            withContext(Dispatchers.Main) { onPicked(jpeg, "photo.jpg", "image/jpeg") }
        }
    }
    return {
        launcher.launch(
            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
        )
    }
}

private fun android.content.Context.displayNameForUri(uri: android.net.Uri): String? =
    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) {
            cursor.getString(0)?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
        } else {
            null
        }
    }

private fun ByteArray.isGifBytes(): Boolean =
    size >= 6 &&
        this[0] == 0x47.toByte() &&
        this[1] == 0x49.toByte() &&
        this[2] == 0x46.toByte() &&
        this[3] == 0x38.toByte() &&
        (this[4] == 0x37.toByte() || this[4] == 0x39.toByte()) &&
        this[5] == 0x61.toByte()

@Composable
actual fun MediaImage(
    bytes: ByteArray,
    isGif: Boolean,
    modifier: Modifier
) {
    val animated = remember(bytes, isGif) {
        if (isGif && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            runCatching {
                ImageDecoder.decodeDrawable(ImageDecoder.createSource(ByteBuffer.wrap(bytes)))
            }.getOrNull()
        } else {
            null
        }
    }
    if (animated != null) {
        AndroidView(
            modifier = modifier,
            factory = { context ->
                ImageView(context).apply {
                    adjustViewBounds = true
                    scaleType = ImageView.ScaleType.FIT_CENTER
                }
            },
            update = { view ->
                view.setImageDrawable(animated)
                (animated as? AnimatedImageDrawable)?.start()
            }
        )
    } else {
        val image = remember(bytes) { decodeImageBitmap(bytes) }
        if (image != null) {
            Image(image, contentDescription = null, contentScale = ContentScale.Fit, modifier = modifier)
        }
    }
}

actual fun decodeImageBitmap(bytes: ByteArray): ImageBitmap? =
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()

@Composable
actual fun rememberMediaActions(): MediaActions {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val legacySaver = remember(ctx) { LegacyDocumentSaver(ctx) }
    val legacySaveLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        scope.launch {
            legacySaver.complete(result.data?.data)
        }
    }
    return remember(ctx, legacySaver, legacySaveLauncher) {
        MediaActions(
            share = { bytes, filename, mime -> shareMedia(ctx, bytes, filename, mime) },
            save = { bytes, filename, mime ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    saveMedia(ctx, bytes, filename, mime)
                } else {
                    legacySaver.save(bytes, filename, mime, legacySaveLauncher)
                }
            },
            open = { bytes, filename, mime -> openMedia(ctx, bytes, filename, mime) },
        )
    }
}

private suspend fun shareMedia(ctx: Context, bytes: ByteArray, filename: String, mime: String): Boolean {
    val uri = withContext(Dispatchers.IO) {
        runCatching { cacheUri(ctx, bytes, filename) }.getOrNull()
    } ?: return false
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = mime
        putExtra(Intent.EXTRA_STREAM, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    return withContext(Dispatchers.Main) {
        runCatching {
            ctx.startActivity(Intent.createChooser(intent, "Share media"))
            true
        }.getOrDefault(false)
    }
}

private suspend fun openMedia(ctx: Context, bytes: ByteArray, filename: String, mime: String): Boolean {
    val uri = withContext(Dispatchers.IO) {
        runCatching { cacheUri(ctx, bytes, filename) }.getOrNull()
    } ?: return false
    val intent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, mime)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    return withContext(Dispatchers.Main) {
        runCatching {
            ctx.startActivity(intent)
            true
        }.getOrDefault(false)
    }
}

private suspend fun saveMedia(ctx: Context, bytes: ByteArray, filename: String, mime: String): Boolean =
    withContext(Dispatchers.IO) {
        runCatching {
            saveMediaStore(ctx, bytes, filename, mime)
        }.getOrDefault(false)
    }

private fun saveMediaStore(ctx: Context, bytes: ByteArray, filename: String, mime: String): Boolean {
    val resolver = ctx.contentResolver
    val safeName = safeFilename(filename)
    val collection: Uri
    val relativePath: String
    when {
        mime.startsWith("image/") -> {
            collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            relativePath = Environment.DIRECTORY_PICTURES + "/Sonar"
        }
        mime.startsWith("video/") -> {
            collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            relativePath = Environment.DIRECTORY_MOVIES + "/Sonar"
        }
        else -> {
            collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            relativePath = Environment.DIRECTORY_DOWNLOADS + "/Sonar"
        }
    }
    val values = ContentValues().apply {
        put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
        put(MediaStore.MediaColumns.MIME_TYPE, mime)
        put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
        put(MediaStore.MediaColumns.IS_PENDING, 1)
    }
    val uri = resolver.insert(collection, values) ?: return false
    return try {
        val output = resolver.openOutputStream(uri) ?: run {
            resolver.delete(uri, null, null)
            return false
        }
        output.use { it.write(bytes) }
        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        true
    } catch (t: Throwable) {
        resolver.delete(uri, null, null)
        false
    }
}

private fun cacheUri(ctx: Context, bytes: ByteArray, filename: String): Uri? {
    val dir = File(ctx.cacheDir, "media-share").apply { mkdirs() }
    val now = System.currentTimeMillis()
    dir.listFiles()?.forEach { file ->
        if (now - file.lastModified() > MEDIA_SHARE_CACHE_MAX_AGE_MS) {
            file.delete()
        }
    }
    val file = File(dir, "${UUID.randomUUID()}-${safeFilename(filename)}")
    file.writeBytes(bytes)
    return FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", file)
}

private class LegacyDocumentSaver(private val ctx: Context) {
    private var pending: PendingDocumentSave? = null

    suspend fun save(
        bytes: ByteArray,
        filename: String,
        mime: String,
        launcher: ActivityResultLauncher<Intent>,
    ): Boolean = withContext(Dispatchers.Main) {
        kotlinx.coroutines.suspendCancellableCoroutine { continuation ->
            pending?.continuation?.resume(false)
            val request = PendingDocumentSave(bytes, continuation)
            pending = request
            continuation.invokeOnCancellation {
                if (pending === request) pending = null
            }
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mime.ifBlank { "*/*" }
                putExtra(Intent.EXTRA_TITLE, safeFilename(filename))
            }
            runCatching { launcher.launch(intent) }.onFailure {
                if (pending === request) pending = null
                if (continuation.isActive) continuation.resume(false)
            }
        }
    }

    suspend fun complete(uri: Uri?) {
        val request = pending ?: return
        pending = null
        if (uri == null) {
            if (request.continuation.isActive) request.continuation.resume(false)
            return
        }
        val ok = withContext(Dispatchers.IO) {
            runCatching {
                val output = ctx.contentResolver.openOutputStream(uri) ?: return@runCatching false
                output.use { it.write(request.bytes) }
                true
            }.getOrDefault(false)
        }
        if (request.continuation.isActive) request.continuation.resume(ok)
    }
}

private class PendingDocumentSave(
    val bytes: ByteArray,
    val continuation: CancellableContinuation<Boolean>,
)

private fun safeFilename(filename: String): String =
    filename.substringAfterLast('/').substringAfterLast('\\').ifBlank { "attachment" }
