package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Marmot v1 → v2 flag day: what ChatScreen shows for core's chat gate. */
class MarmotProtocolGateTest {
    private val blocked = SonarMarmotChatGate(SonarMarmotChatGateState.Blocked, listOf("aa"))
    private val partly = SonarMarmotChatGate(SonarMarmotChatGateState.PartlyUpdated, listOf("aa", "bb"))

    @Test
    fun aContactOnMarmotV2ReplacesTheComposer() {
        assertEquals(SonarComposerGate.UpdateRequired, composerGateFor(blocked, sendsOverMesh = false))
    }

    @Test
    fun unknownMixedAndV1ContactsKeepTheComposer() {
        // Core folds Mixed / Unknown / V1Only into Open; no gate read yet is open too.
        assertEquals(SonarComposerGate.Open, composerGateFor(null, sendsOverMesh = false))
        assertEquals(
            SonarComposerGate.Open,
            composerGateFor(SonarMarmotChatGate(SonarMarmotChatGateState.Open), sendsOverMesh = false),
        )
    }

    @Test
    fun aPartlyUpdatedGroupGetsANoteNotABlock() {
        assertEquals(SonarComposerGate.PartlyUpdated(2), composerGateFor(partly, sendsOverMesh = false))
        assertEquals("1 member is on a newer version", marmotPartlyUpdatedBold(1))
        assertEquals("2 members are on a newer version", marmotPartlyUpdatedBold(2))
    }

    @Test
    fun aLiveBluetoothLinkKeepsAMeshFoldedChatOpen() {
        // BLE sends never touch the Marmot group, so the flag day does not
        // apply to them (docs/CHAT-TYPES.md: send transport is per message).
        assertEquals(SonarComposerGate.Open, composerGateFor(blocked, sendsOverMesh = true))
        assertEquals(SonarComposerGate.Open, composerGateFor(partly, sendsOverMesh = true))
    }

    @Test
    fun copyNamesThePeer() {
        assertEquals(
            "Ana can't read messages from this version of Sonar. Update the app to keep chatting",
            marmotUpdateRequiredText("Ana"),
        )
    }

    @Test
    fun coreRefusalIsRecognisedByItsMarker() {
        assertTrue(isPeerUpdatedSonarError("the contact can't read messages from this version of Sonar: update the app to keep chatting"))
        assertFalse(isPeerUpdatedSonarError("no relay connected within timeout"))
        assertFalse(isPeerUpdatedSonarError(null))
    }

    @Test
    fun updateLinkFollowsTheInstaller() {
        assertEquals(SONAR_ZAPSTORE_URL, sonarUpdateUrlForInstaller("dev.zapstore.app"))
        assertEquals(SONAR_PLAY_URL, sonarUpdateUrlForInstaller("com.android.vending"))
        assertEquals(SONAR_GITHUB_RELEASES_URL, sonarUpdateUrlForInstaller(null))
        assertEquals(SONAR_GITHUB_RELEASES_URL, sonarUpdateUrlForInstaller("com.google.android.packageinstaller"))
    }
}
