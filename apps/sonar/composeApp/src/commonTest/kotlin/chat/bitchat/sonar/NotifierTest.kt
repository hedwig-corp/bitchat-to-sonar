package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NotifierTest {
    @Test
    fun accountReplacementFenceBlocksNotificationsUntilReactivated() {
        assertFalse(accountNotificationsAllowed(suspended = true, panicWipePending = false))
        assertTrue(accountNotificationsAllowed(suspended = false, panicWipePending = false))
    }

    @Test
    fun panicMarkerKeepsNotificationsBlockedAfterInMemoryReactivation() {
        assertFalse(accountNotificationsAllowed(suspended = false, panicWipePending = true))
    }
}
