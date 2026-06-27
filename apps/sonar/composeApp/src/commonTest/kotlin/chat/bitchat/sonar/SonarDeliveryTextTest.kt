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
}
