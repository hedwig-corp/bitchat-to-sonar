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

    /** Back to a chat re-reads its gate from core: while another chat was on
     *  top, core may have reopened it (and notified only the other chat), so
     *  the panel must not stay up from the stale read. Core here has no node
     *  and answers Open, which stands in for "core reopened the chat". */
    @Test
    fun backToAChatReReadsItsGateFromCore() {
        val s = state()
        val blocked = "ab".repeat(32)
        s.push(Screen.Chat(blocked, "Ana"))
        s.seedMarmotChatGateForTest(
            blocked,
            SonarMarmotChatGate(SonarMarmotChatGateState.Blocked, listOf("cd".repeat(32))),
        )
        s.push(Screen.Chat("ef".repeat(32), "Bo"))
        s.back()
        val deadline = System.currentTimeMillis() + 5_000
        while (s.composerGate(blocked, sendsOverMesh = false) != SonarComposerGate.Open &&
            System.currentTimeMillis() < deadline
        ) {
            Thread.sleep(20)
        }
        assertEquals(SonarComposerGate.Open, s.composerGate(blocked, sendsOverMesh = false))
    }
}
