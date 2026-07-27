package chat.bitchat.sonar.screens

import chat.bitchat.sonar.ui.SNIconName
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * Pins the send-payment picker's "pay someone else" classifier — the branch
 * that decides whether the external "Pay …" row appears at all. Get this wrong
 * in either direction and the flow breaks silently: too strict and a valid
 * Bolt12 offer looks like a failed contact search, too loose and the row offers
 * to pay a half-typed contact name.
 */
class SendPaymentDestinationTest {

    @Test
    fun bolt12OfferIsPayableOverLightning() {
        val d = assertNotNull(payableDestination("lno1pg257enxv4ezqcneype82um50ynhxgrwdajx283qfwdpl28qqmc78ymlvhmxcsy"))
        assertEquals(SNIconName.Bolt, d.icon)
        assertEquals("Bolt12 offer · over Lightning", d.subtitle)
    }

    @Test
    fun bolt11InvoiceIsPayable() {
        assertEquals(SNIconName.Bolt, assertNotNull(payableDestination("lnbc21u1p3k9abcdef")).icon)
        assertEquals(SNIconName.Bolt, assertNotNull(payableDestination("lntb500n1pabc")).icon)
    }

    @Test
    fun offersAndInvoicesAreCaseInsensitive() {
        assertNotNull(payableDestination("LNO1PG257ENXV4EZQ"))
        assertNotNull(payableDestination("LNBC21U1P3K9ABC"))
    }

    @Test
    fun lightningAddressNeedsAUserAndADottedHost() {
        val d = assertNotNull(payableDestination("vincenzo@stacker.news"))
        assertEquals(SNIconName.Globe, d.icon)
        assertEquals("Lightning address · over the internet", d.subtitle)

        assertNull(payableDestination("@stacker.news"), "no user part")
        assertNull(payableDestination("vincenzo@"), "no host")
        assertNull(payableDestination("vincenzo@localhost"), "host is not dotted")
        assertNull(payableDestination("vincenzo@.news"), "host starts with a dot")
        assertNull(payableDestination("vincenzo@stacker."), "host ends with a dot")
        assertNull(payableDestination("a@b@c.d"), "two at-signs is not an address")
    }

    @Test
    fun contactSearchTextIsNotADestination() {
        assertNull(payableDestination(""))
        assertNull(payableDestination("maya"))
        assertNull(payableDestination("Sof"))
        // An npub is a Sonar identity, not something the wallet can pay: the
        // picker lists such a contact under "People you can pay" once their
        // descriptor arrives, and until then there is nothing to send to.
        assertNull(payableDestination("npub1w4j8mc7q0e2v9zk5xr3thl6f8s2a7d4ynq9c3uxe650pgh8vrtsq4k9dj"))
    }

    @Test
    fun displayNameUsesTheUserPartOrATruncatedCode() {
        assertEquals("vincenzo", payableDisplayName("vincenzo@stacker.news"))
        assertEquals("vincenzo", payableDisplayName("  vincenzo@stacker.news  "))
        assertEquals("lno1pg257enx…", payableDisplayName("lno1pg257enxv4ezqcneype82um50ynhxgrwdajx"))
        assertEquals("short", payableDisplayName("short"))
    }
}
