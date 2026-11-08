package chat.bitchat.sonar

import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job

/**
 * `SonarAppState.composerGate` is what ChatScreen reads to pick the composer or
 * the update panel (App.kt `composerGate` → `MarmotComposerSlot`). Pinned on a
 * real state object, not only the pure helper.
 */
class MarmotChatGateStateTest {
    private fun state(): SonarAppState {
        DesktopEnv.useTestRoot(createTempDirectory("sonar-marmot-gate").toFile())
        return SonarAppState(CoroutineScope(Job()))
    }

    @AfterTest
    fun restore() = DesktopEnv.useTestRoot(null)

    @Test
    fun aChatWhoseOtherSideMovedToMarmotV2ShowsTheUpdatePanel() {
        val s = state()
        val chat = "ab".repeat(32)
        assertEquals(SonarComposerGate.Open, s.composerGate(chat, sendsOverMesh = false))
        s.seedMarmotChatGateForTest(
            chat,
            SonarMarmotChatGate(SonarMarmotChatGateState.Blocked, listOf("cd".repeat(32))),
        )
        assertEquals(SonarComposerGate.UpdateRequired, s.composerGate(chat, sendsOverMesh = false))
        // Another chat is unaffected.
        assertEquals(SonarComposerGate.Open, s.composerGate("ef".repeat(32), sendsOverMesh = false))
    }

    @Test
    fun aMeshFoldedChatInBluetoothRangeKeepsItsComposer() {
        val s = state()
        val chat = "mesh:" + "12".repeat(32)
        s.seedMarmotChatGateForTest(
            chat,
            SonarMarmotChatGate(SonarMarmotChatGateState.Blocked, listOf("cd".repeat(32))),
        )
        assertEquals(SonarComposerGate.Open, s.composerGate(chat, sendsOverMesh = true))
        assertEquals(SonarComposerGate.UpdateRequired, s.composerGate(chat, sendsOverMesh = false))
    }

    @Test
    fun aPartlyUpdatedGroupKeepsItsComposerWithANote() {
        val s = state()
        val chat = "ab".repeat(32)
        s.seedMarmotChatGateForTest(
            chat,
            SonarMarmotChatGate(SonarMarmotChatGateState.PartlyUpdated, listOf("cd".repeat(32))),
        )
        assertEquals(SonarComposerGate.PartlyUpdated(1), s.composerGate(chat, sendsOverMesh = false))
        s.seedMarmotChatGateForTest(chat, null)
        assertEquals(SonarComposerGate.Open, s.composerGate(chat, sendsOverMesh = false))
    }
}
