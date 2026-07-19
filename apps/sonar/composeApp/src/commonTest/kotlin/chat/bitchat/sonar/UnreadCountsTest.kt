package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class UnreadCountsTest {
    private fun summary(groupId: String, unread: Long) = SonarConversationSummary(
        groupIdHex = groupId,
        name = "chat",
        latestContent = "hi",
        latestSenderNpub = "npub1",
        latestAtSecs = 1L,
        latestMine = false,
        messageCount = 1L,
        unreadCount = unread,
    )

    @Test
    fun unreadCountsSkipsZeroAndSuppressedGroups() {
        val summaries = listOf(
            summary("g-read", 0),
            summary("g-open", 3),
            summary("g-other", 2),
        )
        assertEquals(
            mapOf("g-other" to 2L),
            unreadCountsFromSummaries(summaries, suppressGroupIds = setOf("g-open")),
        )
    }

    @Test
    fun unreadCountsEmptyWhenEverythingSuppressedOrRead() {
        val summaries = listOf(
            summary("g1", 0),
            summary("g2", 4),
        )
        assertTrue(
            unreadCountsFromSummaries(summaries, suppressGroupIds = setOf("g2")).isEmpty(),
        )
    }

    @Test
    fun pruneKeepsOnlyGroupsStillUnreadInCore() {
        val suppress = setOf("g-inflight", "g-done", "g-missing")
        val summaries = listOf(
            summary("g-inflight", 2),
            summary("g-done", 0),
        )
        assertEquals(
            setOf("g-inflight"),
            pruneConfirmedUnreadSuppressions(suppress, summaries),
        )
    }

    @Test
    fun afterMarkReleaseFailedGroupsSurfaceAgain() {
        // Simulates markGroupsRead's post-FFI release: in-flight suppress is
        // cleared for the batch, so a still-unread group is visible again
        // unless the open-session suppress set still covers it.
        val summaries = listOf(summary("g-failed", 2), summary("g-open", 1))
        val afterRelease = emptySet<String>()
        val openSession = setOf("g-open")
        assertEquals(
            mapOf("g-failed" to 2L),
            unreadCountsFromSummaries(summaries, afterRelease + openSession),
        )
    }
}
