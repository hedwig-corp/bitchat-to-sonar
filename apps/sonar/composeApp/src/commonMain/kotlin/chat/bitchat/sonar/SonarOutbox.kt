package chat.bitchat.sonar

internal const val OUTBOX_MAX_PER_PEER = 100
internal const val OUTBOX_TTL_SECS = 24 * 60 * 60L

internal data class QueuedMessage(
    val content: String,
    val peerId: String,
    val messageId: String,
    val timestampSecs: Long,
)

internal data class OutboxEnqueueResult(
    val message: QueuedMessage,
    val evicted: QueuedMessage?,
    val depth: Int,
)

/** One folded-mesh send waiting for its Marmot group/worker. Keeping the echo
 * identity beside the plaintext lets the single per-peer owner reconcile the
 * optimistic row only after the core accepted this exact queue head. */
internal data class PendingMarmotSend(
    val content: String,
    val peerId: String,
    val chatId: String,
    val echoId: String,
)

/** FIFO storage for folded-mesh Marmot fallback. The caller owns execution;
 * this type deliberately exposes only the head so a failed send cannot be
 * removed/requeued behind a message appended while it was in flight. */
internal class PendingMarmotOutbox {
    private val queues = mutableMapOf<String, MutableList<PendingMarmotSend>>()

    fun clear() {
        queues.clear()
    }

    fun isEmpty(): Boolean = queues.isEmpty()

    fun peerIds(): List<String> = queues.keys.toList()

    fun enqueue(npubHex: String, send: PendingMarmotSend) {
        queues.getOrPut(npubHex) { mutableListOf() }.add(send)
    }

    fun peek(npubHex: String): PendingMarmotSend? = queues[npubHex]?.firstOrNull()

    fun snapshot(npubHex: String): List<PendingMarmotSend> = queues[npubHex]?.toList().orEmpty()

    /** A stale worker may never acknowledge a newer head. */
    fun removeFirst(npubHex: String, expected: PendingMarmotSend): Boolean {
        val queue = queues[npubHex] ?: return false
        if (queue.firstOrNull() !== expected) return false
        queue.removeAt(0)
        if (queue.isEmpty()) queues.remove(npubHex)
        return true
    }
}

internal class SonarOutbox(
    private val maxPerPeer: Int = OUTBOX_MAX_PER_PEER,
    private val ttlSecs: Long = OUTBOX_TTL_SECS,
) {
    private val queues = mutableMapOf<String, MutableList<QueuedMessage>>()

    fun clear() {
        queues.clear()
    }

    fun isEmpty(): Boolean = queues.isEmpty()

    fun contains(peerId: String): Boolean = queues.containsKey(peerId)

    fun peerIds(): List<String> = queues.keys.toList()

    fun snapshot(peerId: String): List<QueuedMessage> = queues[peerId]?.toList().orEmpty()

    fun enqueue(peerId: String, content: String, messageId: String, timestampSecs: Long): OutboxEnqueueResult {
        val queue = queues.getOrPut(peerId) { mutableListOf() }
        queue.firstOrNull { it.messageId == messageId }?.let { existing ->
            return OutboxEnqueueResult(existing, evicted = null, depth = queue.size)
        }
        val message = QueuedMessage(
            content = content,
            peerId = peerId,
            messageId = messageId,
            timestampSecs = timestampSecs,
        )
        queue.add(message)
        val evicted = if (queue.size > maxPerPeer) queue.removeAt(0) else null
        return OutboxEnqueueResult(message, evicted, queue.size)
    }

    fun isExpired(message: QueuedMessage, nowSecs: Long): Boolean =
        nowSecs - message.timestampSecs > ttlSecs

    fun remainingAfterFailure(snapshot: List<QueuedMessage>, failedIndex: Int, nowSecs: Long): List<QueuedMessage> =
        snapshot.drop(failedIndex).filterNot { isExpired(it, nowSecs) }

    fun finishFlush(peerId: String, snapshotSize: Int, remaining: List<QueuedMessage>) {
        val appended = queues[peerId].orEmpty().drop(snapshotSize)
        val next = (remaining + appended).toMutableList()
        if (next.isEmpty()) queues.remove(peerId) else queues[peerId] = next
    }
}
