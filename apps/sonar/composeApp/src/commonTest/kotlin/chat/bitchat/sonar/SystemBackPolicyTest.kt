package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals

class SystemBackPolicyTest {
    @Test
    fun navigatesThroughSonarStackAwayFromRoot() {
        assertEquals(
            SystemBackAction.Navigate,
            systemBackAction(isAtRoot = false, isCallScreen = false),
        )
    }

    @Test
    fun leavesRootBackToAndroid() {
        assertEquals(
            SystemBackAction.System,
            systemBackAction(isAtRoot = true, isCallScreen = false),
        )
    }

    @Test
    fun consumesBackOnCallScreenWithoutPoppingIt() {
        assertEquals(
            SystemBackAction.Consume,
            systemBackAction(isAtRoot = false, isCallScreen = true),
        )
    }
}
