package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SonarNotificationSyncResultTest {
    @Test
    fun incompleteEmptyResultNeedsFallback() {
        assertTrue(SonarNotificationSyncResult(timedOut = true).needsNotificationFallback())
        assertTrue(SonarNotificationSyncResult(truncated = true).needsNotificationFallback())
    }

    @Test
    fun partialPreciseProgressDoesNotDuplicateFallback() {
        val precise = SonarDrainNotification(
            messageId = "message-1",
            groupId = "group-1",
            createdAtSecs = 1_700_000_000,
            senderNpub = "npub1sender",
            groupName = "Friends",
            contentPreview = "hello",
        )
        val result = SonarNotificationSyncResult(
            notifications = listOf(precise),
            timedOut = true,
        )

        assertFalse(result.needsNotificationFallback())
    }

    @Test
    fun completeEmptyResultStillNeedsCurrentWakeFallback() {
        assertTrue(SonarNotificationSyncResult(completed = true).needsNotificationFallback())
    }
}
