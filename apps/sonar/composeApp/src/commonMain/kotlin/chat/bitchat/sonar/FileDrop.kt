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

/**
 * One "share into Sonar" gesture from the system share sheet: optional
 * text/link plus already-read file bytes.
 *
 * The bytes are eager rather than lazy because Android scopes the
 * `content://` read grant to the delivering intent — by the time the user
 * picks a recipient the permission can already be gone.
 */
internal data class SharedContent(
    val text: String?,
    val files: DroppedFiles,
    /**
     * Fingerprint of the delivering intent, recorded durably only once the user
     * resolves this share (sends or cancels).
     *
     * Deliberately NOT recorded at hand-off: a process killed while the picker
     * is still open would then have the restored intent suppressed while
     * `pendingShare` — memory-only — died with the process, silently losing a
     * share the user never resolved. Marking at resolution means an unresolved
     * share is correctly re-offered.
     */
    val consumedMarker: String? = null,
) {
    val isEmpty: Boolean
        get() = text.isNullOrBlank() && files.files.isEmpty()

    /** One-line description for the picker's preview strip. */
    val summary: String
        get() = when {
            !text.isNullOrBlank() -> text
            files.files.size == 1 -> files.files[0].filename
            else -> "${files.files.size} files"
        }
}

/**
 * Blob key holding the fingerprint of the last share the user actually
 * resolved. Read on Android when a task is restored, to tell a redelivered root
 * ACTION_SEND intent from a genuinely new share.
 */
internal const val CONSUMED_SHARE_BLOB_KEY = "share.lastConsumedSignature"

/**
 * Blob key holding the fingerprint of the share whose TEXT has already been
 * sent. Distinct from [CONSUMED_SHARE_BLOB_KEY]: a share can have its text
 * delivered while its files are still pending a retry, and a restore in that
 * window must re-offer the files WITHOUT re-offering the text.
 */
internal const val CONSUMED_SHARE_TEXT_BLOB_KEY = "share.lastConsumedTextSignature"

/** A `sinvite1` token followed by its hex payload, anywhere in the input. */
internal val INVITE_TOKEN_IN_TEXT = Regex("sinvite1[0-9a-fA-F]{2,}")

internal const val MAX_INTERNET_ATTACHMENT_BYTES = 25L * 1024L * 1024L
internal const val MAX_MESH_ATTACHMENT_BYTES = 1L * 1024L * 1024L
internal const val MAX_DROPPED_FILES = MAX_ALBUM_PHOTOS

private const val GENERIC_ATTACHMENT_MIME = "application/octet-stream"
private const val PDF_ATTACHMENT_MIME = "application/pdf"
private const val MAX_ENCRYPTED_ATTACHMENT_FILENAME_BYTES = 210

/**
 * MIME values accepted by MDK's encrypted-media validation. Arbitrary files
 * use MDK's documented binary escape hatch; the filename/extension remains
 * available for display and save actions.
 */
private val ENCRYPTED_ATTACHMENT_MIMES = setOf(
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/bmp",
    "image/x-icon",
    "image/tiff",
    "image/x-farbfeld",
    "image/avif",
    "image/qoi",
    "video/mp4",
    "video/quicktime",
    "video/x-matroska",
    "video/webm",
    "video/x-msvideo",
    "video/ogg",
    "audio/ogg",
    "audio/flac",
    "audio/x-flac",
    "audio/aac",
    "audio/mp4",
    "audio/webm",
    "audio/mpeg",
    "audio/wav",
    "audio/x-matroska",
    PDF_ATTACHMENT_MIME,
    "text/plain",
    GENERIC_ATTACHMENT_MIME,
)

internal fun encryptedAttachmentMime(mime: String): String {
    val normalized = mime.substringBefore(';').trim().lowercase()
    return normalized.takeIf { it in ENCRYPTED_ATTACHMENT_MIMES }
        ?: GENERIC_ATTACHMENT_MIME
}

/** Match MDK filename validation without losing a useful short extension. */
internal fun encryptedAttachmentFilename(filename: String): String {
    val basename = filename.substringAfterLast('/').substringAfterLast('\\')
    val cleaned = basename.trim().filterNot {
        it.code < 0x20 || it.code in 0x7f..0x9f
    }
    val candidate = cleaned.takeUnless { it.isEmpty() || it == "." || it == ".." }
        ?: "attachment"
    if (candidate.encodeToByteArray().size <= MAX_ENCRYPTED_ATTACHMENT_FILENAME_BYTES) {
        return candidate
    }

    val dot = candidate.lastIndexOf('.')
    val rawSuffix = if (dot > 0 && dot < candidate.lastIndex) candidate.substring(dot) else ""
    val suffix = rawSuffix.takeIf {
        it.encodeToByteArray().size < MAX_ENCRYPTED_ATTACHMENT_FILENAME_BYTES / 2
    }.orEmpty()
    val base = if (suffix.isEmpty()) candidate else candidate.substring(0, dot)
    val baseBudget = MAX_ENCRYPTED_ATTACHMENT_FILENAME_BYTES - suffix.encodeToByteArray().size
    return (base.utf8Prefix(baseBudget) + suffix).ifEmpty { "attachment" }
}

private fun String.utf8Prefix(maxBytes: Int): String {
    if (maxBytes <= 0) return ""
    val result = StringBuilder()
    var index = 0
    var bytes = 0
    while (index < length) {
        val first = this[index]
        val isSurrogatePair = first.code in 0xd800..0xdbff &&
            index + 1 < length && this[index + 1].code in 0xdc00..0xdfff
        val next = index + if (isSurrogatePair) 2 else 1
        val piece = substring(index, next)
        val pieceBytes = piece.encodeToByteArray().size
        if (bytes + pieceBytes > maxBytes) break
        result.append(piece)
        bytes += pieceBytes
        index = next
    }
    return result.toString()
}

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
    // Sender-declared application/pdf must still pass the plaintext signature
    // check. Other explicit MIME types remain authoritative for non-PDF media.
    if (normalized == PDF_ATTACHMENT_MIME) {
        return if (isVerifiedPdfAttachment(declaredMime, filename, plaintext)) {
            PDF_ATTACHMENT_MIME
        } else {
            GENERIC_ATTACHMENT_MIME
        }
    }
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
