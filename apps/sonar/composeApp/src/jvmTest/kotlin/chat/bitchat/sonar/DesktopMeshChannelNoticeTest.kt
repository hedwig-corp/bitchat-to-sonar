package chat.bitchat.sonar

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.runComposeUiTest
import chat.bitchat.sonar.screens.SonarChannelScreen
import chat.bitchat.sonar.ui.SonarTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The Mesh channel must not claim to work where it cannot.
 *
 * `sonar-ble` implements the peripheral/GATT-server role only for CoreBluetooth, so
 * off Apple platforms `run_peripheral()` returns an error, `MeshLink` never starts,
 * phones cannot discover the desktop and the desktop cannot receive mesh messages.
 * The radio still scans, so peers appear in the presence count — which is what made
 * this read as broken sync rather than an unimplemented transport. The channel
 * meanwhile invited the user to "Say hi".
 *
 * Rendered rather than asserted on the flag alone. A test that only checked
 * `meshMessagingSupported` would stay green with the whole notice deleted, which is
 * exactly how the call-button gate slipped through in #589.
 */
@OptIn(ExperimentalTestApi::class)
class DesktopMeshChannelNoticeTest {

    private fun state(): SonarAppState {
        DesktopEnv.useTestRoot(kotlin.io.path.createTempDirectory("sonar-meshui").toFile())
        return SonarAppState(CoroutineScope(Job()))
    }

    @AfterTest
    fun restore() {
        DesktopEnv.useTestRoot(null)
        MeshRadio.meshMessagingOverrideForTest = null
    }

    @Test
    fun theCapabilityIsAskedOfTheRadioRatherThanThePlatform() {
        // Before the BlueZ peripheral role existed this was "Linux is always
        // false". It is now a property of the adapter, so the notice must follow
        // the capability, which is what the rest of these tests drive.
        MeshRadio.meshMessagingOverrideForTest = false
        assertFalse(MeshRadio.meshMessagingSupported)
        MeshRadio.meshMessagingOverrideForTest = true
        assertTrue(MeshRadio.meshMessagingSupported)
    }

    @Test
    fun theMeshChannelSaysItCannotBeUsedHere() = runComposeUiTest {
        MeshRadio.meshMessagingOverrideForTest = false
        setContent {
            SonarTheme(dark = true) {
                SonarChannelScreen(state(), Screen.Channel("mesh"))
            }
        }
        onNodeWithText("Bluetooth mesh isn't available on this device").assertIsDisplayed()
        // Naming the limit is half of it; the other half is where to go instead,
        // since location channels do reach the same people from this machine.
        assertTrue(
            onAllNodesWithText("location channel", substring = true).fetchSemanticsNodes().isNotEmpty(),
            "the notice must point somewhere that works, not just say no",
        )
    }

    @Test
    fun theMeshChannelDoesNotOfferASendThatCannotLeaveTheDevice() = runComposeUiTest {
        MeshRadio.meshMessagingOverrideForTest = false
        setContent {
            SonarTheme(dark = true) {
                SonarChannelScreen(state(), Screen.Channel("mesh"))
            }
        }
        // The composer placeholder is the tell: its presence means a send button is
        // sitting there producing local echoes nobody will ever answer.
        // "Message Mesh", not "Message Bluetooth mesh": the composer placeholder
        // uses `name`, which is "Mesh" for this channel. Asserting the longer
        // string made this pass for the wrong reason, since it never existed.
        val composer = onAllNodesWithText("Message Mesh").fetchSemanticsNodes()
        assertFalse(
            composer.isNotEmpty(),
            "a channel that cannot deliver must not present a composer",
        )
        onNodeWithText("Sending is unavailable on Bluetooth mesh here.").assertIsDisplayed()
    }

    @Test
    fun aWorkingMeshRadioGetsANormalChannel() = runComposeUiTest {
        // The other half, untestable before the peripheral role existed: where the
        // adapter can advertise, the Mesh channel must behave like any other and
        // keep its composer.
        MeshRadio.meshMessagingOverrideForTest = true
        setContent {
            SonarTheme(dark = true) {
                SonarChannelScreen(state(), Screen.Channel("mesh"))
            }
        }
        assertTrue(
            onAllNodesWithText("Bluetooth mesh isn't available on this device")
                .fetchSemanticsNodes().isEmpty(),
            "a radio that can advertise must not be told it cannot",
        )
        assertTrue(
            onAllNodesWithText("Message Mesh").fetchSemanticsNodes().isNotEmpty(),
            "a working mesh channel must offer a composer",
        )
    }

    @Test
    fun aLocationChannelIsUnaffected() = runComposeUiTest {
        // The notice is scoped to mesh: geohash channels are relay-backed and work
        // fine on this platform, so they must keep their composer.
        setContent {
            SonarTheme(dark = true) {
                SonarChannelScreen(state(), Screen.Channel("dr5ru"))
            }
        }
        val composer = onAllNodesWithText("Message #dr5ru", substring = true).fetchSemanticsNodes()
        assertFalse(composer.isEmpty(), "a working channel must still offer a composer")
    }
}
