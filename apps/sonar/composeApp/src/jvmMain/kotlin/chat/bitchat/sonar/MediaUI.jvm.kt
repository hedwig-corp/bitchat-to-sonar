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
 * Desktop (JVM) `actual` photo/video picker: a native AWT [FileDialog] filtered
 * to images + video containers, multi-select up to [MAX_ALBUM_PHOTOS]. Raw
 * bytes are passed through — JPEG re-encoding is deferred to send confirmation
 * via [reencodeToJpeg]; videos are never re-encoded and are rejected at pick
 * time when they exceed the receiver download cap.
 */
@Composable
actual fun rememberPhotoPicker(
    onPicked: (items: List<PickedPhoto>, rejectedTooLarge: Int) -> Unit
): () -> Unit {
    val scope = rememberCoroutineScope()
    return {
        scope.launch {
            // FileDialog is a modal AWT dialog — open it on the EDT (Compose
            // Desktop runs composition, hence this scope, on the AWT event
            // thread). Decoding/re-encoding then hops to a background thread.
            val picked = pickImageFiles()
            if (picked.isEmpty()) return@launch
            var rejectedTooLarge = 0
            // Same aggregate video budget as the Android picker — every album
            // item is memory-resident at once through the send.
            var remainingVideoBudget = MAX_ALBUM_TOTAL_VIDEO_BYTES
            val items = withContext(Dispatchers.IO) {
                picked.mapNotNull { file ->
                    val videoMime = videoMimeForExtension(file.extension)
                    if (videoMime != null && file.length() > minOf(MAX_INTERNET_ATTACHMENT_BYTES, remainingVideoBudget)) {
                        rejectedTooLarge += 1
                        return@mapNotNull null
                    }
                    val raw = runCatching { file.readBytes() }.getOrNull() ?: return@mapNotNull null
                    if (videoMime != null) {
                        remainingVideoBudget -= raw.size.toLong()
                        return@mapNotNull PickedPhoto(raw, file.name.ifBlank { "video.mp4" }, videoMime)
                    }
                    // Raw bytes — JPEG re-encoding happens lazily on send confirmation.
                    val name = file.name.ifBlank { "photo" }
                    val mime = if (file.extension.equals("gif", ignoreCase = true) || raw.isGifBytes()) {
                        "image/gif"
                    } else {
                        "image/${file.extension.lowercase().ifBlank { "jpeg" }}"
                    }
                    PickedPhoto(raw, name, mime)
                }
            }
            if (items.isNotEmpty() || rejectedTooLarge > 0) onPicked(items, rejectedTooLarge)
        }
    }
}

@Composable
internal actual fun rememberFilePicker(
    maxTotalBytes: Long,
    onPicked: (DroppedFiles) -> Unit,
): () -> Unit {
    val scope = rememberCoroutineScope()
    return {
        scope.launch {
            val picked = pickFiles("Choose files")
            if (picked.isEmpty()) return@launch
            val result = withContext(Dispatchers.IO) {
                readDroppedFiles(
                    picked.map { it.toURI().toString() },
                    maxTotalBytes,
                )
            }
            onPicked(result)
        }
    }
}

private fun pickImageFiles(): List<File> {
    // Images: limit to formats the stock JDK ImageIO can actually decode (no
    // WebP reader), so a picked file always re-encodes rather than silently
    // failing. Videos: containers on the encrypted-attachment MIME whitelist.
    val dialog = FileDialog(null as Frame?, "Choose photos or videos", FileDialog.LOAD).apply {
        isMultipleMode = true
        setFilenameFilter { _, name ->
            name.lowercase().let {
                it.endsWith(".jpg") || it.endsWith(".jpeg") || it.endsWith(".png") ||
                    it.endsWith(".gif") || it.endsWith(".bmp") ||
                    it.endsWith(".mp4") || it.endsWith(".m4v") || it.endsWith(".mov") ||
                    it.endsWith(".webm") || it.endsWith(".mkv") || it.endsWith(".avi")
            }
        }
        isVisible = true
    }
    return try {
        dialog.files.orEmpty().toList().take(MAX_ALBUM_PHOTOS)
    } finally {
        dialog.dispose() // release the native AWT peer
    }
}

