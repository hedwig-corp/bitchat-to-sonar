package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SonarMediaOutboxTest {
    @Test
    fun enqueueEvictsOldestMediaWhenPeerQueueIsFull() {
        val outbox = SonarMediaOutbox(maxPerPeer = 3, ttlSecs = 100)

        outbox.enqueue("peer-1", "id-1", "mesh-media:peer-1:id-1:img.png", "img.png", "image/png", 1)
        outbox.enqueue("peer-1", "id-2", "mesh-media:peer-1:id-2:img.png", "img.png", "image/png", 2)
        outbox.enqueue("peer-1", "id-3", "mesh-media:peer-1:id-3:img.png", "img.png", "image/png", 3)
        val result = outbox.enqueue("peer-1", "id-4", "mesh-media:peer-1:id-4:img.png", "img.png", "image/png", 4)

        assertEquals("id-1", result.evicted?.messageId)
        assertEquals(listOf("id-2", "id-3", "id-4"), outbox.snapshot("peer-1").map { it.messageId })
        assertEquals(3, result.depth)
    }

    @Test
    fun expiredMediaIsDroppedByRemainingAfterFailure() {
        val outbox = SonarMediaOutbox(maxPerPeer = 10, ttlSecs = 100)
        outbox.enqueue("peer-1", "expired-before", "mesh-media:p:expired-before:f", "f", "image/png", 50)
        outbox.enqueue("peer-1", "delivered", "mesh-media:p:delivered:f", "f", "image/png", 120)
        outbox.enqueue("peer-1", "failed", "mesh-media:p:failed:f", "f", "image/png", 130)
        outbox.enqueue("peer-1", "later", "mesh-media:p:later:f", "f", "image/png", 140)
        outbox.enqueue("peer-1", "expired-after", "mesh-media:p:expired-after:f", "f", "image/png", 80)
        val snapshot = outbox.snapshot("peer-1")

        val remaining = outbox.remainingAfterFailure(snapshot, failedIndex = 2, nowSecs = 200)
        outbox.finishFlush("peer-1", snapshotSize = snapshot.size, remaining = remaining)

        // "failed" is re-queued; "later" is kept; both expired entries are gone.
        assertEquals(listOf("failed", "later"), outbox.snapshot("peer-1").map { it.messageId })
    }

    @Test
    fun successfulFlushClearsPeerQueue() {
        val outbox = SonarMediaOutbox(maxPerPeer = 10, ttlSecs = 100)
        outbox.enqueue("peer-1", "id-1", "mesh-media:p:id-1:f", "f", "image/png", 1)
        outbox.enqueue("peer-1", "id-2", "mesh-media:p:id-2:f", "f", "image/png", 2)
        val snapshot = outbox.snapshot("peer-1")

        outbox.finishFlush("peer-1", snapshotSize = snapshot.size, remaining = emptyList())

        assertFalse(outbox.contains("peer-1"))
    }

    @Test
    fun finishFlushPreservesMediaQueuedDuringInFlightFlush() {
        val outbox = SonarMediaOutbox(maxPerPeer = 10, ttlSecs = 100)
        outbox.enqueue("peer-1", "id-1", "mesh-media:p:id-1:f", "f", "image/png", 1)
        outbox.enqueue("peer-1", "id-2", "mesh-media:p:id-2:f", "f", "image/png", 2)
        val snapshot = outbox.snapshot("peer-1")

        // A new image arrives while the flush is in flight.
        outbox.enqueue("peer-1", "id-3", "mesh-media:p:id-3:f", "f", "image/png", 3)
        outbox.finishFlush("peer-1", snapshotSize = snapshot.size, remaining = emptyList())

        assertEquals(listOf("id-3"), outbox.snapshot("peer-1").map { it.messageId })
    }

    @Test
    fun isExpiredFlagsMediaOlderThanTtl() {
        val outbox = SonarMediaOutbox(maxPerPeer = 10, ttlSecs = 60)
        val fresh = QueuedMedia("id-1", "mesh-media:p:id-1:f", "f", "image/png", 100)
        val stale = QueuedMedia("id-2", "mesh-media:p:id-2:f", "f", "image/png", 10)

        assertFalse(outbox.isExpired(fresh, nowSecs = 120))
        assertTrue(outbox.isExpired(stale, nowSecs = 120))
    }

    @Test
    fun peersAreIsolated() {
        val outbox = SonarMediaOutbox(maxPerPeer = 5, ttlSecs = 100)
        outbox.enqueue("peer-a", "id-1", "mesh-media:a:id-1:f", "f", "image/png", 1)
        outbox.enqueue("peer-b", "id-2", "mesh-media:b:id-2:f", "f", "image/jpeg", 2)

        assertEquals(listOf("id-1"), outbox.snapshot("peer-a").map { it.messageId })
        assertEquals(listOf("id-2"), outbox.snapshot("peer-b").map { it.messageId })
        assertTrue(outbox.contains("peer-a"))
        assertTrue(outbox.contains("peer-b"))

        outbox.remove("peer-a")
        assertFalse(outbox.contains("peer-a"))
        assertTrue(outbox.contains("peer-b"))
        assertFalse(outbox.isEmpty())

        outbox.clear()
        assertTrue(outbox.isEmpty())
    }
}
