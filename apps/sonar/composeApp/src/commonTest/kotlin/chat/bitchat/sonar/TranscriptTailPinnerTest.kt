package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals

class TranscriptTailPinnerTest {

    private fun frame(
        itemCount: Int = 40,
        viewportHeight: Int = 2000,
        tailFullyVisible: Boolean,
        scrolling: Boolean = false,
        prepending: Boolean = false,
    ) = TranscriptTailFrame(itemCount, viewportHeight, tailFullyVisible, scrolling, prepending)

    @Test
    fun keyboard_shrink_at_tail_snaps_back_every_frame() {
        val pinner = TranscriptTailPinner()
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(viewportHeight = 2000, tailFullyVisible = true)))
        // IME animates the viewport down; each shrink frame hides the tail again.
        assertEquals(TranscriptTailPin.Snap, pinner.onFrame(frame(viewportHeight = 1700, tailFullyVisible = false)))
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(viewportHeight = 1700, tailFullyVisible = true)))
        assertEquals(TranscriptTailPin.Snap, pinner.onFrame(frame(viewportHeight = 1300, tailFullyVisible = false)))
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(viewportHeight = 1300, tailFullyVisible = true)))
    }

    @Test
    fun media_growth_at_tail_snaps_back() {
        val pinner = TranscriptTailPinner()
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(tailFullyVisible = true)))
        // A loading skeleton swapped to the taller decoded image (same rows).
        assertEquals(TranscriptTailPin.Snap, pinner.onFrame(frame(tailFullyVisible = false)))
    }

    @Test
    fun user_scrolling_away_unpins() {
        val pinner = TranscriptTailPinner()
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(tailFullyVisible = true)))
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(tailFullyVisible = true, scrolling = true)))
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(tailFullyVisible = false, scrolling = true)))
        // Idle away from the tail: reading history must never be yanked down.
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(tailFullyVisible = false)))
    }

    @Test
    fun appended_row_at_tail_follows_with_animation() {
        val pinner = TranscriptTailPinner()
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(itemCount = 40, tailFullyVisible = true)))
        assertEquals(TranscriptTailPin.Animate, pinner.onFrame(frame(itemCount = 41, tailFullyVisible = false)))
    }

    @Test
    fun history_prepend_never_yanks_to_bottom() {
        val pinner = TranscriptTailPinner()
        // Short chat: everything fits, so the tail is visible while the reader
        // sits at the top and a 500-row history page loads underneath.
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(itemCount = 8, tailFullyVisible = true)))
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(itemCount = 8, tailFullyVisible = true, prepending = true)))
        assertEquals(
            TranscriptTailPin.None,
            pinner.onFrame(frame(itemCount = 508, tailFullyVisible = false, prepending = true)),
        )
        // Prepend finished with the anchor restored near the top: stay there.
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(itemCount = 508, tailFullyVisible = false)))
    }

    @Test
    fun returning_to_tail_re_arms_pinning() {
        val pinner = TranscriptTailPinner()
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(tailFullyVisible = true)))
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(tailFullyVisible = false, scrolling = true)))
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(tailFullyVisible = true, scrolling = true)))
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(tailFullyVisible = true)))
        assertEquals(TranscriptTailPin.Snap, pinner.onFrame(frame(tailFullyVisible = false)))
    }

    @Test
    fun empty_transcript_never_pins() {
        val pinner = TranscriptTailPinner()
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(itemCount = 0, tailFullyVisible = false)))
        assertEquals(TranscriptTailPin.None, pinner.onFrame(frame(itemCount = 0, tailFullyVisible = false, viewportHeight = 1300)))
    }
}
