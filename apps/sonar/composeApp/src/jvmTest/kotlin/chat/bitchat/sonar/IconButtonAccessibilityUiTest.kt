package chat.bitchat.sonar

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.text.TextStyle
import chat.bitchat.sonar.ui.SNIconButton
import chat.bitchat.sonar.ui.SNIconName
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * QA-A9: icon-only controls had no content description, so TalkBack announced
 * "button" (or nothing) for back, call, and composer controls. Every back
 * button goes through [SNIconButton], so the default label lives there.
 */
@OptIn(ExperimentalTestApi::class)
class IconButtonAccessibilityUiTest {

    @Test
    fun backIconButtonIsAnnouncedAsBack() = runComposeUiTest {
        var clicks = 0
        setContent { SNIconButton(SNIconName.Back) { clicks += 1 } }

        onNodeWithContentDescription("Back").assertHasClickAction().performClick()
        runOnIdle { assertEquals(1, clicks) }
    }

    @Test
    fun explicitLabelWinsForOtherIcons() = runComposeUiTest {
        setContent { SNIconButton(SNIconName.Phone, contentDescription = "Voice call") {} }

        onNodeWithContentDescription("Voice call").assertHasClickAction()
    }

    @Test
    fun composerFieldIsAnnouncedByItsPlaceholder() = runComposeUiTest {
        // QA-A21: the placeholder is drawn beside the field, so the field
        // itself was an anonymous edit box to TalkBack and uiautomator.
        setContent {
            MessageComposerTextField(
                value = "",
                onValueChange = {},
                textStyle = TextStyle(),
                cursorBrush = SolidColor(Color.Black),
                label = "Message Alice",
            )
        }

        onNodeWithContentDescription("Message Alice").assertExists()
    }
}
