package chat.bitchat.sonar.screens

import chat.bitchat.sonar.wallet.bolt11AmountSats
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Pins the BOLT11 amount parser behind the scan sheet's "Continue · N sats"
 * button. Getting the multiplier wrong is a silent money bug — the sheet would
 * show, and the keypad would be skipped for, an amount that is off by orders of
 * magnitude.
 */
class Bolt11AmountTest {

    @Test
    fun microBtcInvoiceIsTwentyOneHundredSats() {
        // 21u BTC = 21e-6 × 1e8 sats
        assertEquals(2_100L, bolt11AmountSats("lnbc21u1p3k9abcdef"))
    }

    @Test
    fun everyMultiplierScalesCorrectly() {
        assertEquals(100_000L, bolt11AmountSats("lnbc1m1pabc"))   // 1e-3 BTC
        assertEquals(100L, bolt11AmountSats("lnbc1u1pabc"))       // 1e-6 BTC
        assertEquals(1L, bolt11AmountSats("lnbc10n1pabc"))        // 10e-9 BTC
        // 10p BTC = 1e-11 BTC = 0.001 sat → rounds up to 1 rather than to zero.
        assertEquals(1L, bolt11AmountSats("lnbc10p1pabc"))
    }

    /**
     * QA: a `lnbc2100n` invoice (210 sats) showed as 211 on iOS — floating
     * point read it as 210.00000000000003 and rounded up. Every whole-sat
     * nano amount must come back exact.
     */
    @Test
    fun wholeSatAmountsAreExactNeverRoundedUp() {
        assertEquals(210L, bolt11AmountSats("lnbc2100n1p4tfqn0dqq"))
        for (sats in 1L..10_000L) {
            assertEquals(sats, bolt11AmountSats("lnbc${sats * 10}n1pabc"), "${sats * 10}n")
        }
        assertEquals(250_000L, bolt11AmountSats("lnbc2500u1pabc"))
        assertEquals(2_000_000L, bolt11AmountSats("lnbc20m1pabc"))
        // A sub-sat remainder still rounds up: 1.5 sats → 2, 12,345,678.9 → 12,345,679.
        assertEquals(2L, bolt11AmountSats("lnbc15n1pabc"))
        assertEquals(12_345_679L, bolt11AmountSats("lnbc123456789n1pabc"))
    }

    @Test
    fun unknownMultiplierOrOverflowIsNoAmount() {
        assertNull(bolt11AmountSats("lnbc5x1pabc"))
        assertNull(bolt11AmountSats("lnbc99999999999999999m1pabc"))
    }

    @Test
    fun bareAmountIsWholeBitcoin() {
        assertEquals(100_000_000L, bolt11AmountSats("lnbc11pabc"))
    }

    @Test
    fun testnetAndRegtestPrefixesParse() {
        assertEquals(50L, bolt11AmountSats("lntb500n1pabc"))
        assertEquals(50L, bolt11AmountSats("lnbcrt500n1pabc"))
    }

    @Test
    fun amountlessInvoiceHasNoFixedAmount() {
        // "lnbc1…" — the separator immediately follows the prefix.
        assertNull(bolt11AmountSats("lnbc1pabcdef"))
        assertNull(bolt11AmountSats("lntb1pabcdef"))
    }

    @Test
    fun garbageDoesNotThrow() {
        assertNull(bolt11AmountSats(""))
        assertNull(bolt11AmountSats("lnbc"))
        assertNull(bolt11AmountSats("lnbcuuu1pabc"))
        assertNull(bolt11AmountSats("lnbc0u1pabc")) // zero is not an amount
    }

    @Test
    fun scannedKindLabelsTheDecodedPayload() {
        assertEquals("Lightning invoice", scannedKind("lnbc21u1p3k9").name)
        assertEquals("2,100 sats requested", scannedKind("lnbc21u1p3k9").sub)
        // Breez SDK Liquid takes a BOLT11's amount from the invoice, so an
        // amountless one cannot be paid at all — say so on the card rather
        // than inviting an amount and failing at send time.
        assertEquals("No amount — this invoice can't be paid", scannedKind("lnbc1p3k9").sub)
        assertEquals("Bolt12 offer", scannedKind("lno1pg257enx").name)
        assertEquals("Lightning address", scannedKind("vincenzo@stacker.news").sub)
        assertEquals("Bitcoin address", scannedKind("bc1q9x2v8fz4").name)
        // QR payloads often carry a URI scheme; it must not change the verdict.
        assertEquals("Lightning invoice", scannedKind("lightning:lnbc21u1p3k9").name)
    }
}
