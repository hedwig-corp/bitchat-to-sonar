package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
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

    @Test
    fun anOfferPublishedBeforeTheWalletSwitchIsLegacy() {
        val dayBefore = SONAR_PAYMENT_OFFER_CUTOVER_SECS - 86_400
        assertTrue(callDescriptor(publishedAtSecs = dayBefore).hasLegacyPaymentOffer)
        assertTrue(callDescriptor(publishedAtSecs = SONAR_PAYMENT_OFFER_CUTOVER_SECS - 1).hasLegacyPaymentOffer)
    }

    @Test
    fun anOfferPublishedSinceTheWalletSwitchIsCurrent() {
        assertFalse(callDescriptor(publishedAtSecs = SONAR_PAYMENT_OFFER_CUTOVER_SECS).hasLegacyPaymentOffer)
        assertFalse(callDescriptor(publishedAtSecs = SONAR_PAYMENT_OFFER_CUTOVER_SECS + 7 * 86_400).hasLegacyPaymentOffer)
    }

    @Test
    fun aDescriptorWithoutAnOfferIsNeverLegacy() {
        assertFalse(callDescriptor(publishedAtSecs = 1L, bolt12Offer = null).hasLegacyPaymentOffer)
        assertFalse(callDescriptor(publishedAtSecs = 1L, bolt12Offer = " ").hasLegacyPaymentOffer)
    }

    @Test
    fun thePayGateNamesWhatStandsBetweenAChatAndItsSheet() {
        assertEquals(PaymentGateReason.LookupFailed, paymentGateReason(null, lookupFailed = true))
        assertEquals(PaymentGateReason.NothingFound, paymentGateReason(null, lookupFailed = false))
        assertEquals(PaymentGateReason.NoAddress, paymentGateReason(callDescriptor(bolt12Offer = null), lookupFailed = false))
        assertEquals(
            PaymentGateReason.LegacyAddress,
            paymentGateReason(callDescriptor(publishedAtSecs = SONAR_PAYMENT_OFFER_CUTOVER_SECS - 1), lookupFailed = false),
        )
        assertEquals(PaymentGateReason.Payable, paymentGateReason(callDescriptor(), lookupFailed = true))
    }

    private fun callDescriptor(
        schema: Int = 2,
        calls: Boolean = true,
        signaling: List<String> = listOf("marmot"),
        transports: List<String> = listOf("iroh"),
        callIdentity: String = "iroh-hkdf-sonar-call-iroh-v1",
        bolt12Offer: String? = "lno1example",
        publishedAtSecs: Long = SONAR_PAYMENT_OFFER_CUTOVER_SECS + 86_400,
    ) = SonarDescriptor(
        schema = schema,
        calls = calls,
        media = listOf("voice", "video"),
        signaling = signaling,
        transports = transports,
        callIdentity = callIdentity,
        bolt12Offer = bolt12Offer,
        paymentReceipts = listOf("sonar.payment.receipt.v1"),
        publishedAtSecs = publishedAtSecs,
    )
}
