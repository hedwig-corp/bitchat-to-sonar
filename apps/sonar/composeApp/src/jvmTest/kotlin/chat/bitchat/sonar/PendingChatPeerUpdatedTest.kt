package chat.bitchat.sonar

import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job

/**
 * Starting a NEW chat from this (Marmot v1) build with someone whose every
 * install moved to Marmot v2: core's `start_dm` refuses with "peer has updated
 * Sonar". The pending chat must show the update panel in place of the
 * composer, not a generic "couldn't start secure chat" error. Driven through
 * the real call site, [SonarAppState.startChat] → pending setup → the
 * composer gate ChatScreen reads; only the relay wait plus the core call are
 * stubbed.
 */
class PendingChatPeerUpdatedTest {
    private val peerHex = "7e".repeat(32)

    private fun state(): SonarAppState {
        DesktopEnv.useTestRoot(createTempDirectory("sonar-pending-peer-updated").toFile())
        return SonarAppState(CoroutineScope(Job()))
    }

    @AfterTest
    fun restore() = DesktopEnv.useTestRoot(null)

    private fun awaitUntil(condition: () -> Boolean) {
        repeat(300) {
            if (condition()) return
            Thread.sleep(10)
        }
    }

    @Test
    fun aNewChatWithAContactOnMarmotV2ShowsTheUpdatePanelInsteadOfAnError() {
        val s = state()
        s.pendingChatSetupForTest = {
            throw IllegalStateException("peer has updated Sonar: update the app to keep chatting")
        }

        s.startChat(peerHex)

        // Local-first: the pending chat is on screen before setup answers.
        val pending = s.screen as Screen.Chat
        assertTrue(s.isPendingSecureChat(pending.id), "pending chat paints first")
        awaitUntil { s.composerGate(pending.id, sendsOverMesh = false) == SonarComposerGate.UpdateRequired }
        assertEquals(
            SonarComposerGate.UpdateRequired,
            s.composerGate(pending.id, sendsOverMesh = false),
            "the composer is replaced by the update panel",
        )
        assertEquals(marmotUpdateRequiredText(pending.name), s.toast)
        assertEquals(pending.id, (s.screen as Screen.Chat).id, "the user stays in the chat")
    }

    @Test
    fun anyOtherSetupFailureKeepsTheComposerAndTheRawError() {
        val s = state()
        s.pendingChatSetupForTest = { throw IllegalStateException("relay timeout") }

        s.startChat(peerHex)

        val pending = s.screen as Screen.Chat
        awaitUntil { s.toast != null }
        assertEquals("couldn’t start secure chat: relay timeout", s.toast)
        assertEquals(SonarComposerGate.Open, s.composerGate(pending.id, sendsOverMesh = false))
    }
}
