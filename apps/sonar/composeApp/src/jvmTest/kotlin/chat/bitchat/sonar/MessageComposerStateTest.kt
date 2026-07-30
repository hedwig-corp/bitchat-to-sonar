package chat.bitchat.sonar

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The composer's own text state.
 *
 * Pinned here rather than through the UI because the thing that makes it
 * necessary — several input events reaching the field before Compose gets a
 * frame — is what the JVM harness cannot stage: `runComposeUiTest` idles, and so
 * recomposes, between injected events. See R-022.
 */
class MessageComposerStateTest {
    @Test
    fun committedBlanksTheFieldImmediately() {
        val state = MessageComposerState("hi")

        state.committed()

        assertEquals("", state.field.text)
        assertEquals("", state.pushed)
    }

    /**
     * The point of blanking: a keystroke still queued behind the send edits an
     * empty field, so the sent message cannot come back glued to the next one.
     */
    @Test
    fun aKeystrokeAfterCommitStartsFromEmpty() {
        val state = MessageComposerState("hi")
        state.committed()

        // What BasicTextField produces when "!" is typed into the blanked field.
        val moved = state.onEdited(TextFieldValue("!", TextRange(1)))

        assertTrue(moved)
        assertEquals("!", state.pushed)
    }

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
