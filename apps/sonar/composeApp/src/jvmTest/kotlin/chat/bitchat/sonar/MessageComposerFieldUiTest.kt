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
                modifier = Modifier.testTag("message-composer"),
                onSend = {
                    sent = text
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
                modifier = Modifier.testTag("message-composer"),
                onSend = {
                    sent = text
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

    @Test
    fun returnKeyInsertsNewlineWhenDesktopSendDisabled() = runComposeUiTest {
        var text by mutableStateOf("")
        setContent {
            MessageComposerTextField(
                value = text,
                onValueChange = { text = it },
                textStyle = TextStyle(fontSize = 16.sp),
                cursorBrush = SolidColor(androidx.compose.ui.graphics.Color.Black),
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
