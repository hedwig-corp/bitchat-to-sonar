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

    /** Current cost, for tests and trim diagnostics. */
    val costBytes: Long get() = totalCost

    fun get(url: String): DecodedTranscriptMedia? {
        val hit = entries.remove(url) ?: return null
        entries[url] = hit // move to the newest LRU position
        return hit
    }

    fun put(url: String, decoded: DecodedTranscriptMedia) {
        entries.remove(url)?.let { totalCost -= it.costBytes }
        entries[url] = decoded
        totalCost += decoded.costBytes
        trimTo(MAX_COST_BYTES, keep = url)
    }

    /**
     * Evict eldest-first until the cache fits [maxCostBytes]. [keep] is never
     * evicted — `put` passes the entry it just painted so an image larger than
     * the whole budget still survives its own insertion.
     *
     * The OS calls this under memory pressure (see the Android
     * ComponentCallbacks2 hook in `SonarApp`): dropping decoded pixels costs a
     * re-decode from the disk thumbnail, which is far cheaper than being killed.
     */
    fun trimTo(maxCostBytes: Long, keep: String? = null) {
        val eldestFirst = entries.entries.iterator()
        while (totalCost > maxCostBytes && eldestFirst.hasNext()) {
            val eldest = eldestFirst.next()
            if (eldest.key == keep) continue
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
