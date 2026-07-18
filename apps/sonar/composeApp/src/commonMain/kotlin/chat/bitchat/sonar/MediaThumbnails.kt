package chat.bitchat.sonar

import androidx.compose.ui.graphics.ImageBitmap

/**
 * Longest edge, in pixels, a transcript thumbnail is decoded to.
 *
 * Signal-Android sizes list thumbs to the media bubble (~240×320dp) via
 * Glide `.override(w,h)` in `V2ConversationItemThumbnail` / `ThumbnailView`.
 * ~1024px covers a 3x phone bubble with headroom and matches our Compose
 * `MAX_MEDIA_BUBBLE_*` ceiling. Never decode capture resolution into the list:
 * a 12MP ARGB_8888 bitmap is ~48MB and can OOM; a 1024px thumb is ~3MB.
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
 * Signal-Android list path: sample from a file URI/path (Glide `DecryptableUri`
 * + `inSampleSize` / downsample) without allocating a full plaintext
 * [ByteArray] of the attachment. Prefer this for transcript cells.
 */
internal expect fun decodeThumbnailFromPath(path: String, maxEdgePx: Int): ThumbnailDecode?

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
