package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Unit tests for the pure machinery behind the event-driven refresh refactor:
 * the incremental-scan watermark gate, the notification predicate, and the
 * [visibleChats] memo key. These replace the old every-4 s full-page scan with
 * skip logic, so their correctness is what keeps behavior identical.
 */
class EventDrivenRefreshTest {

    // ── chatsNeedingPageScan: only chats whose latest ts/count advanced ──

    private fun m(secs: Long, count: Long = 1L) = ScanMark(secs, count)

    @Test
    fun scanSkipsChatsWithUnchangedLatestTs() {
        val latest = mapOf("a" to m(100), "b" to m(200), "c" to m(300))
        val watermark = mapOf("a" to m(100), "b" to m(200), "c" to m(300))
        assertEquals(emptySet(), chatsNeedingPageScan(latest, watermark))
    }

    @Test
    fun scanIncludesChatWithAdvancedTs() {
        val latest = mapOf("a" to m(100), "b" to m(250), "c" to m(300))
        val watermark = mapOf("a" to m(100), "b" to m(200), "c" to m(300))
        assertEquals(setOf("b"), chatsNeedingPageScan(latest, watermark))
    }

    @Test
    fun scanIncludesSameSecondMessageViaCount() {
        // The regression the composite watermark fixes: a message lands in the
        // SAME second as the last scanned one (⚡PAY PAY/DONE pair, call control
        // after a text). Timestamp is unchanged but the count grew.
        val latest = mapOf("a" to m(200, count = 6))
        val watermark = mapOf("a" to m(200, count = 5))
        assertEquals(setOf("a"), chatsNeedingPageScan(latest, watermark))
    }

    @Test
    fun scanSkipsSameSecondSameCount() {
        val latest = mapOf("a" to m(200, count = 5))
        val watermark = mapOf("a" to m(200, count = 5))
        assertEquals(emptySet(), chatsNeedingPageScan(latest, watermark))
    }

    @Test
    fun scanIncludesNeverSeenChat() {
        val latest = mapOf("a" to m(100), "new" to m(1))
        val watermark = mapOf("a" to m(100))
        // A brand-new chat (no watermark) must always be scanned once, even at
        // ts=0/1, so its first inbound ☎CALL / pay line is processed.
        assertEquals(setOf("new"), chatsNeedingPageScan(latest, watermark))
    }

    @Test
    fun scanTreatsZeroLatestAsScannableWhenUnseen() {
        val latest = mapOf("empty" to m(0, count = 0))
        val watermark = emptyMap<String, ScanMark>()
        assertEquals(setOf("empty"), chatsNeedingPageScan(latest, watermark))
    }

    @Test
    fun scanDoesNotRegressOnLowerLatest() {
        // A summary that somehow reports an older ts than the watermark must not
        // re-trigger a scan (idempotent watermark).
        val latest = mapOf("a" to m(50))
        val watermark = mapOf("a" to m(100))
        assertEquals(emptySet(), chatsNeedingPageScan(latest, watermark))
    }

    @Test
    fun stagedConversationChangePageIsConsumedEvenAtEqualWatermark() {
        val latest = mapOf("chat" to m(200, count = 6))
        val watermark = mapOf("chat" to m(200, count = 6))

        assertEquals(
            setOf("chat"),
            chatsNeedingPageScan(latest, watermark, stagedPageChatIds = setOf("chat")),
        )
    }

    // ── stable-ID notification selection over the bounded changed page ──

    private fun msg(
        id: String,
        secs: Long,
        mine: Boolean = false,
        sender: String = "peer",
    ) = SonarMsg(id, sender, id, mine, secs)

    @Test
    fun notifiesForSecondIncomingMessageInSameSecond() {
        val candidate = newestUnseenIncoming(
            messages = listOf(msg("first", 200), msg("second", 200)),
            seenMessageIds = setOf("first"),
            previousLatestSecs = 200,
            isOpen = false,
        )
        assertEquals("second", candidate?.id)
    }

