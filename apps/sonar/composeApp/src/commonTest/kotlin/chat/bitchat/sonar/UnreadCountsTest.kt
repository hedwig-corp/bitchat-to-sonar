package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
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

    @Test
    fun viewingSuppressMustNotStickAfterLeaveWhenMarkFailed() {
        // openIds are display-only. After leave they must not remain in the
        // prune-managed in-flight set, or a failed mark hides the badge forever.
        val summaries = listOf(summary("g-failed", 2))
        val inFlightAfterMarkRelease = emptySet<String>()
        val openIdsWhileViewing = setOf("g-failed")
        assertEquals(
            emptyMap(),
            unreadCountsFromSummaries(summaries, inFlightAfterMarkRelease + openIdsWhileViewing),
        )
        val openIdsAfterLeave = emptySet<String>()
        assertEquals(
            mapOf("g-failed" to 2L),
            unreadCountsFromSummaries(summaries, inFlightAfterMarkRelease + openIdsAfterLeave),
        )
        // Prune must also not resurrect a viewing id into in-flight suppress.
        assertEquals(
            emptySet(),
            pruneConfirmedUnreadSuppressions(inFlightAfterMarkRelease, summaries),
        )
    }

    @Test
    fun failedSummariesProbeDoesNotSettleOpenUnread() {
        assertNull(
            openChatUnreadFromCache(listOf("group-08", "group-09"), emptyMap()),
            "empty unread cache must not look like a fully-read 0",
        )
        assertEquals(
            3L,
            openChatUnreadFromCache(
                listOf("group-08", "group-09"),
                mapOf("group-08" to 3L),
            ),
        )
        assertEquals(
            4L,
            openChatUnreadFromCache(
                listOf("group-08", "group-09"),
                mapOf("group-08" to 3L, "group-09" to 1L),
            ),
        )
        assertNull(
            openChatUnreadFromCache(listOf("group-09"), mapOf("other" to 5L)),
            "another chat's badge is not a hit for this family",
        )
        assertEquals(
            0L,
            openChatUnreadFromCache(listOf("group-08"), mapOf("group-08" to 0L)),
        )

        val unread = listOf(summary("group-08", 4), summary("other", 1))
        assertEquals(4L, openChatUnreadFromSummaries(unread, listOf("group-08")))
        assertEquals(0L, openChatUnreadFromSummaries(emptyList(), listOf("group-08")))
        assertNull(openChatUnreadFromSummaries(null, listOf("group-08")))

        assertEquals(
            3L,
            capturedOpenChatUnread(
                ids = listOf("group-08", "group-09"),
                unreadByChat = mapOf("group-08" to 3L),
                summaries = null,
            ),
            "cache hit must win even when the index probe failed",
        )
        assertNull(
            capturedOpenChatUnread(
                ids = listOf("group-08", "group-09"),
                unreadByChat = emptyMap(),
                summaries = null,
            ),
            "empty cache + failed probe must leave open unread unset",
        )
        assertEquals(
            0L,
            capturedOpenChatUnread(
                ids = listOf("group-08"),
                unreadByChat = emptyMap(),
                summaries = emptyList(),
            ),
            "empty successful probe still settles 0",
        )
        assertEquals(
            0L,
            capturedOpenChatUnread(
                ids = emptyList(),
                unreadByChat = emptyMap(),
                summaries = null,
            ),
            "mesh with no White Noise group id settles 0",
        )
        assertEquals(
            "group-09",
            openChatUnreadPublishId(
                capturedFor = "group-08",
                stackChatIds = listOf("group-09"),
                historicalFolds = mapOf("group-08" to "group-09"),
            ),
        )
        assertEquals(
            "group-08",
            openChatUnreadPublishId(
                capturedFor = "group-08",
                stackChatIds = emptyList(),
                historicalFolds = mapOf("group-08" to "group-09"),
            ),
            "probe before push must still settle on the captured id",
        )
        assertNull(
            openChatUnreadPublishId(
                capturedFor = "group-08",
                stackChatIds = listOf("other"),
                historicalFolds = mapOf("group-08" to "group-09"),
            ),
            "popped / other-room probe must not publish",
        )
    }

    @Test
    fun liveOnlyProbeKeepsHistUnreadWhenLiveBadgeIsZero() {
        val folds = mapOf("group-08" to "group-09")
        val previous = mapOf("group-08" to 4L)
        val liveOnly = unreadCountsFromSummaries(listOf(summary("group-09", 0)))
        val kept = remountFoldedUnread(liveOnly, previous, folds)
        assertEquals(mapOf("group-08" to 4L), kept)
        assertEquals(
            4L,
            unreadForFoldFamily(
                chatId = "group-09",
                unreadByChat = kept,
                historicalFolds = folds,
            ),
        )
        val afterCopy = remountFoldedUnread(
            unreadCountsFromSummaries(listOf(summary("group-09", 4))),
            previous,
            folds,
        )
        assertEquals(mapOf("group-09" to 4L), afterCopy)
        assertEquals(
            4L,
            unreadForFoldFamily(
                chatId = "group-09",
                unreadByChat = afterCopy,
                historicalFolds = folds,
            ),
            "copy_summary already summed hist onto live — do not double-count",
        )
        assertEquals(
            mapOf("group-08" to 4L),
            remountFoldedUnread(emptyMap(), previous, folds),
            "live-only unread 0 publishes an empty map and must keep hist",
        )
    }

    @Test
    fun recoveredFoldUnreadDoesNotRetireBeforeIndexNewest() {
        assertFalse(
            shouldRetireOpenChatUnread(
                unreadAtOpen = 4L,
                anchorIndex = -1,
                feedNewestTsSecs = 10L,
                expectedNewestTsSecs = 50L,
                familyHasOlder = false,
            ),
            "short live page newer than nothing but older than hist latest must wait",
        )
        assertFalse(
            shouldRetireOpenChatUnread(
                unreadAtOpen = 4L,
                anchorIndex = -1,
                feedNewestTsSecs = 80L,
                expectedNewestTsSecs = 50L,
                familyHasOlder = true,
            ),
            "hidden 0.8 / bak remainder may still hold the unread incoming rows",
        )
        assertTrue(
            shouldRetireOpenChatUnread(
                unreadAtOpen = 4L,
                anchorIndex = -1,
                feedNewestTsSecs = 80L,
                expectedNewestTsSecs = 50L,
                familyHasOlder = false,
            ),
            "caught-up feed with no older family: control-only unread may retire",
        )
        assertFalse(
            shouldRetireOpenChatUnread(
                unreadAtOpen = 4L,
                anchorIndex = 2,
                feedNewestTsSecs = 10L,
                expectedNewestTsSecs = 50L,
                familyHasOlder = false,
            ),
        )
        assertFalse(
            shouldRetireOpenChatUnread(
                unreadAtOpen = 0L,
                anchorIndex = -1,
                feedNewestTsSecs = 10L,
                expectedNewestTsSecs = 50L,
                familyHasOlder = false,
            ),
        )
        val hist = SonarMsg(
            id = "h1",
            senderNpub = "npub1peer",
            content = "old",
            mine = false,
            tsSecs = 50L,
        )
        val live = SonarMsg(
            id = "l1",
            senderNpub = "npub1me",
            content = "new",
            mine = true,
            tsSecs = 10L,
        )
        assertEquals(50L, feedNewestTsSecs(listOf(live, hist)))
        assertEquals(10L, feedNewestTsSecs(listOf(live)))
        assertEquals(0L, feedNewestTsSecs(emptyList()))
    }
}
