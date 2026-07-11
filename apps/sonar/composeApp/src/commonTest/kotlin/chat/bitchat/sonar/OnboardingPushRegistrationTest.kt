package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OnboardingPushRegistrationTest {
    @Test
    fun retriesRegistrationAfterIdentityIsPersisted() {
        var retried = false

        retryPushRegistrationAfterAccountReady(
            hasIdentity = { true },
            retryRegistration = { retried = true },
        )

        assertTrue(retried)
    }

    @Test
    fun doesNotRegisterBeforeIdentityIsPersisted() {
        var retried = false

        retryPushRegistrationAfterAccountReady(
            hasIdentity = { false },
            retryRegistration = { retried = true },
        )

        assertFalse(retried)
    }
}
