package chat.bitchat.sonar

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.runComposeUiTest
import chat.bitchat.sonar.ui.SonarTheme
import kotlin.test.Test

/**
 * QA-A16: "Around you" latched the first tier whose presence arrived (region)
 * and kept naming it after the city lit up. The card follows the data until the
 * user picks a tier, and a pick sticks.
 */
@OptIn(ExperimentalTestApi::class)
class HereCardSelectionUiTest {

    private fun ladder(cityCount: Int, regionCount: Int) = listOf(
        HereItem("mesh", "Bluetooth mesh", "Mesh", "Mesh", 0),
        HereItem("9q8", "Ukiah", "city", "City", cityCount),
        HereItem("9q", "United States", "region", "Region", regionCount),
    )

    @Test
    fun cardFollowsPresenceUntilTheUserPicksATier() = runComposeUiTest {
        var items by mutableStateOf(ladder(cityCount = 0, regionCount = 1))
        setContent { SonarTheme(dark = true) { HereCard(items) {} } }

        onNodeWithText("United States").assertExists()

        // Same ladder size, newer presence: the more precise tier wins.
        items = ladder(cityCount = 1, regionCount = 1)
        waitForIdle()
        onNodeWithText("Ukiah").assertExists()

        // An explicit pick survives later presence updates.
        onNodeWithText("Region").performClick()
        waitForIdle()
        items = ladder(cityCount = 2, regionCount = 1)
        waitForIdle()
        onNodeWithText("United States").assertExists()
    }
}
