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
