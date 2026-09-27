package chat.bitchat.sonar

import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.mint_offline_retrying
import chat.bitchat.sonar.resources.couldn_t_create_the_invoice_try_again
import chat.bitchat.sonar.resources.this_kind_of_payment_isn_t_supported_yet
import chat.bitchat.sonar.resources.your_wallet_is_busy_try_again_in_a
import chat.bitchat.sonar.resources.your_wallet_is_still_starting_try_again
import chat.bitchat.sonar.screens.middleTruncated
import chat.bitchat.sonar.screens.paysShownInvoice
import chat.bitchat.sonar.screens.payableDestination
import chat.bitchat.sonar.screens.payableDisplayName
import chat.bitchat.sonar.screens.receiveInvoiceErrorMessage
import chat.bitchat.sonar.wallet.SendErrorKind
import chat.bitchat.sonar.wallet.WalletPaymentEvent
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The send sheet's footer. QA found "Pays lnbc5u1p4tg7…'s wallet directly":
 * a raw invoice or offer was named as if it were a person. The inputs here go
 * through the picker's own classifier ([payableDestination]) and label
 * ([payableDisplayName]) — what `SonarSendPaymentScreen` hands the sheet.
 */
class PayFooterTest {

    /** The footer the send-payment picker's sheet shows for typed/scanned [input]. */
    private fun footerFor(input: String): PayFooter {
        val d = assertNotNull(payableDestination(input), "the picker must offer to pay $input")
        return payFooter(d.destination, payableDisplayName(d.destination), mesh = false)
    }

    @Test
    fun aRawLightningInvoiceIsNotAName() {
        assertEquals(PayFooter.LightningInvoice, footerFor("lnbc5u1p4tg7xyzabcdef"))
        assertEquals(PayFooter.LightningInvoice, footerFor("LNBC5U1P4TG7XYZABCDEF"))
        assertEquals(PayFooter.LightningInvoice, footerFor("lntb500n1pabcdef"))
        assertEquals(PayFooter.LightningInvoice, footerFor("lightning:lnbc21u1p3k9abcdef"))
        assertEquals(PayFooter.LightningInvoice, footerFor("bitcoin:bc1q9x2v8fz4?lightning=lnbc21u1p3k9"))
    }

    @Test
    fun aRawBolt12OfferIsNotAName() {
        assertEquals(PayFooter.Bolt12Offer, footerFor("lno1pg257enxv4ezqcneype82um50ynhxgrwdajx283qfwdpl28qq"))
        assertEquals(PayFooter.Bolt12Offer, footerFor("bitcoin:bc1q9x2v8fz4?lno=lno1pg257enxv4ezq"))
    }

    @Test
    fun namedDestinationsKeepTheirName() {
        assertEquals(PayFooter.Named("vincenzo", mesh = false), footerFor("vincenzo@stacker.news"))
        // A Lightning address whose user part happens to look like an invoice.
        assertEquals(PayFooter.Named("lnbc", mesh = false), payFooter("lnbc@example.com", "lnbc", mesh = false))
        // A contact: the chat resolves its offer, so no destination reaches the sheet.
        assertEquals(PayFooter.Named("Maya", mesh = true), payFooter(null, "Maya", mesh = true))
        assertEquals(PayFooter.Named("Maya", mesh = false), payFooter(null, "Maya", mesh = false))
    }

    @Test
    fun theReceiveValueKeepsBothEndsCheckable() {
        val offer = "lno1pg257enxv4ezqcneype82um50ynhxgrwdajx283qfwdpl28qqmc78ymlvhmxcsy"
        assertEquals(offer.take(18) + "…" + offer.takeLast(8), middleTruncated(offer))
        assertEquals("lnbc10fake", middleTruncated("lnbc10fake"))
    }

    /** QA: the fee line read "CHF 0.00" for a 1-sat reserve. It is always sats. */
    @Test
    fun theFeeLineIsAlwaysInSats() {
        assertEquals("4 sats", feeLineAmount(4))
        assertEquals("${payFmt(1_234)} sats", feeLineAmount(1_234))
        assertEquals("0 sats", feeLineAmount(0))
    }

    /** Only the shown invoice's own payment retires it — by id, never by amount. */
    @Test
    fun onlyTheShownInvoicesPaymentRetiresIt() {
        fun event(id: String, incoming: Boolean = true, settled: Boolean = true) = WalletPaymentEvent(
            paymentId = id, incoming = incoming, amountSats = 210, feesSats = null,
            timestampSecs = 0, settled = settled,
        )
        assertTrue(paysShownInvoice(event("q1"), "q1"))
        // The same amount paid to the reusable offer is a different payment.
        assertFalse(paysShownInvoice(event("offer-q:tx"), "q1"))
        assertFalse(paysShownInvoice(event("q1", settled = false), "q1"))
        assertFalse(paysShownInvoice(event("q1", incoming = false), "q1"))
        assertFalse(paysShownInvoice(event("q1"), null))
        assertFalse(paysShownInvoice(null, "q1"))
    }

    @Test
    fun aRefusedInvoiceUsesTheWalletsTypedCopy() {
        assertEquals(Res.string.mint_offline_retrying, receiveInvoiceErrorMessage(SendErrorKind.Offline))
        assertEquals(Res.string.your_wallet_is_busy_try_again_in_a, receiveInvoiceErrorMessage(SendErrorKind.Busy))
        assertEquals(Res.string.your_wallet_is_still_starting_try_again, receiveInvoiceErrorMessage(SendErrorKind.NotReady))
        assertEquals(
            Res.string.this_kind_of_payment_isn_t_supported_yet,
            receiveInvoiceErrorMessage(SendErrorKind.Unsupported),
        )
        // Never the send-side "you were not charged" on a receive.
        for (kind in listOf(SendErrorKind.Failed, SendErrorKind.InvalidDestination, SendErrorKind.InsufficientFunds)) {
            assertEquals(Res.string.couldn_t_create_the_invoice_try_again, receiveInvoiceErrorMessage(kind))
        }
    }
}
