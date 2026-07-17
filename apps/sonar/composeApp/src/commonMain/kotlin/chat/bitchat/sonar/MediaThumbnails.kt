package chat.bitchat.sonar

import androidx.compose.ui.graphics.ImageBitmap

/**
 * Longest edge, in pixels, a transcript thumbnail is decoded to.
 *
 * A bubble is ~260dp wide, so ~1024px still oversamples on a 3x phone and
 * leaves headroom for the full-screen viewer to reuse the same thumbnail while
 * the original loads. Signal bounds transcript thumbnails the same way rather
 * than decoding attachments at capture resolution: a 12MP phone photo is 48MB
 * as ARGB_8888 — one such decode blows the whole 48MB memory budget and can OOM
 * a low-end device, while its 1024px thumbnail is ~3MB.
 */
internal const val TRANSCRIPT_THUMB_MAX_EDGE_PX = 1024

/**
 * A downscaled decode: [bitmap] to paint now, [encoded] to persist so the next
 * cold open skips the full-size decode entirely. [encoded] is null when the
 * platform could not re-encode, or when the source was already small enough
 * that a thumbnail would not pay for itself.
 */
internal class ThumbnailDecode(
    val bitmap: ImageBitmap,
    val encoded: ByteArray?,
)

/**
 * Decode [bytes] bounded to [maxEdgePx] on its longest edge, without ever
 * materialising the full-size bitmap (Android samples during decode; Skia
 * scales immediately after). Returns null when the bytes are not a decodable
 * image — callers fall back to a file chip.
 */
internal expect fun decodeThumbnail(bytes: ByteArray, maxEdgePx: Int): ThumbnailDecode?

/**
 * Disk-backed downscaled thumbnails (Signal parity), layered on top of the
 * decoded-pixel [MediaImageMemoryCache].
 *
 * The memory cache only survives while the process does. Without this, every
 * cold start re-read and re-decoded the *original* attachment — the expensive
 * half of the work the memory cache exists to avoid. Thumbnails live beside the
 * attachments in the private media cache, so an account wipe
 * (`MediaCache.wipe()`, which is recursive) takes them with it.
 *
 * GIFs are deliberately excluded: animation needs the original bytes, and a
 * still thumbnail of frame 0 would defeat it.
 */
internal object MediaThumbnailDiskCache {
    suspend fun load(url: String): ThumbnailDecode? {
        val path = MediaCache.thumbnailPath(url)
        if (!MediaCache.exists(path)) return null
        val bytes = MediaCache.read(path) ?: return null
        // Already bounded on write, so this decode is cheap; pass the bound
        // anyway so a corrupt/oversized file can never blow the budget.
        return decodeThumbnail(bytes, TRANSCRIPT_THUMB_MAX_EDGE_PX)
    }

    /** Best-effort: a failed write only costs the next open a re-decode. */
    suspend fun store(url: String, encoded: ByteArray) {
        MediaCache.write(MediaCache.thumbnailPath(url), encoded)
    }
}
