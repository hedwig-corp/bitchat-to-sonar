package chat.bitchat.sonar

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.sp
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(ExperimentalTestApi::class)
class MessageComposerFieldUiTest {
    @Test
    fun returnKeySendsDraftOnDesktopComposer() = runComposeUiTest {
        var text by mutableStateOf("")
        var sent: String? = null
        setContent {
            MessageComposerTextField(
                value = text,
                onValueChange = { text = it },
                textStyle = TextStyle(fontSize = 16.sp),
                cursorBrush = SolidColor(androidx.compose.ui.graphics.Color.Black),
                currentDraft = { text },
                modifier = Modifier.testTag("message-composer"),
                onSend = { typed ->
                    sent = typed
                    text = ""
                },
            )
        }

        onNodeWithTag("message-composer").performClick()
        onNodeWithTag("message-composer").performTextInput("hello desktop")
        onNodeWithTag("message-composer").performKeyInput { pressKey(Key.Enter) }

        runOnIdle {
            assertTrue(messageComposerEnterSends)
            assertEquals("hello desktop", sent)
            assertEquals("", text)
            assertEquals(ImeAction.None, messageComposerKeyboardOptions.imeAction)
        }
    }

    @Test
    fun numPadEnterAlsoSendsDraftOnDesktopComposer() = runComposeUiTest {
        var text by mutableStateOf("")
        var sent: String? = null
        setContent {
            MessageComposerTextField(
                value = text,
                onValueChange = { text = it },
                textStyle = TextStyle(fontSize = 16.sp),
                cursorBrush = SolidColor(androidx.compose.ui.graphics.Color.Black),
                currentDraft = { text },
                modifier = Modifier.testTag("message-composer"),
                onSend = { typed ->
                    sent = typed
                    text = ""
                },
            )
        }

        onNodeWithTag("message-composer").performClick()
        onNodeWithTag("message-composer").performTextInput("from numpad")
        onNodeWithTag("message-composer").performKeyInput { pressKey(Key.NumPadEnter) }

        runOnIdle {
            assertEquals("from numpad", sent)
            assertEquals("", text)
        }
    }

    /**
     * The truncation bug. The call site never recomposes, so the `value` the
     * field holds stays empty while the store takes every keystroke — the
     * divergence a stalled frame produces. In production the composed value is
     * usually a non-empty prefix and only the tail is lost; the mechanism is the
     * same one either way (the handler reading `value` instead of the store),
     * and an empty composed value is simply the cleanest way to stage it here —
     * seeding a prefix puts the caret mid-text on `performClick`, which tests
     * the harness rather than the field.
     */
    @Test
    fun returnKeySendsTheStoredDraftNotTheComposedOne() = runComposeUiTest {
        val composed = ""
        var store = ""
        var sent: String? = null
        setContent {
            MessageComposerTextField(
                value = composed,
                onValueChange = { store = it },
                textStyle = TextStyle(fontSize = 16.sp),
                cursorBrush = SolidColor(androidx.compose.ui.graphics.Color.Black),
                currentDraft = { store },
                modifier = Modifier.testTag("message-composer"),
                onSend = { typed -> if (typed.isNotBlank()) sent = typed },
            )
        }

        onNodeWithTag("message-composer").performClick()
        // The burst, none of which reached a composition.
        onNodeWithTag("message-composer").performTextInput("hello desktop")
        onNodeWithTag("message-composer").performKeyInput { pressKey(Key.Enter) }

        runOnIdle {
            assertEquals("hello desktop", store)
            assertEquals("hello desktop", sent)
        }
    }

    /**
     * Something else committed the draft and cleared it — the send button, or an
     * earlier Enter from the same input batch. Enter must not send it again just
     * because this composition still shows the old text.
     */
    @Test
    fun returnKeyDoesNotResendADraftAlreadyCommittedElsewhere() = runComposeUiTest {
        val composed = "already sent"
        var store = "already sent"
        var sent: String? = null
        setContent {
            MessageComposerTextField(
                value = composed,
                onValueChange = { store = it },
                textStyle = TextStyle(fontSize = 16.sp),
                cursorBrush = SolidColor(androidx.compose.ui.graphics.Color.Black),
                currentDraft = { store },
                modifier = Modifier.testTag("message-composer"),
                onSend = { typed -> if (typed.isNotBlank()) sent = typed },
            )
        }

        onNodeWithTag("message-composer").performClick()
        // The button's click handler ran and cleared the stored draft; this
        // composition has not caught up.
        store = ""
        onNodeWithTag("message-composer").performKeyInput { pressKey(Key.Enter) }

        runOnIdle { assertNull(sent) }
    }

    /**
     * The caller replaced the draft without the field producing the text — a
     * slash-hint completion, or the emoji tray appending. Enter must send what
     * the caller stored, not the text the field last showed.
     */
    @Test
    fun returnKeySendsACompletionTheCallerApplied() = runComposeUiTest {
        val composed = "/f"
        var store = "/f"
        var sent: String? = null
        setContent {
            MessageComposerTextField(
                value = composed,
                onValueChange = { store = it },
                textStyle = TextStyle(fontSize = 16.sp),
                cursorBrush = SolidColor(androidx.compose.ui.graphics.Color.Black),
                currentDraft = { store },
                modifier = Modifier.testTag("message-composer"),
                onSend = { typed -> if (typed.isNotBlank()) sent = typed },
            )
        }

        onNodeWithTag("message-composer").performClick()
        // The hint was clicked; this composition still carries "/f".
        store = "/fav "
        onNodeWithTag("message-composer").performKeyInput { pressKey(Key.Enter) }

        runOnIdle { assertEquals("/fav ", sent) }
    }

    @Test
    fun returnKeyInsertsNewlineWhenDesktopSendDisabled() = runComposeUiTest {
        var text by mutableStateOf("")
        setContent {
            MessageComposerTextField(
                value = text,
                onValueChange = { text = it },
                textStyle = TextStyle(fontSize = 16.sp),
                cursorBrush = SolidColor(androidx.compose.ui.graphics.Color.Black),
                currentDraft = { text },
                modifier = Modifier.testTag("message-composer"),
                onSend = null,
            )
        }

        onNodeWithTag("message-composer").performClick()
        onNodeWithTag("message-composer").performTextInput("first line")
        onNodeWithTag("message-composer").performKeyInput { pressKey(Key.Enter) }
        onNodeWithTag("message-composer").performTextInput("second line")

        runOnIdle {
            assertEquals("first line\nsecond line", text)
        }
    }
}
