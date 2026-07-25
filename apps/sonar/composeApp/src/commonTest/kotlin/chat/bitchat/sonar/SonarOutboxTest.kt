package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class SonarOutboxTest {
    @Test
    fun enqueueEvictsOldestMessageWhenPeerQueueIsFull() {
        val outbox = SonarOutbox(maxPerPeer = 3, ttlSecs = 100)

        outbox.enqueue("peer-1", "one", "id-1", timestampSecs = 1)
        outbox.enqueue("peer-1", "two", "id-2", timestampSecs = 2)
        outbox.enqueue("peer-1", "three", "id-3", timestampSecs = 3)
        val result = outbox.enqueue("peer-1", "four", "id-4", timestampSecs = 4)

        assertEquals("id-1", result.evicted?.messageId)
        assertEquals(listOf("two", "three", "four"), outbox.snapshot("peer-1").map { it.content })
        assertEquals(3, result.depth)
    }

    @Test
    fun enqueueingSameDeliveryAttemptTwiceIsIdempotent() {
        val outbox = SonarOutbox(maxPerPeer = 3, ttlSecs = 100)

        outbox.enqueue("peer-1", "retry me", "same-id", timestampSecs = 1)
        val duplicate = outbox.enqueue("peer-1", "retry me", "same-id", timestampSecs = 1)

        assertEquals(1, duplicate.depth)
        assertEquals(listOf("same-id"), outbox.snapshot("peer-1").map { it.messageId })
    }

    @Test
    fun failureKeepsFailedAndLaterUnexpiredMessagesQueued() {
        val outbox = SonarOutbox(maxPerPeer = 10, ttlSecs = 100)
        outbox.enqueue("peer-1", "expired-before-failure", "id-1", timestampSecs = 50)
        outbox.enqueue("peer-1", "delivered", "id-2", timestampSecs = 120)
        outbox.enqueue("peer-1", "failed", "id-3", timestampSecs = 130)
        outbox.enqueue("peer-1", "later", "id-4", timestampSecs = 140)
        outbox.enqueue("peer-1", "expired-after-failure", "id-5", timestampSecs = 80)
        val snapshot = outbox.snapshot("peer-1")

        val remaining = outbox.remainingAfterFailure(snapshot, failedIndex = 2, nowSecs = 200)
        outbox.finishFlush("peer-1", snapshotSize = snapshot.size, remaining = remaining)

        assertEquals(listOf("failed", "later"), outbox.snapshot("peer-1").map { it.content })
    }

    @Test
    fun successfulFlushClearsPeerQueue() {
        val outbox = SonarOutbox(maxPerPeer = 10, ttlSecs = 100)
        outbox.enqueue("peer-1", "one", "id-1", timestampSecs = 1)
        outbox.enqueue("peer-1", "two", "id-2", timestampSecs = 2)
        val snapshot = outbox.snapshot("peer-1")

        outbox.finishFlush("peer-1", snapshotSize = snapshot.size, remaining = emptyList())

        assertFalse(outbox.contains("peer-1"))
    }

    @Test
    fun finishFlushPreservesMessagesQueuedDuringInFlightFlush() {
        val outbox = SonarOutbox(maxPerPeer = 10, ttlSecs = 100)
        outbox.enqueue("peer-1", "one", "id-1", timestampSecs = 1)
        outbox.enqueue("peer-1", "two", "id-2", timestampSecs = 2)
        val snapshot = outbox.snapshot("peer-1")

        outbox.enqueue("peer-1", "three", "id-3", timestampSecs = 3)
        outbox.finishFlush("peer-1", snapshotSize = snapshot.size, remaining = emptyList())

        assertEquals(listOf("three"), outbox.snapshot("peer-1").map { it.content })
    }
}

class PendingMarmotOutboxTest {
    private fun send(content: String) = PendingMarmotSend(
        content = content,
        peerId = "peer-1",
        chatId = "mesh:peer-1",
        echoId = "echo-$content",
    )

    @Test
    fun failedHeadStaysAheadOfMessagesQueuedWhileItWasInFlight() {
        val outbox = PendingMarmotOutbox()
        val first = send("first")
        val later = send("later")
        outbox.enqueue("npub-1", first)

        val inFlight = outbox.peek("npub-1")
        outbox.enqueue("npub-1", later)
        // Failure deliberately does not acknowledge/requeue the head.

        assertEquals(listOf("first", "later"), outbox.snapshot("npub-1").map { it.content })
        assertEquals(first, inFlight)
        assertEquals(true, outbox.removeFirst("npub-1", first))
        assertEquals(later, outbox.peek("npub-1"))
    }

    @Test
    fun staleWorkerCannotAcknowledgeANewerHead() {
        val outbox = PendingMarmotOutbox()
        val delivered = send("delivered")
        val next = send("next")
        outbox.enqueue("npub-1", delivered)
        outbox.enqueue("npub-1", next)
        assertEquals(true, outbox.removeFirst("npub-1", delivered))

        assertFalse(outbox.removeFirst("npub-1", delivered))
        assertEquals(next, outbox.peek("npub-1"))
    }

    @Test
    fun clearDropsEveryPeerQueueAtDeletionBoundary() {
        val outbox = PendingMarmotOutbox()
        outbox.enqueue("npub-1", send("one"))
        outbox.enqueue("npub-2", send("two"))

        outbox.clear()

        assertEquals(emptyList(), outbox.peerIds())
        assertNull(outbox.peek("npub-1"))
        assertNull(outbox.peek("npub-2"))
    }

}
