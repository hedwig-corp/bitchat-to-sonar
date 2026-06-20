package chat.bitchat.sonar

import androidx.compose.foundation.Image
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.awt.SwingPanel
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.layout.ContentScale
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
import javax.swing.ImageIcon
import javax.swing.JLabel
import javax.swing.SwingConstants

/**
 * Desktop (JVM) `actual` photo picker: a native AWT [FileDialog] filtered to
 * images. Raw bytes are passed through — JPEG re-encoding is deferred to send
 * confirmation via [reencodeToJpeg].
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
            val raw = withContext(Dispatchers.IO) { runCatching { picked.readBytes() }.getOrNull() }
                ?: return@launch
            // Pass raw bytes — JPEG re-encoding happens lazily on send confirmation.
            val name = picked.name.ifBlank { "photo" }
            val mime = if (picked.extension.equals("gif", ignoreCase = true) || raw.isGifBytes()) {
                "image/gif"
            } else {
                "image/${picked.extension.lowercase().ifBlank { "jpeg" }}"
            }
            onPicked(raw, name, mime)
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
    if (isGif) {
        val icon = remember(bytes) { ImageIcon(bytes) }
        SwingPanel(
            modifier = modifier,
            background = Color.Transparent,
            factory = {
                JLabel(icon).apply {
                    horizontalAlignment = SwingConstants.CENTER
                    verticalAlignment = SwingConstants.CENTER
                    isOpaque = false
                }
            },
            update = { label ->
                if (label.icon !== icon) label.icon = icon
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

actual fun writeTempMediaFile(data: ByteArray, suffix: String): String {
    val file = File.createTempFile("sonar-preview-", suffix)
    file.deleteOnExit()
    file.writeBytes(data)
    return file.absolutePath
}

actual fun readTempMediaFile(path: String): ByteArray? =
    runCatching { File(path).readBytes() }.getOrNull()

actual fun deleteTempMediaFile(path: String) {
    runCatching { File(path).delete() }
}

actual fun reencodeToJpeg(data: ByteArray): ByteArray {
    val src = ImageIO.read(ByteArrayInputStream(data)) ?: return data
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
