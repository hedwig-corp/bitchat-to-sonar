package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

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
    fun unfocused_desktop_window_keeps_the_fast_retries() {
        // Same reason as above, one layer down: alt-tab suspends no sockets, so
        // an unfocused desktop window must not be slowed to the mobile backoff.
        // The default argument resolves to the JVM actual (false), so calling
        // with two arguments is exactly what SonarAppState does on desktop.
        assertEquals(
            1_000L,
            RelayConnectionPolicy.connectRetryDelayMs(consecutiveFailures = 1, foreground = false),
        )
    }
}
