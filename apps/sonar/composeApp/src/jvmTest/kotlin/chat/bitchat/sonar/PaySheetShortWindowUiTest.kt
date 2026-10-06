package chat.bitchat.sonar

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertIsNotFocused
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.unit.dp
import chat.bitchat.sonar.ui.SonarTheme
import kotlin.test.Test

/**
 * Opened from a chat whose composer still held the soft keyboard, the pay sheet
 * got only the space above the keyboard (the app root is `imePadding()`, about
 * 500 dp left on a phone), and its Column squeezed the last children: the Send
 * button shrank to a bare colored bar with no label, and the footer vanished.
 */
@OptIn(ExperimentalTestApi::class)
class PaySheetShortWindowUiTest {

    @Test
    fun theSendButtonKeepsItsLabelWhenTheSheetIsTallerThanItsWindow() = runComposeUiTest {
        setContent {
            SonarTheme(dark = true) {
                // About what a phone leaves above an open keyboard.
                Box(Modifier.size(width = 400.dp, height = 420.dp)) {
                    PaySheet(
                        peerName = "Cody",
                        balanceSats = 2_780,
                        mesh = false,
                        fiatOf = { null },
                        onSend = { _, _ -> },
                        onClose = {},
                        feeQuote = { 0L },
                    )
                }
            }
        }
        // Unmerged: the clickable scrim merges every text in the sheet into
        // one node the size of the window, which would always "fit".
        // Before the fix the label measured 0 dp tall below a ~575 dp window.
        val send = onNodeWithText("Send over Lightning", useUnmergedTree = true)
        send.assertHeightIsAtLeast(18.dp)
        send.performScrollTo().assertIsDisplayed()
        onNodeWithText("Payment goes straight to Cody's wallet", substring = true, useUnmergedTree = true)
            .assertHeightIsAtLeast(12.dp)
            .performScrollTo()
            .assertIsDisplayed()
    }

    @Test
    fun openingTheSheetTakesTheKeyboardFromTheComposer() = runComposeUiTest {
        var open by mutableStateOf(false)
        val composer = FocusRequester()
        setContent {
            SonarTheme(dark = true) {
                Box(Modifier.size(width = 400.dp, height = 800.dp)) {
                    BasicTextField(
                        value = "",
                        onValueChange = {},
                        modifier = Modifier.testTag("composer").focusRequester(composer),
                    )
                    if (open) {
                        PaySheet(
                            peerName = "Cody",
                            balanceSats = 2_780,
                            mesh = false,
                            fiatOf = { null },
                            onSend = { _, _ -> },
                            onClose = {},
                        )
                    }
                }
            }
        }
        runOnIdle { composer.requestFocus() }
        onNodeWithTag("composer").assertIsFocused()

        open = true
        waitForIdle()

        // The sheet has its own keypad: a focused composer only keeps the
        // keyboard up and the sheet squeezed above it.
        onNodeWithTag("composer").assertIsNotFocused()
    }
}
