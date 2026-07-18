package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NoteToSelfTest {
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
}
