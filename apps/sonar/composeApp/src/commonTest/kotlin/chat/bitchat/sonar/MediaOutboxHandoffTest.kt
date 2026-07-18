package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MediaOutboxHandoffTest {
    @Test
    fun replacementRequiresImmediateRetryOnlyAfterRelayInstall() {
        val usedNode = Any()
        val replacementNode = Any()

        assertFalse(mediaOutboxHandoffRequired(usedNode, usedNode, relayConnected = true))
        assertFalse(mediaOutboxHandoffRequired(usedNode, replacementNode, relayConnected = false))
        assertTrue(mediaOutboxHandoffRequired(usedNode, replacementNode, relayConnected = true))
    }
}
