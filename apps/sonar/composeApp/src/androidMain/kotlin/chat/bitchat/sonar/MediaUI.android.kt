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
import kotlinx.coroutines.CancellationException
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
    onPicked: (items: List<PickedPhoto>, rejectedTooLarge: Int) -> Unit
): () -> Unit {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(MAX_ALBUM_PHOTOS)
    ) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch(Dispatchers.IO) {
            // Load every pick in selection order; 2+ stage as one album.
            var rejectedTooLarge = 0
            val items = uris.mapNotNull { uri ->
                val sourceMime = ctx.contentResolver.getType(uri).orEmpty()
                if (isVideoMime(sourceMime)) {
                    // Videos can far exceed the receiver download cap — check
                    // the provider-reported size BEFORE buffering anything.
                    val read = ctx.readVideoBounded(uri, MAX_INTERNET_ATTACHMENT_BYTES)
                    if (read.tooLarge) {
                        rejectedTooLarge += 1
                        return@mapNotNull null
                    }
                    val raw = read.bytes ?: return@mapNotNull null
                    val sourceName = ctx.displayNameForUri(uri) ?: "video.mp4"
                    return@mapNotNull PickedPhoto(raw, sourceName, sourceMime)
                }
                val raw = ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: return@mapNotNull null
                val sourceName = ctx.displayNameForUri(uri) ?: "photo"
                if (sourceMime.equals("image/gif", ignoreCase = true) || raw.isGifBytes()) {
                    val filename = sourceName.takeIf { it.endsWith(".gif", ignoreCase = true) }
                        ?: "animation.gif"
                    PickedPhoto(raw, filename, "image/gif")
                } else {
                    // Raw bytes — JPEG re-encoding happens lazily on send confirmation.
                    PickedPhoto(raw, sourceName.ifBlank { "photo" }, sourceMime.ifBlank { "image/jpeg" })
                }
            }
            if (items.isNotEmpty() || rejectedTooLarge > 0) {
                withContext(Dispatchers.Main) { onPicked(items, rejectedTooLarge) }
            }
        }
    }
    return {
        launcher.launch(
            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)
        )
    }
}

private class BoundedVideoRead(val bytes: ByteArray?, val tooLarge: Boolean)

/** Read a picked video fully, refusing to buffer anything over [maxBytes].
 *  Provider-reported size rejects cheaply; an unreported size is enforced
 *  while streaming so an over-cap video never materializes in memory. */
private fun Context.readVideoBounded(uri: Uri, maxBytes: Long): BoundedVideoRead {
    val metadata = pickedFileMetadata(uri)
    if (metadata.size != null && metadata.size > maxBytes) {
        return BoundedVideoRead(null, tooLarge = true)
    }
    var tooLarge = false
    val bytes = runCatching {
        contentResolver.openInputStream(uri)?.use { input ->
            val output = ByteArrayOutputStream(minOf(metadata.size ?: DEFAULT_BUFFER_SIZE.toLong(), maxBytes).toInt())
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            var total = 0L
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                if (total > maxBytes) {
                    tooLarge = true
                    return@use null
                }
                output.write(buffer, 0, read)
            }
            output.toByteArray()
        }
    }.getOrNull()
    return BoundedVideoRead(bytes, tooLarge)
}

@Composable
internal actual fun rememberFilePicker(
    maxTotalBytes: Long,
    onPicked: (DroppedFiles) -> Unit,
): () -> Unit {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch(Dispatchers.IO) {
            val result = ctx.readPickedFiles(uris, maxTotalBytes)
            withContext(Dispatchers.Main) { onPicked(result) }
        }
    }
    return { launcher.launch(arrayOf("*/*")) }
}

private data class PickedFileMetadata(
    val displayName: String,
    val size: Long?,
)

private fun Context.readPickedFiles(uris: List<Uri>, maxTotalBytes: Long): DroppedFiles {
    if (maxTotalBytes <= 0L) return DroppedFiles(emptyList(), rejectedCount = uris.size)

    val files = mutableListOf<DroppedFile>()
    var rejectedCount = (uris.size - MAX_DROPPED_FILES).coerceAtLeast(0)
    var remainingBytes = maxTotalBytes
    for (uri in uris.take(MAX_DROPPED_FILES)) {
        // Every URI is backed by provider IPC. A grant can be revoked or a
        // provider can fail while querying metadata/MIME, so isolate failures
        // per item instead of cancelling the whole picker coroutine.
        val file = try {
            readPickedFile(uri, remainingBytes)
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            null
        }
        if (file == null) {
            rejectedCount += 1
        } else {
            files += file
            remainingBytes -= file.bytes.size.toLong()
        }
    }
    return DroppedFiles(files, rejectedCount)
}