    @Test
    fun oldBackfillDoesNotRenotifyCachedLatest() {
        val candidate = newestUnseenIncoming(
            messages = listOf(msg("old-backfill", 100), msg("latest", 200)),
            seenMessageIds = setOf("latest"),
            previousLatestSecs = 200,
            isOpen = false,
        )
        assertEquals(null, candidate)
    }

    @Test
    fun incomingBeforeOwnLatestStillNotifies() {
        val candidate = newestUnseenIncoming(
            messages = listOf(msg("incoming", 200), msg("mine", 200, mine = true)),
            seenMessageIds = emptySet(),
            previousLatestSecs = 100,
            isOpen = false,
        )
        assertEquals("incoming", candidate?.id)
    }

    @Test
    fun incomingBeforeBlockedLatestStillNotifies() {
        val candidate = newestUnseenIncoming(
            messages = listOf(
                msg("allowed", 200, sender = "friend"),
                msg("blocked", 201, sender = "blocked-peer"),
            ),
            seenMessageIds = emptySet(),
            previousLatestSecs = 100,
            isOpen = false,
            allowsMessage = { it.senderNpub != "blocked-peer" },
        )
        assertEquals("allowed", candidate?.id)
    }

    @Test
    fun seedPassAndOpenChatDoNotNotify() {
        val messages = listOf(msg("incoming", 200))
        assertEquals(
            null,
            newestUnseenIncoming(messages, emptySet(), previousLatestSecs = null, isOpen = false),
        )
        assertEquals(
            null,
            newestUnseenIncoming(messages, emptySet(), previousLatestSecs = 100, isOpen = true),
        )
    }

    @Test
    fun firstMessageAfterEmptyChatSeedNotifies() {
        val candidate = newestUnseenIncoming(
            messages = listOf(msg("first", 200)),
            seenMessageIds = emptySet(),
            previousLatestSecs = 0,
            isOpen = false,
        )
        assertEquals("first", candidate?.id)
    }

    @Test
    fun seenAndOwnMessagesDoNotNotify() {
        assertEquals(
            null,
            newestUnseenIncoming(
                messages = listOf(msg("seen", 200), msg("mine", 201, mine = true)),
                seenMessageIds = setOf("seen"),
                previousLatestSecs = 100,
                isOpen = false,
            ),
        )
    }

    // ── VisibleChatsKey: equal inputs ⇒ equal key (cache hit), any change ⇒ miss ──

    private fun key(
        chatsIdentity: Int = 1,
        folded: Set<String> = setOf("g1"),
        pendingChats: Map<String, String> = mapOf("p1" to "npub1"),
        pendingGroups: Set<String> = setOf("pg1"),
        social: Int = 7,
        snapshot: Int = 3,
        npub: String = "me",
        hold: Int = 0,
    ) = VisibleChatsKey(chatsIdentity, folded, pendingChats, pendingGroups, social, snapshot, npub, hold)

    @Test
    fun identicalKeysAreEqual() {
        assertEquals(key(), key())
    }

    @Test
    fun chatsIdentityChangeInvalidates() {
        assertFalse(key(chatsIdentity = 1) == key(chatsIdentity = 2))
    }

    @Test
    fun foldedChangeInvalidates() {
        assertFalse(key(folded = setOf("g1")) == key(folded = setOf("g1", "g2")))
    }

    @Test
    fun pendingChatsChangeInvalidates() {
        assertFalse(key(pendingChats = mapOf("p1" to "a")) == key(pendingChats = mapOf("p1" to "b")))
    }

    @Test
    fun pendingGroupsChangeInvalidates() {
        assertFalse(key(pendingGroups = setOf("pg1")) == key(pendingGroups = emptySet()))
    }

    @Test
    fun socialVersionChangeInvalidates() {
        assertFalse(key(social = 7) == key(social = 8))
    }

    @Test
    fun snapshotVersionChangeInvalidates() {
        assertFalse(key(snapshot = 3) == key(snapshot = 4))
    }

    @Test
    fun holdVersionChangeInvalidates() {
        assertFalse(key(hold = 0) == key(hold = 1))
    }

    @Test
    fun ownNpubChangeInvalidates() {
        assertFalse(key(npub = "me") == key(npub = "someoneElse"))
    }
}
