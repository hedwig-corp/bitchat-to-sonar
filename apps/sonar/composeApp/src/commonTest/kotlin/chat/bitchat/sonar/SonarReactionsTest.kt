package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** ⚡REACT codec + fold semantics — must stay byte-identical to the iOS
 *  `SonarReactionMessage` validator so the platforms never diverge on a
 *  peer-crafted line. */
class SonarReactionsTest {

    private fun msg(
        id: String,
        content: String,
        mine: Boolean = false,
        sender: String = if (mine) "" else "peer",
        state: String? = null,
        reactions: List<SonarReaction> = emptyList(),
    ) = SonarMsg(
        id = id,
        senderNpub = sender,
        content = content,
        mine = mine,
        tsSecs = 1L,
        state = state,
        reactions = reactions,
    )

    // ── Codec ──────────────────────────────────────────────────────────

    @Test
    fun decodeRoundTripsAddAndRemove() {
        val add = ReactionLine("a1b2c3d4", "👍", add = true)
        assertEquals(add, ReactionLine.decode(add.encoded()))
        val remove = ReactionLine("A1B2-C3D4", "❤️", add = false)
        assertEquals(remove, ReactionLine.decode(remove.encoded()))
    }

    @Test
    fun decodeRejectsMalformedLines() {
        assertNull(ReactionLine.decode("hello"))
        assertNull(ReactionLine.decode("⚡REACT|2|abc|👍|add"), "unknown version")
        assertNull(ReactionLine.decode("⚡REACT|1|abc|👍|maybe"), "unknown verb")
        assertNull(ReactionLine.decode("⚡REACT|1|abc|👍"), "missing field")
        assertNull(ReactionLine.decode("⚡REACT|1|abc|👍|add|extra"), "extra field")
        assertNull(ReactionLine.decode("⚡REACT|1||👍|add"), "empty target")
        assertNull(ReactionLine.decode("⚡REACT|1|abc||remove"), "empty emoji (both verbs)")
        assertNull(ReactionLine.decode("⚡REACT|1|echo-a1b2|👍|add"), "non-hex target (pending echo)")
        assertNull(ReactionLine.decode("⚡REACT|1|٩٩٩|👍|add"), "unicode digits (iOS rejects)")
        assertNull(ReactionLine.decode("⚡REACT|1|${"a".repeat(65)}|👍|add"), "target too long")
        assertNull(ReactionLine.decode("⚡REACT|1|abc|this is not an emoji at all!!|add"), "emoji too long")
    }

    @Test
    fun isReactionLineIsACheapPrefixCheck() {
        assertTrue(ReactionLine.isReactionLine("⚡REACT|1|abc|👍|add"))
        assertTrue(ReactionLine.isReactionLine("⚡REACT|garbage"), "prefilter, not validation")
        assertFalse(ReactionLine.isReactionLine("⚡PAY|1|abc|21"))
    }

    // ── Fold ───────────────────────────────────────────────────────────

    @Test
    fun foldAggregatesAndHidesLines() {
        val out = foldMeshReactions(
            listOf(
                msg("aa11", "hello"),
                msg("r1", ReactionLine("aa11", "👍", true).encoded(), mine = true),
                msg("r2", ReactionLine("aa11", "👍", true).encoded(), sender = "peer"),
            )
        )
        assertEquals(1, out.size, "reaction lines never render as rows")
        assertEquals(listOf(SonarReaction("👍", 2, mine = true)), out[0].reactions)
    }

    @Test
    fun foldIsLastWriteWinsPerSenderAndReplaceIsOneSlot() {
        val out = foldMeshReactions(
            listOf(
                msg("aa11", "hello"),
                msg("r1", ReactionLine("aa11", "👍", true).encoded(), sender = "peer"),
                msg("r2", ReactionLine("aa11", "❤️", true).encoded(), sender = "peer"),
            )
        )
        assertEquals(listOf(SonarReaction("❤️", 1, mine = false)), out[0].reactions)
    }

    @Test
    fun staleRemoveNeverWipesANewerReplacement() {
        val out = foldMeshReactions(
            listOf(
                msg("aa11", "hello"),
                msg("r1", ReactionLine("aa11", "❤️", true).encoded(), sender = "peer"),
                // Duplicated/reordered remove of the OLD emoji arrives late:
                msg("r2", ReactionLine("aa11", "👍", false).encoded(), sender = "peer"),
            )
        )
        assertEquals(listOf(SonarReaction("❤️", 1, mine = false)), out[0].reactions)
    }

    @Test
    fun removeClearsOwnEmoji() {
        val out = foldMeshReactions(
            listOf(
                msg("aa11", "hello"),
                msg("r1", ReactionLine("aa11", "👍", true).encoded(), mine = true),
                msg("r2", ReactionLine("aa11", "👍", false).encoded(), mine = true),
            )
        )
        assertTrue(out[0].reactions.isEmpty())
    }

    @Test
    fun failedLocalSendDoesNotFoldButIsStillHidden() {
        val out = foldMeshReactions(
            listOf(
                msg("aa11", "hello"),
                msg("r1", ReactionLine("aa11", "👍", true).encoded(), mine = true, state = "failed"),
            )
        )
        assertEquals(1, out.size, "failed line still never renders as a row")
        assertTrue(out[0].reactions.isEmpty(), "a chip for an undelivered reaction would lie")
    }

    @Test
    fun foldMergesWithCoreProvidedAggregates() {
        val out = foldMeshReactions(
            listOf(
                msg("aa11", "hello", reactions = listOf(SonarReaction("👍", 1, mine = false))),
                msg("r1", ReactionLine("aa11", "👍", true).encoded(), mine = true),
            )
        )
        assertEquals(listOf(SonarReaction("👍", 2, mine = true)), out[0].reactions)
    }

    @Test
    fun orphanReactionToUnknownTargetIsHiddenAndHarmless() {
        val out = foldMeshReactions(
            listOf(
                msg("aa11", "hello"),
                msg("r1", ReactionLine("dead", "👍", true).encoded(), sender = "peer"),
            )
        )
        assertEquals(1, out.size)
        assertTrue(out[0].reactions.isEmpty())
    }

    @Test
    fun reactionFreeTranscriptIsReturnedUntouched() {
        val source = listOf(msg("aa11", "hello"), msg("bb22", "world"))
        assertEquals(source, foldMeshReactions(source))
    }
}
