package chat.bitchat.sonar

internal const val OUTBOX_MAX_PER_PEER = 100
internal const val OUTBOX_TTL_SECS = 24 * 60 * 60L

data class QueuedMessage(
    val content: String,
    val peerId: String,
    val messageId: String,
    val timestampSecs: Long,
    /** Per-peer durable FIFO order. Zero means "assign atomically". */
    val sequence: Long = 0L,
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

    fun remove(peerId: String) {
        queues.remove(peerId)
    }

    fun isEmpty(): Boolean = queues.isEmpty()

    fun contains(peerId: String): Boolean = queues.containsKey(peerId)

    fun peerIds(): List<String> = queues.keys.toList()

    fun snapshot(peerId: String): List<QueuedMessage> = queues[peerId]?.toList().orEmpty()

    fun restore(messages: Iterable<QueuedMessage>) {
        messages.groupBy { it.peerId }.forEach { (peerId, restored) ->
            queues[peerId] = restored
                .distinctBy { it.messageId }
                .sortedWith(compareBy<QueuedMessage> { it.sequence }.thenBy { it.messageId })
                .take(maxPerPeer)
                .toMutableList()
        }
    }

    fun enqueue(message: QueuedMessage): OutboxEnqueueResult {
        val queue = queues.getOrPut(message.peerId) { mutableListOf() }
        val existing = queue.firstOrNull { it.messageId == message.messageId }
        if (existing != null) return OutboxEnqueueResult(existing, null, queue.size)
        queue.add(message)
        queue.sortWith(compareBy<QueuedMessage> { it.sequence }.thenBy { it.messageId })
        val evicted = if (queue.size > maxPerPeer) queue.removeAt(0) else null
        return OutboxEnqueueResult(message, evicted, queue.size)
    }

    fun enqueue(peerId: String, content: String, messageId: String, timestampSecs: Long): OutboxEnqueueResult {
        val queue = queues.getOrPut(peerId) { mutableListOf() }
        val message = QueuedMessage(
            content = content,
            peerId = peerId,
            messageId = messageId,
            timestampSecs = timestampSecs,
        )
        return enqueue(message)
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
