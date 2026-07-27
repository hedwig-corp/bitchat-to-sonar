package chat.bitchat.sonar

import chat.bitchat.sonar.push.PushTransport
import chat.bitchat.sonar.push.PushTransportPolicy
import kotlin.test.Test
import kotlin.test.assertEquals

class PushTransportPolicyTest {

    @Test
    fun fcmWinsWheneverPlayServicesIsAvailable() {
        // Sandboxed Play on GrapheneOS also reports SUCCESS — FCM stays the
        // preferred transport even when a distributor is installed alongside.
        assertEquals(PushTransport.FCM, PushTransportPolicy.choose(true, false))
        assertEquals(PushTransport.FCM, PushTransportPolicy.choose(true, true))
    }

    @Test
    fun unifiedPushIsTheDegoogledFallback() {
        assertEquals(PushTransport.UNIFIED_PUSH, PushTransportPolicy.choose(false, true))
    }

    @Test
    fun noTransportMustBeExplicitNotSilent() {
        // The honest-degrade state the Diagnostics UI renders: no Play, no
        // distributor — never pretend background delivery works.
        assertEquals(PushTransport.NONE, PushTransportPolicy.choose(false, false))
    }
}
