package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SonarDescriptorTest {

    @Test
    fun currentCallsSupportAcceptsLegacyAndMetaSchemas() {
        assertTrue(callDescriptor(schema = 1).supportsCurrentCalls)
        assertTrue(callDescriptor(schema = 2).supportsCurrentCalls)
    }

    @Test
    fun currentCallsSupportRequiresHonestCallRoute() {
        assertFalse(callDescriptor(calls = false).supportsCurrentCalls)
        assertFalse(callDescriptor(signaling = emptyList()).supportsCurrentCalls)
        assertFalse(callDescriptor(transports = emptyList()).supportsCurrentCalls)
        assertFalse(callDescriptor(callIdentity = "unknown").supportsCurrentCalls)
    }

    private fun callDescriptor(
        schema: Int = 2,
        calls: Boolean = true,
        signaling: List<String> = listOf("marmot"),
        transports: List<String> = listOf("iroh"),
        callIdentity: String = "iroh-hkdf-sonar-call-iroh-v1",
    ) = SonarDescriptor(
        schema = schema,
        calls = calls,
        media = listOf("voice", "video"),
        signaling = signaling,
        transports = transports,
        callIdentity = callIdentity,
        bolt12Offer = "lno1example",
        paymentReceipts = listOf("sonar.payment.receipt.v1"),
        publishedAtSecs = 1L,
    )
}
