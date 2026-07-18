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
}
