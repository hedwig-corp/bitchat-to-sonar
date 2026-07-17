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

@OptIn(ExperimentalTestApi::class)
class MessageComposerFieldUiTest {
    @Test
    fun returnKeyInsertsNewlineInSharedComposer() = runComposeUiTest {
        var text by mutableStateOf("")
        setContent {
            MessageComposerTextField(
                value = text,
                onValueChange = { text = it },
                textStyle = TextStyle(fontSize = 16.sp),
                cursorBrush = SolidColor(androidx.compose.ui.graphics.Color.Black),
                modifier = Modifier.testTag("message-composer"),
            )
        }

        onNodeWithTag("message-composer").performClick()
        onNodeWithTag("message-composer").performTextInput("first line")
        onNodeWithTag("message-composer").performKeyInput { pressKey(Key.Enter) }
        onNodeWithTag("message-composer").performTextInput("second line")

        runOnIdle {
            assertEquals("first line\nsecond line", text)
            assertEquals(ImeAction.None, messageComposerKeyboardOptions.imeAction)
        }
    }
}
