package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SystemBackPolicyTest {
    @Test
    fun interceptsSystemBackAwayFromRoot() {
        assertTrue(shouldHandleSystemBack(isAtRoot = false))
    }

    @Test
    fun letsAndroidHandleSystemBackAtRoot() {
        assertFalse(shouldHandleSystemBack(isAtRoot = true))
    }

    @Test
    fun interceptsSystemBackForTransientUiAtRoot() {
        assertTrue(shouldHandleSystemBack(isAtRoot = true, hasTransientUi = true))
    }

    @Test
    fun interceptsSystemBackForTransientUiAwayFromRoot() {
        assertTrue(shouldHandleSystemBack(isAtRoot = false, hasTransientUi = true))
    }
}
