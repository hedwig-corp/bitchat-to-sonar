package chat.bitchat.sonar

import androidx.compose.ui.graphics.ImageBitmap

/** Decoded transcript media ready to paint: a bitmap for static images, raw
 *  bytes for GIF animation. Both null when the payload could not be decoded as
 *  an image (the bubble falls back to a file chip). */
internal class DecodedTranscriptMedia(
    val bitmap: ImageBitmap?,
    val gifBytes: ByteArray?,
) {
    val costBytes: Long =
        gifBytes?.size?.toLong()
            ?: bitmap?.let { it.width.toLong() * it.height.toLong() * 4L }
            ?: 1L
}

/**
 * Decoded-thumbnail memory cache (Signal ThumbnailView / CVMediaCache parity):
 * reopening a chat or scrolling back to an already-seen image must paint the
 * real pixels on the first frame instead of flashing the download skeleton
 * while the attachment is re-read from disk and re-decoded.
 *
 * UI-thread confined: reads happen in composition and writes on the main
 * dispatcher after a background decode, so no locking is required.
 */
internal object MediaImageMemoryCache {
    /** LRU budget for decoded pixels/GIF bytes across every transcript. */
    private const val MAX_COST_BYTES = 48L * 1024L * 1024L

    private val entries = LinkedHashMap<String, DecodedTranscriptMedia>()
    private var totalCost = 0L

    fun get(url: String): DecodedTranscriptMedia? {
        val hit = entries.remove(url) ?: return null
        entries[url] = hit // move to the newest LRU position
        return hit
    }

    fun put(url: String, decoded: DecodedTranscriptMedia) {
        entries.remove(url)?.let { totalCost -= it.costBytes }
        entries[url] = decoded
        totalCost += decoded.costBytes
        val eldestFirst = entries.entries.iterator()
        while (totalCost > MAX_COST_BYTES && eldestFirst.hasNext()) {
            val eldest = eldestFirst.next()
            // Keep the entry just painted even when it alone exceeds the budget.
            if (eldest.key == url) continue
            eldestFirst.remove()
            totalCost -= eldest.value.costBytes
        }
    }

    /** Account wipe: decoded chat images must not outlive the encrypted store. */
    fun clear() {
        entries.clear()
        totalCost = 0L
    }
}
