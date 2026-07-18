package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TranscriptSpikeBTest {

    @Test
    fun reverse_feed_puts_newest_at_index_zero() {
        val chrono = listOf(
            SpikeBMessage("a", "oldest", mine = false),
            SpikeBMessage("b", "mid", mine = true),
            SpikeBMessage("c", "newest", mine = false),
        )
        val reverse = spikeBBuildReverseFeed(chrono, unreadFromNewest = 0)
        assertEquals(listOf("c", "b", "a"), reverse.map { it.id })
    }

    @Test
    fun unread_anchor_counts_non_mine_from_newest_edge() {
        val chrono = listOf(
            SpikeBMessage("1", "old peer", mine = false),
            SpikeBMessage("2", "me", mine = true),
            SpikeBMessage("3", "peer", mine = false),
            SpikeBMessage("4", "peer-new", mine = false),
            SpikeBMessage("5", "me-new", mine = true),
        )
        // 2 unread from newest non-mine edge → anchor on id "3"
        val reverse = spikeBBuildReverseFeed(chrono, unreadFromNewest = 2)
        assertEquals("5", reverse.first().id) // newest
        assertEquals("3", reverse.first { it.isUnreadAnchor }.id)
        assertEquals(2, reverse.indexOfFirst { it.isUnreadAnchor })
    }

    @Test
    fun initial_scroll_prefers_unread_divider_over_tail() {
        assertEquals(4, spikeBInitialScrollIndex(unreadAnchorIndex = 4, itemCount = 10))
        assertEquals(0, spikeBInitialScrollIndex(unreadAnchorIndex = -1, itemCount = 10))
        assertEquals(0, spikeBInitialScrollIndex(unreadAnchorIndex = 99, itemCount = 10))
    }

    @Test
    fun load_older_triggers_at_visual_top_high_indices() {
        assertTrue(spikeBShouldLoadOlder(didInitialScroll = true, totalItems = 40, highestVisibleIndex = 38))
        assertFalse(spikeBShouldLoadOlder(didInitialScroll = true, totalItems = 40, highestVisibleIndex = 2))
        assertFalse(spikeBShouldLoadOlder(didInitialScroll = false, totalItems = 40, highestVisibleIndex = 39))
    }

    @Test
    fun reverse_tail_pinner_snaps_when_ime_covers_newest() {
        val pinner = TranscriptTailPinnerSpikeB()
        assertEquals(
            SpikeBTailPin.None,
            pinner.onFrame(
                SpikeBTailFrame(
                    itemCount = 5,
                    viewportHeight = 2000,
                    tailFullyVisible = true,
                    scrolling = false,
                    prepending = false,
                ),
            ),
        )
        assertEquals(
            SpikeBTailPin.Snap,
            pinner.onFrame(
                SpikeBTailFrame(
                    itemCount = 5,
                    viewportHeight = 1300,
                    tailFullyVisible = false,
                    scrolling = false,
                    prepending = false,
                ),
            ),
        )
    }

    @Test
    fun reverse_tail_pinner_respects_user_scroll_away() {
        val pinner = TranscriptTailPinnerSpikeB()
        pinner.onFrame(
            SpikeBTailFrame(5, 2000, tailFullyVisible = true, scrolling = false, prepending = false),
        )
        assertEquals(
            SpikeBTailPin.None,
            pinner.onFrame(
                SpikeBTailFrame(5, 2000, tailFullyVisible = false, scrolling = true, prepending = false),
            ),
        )
        assertEquals(
            SpikeBTailPin.None,
            pinner.onFrame(
                SpikeBTailFrame(5, 2000, tailFullyVisible = false, scrolling = false, prepending = false),
            ),
        )
    }

    @Test
    fun reverse_tail_pinner_ignores_history_prepend() {
        val pinner = TranscriptTailPinnerSpikeB()
        pinner.onFrame(
            SpikeBTailFrame(5, 2000, tailFullyVisible = true, scrolling = false, prepending = false),
        )
        assertEquals(
            SpikeBTailPin.None,
            pinner.onFrame(
                SpikeBTailFrame(25, 2000, tailFullyVisible = false, scrolling = false, prepending = true),
            ),
        )
    }
}
