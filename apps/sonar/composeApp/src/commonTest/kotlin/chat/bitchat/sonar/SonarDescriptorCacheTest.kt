package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The descriptor cache is what makes "Send bitcoin" survive a cold start: the
 * peer's BOLT12 offer lives in their Sonar descriptor, and before this cache the
 * map was memory-only, so every launch hid the payment row until a relay
 * round-trip landed.
 */
class SonarDescriptorCacheTest {

    private val npubHex = "a".repeat(64)

    @Test
    fun roundTripsResolvedDescriptorsIncludingTheBolt12Offer() {
        val cache = mapOf(npubHex to descriptor())

        val decoded = decodeSonarDescriptorCache(encodeSonarDescriptorCache(cache))

        assertEquals(cache, decoded)
        assertEquals("lno1qcp4256ypq", decoded[npubHex]?.bolt12Offer)
    }

    @Test
    fun roundTripsDescriptorsWithoutAnOffer() {
        val cache = mapOf(npubHex to descriptor(bolt12Offer = null, paymentReceipts = emptyList()))

        val decoded = decodeSonarDescriptorCache(encodeSonarDescriptorCache(cache))

        assertEquals(cache, decoded)
    }

    /** Descriptor strings are peer-controlled: a tab or newline inside a
     *  capability token must not be able to forge extra cache rows. */
    @Test
    fun peerControlledStringsCannotCorruptLineFraming() {
        val hostile = descriptor(
            callIdentity = "iroh\tinjected\nb".repeat(2) + "1".repeat(60),
            media = listOf("voice\nfake"),
        )

        val decoded = decodeSonarDescriptorCache(encodeSonarDescriptorCache(mapOf(npubHex to hostile)))

        assertEquals(1, decoded.size)
        assertEquals(hostile, decoded[npubHex])
    }

    @Test
    fun dropsRowsThatAreNotKeyedByA32BytePubkeyHex() {
        val encoded = encodeSonarDescriptorCache(
            mapOf(
                npubHex to descriptor(),
                "npub1notahexkey" to descriptor(),
                "" to descriptor(),
            )
        )

        val decoded = decodeSonarDescriptorCache(encoded)

        assertEquals(setOf(npubHex), decoded.keys)
    }

    @Test
    fun ignoresTruncatedAndGarbageLines() {
        val blob = buildString {
            appendLine("not a descriptor row")
            appendLine("${npubHex}\t2\t1")
            appendLine()
            append(encodeSonarDescriptorCache(mapOf(npubHex to descriptor())))
        }

        val decoded = decodeSonarDescriptorCache(blob)

        assertEquals(setOf(npubHex), decoded.keys)
        assertTrue(decoded.getValue(npubHex).bolt12Offer?.startsWith("lno") == true)
    }

    @Test
    fun decodesAnEmptyBlobToAnEmptyCache() {
        assertEquals(emptyMap(), decodeSonarDescriptorCache(""))
    }

    private fun descriptor(
        bolt12Offer: String? = "lno1qcp4256ypq",
        paymentReceipts: List<String> = listOf("sonar.payment.receipt.v1"),
        callIdentity: String = "iroh-hkdf-sonar-call-iroh-v1",
        media: List<String> = listOf("voice", "video"),
    ) = SonarDescriptor(
        schema = 2,
        calls = true,
        media = media,
        signaling = listOf("marmot"),
        transports = listOf("iroh"),
        callIdentity = callIdentity,
        bolt12Offer = bolt12Offer,
        paymentReceipts = paymentReceipts,
        publishedAtSecs = 1_753_000_000L,
    )
}
