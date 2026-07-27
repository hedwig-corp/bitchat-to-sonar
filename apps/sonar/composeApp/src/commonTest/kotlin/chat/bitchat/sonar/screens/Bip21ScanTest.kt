package chat.bitchat.sonar.screens

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Pins the scanned-payload resolver, and in particular the BIP-21 unified URI
 * that modern wallets encode:
 *
 *     bitcoin:BC1Q…?amount=0.0001&lno=lno1…
 *
 * The bug these tests exist for: the whole URI used to be handed to the wallet
 * verbatim, so the BOLT12 offer in `lno=` was ignored, the code was labelled a
 * plain on-chain address, and the payment failed.
 */
class Bip21ScanTest {

    @Test
    fun unifiedUriPrefersTheBolt12Offer() {
        val k = scannedKind("bitcoin:bc1q9x2v8fz4?lno=lno1pg257enxv4ezq")
        assertEquals("lno1pg257enxv4ezq", k.destination, "must pay the offer, not the URI")
        assertEquals("Bolt12 offer", k.name)
    }

    @Test
    fun unifiedUriFallsBackToTheInvoiceThenTheAddress() {
        val withInvoice = scannedKind("bitcoin:bc1q9x2v8fz4?lightning=lnbc21u1p3k9")
        assertEquals("lnbc21u1p3k9", withInvoice.destination)
        assertEquals("Lightning invoice", withInvoice.name)
        // The invoice's own amount is authoritative.
        assertEquals(2_100L, withInvoice.fixedSats)

        val addressOnly = scannedKind("bitcoin:bc1q9x2v8fz4?label=Cafe%20Lumen")
        assertEquals("bc1q9x2v8fz4", addressOnly.destination, "query string must be stripped")
        assertEquals("Bitcoin address", addressOnly.name)
    }

    @Test
    fun offerWinsOverInvoiceWhenBothArePresent() {
        val k = scannedKind("bitcoin:bc1q9x2v8fz4?lightning=lnbc21u1p3k9&lno=lno1pg257")
        assertEquals("lno1pg257", k.destination)
    }

    @Test
    fun uriAmountBecomesTheFixedAmount() {
        assertEquals(10_000L, scannedKind("bitcoin:bc1qabc?amount=0.0001").fixedSats)
        assertEquals(100_000_000L, scannedKind("bitcoin:bc1qabc?amount=1").fixedSats)
        assertEquals(1L, scannedKind("bitcoin:bc1qabc?amount=0.00000001").fixedSats)
        assertNull(scannedKind("bitcoin:bc1qabc").fixedSats)
    }

    @Test
    fun btcToSatsIsExactAndRefusesWhatItCannotRepresent() {
        assertEquals(100_000L, btcToSats("0.001"))
        assertEquals(2_100L, btcToSats("0.000021"))
        // 0.1 + 0.2 arithmetic must not appear anywhere near an amount.
        assertEquals(30_000_000L, btcToSats("0.3"))
        assertNull(btcToSats("0.000000001"), "9 decimals cannot be sats — refuse, don't truncate")
        assertNull(btcToSats("abc"))
        assertNull(btcToSats("1.2.3"))
        assertNull(btcToSats("0"))
        assertNull(btcToSats(null))
    }

    @Test
    fun uppercaseQrPayloadsResolve() {
        // BIP-21 QRs are commonly all-uppercase for encoding efficiency.
        val k = scannedKind("BITCOIN:BC1Q9X2V8FZ4?LNO=LNO1PG257ENXV4EZQ")
        assertEquals("lno1pg257enxv4ezq", k.destination)
        assertEquals("Bolt12 offer", k.name)
    }

    @Test
    fun base58AddressKeepsItsCase() {
        // bech32 is case-insensitive; base58 is NOT — lowercasing it would
        // silently change the address.
        val k = scannedKind("bitcoin:1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2")
        assertEquals("1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2", k.destination)
    }

    @Test
    fun schemePrefixedBareCodesAreUnwrapped() {
        assertEquals("lnbc21u1p3k9", scannedKind("lightning:lnbc21u1p3k9").destination)
        assertEquals("Lightning invoice", scannedKind("LIGHTNING:LNBC21U1P3K9").name)
    }

    @Test
    fun aLabelContainingAnAtSignIsNotALightningAddress() {
        // The old classifier looked for "@" anywhere in the payload.
        val k = scannedKind("bitcoin:bc1qabc?label=pay%40cafe")
        assertEquals("Bitcoin address", k.name)
        assertEquals("bc1qabc", k.destination)
    }

    @Test
    fun aPastedUriIsOfferedAndResolvedInTheField() {
        // The typed/pasted path had the identical bug: the row never appeared
        // for a BIP-21 URI, and would have paid the URI rather than the offer.
        val d = payableDestination("bitcoin:bc1q9x2v8fz4?amount=0.0001&lno=lno1pg257")
        assertEquals("lno1pg257", d?.destination)
        assertEquals(10_000L, d?.fixedSats)

        val invoice = payableDestination("lnbc21u1p3k9")
        assertEquals(2_100L, invoice?.fixedSats, "a typed invoice fixes its amount too")
    }
}
