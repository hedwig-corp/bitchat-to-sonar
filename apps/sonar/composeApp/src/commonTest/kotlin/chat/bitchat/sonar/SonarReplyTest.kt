package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SonarReplyTest {
    @Test
    fun longPressPreviewMatchesSignalAndroidPressStates() {
        assertEquals(1f, sonarMessagePressScale(pressed = false, menuOpen = false, delayElapsed = false))
        assertEquals(1f, sonarMessagePressScale(pressed = true, menuOpen = false, delayElapsed = false))
        assertEquals(
            SONAR_MESSAGE_PRESS_SCALE_FACTOR,
            sonarMessagePressScale(pressed = true, menuOpen = false, delayElapsed = true),
        )
        assertEquals(
            SONAR_MESSAGE_PRESS_SCALE_FACTOR,
            sonarMessagePressScale(pressed = false, menuOpen = true, delayElapsed = false),
        )
        assertEquals(100L, SONAR_MESSAGE_PRESS_SCALE_DELAY_MS)
    }

    @Test
    fun longPressOverlayKeepsSignalAnchorUntilItWouldOverflow() {
        assertEquals(
            320f,
            sonarMessageMenuTopPx(
                anchorTopPx = 320f,
                overlayHeightPx = 240,
                viewportHeightPx = 800,
                paddingPx = 16f,
            ),
        )
        assertEquals(
            544f,
            sonarMessageMenuTopPx(
                anchorTopPx = 720f,
                overlayHeightPx = 240,
                viewportHeightPx = 800,
                paddingPx = 16f,
            ),
        )
        assertEquals(
            16f,
            sonarMessageMenuTopPx(
                anchorTopPx = -20f,
                overlayHeightPx = 240,
                viewportHeightPx = 800,
                paddingPx = 16f,
            ),
        )
    }

    @Test
    fun nipC7RequiresEventIdHexAndNpub() {
        val id = "a".repeat(64)
        assertTrue(sonarCanEmitNipC7(id, "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"))
        assertFalse(sonarCanEmitNipC7("optimistic-1", "npub1abc"))
        assertFalse(sonarCanEmitNipC7(id, null))
        assertFalse(sonarCanEmitNipC7(id, "hex-not-npub"))
        assertFalse(sonarCanEmitNipC7("zz".repeat(32), "npub1abc"))
    }

    @Test
    fun replyDisabledOnEchoAndSendingRows() {
        val live = SonarMsg("ab".repeat(32), "npub1peer", "hi", mine = false, tsSecs = 1)
        assertTrue(sonarCanReply(live))
        assertFalse(sonarCanReply(live.copy(id = "echo-1")))
        assertFalse(sonarCanReply(live.copy(id = "optimistic-1")))
        assertFalse(sonarCanReply(live.copy(state = "Sending")))
        assertFalse(sonarCanReply(live.copy(state = "Uploading")))
        assertFalse(sonarCanReply(live.copy(content = TrillLine("deadbeef").encoded())))
        assertFalse(sonarCanReply(live.copy(classification = SonarMsgClass.CallControl)))
    }

    @Test
    fun copyUsesFullSourceAndSkipsNonTextRows() {
        val live = SonarMsg("ab".repeat(32), "npub1peer", "  hello  ", mine = false, tsSecs = 1)
        assertEquals("  hello  ", sonarCopyableText(live))
        assertFalse(sonarCopyableText(live)!!.contains(SonarClock.hourMinute(live.tsSecs)))
        assertEquals("  hello  ", sonarCopyableText(live.copy(state = "Sending")))
        assertEquals(null, sonarCopyableText(live.copy(content = "   ")))
        assertEquals(null, sonarCopyableText(live.copy(classification = SonarMsgClass.CallControl)))
        assertEquals(null, sonarCopyableText(live.copy(classification = SonarMsgClass.PayReceipt("abc", 21))))
        assertEquals(null, sonarCopyableText(live.copy(content = TrillLine("deadbeef").encoded())))
    }

    @Test
    fun androidSwipeInterpolatorMatchesSignalUntilTriggerThenRubberBands() {
        val trigger = 64f
        val max = 96f
        assertEquals(0f, sonarSwipeReplyBubbleOffset(-8f, trigger, max))
        assertEquals(32f, sonarSwipeReplyBubbleOffset(32f, trigger, max))
        assertEquals(63.9f, sonarSwipeReplyBubbleOffset(63.9f, trigger, max), 0.01f)
        val past = sonarSwipeReplyBubbleOffset(80f, trigger, max)
        assertTrue(past > trigger)
        assertTrue(past < 80f)
        assertTrue(past <= max)
        val far = sonarSwipeReplyBubbleOffset(400f, trigger, max)
        assertTrue(far > past)
        assertTrue(far < max)
        assertFalse(sonarSwipeReplyTriggered(63.9f, trigger))
        assertTrue(sonarSwipeReplyTriggered(64f, trigger))
        assertEquals(0.5f, sonarSwipeReplyProgress(32f, trigger))
        assertEquals(1f, sonarSwipeReplyProgress(80f, trigger))
    }

    @Test
    fun iosSwipeInterpolatorRubberBandsAtQuarterOverflow() {
        val trigger = SONAR_SWIPE_REPLY_IOS_TRIGGER_PT
        assertEquals(40f, sonarSwipeReplyIosOffset(40f, trigger))
        assertEquals(55f, sonarSwipeReplyIosOffset(55f, trigger))
        assertEquals(55f + 20f / 4f, sonarSwipeReplyIosOffset(75f, trigger))
        assertEquals(0f, sonarSwipeReplyIosOffset(-12f, trigger))
    }

    @Test
    fun swipeStartIgnoresSystemBackEdgeAndBlankSide() {
        assertFalse(sonarSwipeReplyAllowsStart(localX = 10f, rowWidth = 400f, mine = false, edgeGuardPx = 24f))
        assertTrue(sonarSwipeReplyAllowsStart(localX = 40f, rowWidth = 400f, mine = false, edgeGuardPx = 24f))
        assertFalse(sonarSwipeReplyAllowsStart(localX = 360f, rowWidth = 400f, mine = false, edgeGuardPx = 24f))
        assertTrue(sonarSwipeReplyAllowsStart(localX = 320f, rowWidth = 400f, mine = true, edgeGuardPx = 24f))
        assertFalse(sonarSwipeReplyAllowsStart(localX = 40f, rowWidth = 400f, mine = true, edgeGuardPx = 24f))
        assertFalse(sonarSwipeReplyAllowsStart(localX = 390f, rowWidth = 400f, mine = false, edgeGuardPx = 24f, ltr = false))
        assertTrue(sonarSwipeReplyAllowsStart(localX = 360f, rowWidth = 400f, mine = false, edgeGuardPx = 24f, ltr = false))
        assertFalse(sonarSwipeReplyAllowsStart(localX = 40f, rowWidth = 400f, mine = false, edgeGuardPx = 24f, ltr = false))
        assertTrue(sonarSwipeReplyAllowsStart(localX = 80f, rowWidth = 400f, mine = true, edgeGuardPx = 24f, ltr = false))
        assertEquals(32f, sonarSwipeReplySignedOffset(32f, ltr = true))
        assertEquals(-32f, sonarSwipeReplySignedOffset(32f, ltr = false))
    }

    @Test
    fun resolvedPreviewPrefersSnapshotThenParentThenFallback() {
        val reply = SonarReplyRef(parentId = "ab".repeat(32), parentNpub = "npub1peer", preview = "")
        assertEquals(
            "parent body",
            sonarResolvedReplyPreview(reply, parentContent = "parent body", fallback = "Message"),
        )
        assertEquals(
            "snap",
            sonarResolvedReplyPreview(reply.copy(preview = "snap"), parentContent = "parent body", fallback = "Message"),
        )
        assertEquals(
            "Message",
            sonarResolvedReplyPreview(reply, parentContent = "  ", fallback = "Message"),
        )
        assertEquals(
            "Payment",
            sonarResolvedReplyPreview(
                reply.copy(preview = "⚡PAY|1|abc|21"),
                parentContent = "⚡PAY|1|abc|21",
                fallback = "Message",
                typedPreview = "Payment",
            ),
        )
        assertEquals(
            "Message",
            sonarResolvedReplyPreview(
                reply.copy(preview = "⚡PAY|1|abc|21"),
                parentContent = "⚡PAY|1|abc|21",
                fallback = "Message",
            ),
        )
        assertEquals(
            "Payment",
            sonarTypedReplyPreview(
                SonarMsgClass.PayReceipt("abc", 21),
                hasSticker = false,
                hasMedia = false,
                paymentLabel = "Payment",
                photoLabel = "Photo",
                stickerLabel = "Sticker",
            ),
        )
    }

    @Test
    fun meshReplyHydratesPreviewFromParentInWindow() {
        val parent = SonarMsg("parent-mid", "npub1peer", "see you at 9", mine = false, tsSecs = 1)
        val child = sonarMeshReplyRef("parent-mid", listOf(parent))
        assertEquals("parent-mid", child?.parentId)
        assertEquals("see you at 9", child?.preview)
        assertEquals("npub1peer", child?.parentNpub)
        assertEquals(null, sonarMeshReplyRef(" ", listOf(parent)))
        assertEquals("", sonarMeshReplyRef("missing", listOf(parent))?.preview)
        assertEquals("parent-mid", sonarMeshReplyToWire(child))
        assertEquals(null, sonarMeshReplyToWire(null))
    }
}
