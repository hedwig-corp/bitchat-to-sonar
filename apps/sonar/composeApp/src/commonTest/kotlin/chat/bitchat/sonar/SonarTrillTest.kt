package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SonarTrillTest {

    // ── Wire codec (docs/SONAR-TRILL.md) ──

    @Test
    fun encodeDecodeRoundTrip() {
        val line = TrillLine("deadbeef01234567")
        assertEquals("⚡TRILL|1|deadbeef01234567", line.encoded())
        assertEquals(line, TrillLine.decode(line.encoded()))
        assertTrue(TrillLine.isTrillLine(line.encoded()))
    }

    @Test
    fun randomIdIsSixteenHexAndRoundTrips() {
        val id = randomTrillId()
        assertEquals(16, id.length)
        assertTrue(id.all { it in '0'..'9' || it in 'a'..'f' })
        assertEquals(id, TrillLine.decode(TrillLine(id).encoded())?.id)
    }

    @Test
    fun rejectsOtherVersions() {
        // Locked to v1 so future versions degrade to plain text, never mis-render.
        assertNull(TrillLine.decode("⚡TRILL|2|deadbeef"))
        assertNull(TrillLine.decode("⚡TRILL|0|deadbeef"))
        assertNull(TrillLine.decode("⚡TRILL|11|deadbeef"))
    }

    @Test
    fun rejectsTrailingFields() {
        assertNull(TrillLine.decode("⚡TRILL|1|abc|extra"))
        assertNull(TrillLine.decode("⚡TRILL|1|abc|"))
        assertNull(TrillLine.decode("⚡TRILL|1"))
        assertNull(TrillLine.decode("⚡TRILL"))
    }

    @Test
    fun rejectsBadIds() {
        assertNull(TrillLine.decode("⚡TRILL|1|"))
        assertNull(TrillLine.decode("⚡TRILL|1|xyz"))
        assertNull(TrillLine.decode("⚡TRILL|1|abc def"))
        assertNull(TrillLine.decode("⚡TRILL|1|" + "a".repeat(65)))
        // 64 chars of hex-or-dash is the maximum accepted shape.
        assertEquals("a".repeat(64), TrillLine.decode("⚡TRILL|1|" + "a".repeat(64))?.id)
        assertEquals("ab-CD-12", TrillLine.decode("⚡TRILL|1|ab-CD-12")?.id)
    }

    @Test
    fun ordinaryTextIsNotATrill() {
        assertFalse(TrillLine.isTrillLine("hello"))
        assertFalse(TrillLine.isTrillLine("⚡PAY|1|abc|2100"))
        assertFalse(TrillLine.isTrillLine("TRILL|1|abc"))
    }

    // ── Chat-list preview ──

    @Test
    fun previewMapsTrillToNudge() {
        assertEquals("Nudge", messagePreview("⚡TRILL|1|deadbeef"))
        // Non-trill lines keep their existing previews.
        assertEquals("hello", messagePreview("hello"))
        assertEquals("₿ Payment", messagePreview("⚡PAY|1|abc|2100"))
    }

    // ── Notification copy: never the raw wire line ──

    @Test
    fun trillNotificationUsesNudgeCopyNotRawLine() {
        val n = SonarNotificationRouter.build(
            idKey = "chat-1",
            kind = SonarNotificationKind.Trill,
            senderName = "Alice",
            preview = "⚡TRILL|1|deadbeef",
        )
        assertEquals("Alice nudged you", n?.title)
        assertEquals("👋 They want your attention.", n?.body)
        assertFalse(n!!.title.contains("⚡TRILL"))
        assertFalse(n.body.contains("⚡TRILL"))
    }

    @Test
    fun trillClassificationFindsTrillLines() {
        assertEquals(
            SonarNotificationKind.Trill,
            SonarNotificationRouter.classifyContent("⚡TRILL|1|deadbeef"),
        )
        assertEquals(
            SonarNotificationKind.Message,
            SonarNotificationRouter.classifyContent("⚡TRILL|2|deadbeef"),
        )
    }

    // ── Receiver alert throttle: one buzz per chat per 8 s window ──

    @Test
    fun secondTrillWithinWindowIsSilent() {
        val throttle = TrillAlertThrottle()
        assertTrue(throttle.tryAlert("chat-a", nowMs = 1_000))
        assertFalse(throttle.tryAlert("chat-a", nowMs = 1_001))
        assertFalse(throttle.tryAlert("chat-a", nowMs = 8_999))
        assertTrue(throttle.tryAlert("chat-a", nowMs = 9_000))
    }

    @Test
    fun throttleWindowsArePerChat() {
        val throttle = TrillAlertThrottle()
        assertTrue(throttle.tryAlert("chat-a", nowMs = 1_000))
        assertTrue(throttle.tryAlert("chat-b", nowMs = 1_000))
        assertFalse(throttle.tryAlert("chat-b", nowMs = 2_000))
    }

    @Test
    fun silentTrillDoesNotResetTheWindow() {
        val throttle = TrillAlertThrottle()
        assertTrue(throttle.tryAlert("chat-a", nowMs = 0))
        // Throttled attempts must not extend the silence past the original window.
        assertFalse(throttle.tryAlert("chat-a", nowMs = 7_000))
        assertTrue(throttle.tryAlert("chat-a", nowMs = 8_000))
    }

    // ── Per-chat mute ──

    @Test
    fun muteSuppressesUntilExpiryAndForeverNeverExpires() {
        assertFalse(isMutedAt(null, nowSecs = 100))
        assertTrue(isMutedAt(muteUntilFor(3_600, nowSecs = 100), nowSecs = 100))
        assertTrue(isMutedAt(muteUntilFor(3_600, nowSecs = 100), nowSecs = 3_699))
        assertFalse(isMutedAt(muteUntilFor(3_600, nowSecs = 100), nowSecs = 3_700))
        assertTrue(isMutedAt(muteUntilFor(null, nowSecs = 100), nowSecs = Long.MAX_VALUE - 1))
    }

    @Test
    fun expiredMutesAreCleared() {
        val map = mapOf("live" to 2_000L, "expired" to 500L, "forever" to MUTE_FOREVER_SECS)
        val cleared = withExpiredMutesCleared(map, nowSecs = 1_000)
        assertEquals(setOf("live", "forever"), cleared.keys)
    }

    @Test
    fun muteMapRoundTripsThroughBlob() {
        val map = mapOf(
            "mesh:abcdef0123456789" to 1_234L,
            "a".repeat(64) to MUTE_FOREVER_SECS,
        )
        assertEquals(map, decodeMuteMap(encodeMuteMap(map)))
        assertEquals(emptyMap<String, Long>(), decodeMuteMap(""))
        assertEquals(emptyMap<String, Long>(), decodeMuteMap("garbage\n|123\nchat|notanumber"))
    }

    @Test
    fun muteDurationLadderMatchesDesign() {
        assertEquals(
            listOf(3_600L, 8 * 3_600L, 24 * 3_600L, 7 * 24 * 3_600L, null),
            MUTE_DURATIONS.map { it.secs },
        )
    }

    // ── Blocked peers: a trill is a normal message, so the ingest guard drops it ──

    @Test
    fun blockedSenderTrillIsDroppedByIngestGuards() {
        val blockedNpub = "b".repeat(64)
        val social = SonarSocialState().withBlockedNostr(blockedNpub, true)
        val trill = SonarMsg(
            id = "m1",
            senderNpub = blockedNpub,
            content = "⚡TRILL|1|deadbeef",
            mine = false,
            tsSecs = 200,
        )

        // The chat-message guard used at every ingest path rejects it…
        assertFalse(social.allowsChatMessage("chat-1", blockedNpub, mine = false))
        // …so the trill scan (same selection machinery as notifications) never
        // surfaces it as an alert candidate.
        assertNull(
            newestUnseenIncoming(
                messages = listOf(trill),
                seenMessageIds = emptySet(),
                previousLatestSecs = 100,
                isOpen = false,
                allowsMessage = { message ->
                    TrillLine.isTrillLine(message.content) &&
                        social.allowsChatMessage("chat-1", message.senderNpub, message.mine)
                },
            ),
        )
    }

    @Test
    fun ownTrillEchoNeverAlerts() {
        val mine = SonarMsg("m1", "c".repeat(64), "⚡TRILL|1|deadbeef", mine = true, tsSecs = 200)
        assertNull(
            newestUnseenIncoming(
                messages = listOf(mine),
                seenMessageIds = emptySet(),
                previousLatestSecs = 100,
                isOpen = false,
                allowsMessage = { TrillLine.isTrillLine(it.content) },
            ),
        )
    }

    @Test
    fun seedPassDoesNotAlertForBackfilledTrills() {
        // previousLatestSecs == null is the cold-start seed pass: history must
        // not buzz the phone.
        val trill = SonarMsg("m1", "d".repeat(64), "⚡TRILL|1|deadbeef", mine = false, tsSecs = 200)
        assertNull(
            newestUnseenIncoming(
                messages = listOf(trill),
                seenMessageIds = emptySet(),
                previousLatestSecs = null,
                isOpen = false,
                allowsMessage = { TrillLine.isTrillLine(it.content) },
            ),
        )
    }
}
