package chat.bitchat.sonar

import chat.bitchat.sonar.store.MESSAGE_STORE_CAP
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class SonarOutboxTest {
    @Test
    fun directTranscriptReplayDistinguishesAlreadyPresentFromIdCollision() {
        val candidate = SonarMsg(
            "stable-id",
            "sender",
            "hello",
            mine = true,
            tsSecs = 1,
            viaInternet = true,
            state = "Sending",
        )

        assertEquals(
            MeshTranscriptAdmission.AlreadyPresent,
            classifyMeshTranscriptReplay(candidate.copy(state = "Couldn't send"), candidate),
        )
        assertEquals(
            MeshTranscriptAdmission.CommitFailed,
            classifyMeshTranscriptReplay(candidate.copy(content = "different"), candidate),
        )
        assertEquals(null, classifyMeshTranscriptReplay(null, candidate))
    }

    @Test
    fun composePrivateTranscriptRetainsOnlyNewestLocalWindow() {
        val messages = (0 until MESSAGE_STORE_CAP + 25).map { index ->
            SonarMsg("id-$index", "peer", "message-$index", mine = false, tsSecs = index.toLong())
        }.reversed()

        val retained = retainedPrivateTranscript(messages)

        assertEquals(MESSAGE_STORE_CAP, retained.size)
        assertEquals("id-25", retained.first().id)
        assertEquals("id-${MESSAGE_STORE_CAP + 24}", retained.last().id)
    }

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

    @Test
    fun durableRestoreUsesSequenceForSameSecondMessages() {
        val outbox = SonarOutbox(maxPerPeer = 10, ttlSecs = 100)
        outbox.restore(
            listOf(
                QueuedMessage("second", "peer-1", "random-a", 100, sequence = 2),
                QueuedMessage("first", "peer-1", "random-z", 100, sequence = 1),
            ),
        )

        assertEquals(listOf("first", "second"), outbox.snapshot("peer-1").map { it.content })
    }
}
