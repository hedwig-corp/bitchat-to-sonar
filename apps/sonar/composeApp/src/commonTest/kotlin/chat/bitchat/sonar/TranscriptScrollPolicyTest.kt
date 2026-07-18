package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

/**
 * Phase 1 Compose policy tests (distinct from [TranscriptTailPinnerTest]).
 * Pins OpenAction / inset decide / continuity / session → legacy pin mapping.
 */
class TranscriptScrollPolicyTest {

    @Test
    fun openAction_fullyRead_isLiveEdge() {
        assertEquals(
            TranscriptOpenAction.LiveEdge,
            TranscriptScrollPolicy.resolveOpenAction(
                unreadAnchorId = null,
                unreadCountAtOpen = 0L,
            ),
        )
    }

    @Test
    fun openAction_unreadCount_isUnreadDivider() {
        assertEquals(
            TranscriptOpenAction.UnreadDivider,
            TranscriptScrollPolicy.resolveOpenAction(
                unreadAnchorId = null,
                unreadCountAtOpen = 3L,
            ),
        )
    }

    @Test
    fun openAction_frozenUnreadAnchor_isUnreadDivider() {
        assertEquals(
            TranscriptOpenAction.UnreadDivider,
            TranscriptScrollPolicy.resolveOpenAction(
                unreadAnchorId = "m:abc",
                unreadCountAtOpen = 0L,
            ),
        )
    }

    @Test
    fun openAction_abandonedUnread_isLiveEdge() {
        assertEquals(
            TranscriptOpenAction.LiveEdge,
            TranscriptScrollPolicy.resolveOpenAction(
                unreadAnchorId = null,
                unreadCountAtOpen = 2L,
                unreadAnchorAbandoned = true,
            ),
        )
    }

    @Test
    fun openAction_jumpId_wins() {
        assertEquals(
            TranscriptOpenAction.Jump("m:search"),
            TranscriptScrollPolicy.resolveOpenAction(
                unreadAnchorId = "m:unread",
                unreadCountAtOpen = 5L,
                jumpMessageId = "m:search",
            ),
        )
    }

    @Test
    fun openAction_unsetCapture_isProvisionalLiveEdge() {
        // Nil capture → provisional live edge (avoid mid-history agent opens).
        assertEquals(
            TranscriptOpenAction.LiveEdge,
            TranscriptScrollPolicy.resolveOpenAction(
                unreadAnchorId = null,
                unreadCountAtOpen = null,
            ),
        )
    }

    @Test
    fun openAction_settledZero_isLiveEdge() {
        assertEquals(
            TranscriptOpenAction.LiveEdge,
            TranscriptScrollPolicy.resolveOpenAction(
                unreadAnchorId = null,
                unreadCountAtOpen = 0L,
            ),
        )
    }

    @Test
    fun dayLabel_todayOnlyForCurrentLocalDay() {
        val now = SonarClock.nowSecs()
        assertEquals("Today", dayLabel(now))
        // ~30 days ago must not say Today (regression: delta >= 0 treated all
        // non-negative as Today; older history at top of chat used wrong chip).
        val monthAgo = now - 30L * 86_400L
        assertTrue(dayLabel(monthAgo) != "Today")
        assertTrue(dayLabel(monthAgo) != "Yesterday")
    }

    @Test
    fun insetChange_atTail_pins() {
        assertEquals(
            TranscriptScrollDecision.Pin(animate = false),
            TranscriptScrollPolicy.decideInsetChange(
                wasAtTail = true,
                userScrolling = false,
                prepending = false,
            ),
        )
    }

    @Test
    fun insetChange_inHistory_locksteps() {
        assertEquals(
            TranscriptScrollDecision.Lockstep,
            TranscriptScrollPolicy.decideInsetChange(
                wasAtTail = false,
                userScrolling = false,
                prepending = false,
            ),
        )
    }