private fun Context.readPickedFile(uri: Uri, maxBytes: Long): DroppedFile? {
    if (maxBytes <= 0L) return null
    val metadata = pickedFileMetadata(uri)
    if (metadata.size != null && metadata.size > maxBytes) return null
    val bytes = runCatching {
        contentResolver.openInputStream(uri)?.use { input ->
            val readLimit = maxBytes.coerceAtMost(Int.MAX_VALUE.toLong() - 1L).toInt()
            val output = ByteArrayOutputStream(minOf(metadata.size ?: 0L, maxBytes).toInt())
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            var total = 0
            while (true) {
                val remaining = readLimit - total
                if (remaining < 0) return@use null
                val read = input.read(buffer, 0, minOf(buffer.size, remaining + 1))
                if (read < 0) break
                total += read
                if (total > readLimit) return@use null
                output.write(buffer, 0, read)
            }
            output.toByteArray()
        }
    }.getOrNull() ?: return null
    if (bytes.size.toLong() > maxBytes) return null
    val filename = metadata.displayName.ifBlank { "attachment" }
    val declaredMime = contentResolver.getType(uri).orEmpty()
    return DroppedFile(
        bytes = bytes,
        filename = filename,
        mime = effectiveAttachmentMime(declaredMime, filename, bytes),
    )
}

private fun Context.pickedFileMetadata(uri: Uri): PickedFileMetadata {
    val projection = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
    return contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
        if (!cursor.moveToFirst()) return@use null
        val displayNameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
        val displayName = if (displayNameIndex >= 0) {
            cursor.getString(displayNameIndex).orEmpty()
                .substringAfterLast('/')
                .substringAfterLast('\\')
        } else {
            ""
        }
        val size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
            cursor.getLong(sizeIndex).takeIf { it >= 0L }
        } else {
            null
        }
        PickedFileMetadata(displayName.ifBlank { "attachment" }, size)
    } ?: PickedFileMetadata("attachment", null)
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

actual fun decodeVideoPosterFrame(path: String): ImageBitmap? =
    runCatching {
        val retriever = android.media.MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            retriever.frameAtTime?.asImageBitmap()
        } finally {
            retriever.release()
        }
    }.getOrNull()

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
            share = { path, filename, mime -> shareMedia(ctx, path, filename, mime) },
            save = { path, filename, mime ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    saveMedia(ctx, path, filename, mime)
                } else {
                    val bytes = withContext(Dispatchers.IO) { runCatching { File(path).readBytes() }.getOrNull() }
                    bytes != null && legacySaver.save(bytes, filename, mime, legacySaveLauncher)
                }
            },
            open = { path, filename, mime -> openMedia(ctx, path, filename, mime) },
        )
    }
}

private suspend fun shareMedia(ctx: Context, path: String, filename: String, mime: String): Boolean {
    val uri = withContext(Dispatchers.IO) {
        runCatching { cacheUri(ctx, File(path), filename) }.getOrNull()
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

private suspend fun openMedia(ctx: Context, path: String, filename: String, mime: String): Boolean {
    val uri = withContext(Dispatchers.IO) {
        runCatching { cacheUri(ctx, File(path), filename) }.getOrNull()
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

private suspend fun saveMedia(ctx: Context, path: String, filename: String, mime: String): Boolean =
    withContext(Dispatchers.IO) {
        runCatching {
            saveMediaStore(ctx, File(path), filename, mime)
        }.getOrDefault(false)
    }

private fun saveMediaStore(ctx: Context, source: File, filename: String, mime: String): Boolean {
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
        output.use { destination -> source.inputStream().use { it.copyTo(destination) } }
        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        true
    } catch (t: Throwable) {
        resolver.delete(uri, null, null)
        false
    }
}

private fun cacheUri(ctx: Context, source: File, filename: String): Uri? {
    val dir = File(ctx.cacheDir, "media-share").apply { mkdirs() }
    val now = System.currentTimeMillis()
    dir.listFiles()?.forEach { file ->
        if (now - file.lastModified() > MEDIA_SHARE_CACHE_MAX_AGE_MS) {
            file.delete()
        }
    }
    val file = File(dir, "${UUID.randomUUID()}-${safeFilename(filename)}")
    source.copyTo(file, overwrite = false)
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

actual fun writeTempMediaFile(data: ByteArray, suffix: String): String {
    val file = File.createTempFile("sonar-preview-", suffix)
    file.writeBytes(data)
    return file.absolutePath
}

actual fun readTempMediaFile(path: String): ByteArray? =
    runCatching { File(path).readBytes() }.getOrNull()

actual fun deleteTempMediaFile(path: String) {
    runCatching { File(path).delete() }
}

actual fun reencodeToJpeg(data: ByteArray): ByteArray? {
    val bmp = BitmapFactory.decodeByteArray(data, 0, data.size) ?: return null
    val out = ByteArrayOutputStream()
    if (!bmp.compress(Bitmap.CompressFormat.JPEG, 85, out)) return null
    return out.toByteArray().takeIf { it.isNotEmpty() }
}
