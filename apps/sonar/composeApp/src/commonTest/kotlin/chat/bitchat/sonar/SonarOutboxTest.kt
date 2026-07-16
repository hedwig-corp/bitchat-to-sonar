package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

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
    fun failureKeepsFailedAndLaterUnexpiredMessagesQueued() {
        val outbox = SonarOutbox(maxPerPeer = 10, ttlSecs = 100)
        outbox.enqueue("peer-1", "expired-before-failure", "id-1", timestampSecs = 50)
        outbox.enqueue("peer-1", "delivered", "id-2", timestampSecs = 120)
        outbox.enqueue("peer-1", "failed", "id-3", timestampSecs = 130)
        outbox.enqueue("peer-1", "later", "id-4", timestampSecs = 140)
        outbox.enqueue("peer-1", "expired-after-failure", "id-5", timestampSecs = 80)
        val snapshot = outbox.snapshot("peer-1")

        val remaining = outbox.remainingAfterFailure(snapshot, failedIndex = 2, nowSecs = 200)
        outbox.finishFlush("peer-1", snapshot = snapshot, remaining = remaining)

        assertEquals(listOf("failed", "later"), outbox.snapshot("peer-1").map { it.content })
    }

    @Test
    fun successfulFlushClearsPeerQueue() {
        val outbox = SonarOutbox(maxPerPeer = 10, ttlSecs = 100)
        outbox.enqueue("peer-1", "one", "id-1", timestampSecs = 1)
        outbox.enqueue("peer-1", "two", "id-2", timestampSecs = 2)
        val snapshot = outbox.snapshot("peer-1")

        outbox.finishFlush("peer-1", snapshot = snapshot, remaining = emptyList())

        assertFalse(outbox.contains("peer-1"))
    }

    @Test
    fun finishFlushPreservesMessagesQueuedDuringInFlightFlush() {
        val outbox = SonarOutbox(maxPerPeer = 10, ttlSecs = 100)
        outbox.enqueue("peer-1", "one", "id-1", timestampSecs = 1)
        outbox.enqueue("peer-1", "two", "id-2", timestampSecs = 2)
        val snapshot = outbox.snapshot("peer-1")

        outbox.enqueue("peer-1", "three", "id-3", timestampSecs = 3)
        outbox.finishFlush("peer-1", snapshot = snapshot, remaining = emptyList())

        assertEquals(listOf("three"), outbox.snapshot("peer-1").map { it.content })
    }

    @Test
    fun finishFlushPreservesInFlightEnqueueAtMaxCapacity() {
        // Regression: at max capacity an in-flight enqueue EVICTS the head, so the
        // live queue is still snapshot-sized but no longer starts with the
        // snapshot. The old positional `drop(snapshotSize)` returned empty and
        // silently erased the newly queued message. Reconciling by id keeps it.
        val outbox = SonarOutbox(maxPerPeer = 3, ttlSecs = 100)
        outbox.enqueue("peer-1", "one", "id-1", timestampSecs = 1)
        outbox.enqueue("peer-1", "two", "id-2", timestampSecs = 2)
        outbox.enqueue("peer-1", "three", "id-3", timestampSecs = 3)
        val snapshot = outbox.snapshot("peer-1")
        assertEquals(3, snapshot.size)

        // Arrives mid-flush: evicts "one", queue becomes [two, three, four].
        outbox.enqueue("peer-1", "four", "id-4", timestampSecs = 4)
        outbox.finishFlush("peer-1", snapshot = snapshot, remaining = emptyList())

        assertEquals(listOf("four"), outbox.snapshot("peer-1").map { it.content })
    }

    @Test
    fun finishFlushAtMaxCapacityKeepsUndeliveredAheadOfInFlightEnqueue() {
        val outbox = SonarOutbox(maxPerPeer = 3, ttlSecs = 100)
        outbox.enqueue("peer-1", "one", "id-1", timestampSecs = 1)
        outbox.enqueue("peer-1", "two", "id-2", timestampSecs = 2)
        outbox.enqueue("peer-1", "three", "id-3", timestampSecs = 3)
        val snapshot = outbox.snapshot("peer-1")

        outbox.enqueue("peer-1", "four", "id-4", timestampSecs = 4)
        // "two"/"three" could not be delivered; they must precede the newcomer.
        outbox.finishFlush("peer-1", snapshot = snapshot, remaining = snapshot.drop(1))

        assertEquals(listOf("two", "three", "four"), outbox.snapshot("peer-1").map { it.content })
    }

    @Test
    fun enqueueIsIdempotentByMessageId() {
        val outbox = SonarOutbox(maxPerPeer = 10, ttlSecs = 100)

        outbox.enqueue("peer-1", "original", "id-1", timestampSecs = 1)
        val duplicate = outbox.enqueue("peer-1", "duplicate", "id-1", timestampSecs = 2)

        assertEquals(listOf("original"), outbox.snapshot("peer-1").map { it.content })
        assertEquals(1, duplicate.depth)
        assertEquals(null, duplicate.evicted)
    }
}
