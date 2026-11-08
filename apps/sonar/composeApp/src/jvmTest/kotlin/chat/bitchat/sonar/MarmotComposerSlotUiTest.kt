package chat.bitchat.sonar

import androidx.compose.material3.Text
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.runComposeUiTest
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The composer slot ChatScreen's `ChatBottomChrome` renders through: with every
 * other member on Marmot v2 the composer is not composed at all (no text, media,
 * sticker or voice path), and the panel's button opens the store.
 */
@OptIn(ExperimentalTestApi::class)
class MarmotComposerSlotUiTest {
    @Test
    fun updateRequiredReplacesTheComposerAndLinksToTheStore() = runComposeUiTest {
        var updates = 0
        setContent {
            MarmotComposerSlot(
                composerGate = composerGateFor(
                    SonarMarmotChatGate(SonarMarmotChatGateState.Blocked, listOf("aa")),
                    sendsOverMesh = false,
                ),
                peerName = "Ana",
                onUpdate = { updates++ },
            ) {
                Text("COMPOSER")
            }
        }
        onNodeWithText("Ana can't read messages from this version of Sonar. Update the app to keep chatting").assertIsDisplayed()
        onNodeWithText("COMPOSER").assertDoesNotExist()
        onNodeWithText("Update Sonar").performClick()
        assertEquals(1, updates)
    }

    @Test
    fun anOpenGateKeepsTheComposer() = runComposeUiTest {
        setContent {
            MarmotComposerSlot(
                composerGate = composerGateFor(null, sendsOverMesh = false),
                peerName = "Ana",
                onUpdate = {},
            ) {
                Text("COMPOSER")
            }
        }
        onNodeWithText("COMPOSER").assertIsDisplayed()
        onNodeWithText("Update Sonar").assertDoesNotExist()
    }
}
