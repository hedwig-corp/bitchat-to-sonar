package chat.bitchat.sonar

internal const val MEDIA_OUTBOX_MAX_PER_PEER = 16
internal const val MEDIA_OUTBOX_TTL_SECS = 24 * 60 * 60L

/**
 * Media metadata held for retry. Raw bytes are NOT stored here — they live in
 * `mediaCache` (in-memory, ≤1 MB) and `MessageStore.saveMeshMedia` (file-backed),
 * keyed by [mediaUrl]. This mirrors [SonarOutbox] but keeps attachment metadata
 * instead of plain text.
 */
internal data class QueuedMedia(
    val messageId: String,
    val mediaUrl: String,
    val filename: String,
    val mime: String,
    val timestampSecs: Long,
)

internal data class MediaOutboxEnqueueResult(
    val media: QueuedMedia,
    val evicted: QueuedMedia?,
    val depth: Int,
)

/**
 * Per-peer FIFO queue of undelivered mesh-DM media attachments. Mirrors the
 * text [SonarOutbox]: bounded depth per peer (oldest evicted first), a 24h TTL,
 * and the same snapshot/finishFlush API so an in-flight flush preserves messages
 * queued while it runs.
 */
internal class SonarMediaOutbox(
    private val maxPerPeer: Int = MEDIA_OUTBOX_MAX_PER_PEER,
    private val ttlSecs: Long = MEDIA_OUTBOX_TTL_SECS,
) {
    private val queues = mutableMapOf<String, MutableList<QueuedMedia>>()

    fun clear() {
        queues.clear()
    }

    fun isEmpty(): Boolean = queues.isEmpty()

    fun contains(peerId: String): Boolean = queues.containsKey(peerId)

    fun peerIds(): List<String> = queues.keys.toList()

    fun snapshot(peerId: String): List<QueuedMedia> = queues[peerId]?.toList().orEmpty()

    fun enqueue(
        peerId: String,
        messageId: String,
        mediaUrl: String,
        filename: String,
        mime: String,
        timestampSecs: Long,
    ): MediaOutboxEnqueueResult {
        val queue = queues.getOrPut(peerId) { mutableListOf() }
        val media = QueuedMedia(
            messageId = messageId,
            mediaUrl = mediaUrl,
            filename = filename,
            mime = mime,
            timestampSecs = timestampSecs,
        )
        queue.add(media)
        val evicted = if (queue.size > maxPerPeer) queue.removeAt(0) else null
        return MediaOutboxEnqueueResult(media, evicted, queue.size)
    }

    fun isExpired(media: QueuedMedia, nowSecs: Long): Boolean =
        nowSecs - media.timestampSecs > ttlSecs

    fun remainingAfterFailure(snapshot: List<QueuedMedia>, failedIndex: Int, nowSecs: Long): List<QueuedMedia> =
        snapshot.drop(failedIndex).filterNot { isExpired(it, nowSecs) }

    fun finishFlush(peerId: String, snapshotSize: Int, remaining: List<QueuedMedia>) {
        val appended = queues[peerId].orEmpty().drop(snapshotSize)
        val next = (remaining + appended).toMutableList()
        if (next.isEmpty()) queues.remove(peerId) else queues[peerId] = next
    }

    fun remove(peerId: String) {
        queues.remove(peerId)
    }
}
