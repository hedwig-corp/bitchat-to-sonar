package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SonarDeliveryTextTest {
    @Test fun labelNormalizesKnownStates() {
        assertNull(sonarDeliveryLabel(null))
        assertNull(sonarDeliveryLabel("  "))
        assertEquals("Sending", sonarDeliveryLabel("sending"))
        assertEquals("Uploading", sonarDeliveryLabel("Uploading"))
        assertEquals("Couldn't send", sonarDeliveryLabel("couldnt send"))
        assertEquals("Delivered", sonarDeliveryLabel("delivered"))
    }

    @Test fun pendingAndFailedClassifiersUseNormalizedState() {
        assertTrue(sonarDeliveryPending("sending"))
        assertTrue(sonarDeliveryPending("Uploading"))
        assertFalse(sonarDeliveryPending("Delivered"))
        assertTrue(sonarDeliveryFailed("failed"))
        assertTrue(sonarDeliveryFailed("Couldn't send"))
        assertFalse(sonarDeliveryFailed("Sending"))
    }

    @Test fun unknownStatePassesThrough() {
        assertEquals("Queued locally", sonarDeliveryLabel("Queued locally"))
    }

    @Test fun partialDeliveryRendersReachedOfTotal() {
        assertEquals("Delivered to 2 of 5", sonarDeliveryLabel("partial:2:5"))
        // Case-insensitive marker, whitespace-tolerant like the other states.
        assertEquals("Delivered to 1 of 3", sonarDeliveryLabel("  Partial:1:3  "))
    }

    @Test fun partialDeliveryEdgeCounts() {
        // Nobody reached yet (iOS seeds .partiallyDelivered(reached: 0, total: n)).
        assertEquals("Delivered to 0 of 4", sonarDeliveryLabel("partial:0:4"))
        // Everyone reached — same copy as iOS stateText(), not folded to "Delivered".
        assertEquals("Delivered to 4 of 4", sonarDeliveryLabel("partial:4:4"))
    }

    @Test fun malformedPartialFallsThroughToPassthrough() {
        assertEquals("partial:2", sonarDeliveryLabel("partial:2"))
        assertEquals("partial:x:y", sonarDeliveryLabel("partial:x:y"))
        assertEquals("partial:-1:5", sonarDeliveryLabel("partial:-1:5"))
        assertEquals("partial:2:5:9", sonarDeliveryLabel("partial:2:5:9"))
    }

    @Test fun partialDeliveryIsNeitherPendingNorFailed() {
        assertFalse(sonarDeliveryPending("partial:2:5"))
        assertFalse(sonarDeliveryFailed("partial:2:5"))
    }

    @Test fun retryIsOnlyOfferedForFailedOutgoingInternetMessages() {
        val failedInternet = SonarMsg(
            id = "internet",
            senderNpub = "me",
            content = "hello",
            mine = true,
            tsSecs = 1,
            viaInternet = true,
            state = "failed",
        )

        assertTrue(sonarCanRetryMessage(failedInternet))
        assertFalse(sonarCanRetryMessage(failedInternet.copy(viaInternet = false)))
        assertFalse(sonarCanRetryMessage(failedInternet.copy(mine = false)))
        assertFalse(sonarCanRetryMessage(failedInternet.copy(state = "Sending")))
    }
}
