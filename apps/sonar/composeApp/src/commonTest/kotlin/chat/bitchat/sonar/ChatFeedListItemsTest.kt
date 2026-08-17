package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Pins the flattened transcript list structure the production ChatScreen
 * renders (Day sticky headers / Unread divider / rows with stable keys) and
 * the index math the open + continuity paths depend on. Every entry occupies
 * exactly one lazy index — sticky headers included — so these mappings are
 * what keeps ContinuityToken restores and unread opens exact.
 */
class ChatFeedListItemsTest {

    private fun msg(id: String, tsSecs: Long): SonarMsg = SonarMsg(
        id = id,
        senderNpub = "npub-peer",
        content = "hello $id",
        mine = false,
        tsSecs = tsSecs,
    )

    // 48h apart so the two groups land on different local days in every zone.
    private val t0 = 1_700_000_000L
    private val t1 = t0 + 60
    private val t2 = t0 + 2 * 86_400

    @Test
    fun insertsOneDayHeaderPerLocalDayGroup() {
        val feed = listOf<Any>(msg("a", t0), msg("b", t1), msg("c", t2))
        val items = buildChatFeedListItems(feed, unreadAnchorIndex = -1)

        assertEquals(5, items.size)
        assertTrue(items[0] is ChatFeedListItem.Day)
        assertEquals("m:a", chatFeedListKey(items[1]))
        assertEquals("m:b", chatFeedListKey(items[2]))
        assertTrue(items[3] is ChatFeedListItem.Day)
        assertEquals("m:c", chatFeedListKey(items[4]))
        // Two different days must own two different sticky-header keys.
        assertTrue(chatFeedListKey(items[0]) != chatFeedListKey(items[3]))
    }

    @Test
    fun unreadDividerLandsBeforeItsAnchorRow() {
        val feed = listOf<Any>(msg("a", t0), msg("b", t1), msg("c", t1 + 60))
        val items = buildChatFeedListItems(feed, unreadAnchorIndex = 1)

        val unread = items.indexOfFirst { it is ChatFeedListItem.Unread }
        val anchorRow = chatFeedListIndexForFeedRow(items, 1)
        assertTrue(unread >= 0)
        assertEquals(unread + 1, anchorRow)
        // Open lands on the divider, not the tail.
        assertEquals(unread, chatFeedListOpenIndex(items, "m:b", 1))
    }

    @Test
    fun tailIndexIsLastRowNotLastListEntry() {
        val feed = listOf<Any>(msg("a", t0), msg("b", t2))
        val items = buildChatFeedListItems(feed, unreadAnchorIndex = -1)
        val tail = chatFeedListTailIndex(items)
        assertEquals("m:b", chatFeedListKey(items[tail]))
        assertEquals(items.size - 1, tail)
    }

    @Test
    fun indexForKeyRoundTripsEveryEntry() {
        val feed = listOf<Any>(msg("a", t0), msg("b", t2))
        val items = buildChatFeedListItems(feed, unreadAnchorIndex = 0)
        items.forEachIndexed { i, item ->
            assertEquals(i, chatFeedListIndexForKey(items, chatFeedListKey(item)))
        }
    }

    @Test
    fun fullyReadOpenFallsBackToLiveEdge() {
        val feed = listOf<Any>(msg("a", t0), msg("b", t1))
        val items = buildChatFeedListItems(feed, unreadAnchorIndex = -1)
        assertEquals(chatFeedListTailIndex(items), chatFeedListOpenIndex(items, null, -1))
    }

    @Test
    fun duplicateCallRecordsCollapseLastWinsAndKeepUniqueKeys() {
        val first = CallRecord(id = "call-1", video = false, mine = true, durSecs = 0, tsSecs = t0)
        val second = first.copy(durSecs = 42, tsSecs = t0 + 5)
        val duplicates = listOf(first, second)
        val deduped = dedupeCallRecordsLastWins(duplicates)
        assertEquals(1, deduped.size)
        assertEquals(42, deduped.single().durSecs)
        val one = listOf(first)
        val singleton = dedupeCallRecordsLastWins(one)
        // Singleton path must not leak the mutable/input list into remember().
        assertTrue(singleton !== one)
        assertEquals(first, singleton.single())

        // Production path: feed builder sees already-deduped callRecords(), but
        // also tolerate a duplicate list if a caller forgets the read seam.
        val keys = buildChatFeedListItems(
            listOf(msg("a", t0)) + dedupeCallRecordsLastWins(duplicates),
            unreadAnchorIndex = -1,
        ).map(::chatFeedListKey)
        assertEquals(keys.size, keys.toSet().size)
        assertTrue(keys.contains("c:call-1"))
    }

    @Test
    fun hangupThenFinalizeUpsertsOneCallRecord() {
        val list = mutableListOf(
            CallRecord(id = "call-1", video = false, mine = true, durSecs = 0, tsSecs = t0),
            CallRecord(id = "call-1", video = false, mine = true, durSecs = 1, tsSecs = t0 + 1),
        )
        upsertCallRecordList(
            list,
            CallRecord(id = "call-1", video = false, mine = true, durSecs = 42, tsSecs = t0 + 5),
        )
        assertEquals(1, list.size)
        assertEquals(42, list.single().durSecs)

        val keys = buildChatFeedListItems(
            listOf(msg("a", t0), list.single()),
            unreadAnchorIndex = -1,
        ).map(::chatFeedListKey)
        assertEquals(keys.size, keys.toSet().size)
    }

    @Test
    fun duplicateMessageIdsCollapseLastWinsAndKeepUniqueKeys() {
        val first = msg("same", t0)
        val second = first.copy(content = "newer", tsSecs = t0 + 1)
        val collapsed = dedupeTranscriptMessagesLastWins(listOf(first, second))
        assertEquals(listOf("newer"), collapsed.map { it.content })
        val keys = buildChatFeedListItems(collapsed, unreadAnchorIndex = -1).map(::chatFeedListKey)
        assertEquals(keys.size, keys.toSet().size)
        assertEquals(listOf("m:same"), keys.filter { it.startsWith("m:") })
    }
}
