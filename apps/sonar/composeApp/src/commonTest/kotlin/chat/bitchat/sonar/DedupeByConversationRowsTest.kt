package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals

/** [dedupeByConversationRows]: core's fold wins; the local fold covers only
 *  chats core has not listed yet (a restored snapshot before the store opens). */
class DedupeByConversationRowsTest {
    private val me = "npub1me"
    private val a1 = SonarChat("a1", "", listOf(me, "npub1sara"))
    private val a2 = SonarChat("a2", "", listOf(me, "npub1sara"))
    private val b1 = SonarChat("b1", "", listOf(me, "npub1luca"))
    private val b2 = SonarChat("b2", "", listOf(me, "npub1luca"))

    @Test
    fun coreSetPicksTheRowGroupEvenWhenLocalRecencyDisagrees() {
        val kept = dedupeByConversationRows(
            chats = listOf(a1, a2),
            ownNpub = me,
            latestSecs = { if (it == "a1") 900L else 100L },
            groupIdsByGroup = mapOf("a1" to listOf("a2", "a1"), "a2" to listOf("a2", "a1")),
        )
        assertEquals(listOf("a2"), kept.map { it.id })
    }

    @Test
    fun theNextGroupOfTheSetStandsInWhenTheRowGroupIsFilteredOut() {
        // The row group is gone from the input (folded into a mesh row, held,
        // blocked): the person still gets exactly one row.
        val kept = dedupeByConversationRows(
            chats = listOf(a1),
            ownNpub = me,
            latestSecs = { 0L },
            groupIdsByGroup = mapOf("a1" to listOf("a2", "a1"), "a2" to listOf("a2", "a1")),
        )
        assertEquals(listOf("a1"), kept.map { it.id })
    }

    @Test
    fun chatsCoreHasNotListedFallBackToTheLocalFold() {
        val kept = dedupeByConversationRows(
            chats = listOf(a1, a2, b1, b2),
            ownNpub = me,
            latestSecs = { if (it == "b2") 900L else 100L },
            groupIdsByGroup = mapOf("a1" to listOf("a1", "a2"), "a2" to listOf("a1", "a2")),
        )
        assertEquals(listOf("a1", "b2"), kept.map { it.id })
    }

    @Test
    fun noCoreRowsIsExactlyTheLocalFold() {
        val chats = listOf(a1, a2, b1)
        assertEquals(
            dedupeDirectMarmotChats(chats, me) { 0L },
            dedupeByConversationRows(chats, me, { 0L }, emptyMap()),
        )
    }
}
