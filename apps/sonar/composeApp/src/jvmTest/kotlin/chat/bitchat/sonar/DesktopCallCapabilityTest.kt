package chat.bitchat.sonar

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The desktop build must not offer calls it cannot make or take, to its own user or
 * to anyone else.
 *
 * The desktop core has no iroh call engine and said so only in a comment claiming
 * "the call UI is never offered". Nothing enforced that: the detail rail rendered
 * Phone and Videocam buttons on every install, and the node advertised CAP_CALLS to
 * every peer in BLE range and `callsEnabled = true` in its Sonar descriptor, so a
 * contact's phone lit its own call button, dialled, and got an instant decline their
 * UI renders as the person declining.
 *
 * These drive the real gates, not just the flag. An earlier version of this file
 * asserted only that [SonarCore.callsSupported] is false, which stayed green under
 * the mutation that matters: delete the capability line from `canCall` and revert the
 * rail to an unconditional row, and the bug is back with the constant untouched.
 */
class DesktopCallCapabilityTest {

    private fun state(): SonarAppState {
        DesktopEnv.useTestRoot(kotlin.io.path.createTempDirectory("sonar-calltest").toFile())
        return SonarAppState(CoroutineScope(Job()))
    }

    @AfterTest
    fun restore() = DesktopEnv.useTestRoot(null)

    @Test
    fun desktopReportsThatCallsAreUnavailable() {
        assertFalse(
            SonarCore.callsSupported,
            "the desktop dylib is built without calls-audio, so the UI must be told",
        )
    }

    @Test
    fun theCapabilityMatchesWhatTheEngineActuallyDoes() = kotlinx.coroutines.runBlocking {
        // If this starts succeeding, calls were wired into the desktop dylib and the
        // flag is now lying in the other direction, hiding a feature that works.
        assertFailsWith<IllegalStateException>(
            "callStart must fail while callsSupported is false",
        ) { SonarCore.callStart() }
        Unit
    }

    @Test
    fun aFullyCallCapablePeerStillGetsNoCallButton() {
        val s = state()
        // A peer that satisfies every OTHER condition canCall checks. Without this
        // setup the test is worthless: an empty state has no route, so canCall
        // returns false regardless, and deleting the capability line leaves it green.
        // That is exactly how the first version of this test passed while the bug
        // was fully restorable.
        val peerNpub = "npub1zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygse4sl3h"
        val chatId = "callable-peer-group"
        s.seedCallableChatForTest(
            chatId, peerNpub,
            SonarDescriptor(
                schema = 1,
                calls = true,
                media = emptyList(),
                signaling = listOf("marmot"),
                transports = listOf("iroh"),
                callIdentity = "iroh-hkdf-sonar-call-iroh-v1",
                bolt12Offer = null,
                paymentReceipts = emptyList(),
                publishedAtSecs = 0,
            ),
        )
        // The test proving its own premise. Without this the assertion below is
        // satisfied by a state that simply has no route, which is how the first
        // version passed while the capability gate was deletable.
        assertTrue(
            s.hasCallRoute(chatId),
            "fixture must be a peer this app WOULD call if it had an engine",
        )
        assertFalse(
            s.canCall(chatId),
            "the peer can take calls; THIS build cannot, and that is what must decide it",
        )
    }

    @Test
    fun peersAreNotToldThisNodeTakesCalls() {
        // The half that is invisible locally: advertising CAP_CALLS lights a call
        // button on someone ELSE's device.
        val caps = state().capabilities()
        assertEquals(
            0, caps and SonarAnnounce.CAP_CALLS,
            "a build with no call engine must not advertise CAP_CALLS to peers",
        )
        assertEquals(
            SonarAnnounce.CAP_MARMOT, caps and SonarAnnounce.CAP_MARMOT,
            "gating calls must not disturb the other advertised capabilities",
        )
    }
}
