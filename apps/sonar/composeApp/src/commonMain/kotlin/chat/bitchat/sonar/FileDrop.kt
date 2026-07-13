package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

internal data class DroppedFile(
    val bytes: ByteArray,
    val filename: String,
    val mime: String,
)

internal data class DroppedFiles(
    val files: List<DroppedFile>,
    val rejectedCount: Int,
)

internal const val MAX_INTERNET_ATTACHMENT_BYTES = 25L * 1024L * 1024L
internal const val MAX_MESH_ATTACHMENT_BYTES = 1L * 1024L * 1024L
internal const val MAX_DROPPED_FILES = MAX_ALBUM_PHOTOS

private const val GENERIC_ATTACHMENT_MIME = "application/octet-stream"
private const val PDF_ATTACHMENT_MIME = "application/pdf"

/**
 * MIME used for local display and native open/share actions. Older messages and
 * desktop file drops can carry the generic binary MIME even when the original
 * file is a PDF. Refine that metadata only when both the filename and the
 * already-decrypted plaintext signature agree; sender-controlled extensions
 * alone are never trusted.
 */
internal fun effectiveAttachmentMime(
    declaredMime: String,
    filename: String,
    plaintext: ByteArray,
): String {
    val normalized = declaredMime.substringBefore(';').trim().lowercase()
    if (normalized.isNotEmpty() && normalized != GENERIC_ATTACHMENT_MIME) return normalized
    return if (isVerifiedPdfAttachment(declaredMime, filename, plaintext)) {
        PDF_ATTACHMENT_MIME
    } else {
        normalized.ifEmpty { GENERIC_ATTACHMENT_MIME }
    }
}

/** True only when PDF metadata is backed by a PDF plaintext signature. */
internal fun isVerifiedPdfAttachment(
    declaredMime: String,
    filename: String,
    plaintext: ByteArray,
): Boolean {
    val normalized = declaredMime.substringBefore(';').trim().lowercase()
    val hasPdfMetadata = normalized == PDF_ATTACHMENT_MIME ||
        filename.substringAfterLast('.', missingDelimiterValue = "").equals("pdf", ignoreCase = true)
    return hasPdfMetadata && plaintext.hasPdfSignature()
}

private fun ByteArray.hasPdfSignature(): Boolean =
    size >= 4 &&
        this[0] == 0x25.toByte() &&
        this[1] == 0x50.toByte() &&
        this[2] == 0x44.toByte() &&
        this[3] == 0x46.toByte()

/** Desktop file-drop target. Mobile actuals are a no-op. */
@Composable
internal expect fun Modifier.fileDropTarget(
    enabled: Boolean,
    maxTotalBytes: Long,
    onDropped: (DroppedFiles) -> Unit,
): Modifier
