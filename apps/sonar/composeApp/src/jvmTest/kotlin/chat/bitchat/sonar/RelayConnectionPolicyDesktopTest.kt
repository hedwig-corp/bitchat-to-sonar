package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Desktop-only half of the relay latch policy. Lives in jvmTest, not commonTest:
 * commonTest compiles into every KMP test target and the Android actual returns
 * true, so this assertion would fail under `testDebugUnitTest`.
 */
class RelayConnectionPolicyDesktopTest {
    @Test
    fun desktop_focus_loss_does_not_invalidate_relay_latch() {
        // Main.kt bridges every windowLostFocus to setForeground(false); alt-tab
        // must not rebuild a healthy node.
        assertFalse(RelayConnectionPolicy.shouldInvalidateOnBackground())
    }

    @Test
    fun desktop_heartbeat_reconnects_while_unfocused() {
        // Pins the wiring, not just the rule: gating the heartbeat attach on
        // `foreground` alone would strand desktop, because Main.kt reports
        // foreground=false on every windowLostFocus and there is no push wake to
        // take over the reconnect. Feeding it the same platform value the
        // SonarAppState.poll() call site passes proves the pair composes right
        // here — the pure matrix lives in RelayConnectionPolicyTest.
        assertTrue(
            RelayConnectionPolicy.shouldReconnectOnHeartbeat(
                foreground = false,
                invalidatesOnBackground = RelayConnectionPolicy.shouldInvalidateOnBackground(),
            ),
        )
    }
}
