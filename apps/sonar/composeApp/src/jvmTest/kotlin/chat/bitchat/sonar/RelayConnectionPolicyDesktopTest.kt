package chat.bitchat.sonar

import kotlin.test.Test
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
}
