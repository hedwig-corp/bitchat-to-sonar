package chat.bitchat.sonar

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.runComposeUiTest
import chat.bitchat.sonar.ui.SNIconName
import chat.bitchat.sonar.ui.SNSettingsRow
import kotlin.test.Test

/**
 * #607 QA: no settings toggle exposed its state — uiautomator listed "Share
 * local time", "App lock" and "Read receipts" as checkable=false whatever the
 * switch showed, so TalkBack could not say whether a setting was on. A toggle
 * row must be one switch node that reports on/off; a plain row stays a button.
 */
@OptIn(ExperimentalTestApi::class)
class SettingsToggleSemanticsUiTest {

    @Test
    fun toggleRowReportsItsStateAndFlipsOnTap() = runComposeUiTest {
        var on by mutableStateOf(false)
        setContent {
            SNSettingsRow(icon = SNIconName.Globe, label = "Share local time", toggle = on) { on = !on }
        }
        val row = onNode(isToggleable() and hasText("Share local time", substring = true))
        row.assertIsOff().performClick()
        row.assertIsOn()
    }

    @Test
    fun plainRowIsNotAToggle() = runComposeUiTest {
        setContent { SNSettingsRow(icon = SNIconName.Globe, label = "Verified people") {} }
        onNodeWithText("Verified people").assertHasClickAction()
        onNode(isToggleable()).assertDoesNotExist()
    }
}
