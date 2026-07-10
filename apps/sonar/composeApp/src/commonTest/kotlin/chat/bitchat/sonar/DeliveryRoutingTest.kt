package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

class DeliveryRoutingTest {
    @Test
    fun deliveryAttemptsEveryItemAndReturnsOnlyFailuresInOrder() {
        val attempted = mutableListOf<Int>()

        val failed = collectFailedDeliveries(listOf(1, 2, 3, 4)) { item ->
            attempted += item
            item % 2 != 0
        }

        assertEquals(listOf(1, 2, 3, 4), attempted)
        assertEquals(listOf(2, 4), failed)
    }

    @Test
    fun successfulDeliveryHasNoFallbackItems() {
        assertEquals(emptyList(), collectFailedDeliveries(listOf("a", "b")) { true })
    }

    @Test
    fun mediaFailuresComparePayloadsByContent() {
        val first = MeshMediaSendFailure("peer", "id", byteArrayOf(1, 2), "photo.jpg", "image/jpeg", 7)
        val same = MeshMediaSendFailure("peer", "id", byteArrayOf(1, 2), "photo.jpg", "image/jpeg", 7)
        val changed = MeshMediaSendFailure("peer", "id", byteArrayOf(1, 3), "photo.jpg", "image/jpeg", 7)

        assertEquals(first, same)
        assertEquals(first.hashCode(), same.hashCode())
        assertNotEquals(first, changed)
    }

    @Test
    fun pendingFavoriteControlIsLatestWinsAndNormalizesPeerIds() {
        val pending = PendingFavoriteControls()
        pending.hold("mesh:ABC", "favorite")
        pending.hold("abc", "unfavorite")

        assertEquals(listOf("abc"), pending.peerIds())
        assertEquals("unfavorite", pending.payloadForFlush("mesh:ABC", blocked = false))
    }

    @Test
    fun blockingDiscardsPendingControlAcrossLaterUnblock() {
        val pending = PendingFavoriteControls()
        pending.hold("peer", "favorite")

        assertNull(pending.payloadForFlush("peer", blocked = true))
        assertNull(pending.payloadForFlush("peer", blocked = false))
    }

    @Test
    fun failedFlushRetainsControlAndSuccessfulFlushRemovesIt() {
        val pending = PendingFavoriteControls()
        pending.hold("peer", "favorite")

        assertEquals("favorite", pending.payloadForFlush("peer", blocked = false))
        assertEquals("favorite", pending.payloadForFlush("peer", blocked = false))
        pending.delivered("peer")

        assertNull(pending.payloadForFlush("peer", blocked = false))
    }
}
