package chat.bitchat.sonar

internal const val OUTBOX_MAX_PER_PEER = 100

internal data class QueuedMessage(
    val content: String,
    val peerId: String,
    val messageId: String,
    val timestampSecs: Long,
    val awaitingCleanup: Boolean = false,
)

internal data class OutboxEnqueueResult(
    val message: QueuedMessage,
    val evicted: QueuedMessage?,
    val depth: Int,
)

internal class SonarOutbox(
    private val maxPerPeer: Int = OUTBOX_MAX_PER_PEER,
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

    fun restore(message: QueuedMessage) {
        val queue = queues.getOrPut(message.peerId) { mutableListOf() }
        if (queue.none { it.messageId == message.messageId }) {
            queue.add(message)
            queue.sortBy { it.timestampSecs }
        }
    }

    fun remainingAfterFailure(snapshot: List<QueuedMessage>, failedIndex: Int): List<QueuedMessage> =
        snapshot.drop(failedIndex)

    fun remainingAfterCleanupFailure(
        snapshot: List<QueuedMessage>,
        failedIndex: Int,
    ): List<QueuedMessage> =
        listOf(snapshot[failedIndex].copy(awaitingCleanup = true)) + snapshot.drop(failedIndex + 1)

    fun finishFlush(peerId: String, snapshot: List<QueuedMessage>, remaining: List<QueuedMessage>): Boolean {
        val snapshotIds = snapshot.mapTo(mutableSetOf()) { it.messageId }
        val appended = queues[peerId].orEmpty().filterNot { it.messageId in snapshotIds }
        val next = (remaining + appended).toMutableList()
        if (next.isEmpty()) queues.remove(peerId) else queues[peerId] = next
        return remaining.isEmpty() && appended.isNotEmpty()
    }
}