    @Test
    fun insetChange_userScrolling_ignores() {
        assertEquals(
            TranscriptScrollDecision.Ignore,
            TranscriptScrollPolicy.decideInsetChange(
                wasAtTail = true,
                userScrolling = true,
                prepending = false,
            ),
        )
    }

    @Test
    fun insetChange_prepending_ignores() {
        assertEquals(
            TranscriptScrollDecision.Ignore,
            TranscriptScrollPolicy.decideInsetChange(
                wasAtTail = true,
                userScrolling = false,
                prepending = true,
            ),
        )
    }

    @Test
    fun continuityToken_acceptsEdgeDistance() {
        val token = TranscriptScrollPolicy.captureContinuityToken(
            anchorId = "m:42",
            edgeDistancePx = 120,
        )
        assertEquals("m:42", token.anchorId)
        assertEquals(120, token.edgeDistancePx)
    }

    @Test
    fun continuityToken_acceptsPixelOffset() {
        val token = TranscriptScrollPolicy.captureContinuityToken(
            anchorId = "m:42",
            pixelOffset = -80,
        )
        assertEquals(-80, token.pixelOffset)
    }

    @Test
    fun continuityToken_requiresBias() {
        assertFailsWith<IllegalArgumentException> {
            TranscriptContinuityToken(anchorId = "m:42")
        }
    }

    @Test
    fun coalesce_ms_matches_signal() {
        assertEquals(10L, TranscriptScrollPolicy.INSET_COALESCE_MS)
    }

    @Test
    fun coalescer_lastOnly_until_consume() {
        val c = TranscriptInsetCoalescer()
        assertTrue(c.request())
        assertFalse(c.request())
        assertTrue(c.isScheduled)
        assertTrue(c.consume())
        assertFalse(c.consume())
        assertTrue(c.request())
    }

    @Test
    fun session_keyboardShrink_atTail_pinsSnap() {
        val session = TranscriptTailPinSession()
        assertEquals(
            TranscriptScrollDecision.Ignore,
            session.onLayoutFrame(40, tailFullyVisible = true, scrolling = false, prepending = false),
        )
        assertEquals(
            TranscriptScrollDecision.Pin(animate = false),
            session.onLayoutFrame(40, tailFullyVisible = false, scrolling = false, prepending = false),
        )
    }

    @Test
    fun session_append_atTail_pinsAnimate() {
        val session = TranscriptTailPinSession()
        session.onLayoutFrame(40, tailFullyVisible = true, scrolling = false, prepending = false)
        assertEquals(
            TranscriptScrollDecision.Pin(animate = true),
            session.onLayoutFrame(41, tailFullyVisible = false, scrolling = false, prepending = false),
        )
    }

    @Test
    fun session_userScroll_ignores() {
        val session = TranscriptTailPinSession()
        session.onLayoutFrame(40, tailFullyVisible = true, scrolling = false, prepending = false)
        assertEquals(
            TranscriptScrollDecision.Ignore,
            session.onLayoutFrame(40, tailFullyVisible = false, scrolling = true, prepending = false),
        )
        assertEquals(
            TranscriptScrollDecision.Ignore,
            session.onLayoutFrame(40, tailFullyVisible = false, scrolling = false, prepending = false),
        )
    }

    @Test
    fun toLegacyPin_mapsPinAndSuppressesLockstep() {
        assertEquals(
            TranscriptTailPin.Snap,
            TranscriptScrollPolicy.toLegacyPin(TranscriptScrollDecision.Pin(animate = false)),
        )
        assertEquals(
            TranscriptTailPin.Animate,
            TranscriptScrollPolicy.toLegacyPin(TranscriptScrollDecision.Pin(animate = true)),
        )
        assertEquals(
            TranscriptTailPin.None,
            TranscriptScrollPolicy.toLegacyPin(TranscriptScrollDecision.Lockstep),
        )
        assertEquals(
            TranscriptTailPin.None,
            TranscriptScrollPolicy.toLegacyPin(TranscriptScrollDecision.Ignore),
        )
    }
}
