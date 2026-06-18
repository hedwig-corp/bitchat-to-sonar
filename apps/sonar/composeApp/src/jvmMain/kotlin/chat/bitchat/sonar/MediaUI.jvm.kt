package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.jetbrains.skia.Image as SkiaImage
import java.awt.Desktop
import java.awt.Frame
import java.awt.FileDialog
import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import javax.imageio.IIOImage
import javax.imageio.ImageIO
import javax.imageio.ImageWriteParam

/**
 * Desktop (JVM) `actual` photo picker: a native AWT [FileDialog] filtered to
 * images. The chosen file is re-encoded to JPEG (matching the Android actual) so
 * the Rust core's image encoder — which doesn't take HEIC/PNG-with-alpha — always
 * gets a format it handles.
 */
@Composable
actual fun rememberPhotoPicker(
    onPicked: (bytes: ByteArray, filename: String, mime: String) -> Unit
): () -> Unit {
    val scope = rememberCoroutineScope()
    return {
        scope.launch {
            // FileDialog is a modal AWT dialog — open it on the EDT (Compose
            // Desktop runs composition, hence this scope, on the AWT event
            // thread). Decoding/re-encoding then hops to a background thread.
            val picked = pickImageFile() ?: return@launch
            val jpeg = withContext(Dispatchers.IO) { runCatching { reencodeJpeg(picked.readBytes()) }.getOrNull() }
                ?: return@launch
            onPicked(jpeg, "photo.jpg", "image/jpeg")
        }
    }
}

private fun pickImageFile(): File? {
    // Limit to formats the stock JDK ImageIO can actually decode (no WebP reader),
    // so a picked file always re-encodes rather than silently failing.
    val dialog = FileDialog(null as Frame?, "Choose an image", FileDialog.LOAD).apply {
        setFilenameFilter { _, name ->
            name.lowercase().let {
                it.endsWith(".jpg") || it.endsWith(".jpeg") || it.endsWith(".png") ||
                    it.endsWith(".gif") || it.endsWith(".bmp")
            }
        }
        isVisible = true
    }
    return try {
        val dir = dialog.directory ?: return null
        val name = dialog.file ?: return null
        File(dir, name)
    } finally {
        dialog.dispose() // release the native AWT peer
    }
}

/** Decode → flatten any alpha onto white → JPEG at quality 0.85 (matches the
 *  Android actual's `Bitmap.compress(JPEG, 85, …)`). */
private fun reencodeJpeg(raw: ByteArray): ByteArray {
    val src = ImageIO.read(ByteArrayInputStream(raw)) ?: error("unsupported image")
    val rgb = BufferedImage(src.width, src.height, BufferedImage.TYPE_INT_RGB)
    val g = rgb.createGraphics()
    g.drawImage(src, 0, 0, java.awt.Color.WHITE, null)
    g.dispose()
    val writer = ImageIO.getImageWritersByFormatName("jpg").next()
    val out = ByteArrayOutputStream()
    ImageIO.createImageOutputStream(out).use { ios ->
        writer.output = ios
        val param = writer.defaultWriteParam.apply {
            compressionMode = ImageWriteParam.MODE_EXPLICIT
            compressionQuality = 0.85f
        }
        writer.write(null, IIOImage(rgb, null, null), param)
    }
    writer.dispose()
    return out.toByteArray()
}

actual fun decodeImageBitmap(bytes: ByteArray): ImageBitmap? =
    runCatching { SkiaImage.makeFromEncoded(bytes).toComposeImageBitmap() }.getOrNull()

@Composable
actual fun rememberMediaActions(): MediaActions =
    remember {
        MediaActions(
            canShare = false,
            share = { _, _, _ -> false },
            save = { bytes, filename, _ -> saveMediaFile(bytes, filename) },
            open = { bytes, filename, _ -> openTempMedia(bytes, filename) },
        )
    }

private suspend fun saveMediaFile(bytes: ByteArray, filename: String): Boolean {
    val picked = pickSaveFile(safeFilename(filename)) ?: return false
    return withContext(Dispatchers.IO) {
        runCatching {
            picked.writeBytes(bytes)
            true
        }.getOrDefault(false)
    }
}

private suspend fun openTempMedia(bytes: ByteArray, filename: String): Boolean =
    withContext(Dispatchers.IO) {
        runCatching {
            if (!Desktop.isDesktopSupported()) return@runCatching false
            val file = File.createTempFile("sonar-media-", "-" + safeFilename(filename))
            file.writeBytes(bytes)
            file.deleteOnExit()
            Desktop.getDesktop().open(file)
            true
        }.getOrDefault(false)
    }

private fun pickSaveFile(filename: String): File? {
    val dialog = FileDialog(null as Frame?, "Save media", FileDialog.SAVE).apply {
        file = filename
        isVisible = true
    }
    return try {
        val dir = dialog.directory ?: return null
        val name = dialog.file ?: return null
        File(dir, name)
    } finally {
        dialog.dispose()
    }
}

private fun safeFilename(filename: String): String =
    filename.substringAfterLast('/').substringAfterLast('\\').ifBlank { "attachment" }
