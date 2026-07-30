package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The composer's answer to "what text would a send commit right now?".
 *
 * These pin the state machine directly because the thing that makes it
 * necessary — several input events reaching the field before Compose gets a
 * frame — is exactly what the JVM UI harness cannot stage: it idles (and so
 * recomposes) between injected events. See R-022.
 */
class ComposerLiveTextTest {
    @Test
    fun keystrokesAreVisibleBeforeTheCallerRecomposes() {
        val live = ComposerLiveText("")

        live.onFieldValue("hello")
        live.onFieldValue("hello desktop")

        assertEquals("hello desktop", live.text)
    }

    @Test
    fun callerOwnedChangeWins() {
        val live = ComposerLiveText("")
        live.onFieldValue("/he")

        // Slash-hint completion: the caller rewrote the draft itself.
        live.onHoistedValue("/help ")

        assertEquals("/help ", live.text)
    }

    /**
     * The contract this design rests on: a differing hoisted value is treated as
     * the caller's, so a caller that forwards [onFieldValue] late would drag the
     * field back to older text. Every call site writes the draft synchronously
     * in `onValueChange`, which is what keeps the hoisted value from ever
     * trailing the field. Pinned so a future debounced/async draft store shows
     * up here instead of as truncated messages.
     */
    @Test
    fun aLateHoistedValueWouldWin() {
        val live = ComposerLiveText("")
        live.onFieldValue("h")
        live.onFieldValue("hi")

        live.onHoistedValue("h")

        assertEquals("h", live.text)
    }

    @Test
    fun sendDoesNotHandOutTheSameTextTwice() {
        val live = ComposerLiveText("")
        live.onFieldValue("send me once")

        val first = live.text
        live.onSent()
        val second = live.text

        assertEquals("send me once", first)
        assertEquals("", second)
    }

    @Test
    fun draftTheCallerKeptComesBackAfterSend() {
        val live = ComposerLiveText("")
        live.onFieldValue("rejected send")
        live.onSent()

        // The caller did not clear the draft, so the next composition restores it.
        live.onHoistedValue("rejected send")

        assertEquals("rejected send", live.text)
    }

    @Test
    fun clearedDraftStaysCleared() {
        val live = ComposerLiveText("")
        live.onFieldValue("gone")
        live.onSent()

        live.onHoistedValue("")

        assertEquals("", live.text)
    }

    @Test
    fun switchingChatsAdoptsTheNewConversationsDraft() {
        val live = ComposerLiveText("")
        live.onFieldValue("for alice")

        // Same composable slot, different conversation.
        live.onHoistedValue("for bob")

        assertEquals("for bob", live.text)
    }
}
