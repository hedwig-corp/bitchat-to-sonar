package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SonarOutboxTest {
    @Test
    fun recoveredGroupCancellationIsRetiredInsteadOfShownAsFailed() {
        assertTrue(isRecoveredGroupCancellation("invalid input: group operation was cancelled"))
        assertFalse(isRecoveredGroupCancellation("relay temporarily unavailable"))
        assertFalse(isRecoveredGroupCancellation(null))
    }

    @Test
    fun enqueueEvictsOldestMessageWhenPeerQueueIsFull() {
        val outbox = SonarOutbox(maxPerPeer = 3)

        outbox.enqueue("peer-1", "one", "id-1", timestampSecs = 1)
        outbox.enqueue("peer-1", "two", "id-2", timestampSecs = 2)
        outbox.enqueue("peer-1", "three", "id-3", timestampSecs = 3)
        val result = outbox.enqueue("peer-1", "four", "id-4", timestampSecs = 4)

        assertEquals("id-1", result.evicted?.messageId)
        assertEquals(listOf("two", "three", "four"), outbox.snapshot("peer-1").map { it.content })
        assertEquals(3, result.depth)
    }

    @Test
    fun failureKeepsEveryLaterMessageQueuedRegardlessOfAge() {
        val outbox = SonarOutbox(maxPerPeer = 10)
        outbox.enqueue("peer-1", "old-before-failure", "id-1", timestampSecs = 50)
        outbox.enqueue("peer-1", "delivered", "id-2", timestampSecs = 120)
        outbox.enqueue("peer-1", "failed", "id-3", timestampSecs = 130)
        outbox.enqueue("peer-1", "later", "id-4", timestampSecs = 140)
        outbox.enqueue("peer-1", "old-after-failure", "id-5", timestampSecs = 80)
        val snapshot = outbox.snapshot("peer-1")

        val remaining = outbox.remainingAfterFailure(snapshot, failedIndex = 2)
        outbox.finishFlush("peer-1", snapshot = snapshot, remaining = remaining)

        assertEquals(listOf("failed", "later", "old-after-failure"), outbox.snapshot("peer-1").map { it.content })
    }

    @Test
    fun successfulFlushClearsPeerQueue() {
        val outbox = SonarOutbox(maxPerPeer = 10)
        outbox.enqueue("peer-1", "one", "id-1", timestampSecs = 1)
        outbox.enqueue("peer-1", "two", "id-2", timestampSecs = 2)
        val snapshot = outbox.snapshot("peer-1")

        outbox.finishFlush("peer-1", snapshot = snapshot, remaining = emptyList())

        assertFalse(outbox.contains("peer-1"))
    }

    @Test
    fun finishFlushPreservesMessagesQueuedDuringInFlightFlush() {
        val outbox = SonarOutbox(maxPerPeer = 10)
        outbox.enqueue("peer-1", "one", "id-1", timestampSecs = 1)
        outbox.enqueue("peer-1", "two", "id-2", timestampSecs = 2)
        val snapshot = outbox.snapshot("peer-1")

        outbox.enqueue("peer-1", "three", "id-3", timestampSecs = 3)
        outbox.finishFlush("peer-1", snapshot = snapshot, remaining = emptyList())

        assertEquals(listOf("three"), outbox.snapshot("peer-1").map { it.content })
    }

    @Test
    fun finishFlushPreservesMessageAppendedWhenFullQueueEvictsSnapshotHead() {
        val outbox = SonarOutbox(maxPerPeer = 3)
        outbox.enqueue("peer-1", "one", "id-1", timestampSecs = 1)
        outbox.enqueue("peer-1", "two", "id-2", timestampSecs = 2)
        outbox.enqueue("peer-1", "three", "id-3", timestampSecs = 3)
        val snapshot = outbox.snapshot("peer-1")

        outbox.enqueue("peer-1", "four", "id-4", timestampSecs = 4)
        outbox.finishFlush("peer-1", snapshot = snapshot, remaining = emptyList())

        assertEquals(listOf("four"), outbox.snapshot("peer-1").map { it.content })
    }

    @Test
    fun restoreIsIdempotentAndReestablishesTimestampOrder() {
        val outbox = SonarOutbox(maxPerPeer = 10)
        val later = QueuedMessage("later", "peer-1", "id-2", timestampSecs = 20)
        val earlier = QueuedMessage("earlier", "peer-1", "id-1", timestampSecs = 10)

        outbox.restore(later)
        outbox.restore(earlier)
        outbox.restore(later)

        assertEquals(listOf("id-1", "id-2"), outbox.snapshot("peer-1").map { it.messageId })
    }

    @Test
    fun cleanupFailureKeepsDeliveredRowWithoutResendingFlagAndPreservesTail() {
        val outbox = SonarOutbox()
        outbox.enqueue("peer", "first", "id-1", 1)
        outbox.enqueue("peer", "second", "id-2", 2)
        val snapshot = outbox.snapshot("peer")

        val remaining = outbox.remainingAfterCleanupFailure(snapshot, 0)

        assertEquals(listOf("id-1", "id-2"), remaining.map { it.messageId })
        assertEquals(true, remaining.first().awaitingCleanup)
        assertEquals(false, remaining.last().awaitingCleanup)
    }

    @Test
    fun preRouteContextRoundTripsDelimitersAndUnicode() {
        val parts = listOf("group:name", "npub1peer", "Sarà 🚲")

        assertEquals(parts, decodePreRouteContext(encodePreRouteContext(parts)))
    }

    @Test
    fun groupOperationSentinelRestoresRouteWithoutCreatingAnEmptyMessage() {
        val create = preRouteGroupRestorePlan(
            PRE_ROUTE_GROUP_OPERATION,
            encodePreRouteContext(listOf("create", "Low signal", "npub1alice", "npub1bob")),
        )

        assertEquals("Low signal", create?.name)
        assertEquals(listOf("npub1alice", "npub1bob"), create?.members)
        assertEquals(false, create?.restoreMessage)
        assertNull(create?.inviteId)

        val queuedMessage = preRouteGroupRestorePlan(
            PRE_ROUTE_GROUP_CREATE,
            encodePreRouteContext(listOf("Low signal", "npub1alice", "npub1bob")),
        )
        assertEquals(true, queuedMessage?.restoreMessage)
    }

    @Test
    fun resolvedGroupCheckpointUsesConcreteGroupInsteadOfEncodedSetupContext() {
        val groupId = "real-mls-group"
        val setupContext = encodePreRouteContext(listOf("Low signal", "npub1alice"))

        assertEquals(groupId, resolvedPreRouteChatId(groupId, setupContext))
        assertEquals(groupId, resolvedPreRouteChatId(groupId, "group-pending:setup"))
        assertEquals("mesh:peer", resolvedPreRouteChatId(groupId, "mesh:peer"))
    }
}
