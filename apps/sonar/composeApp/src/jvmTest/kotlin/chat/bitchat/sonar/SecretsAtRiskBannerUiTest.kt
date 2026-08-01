package chat.bitchat.sonar

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.runComposeUiTest
import chat.bitchat.sonar.desktop.SecretsAtRiskBanner
import chat.bitchat.sonar.ui.SonarTheme
import kotlin.test.Test

/**
 * The warning exists to be READ. Everything else in this change is verifiable
 * from storage state, but "the user is told" is only true if the text renders,
 * and nothing else in the suite covers that.
 */
@OptIn(ExperimentalTestApi::class)
class SecretsAtRiskBannerUiTest {

    @Test
    fun theBannerShowsTheHeadlineAndTheReason() = runComposeUiTest {
        val reason = "secret-tool is not installed (install the libsecret-tools package)"
        setContent {
            SonarTheme(dark = true) { SecretsAtRiskBanner(reason) }
        }
        // The headline tells the user something is wrong at a glance.
        onNodeWithText("Account key unprotected").assertIsDisplayed()
        // The reason tells them what to do about it.
        onNodeWithText(reason).assertIsDisplayed()
    }
}