private fun pickFiles(title: String): List<File> {
    val dialog = FileDialog(null as Frame?, title, FileDialog.LOAD).apply {
        isMultipleMode = true
        isVisible = true
    }
    return try {
        dialog.files.orEmpty().toList()
    } finally {
        dialog.dispose()
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

actual fun decodeImageBounds(bytes: ByteArray): Pair<Int, Int>? = runCatching {
    // ImageIO's reader exposes the header dimensions without decoding pixels.
    javax.imageio.ImageIO.createImageInputStream(java.io.ByteArrayInputStream(bytes))
        ?.use { stream ->
            val readers = javax.imageio.ImageIO.getImageReaders(stream)
            if (!readers.hasNext()) return@use null
            val reader = readers.next()
            try {
                reader.input = stream
                val w = reader.getWidth(0)
                val h = reader.getHeight(0)
                if (w > 0 && h > 0) w to h else null
            } finally {
                reader.dispose()
            }
        }
}.getOrNull()

internal actual fun decodeThumbnail(bytes: ByteArray, maxEdgePx: Int): ThumbnailDecode? =
    runCatching {
        val source = SkiaImage.makeFromEncoded(bytes)
        val longestEdge = maxOf(source.width, source.height)
        if (longestEdge <= maxEdgePx) {
            // Already within bounds: paint it, and skip the thumbnail — a
            // re-encode would cost quality and save no decode later.
            return@runCatching ThumbnailDecode(source.toComposeImageBitmap(), encoded = null)
        }
        // Skia has no sampled decode like BitmapFactory's inSampleSize, so the
        // full image does exist briefly here. Desktop has no per-app heap cap
        // and far more RAM than the phones this bound protects, so a scale-
        // after-decode is an acceptable trade for a much simpler path.
        val ratio = maxEdgePx.toFloat() / longestEdge
        val surface = org.jetbrains.skia.Surface.makeRasterN32Premul(
            (source.width * ratio).toInt().coerceAtLeast(1),
            (source.height * ratio).toInt().coerceAtLeast(1),
        )
        surface.canvas.drawImageRect(
            source,
            org.jetbrains.skia.Rect.makeWH(source.width.toFloat(), source.height.toFloat()),
            org.jetbrains.skia.Rect.makeWH(surface.width.toFloat(), surface.height.toFloat()),
        )
        val scaled = surface.makeImageSnapshot()
        val encoded = scaled
            .encodeToData(org.jetbrains.skia.EncodedImageFormat.WEBP, quality = 80)
            ?.bytes
        ThumbnailDecode(scaled.toComposeImageBitmap(), encoded)
    }.getOrNull()

// The stock JVM has no video decoder — the preview falls back to a generic
// video tile (filename + play glyph) instead of a poster frame.
actual fun decodeVideoPosterFrame(path: String): ImageBitmap? = null

@Composable
actual fun rememberMediaActions(): MediaActions =
    remember {
        MediaActions(
            canShare = false,
            share = { _, _, _ -> false },
            save = { path, filename, _ -> saveMediaFile(path, filename) },
            open = { path, filename, _ -> openLocalMedia(path, filename) },
        )
    }

private suspend fun saveMediaFile(path: String, filename: String): Boolean {
    val picked = pickSaveFile(safeFilename(filename)) ?: return false
    return withContext(Dispatchers.IO) {
        runCatching {
            File(path).copyTo(picked, overwrite = true)
            true
        }.getOrDefault(false)
    }
}

private suspend fun openLocalMedia(path: String, filename: String): Boolean =
    withContext(Dispatchers.IO) {
        runCatching {
            if (!Desktop.isDesktopSupported()) return@runCatching false
            val file = File.createTempFile("sonar-media-", "-" + safeFilename(filename))
            File(path).copyTo(file, overwrite = true)
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

actual fun reencodeToJpeg(data: ByteArray): ByteArray? {
    val src = ImageIO.read(ByteArrayInputStream(data)) ?: return null
    val rgb = BufferedImage(src.width, src.height, BufferedImage.TYPE_INT_RGB)
    val g = rgb.createGraphics()
    g.drawImage(src, 0, 0, java.awt.Color.WHITE, null)
    g.dispose()
    val writers = ImageIO.getImageWritersByFormatName("jpg")
    if (!writers.hasNext()) return null
    val writer = writers.next()
    val out = ByteArrayOutputStream()
    try {
        ImageIO.createImageOutputStream(out).use { ios ->
            writer.output = ios
            val param = writer.defaultWriteParam.apply {
                compressionMode = ImageWriteParam.MODE_EXPLICIT
                compressionQuality = 0.85f
            }
            writer.write(null, IIOImage(rgb, null, null), param)
        }
        return out.toByteArray().takeIf { it.isNotEmpty() }
    } finally {
        writer.dispose()
    }
}
