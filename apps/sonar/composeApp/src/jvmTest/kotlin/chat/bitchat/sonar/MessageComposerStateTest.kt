package chat.bitchat.sonar

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/**
 * The composer's own text state — what the field shows and when it adopts the
 * caller's draft. It does **not** decide what a send commits; that is
 * `currentDraft`. See R-022.
 */
class MessageComposerStateTest {
    @Test
    fun selectionOnlyMovesDoNotWakeTheStore() {
        val state = MessageComposerState("hello")

        val moved = state.onEdited(TextFieldValue("hello", TextRange(2)))

        assertFalse(moved)
        assertEquals(TextRange(2), state.field.selection)
    }

    @Test
    fun adoptPutsTheCaretAtTheEnd() {
        val state = MessageComposerState("/f")

        state.adopt("/fav ")

        assertEquals("/fav ", state.field.text)
        assertEquals(TextRange(5), state.field.selection)
    }

    /**
     * Same composable slot, different conversation: the field must take the new
     * chat's draft rather than keep the previous one.
     */
    @Test
    fun adoptTakesAnotherConversationsDraft() {
        val state = MessageComposerState("for alice")

        state.adopt("for bob")

        assertEquals("for bob", state.field.text)
        assertEquals("for bob", state.pushed)
    }
}
