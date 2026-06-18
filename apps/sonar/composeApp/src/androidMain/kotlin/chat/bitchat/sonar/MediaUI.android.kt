package chat.bitchat.sonar

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID

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
            // Re-encode to JPEG: guarantees a format the core image encoder
            // handles (HEIC isn't) and keeps the upload small.
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

actual fun decodeImageBitmap(bytes: ByteArray): ImageBitmap? =
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()

@Composable
actual fun rememberMediaActions(): MediaActions {
    val ctx = LocalContext.current
    return remember(ctx) {
        MediaActions(
            share = { bytes, filename, mime -> shareMedia(ctx, bytes, filename, mime) },
            save = { bytes, filename, mime -> saveMedia(ctx, bytes, filename, mime) },
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
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                saveMediaStore(ctx, bytes, filename, mime)
            } else {
                val dir = ctx.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                    ?: ctx.filesDir.resolve("downloads")
                dir.mkdirs()
                dir.resolve(safeFilename(filename)).writeBytes(bytes)
                true
            }
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

private fun safeFilename(filename: String): String =
    filename.substringAfterLast('/').substringAfterLast('\\').ifBlank { "attachment" }
