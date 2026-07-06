package chat.bitchat.sonar

import chat.bitchat.sonar.wallet.InvoiceRequestPayload
import chat.bitchat.sonar.wallet.JsonLite
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Parsing of the NDS invoice_request push payload and the JSON reply encoding
 * — the Android analog of iOS `InvoiceRequestTask`'s request/response types.
 */
class InvoiceRequestPayloadTest {

    private val realShape =
        """{"offer":"lno1qsgqmqvgm96frzdg8m0gc6nzeqffvzsqzrxqy32afmr3jn9ggl9g2s""" +
            """8eurvxem","invoice_request":"lnr1qqgz2d7u2smys9dc5q2447e8thjlgq3qqc""" +
            """0","reply_url":"https://nds.sonar.hedwig.sh/api/v1/response/9674711774637014390"}"""

    @Test
    fun parsesTheRealNdsShape() {
        val p = InvoiceRequestPayload.parse(realShape)!!
        assertEquals("https://nds.sonar.hedwig.sh/api/v1/response/9674711774637014390", p.replyUrl)
        assertEquals("lnr1qqgz2d7u2smys9dc5q2447e8thjlgq3qqc0", p.invoiceRequest)
        assertEquals(true, p.offer.startsWith("lno1"))
    }

    @Test
    fun fieldOrderDoesNotMatter() {
        val p = InvoiceRequestPayload.parse(
            """{"reply_url":"https://x/api/v1/response/1","offer":"lno1abc","invoice_request":"lnr1abc"}"""
        )!!
        assertEquals("lno1abc", p.offer)
        assertEquals("lnr1abc", p.invoiceRequest)
        assertEquals("https://x/api/v1/response/1", p.replyUrl)
    }

    @Test
    fun missingFieldRejects() {
        assertNull(InvoiceRequestPayload.parse("""{"offer":"lno1abc","invoice_request":"lnr1abc"}"""))
        assertNull(InvoiceRequestPayload.parse("""{"offer":"","invoice_request":"a","reply_url":"b"}"""))
        assertNull(InvoiceRequestPayload.parse("not json"))
        assertNull(InvoiceRequestPayload.parse(""))
    }

    @Test
    fun whitespaceAndEscapesDecode() {
        val p = InvoiceRequestPayload.parse(
            "{ \"offer\" : \"lno1a\\u0062c\" ,\n \"invoice_request\": \"ln\\\"r\", \"reply_url\": \"https:\\/\\/x\\/r\\/1\" }"
        )!!
        assertEquals("lno1abc", p.offer)
        assertEquals("ln\"r", p.invoiceRequest)
        assertEquals("https://x/r/1", p.replyUrl)
    }

    @Test
    fun valueContainingKeyNameDoesNotConfuseParser() {
        // A value that contains the text `"reply_url":` must not shadow the real field.
        val p = InvoiceRequestPayload.parse(
            """{"offer":"lno1\"reply_url\":\"evil\"","invoice_request":"lnr1","reply_url":"https://good/r/1"}"""
        )!!
        assertEquals("https://good/r/1", p.replyUrl)
    }

    // ── JsonLite.encodeObject: reply bodies ──

    @Test
    fun encodesInvoiceReply() {
        assertEquals("""{"invoice":"lni1abc"}""", JsonLite.encodeObject("invoice", "lni1abc"))
    }

    @Test
    fun encodesErrorReplyWithEscaping() {
        assertEquals(
            """{"error":"bad \"offer\"\nline"}""",
            JsonLite.encodeObject("error", "bad \"offer\"\nline"),
        )
    }

    @Test
    fun nonStringValueForFieldReturnsNull() {
        assertNull(JsonLite.stringField("""{"offer":123,"x":"y"}""", "offer"))
    }

    @Test
    fun nestedObjectValueBailsInsteadOfMatchingInnerKey() {
        // Descending into a nested value could match an inner "reply_url" and
        // return a WRONG value — the parser must bail (null) on nesting.
        assertNull(
            JsonLite.stringField(
                """{"a":{"reply_url":"https://evil/r/1"},"reply_url":"https://good/r/1"}""",
                "reply_url",
            )
        )
        assertNull(JsonLite.stringField("""{"a":[1,2],"offer":"lno1"}""", "offer"))
    }
}
