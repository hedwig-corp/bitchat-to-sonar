package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

/**
 * The desktop build declares that it cannot place or take calls.
 *
 * The desktop core has no iroh call engine, and it said so only in a comment
 * claiming "the call UI is never offered" while the detail rail rendered Phone and
 * Videocam buttons on every install and an incoming offer raised a ringing screen
 * whose Accept could only fail. [SonarCore.callsSupported] makes that a value the UI
 * can ask instead of a claim in a comment.
 *
 * What this pins: the capability, and that it agrees with the engine underneath it.
 * What it does NOT pin: that the UI consults it. `canCall()` gates every call button
 * and the incoming-offer path, but no test constructs a `SonarAppState` (no harness
 * for it exists in this source set), so a future button added without asking
 * `canCall` would not fail here. That is the same gap that let this bug exist, and
 * it is recorded rather than papered over.
 */
class DesktopCallCapabilityTest {

    @Test
    fun desktopReportsThatCallsAreUnavailable() {
        assertFalse(
            SonarCore.callsSupported,
            "the desktop dylib is built without calls-audio, so the UI must be told",
        )
    }

    @Test
    fun theCapabilityMatchesWhatTheEngineActuallyDoes() = kotlinx.coroutines.runBlocking {
        // If this ever starts succeeding, calls were wired into the desktop dylib and
        // `callsSupported` is now lying in the other direction, hiding a feature that
        // works. Either way the two must move together.
        assertFailsWith<IllegalStateException>(
            "callStart must fail while callsSupported is false",
        ) { SonarCore.callStart() }
        Unit
    }
}
