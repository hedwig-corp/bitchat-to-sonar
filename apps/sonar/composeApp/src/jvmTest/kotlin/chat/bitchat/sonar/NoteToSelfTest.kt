package chat.bitchat.sonar

import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job

class NoteToSelfTest {
    private val other = SonarChat(id = "giulia-group", name = "Giulia", members = listOf("npub1her", "npub1me"))

    private fun state(): SonarAppState {
        DesktopEnv.useTestRoot(createTempDirectory("sonar-note-to-self").toFile())
        return SonarAppState(CoroutineScope(Job()))
    }

    @AfterTest
    fun restore() = DesktopEnv.useTestRoot(null)

    // Pins the Messages list both the phone home screen and the desktop
    // sidebar render, not only the pin helper.
    @Test
    fun noteToSelfTopsTheMessagesListEvenWhenAnotherChatIsNewer() {
        val s = state()
        s.seedNoteToSelfForTest(
            noteId = "n0te",
            others = listOf(other),
            unread = emptyMap(),
            latestSecs = mapOf(other.id to 1_700_000_000L),
        )
        // The premise: by recency alone the newer chat would come first.
        val byRecency = mergeHomeMessageRows(emptyList(), s.visibleChats) { s.marmotRow(it).tsSecs }
        assertEquals(other.id, (byRecency.first() as HomeMessageRow.Marmot).chat.id)

        val rows = s.homeMessageRows(emptyList(), s.visibleChats)
        assertEquals(listOf("n0te", other.id), rows.map { it.listKey })
    }

    @Test
    fun noteToSelfNeverShowsUnreadWhileOtherChatsStillDo() {
        val s = state()
        s.seedNoteToSelfForTest(
            noteId = "n0te",
            others = listOf(other),
            unread = mapOf("n0te" to 3L, other.id to 1L),
            latestSecs = emptyMap(),
        )
        assertFalse(s.marmotRow("n0te").unread, "your own notes are never unread")
        assertTrue(s.marmotRow(other.id).unread, "the unread count itself still works")
        assertEquals("Note to Self", s.marmotRow("n0te").title)
    }

    @Test
    fun pinNoteToSelfHomeRows_movesMarkedChatFirst() {
        val note = SonarChat(id = "abc", name = NOTE_TO_SELF_TITLE, members = listOf("npub1me"))
        val other = SonarChat(id = "def", name = "Giulia", members = listOf("npub1me", "npub1her"))
        val rows = listOf(
            HomeMessageRow.Marmot(other),
            HomeMessageRow.Marmot(note),
        )
        val pinned = pinNoteToSelfHomeRows(rows, noteToSelfGroupId = "abc")
        assertEquals("abc", (pinned.first() as HomeMessageRow.Marmot).chat.id)
        assertEquals(2, pinned.size)
    }

    @Test
    fun isNoteToSelfChatId_matchesPendingAndReal() {
        assertTrue(isNoteToSelfChatId(PENDING_NOTE_TO_SELF_ID, null))
        assertTrue(isNoteToSelfChatId("deadbeef", "deadbeef"))
        assertFalse(isNoteToSelfChatId("other", "deadbeef"))
    }

    @Test
    fun isNoteToSelfChat_ignoresTitleHeuristic() {
        val lookalike = SonarChat(id = "other", name = NOTE_TO_SELF_TITLE, members = listOf("npub1me"))
        assertFalse(isNoteToSelfChat(lookalike, noteToSelfGroupId = "deadbeef"))
        assertTrue(isNoteToSelfChat(lookalike.copy(id = "deadbeef"), noteToSelfGroupId = "deadbeef"))
    }
}
