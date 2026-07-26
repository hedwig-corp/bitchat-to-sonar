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

    /** `eraseAllChats()` clears chats and links but not the descriptor map, so
     *  without a cap a long-lived identity grows the blob forever — and it is
     *  decoded synchronously on the cold-start path. iOS caps at the same limit. */
    @Test
    fun keepsOnlyTheFreshestDescriptorsWhenOverTheCap() {
        val overCap = SONAR_DESCRIPTOR_CACHE_ENTRY_LIMIT + 50
        val cache = (0 until overCap).associate { i ->
            i.toString(16).padStart(64, '0') to descriptor(publishedAtSecs = i.toLong())
        }

        val decoded = decodeSonarDescriptorCache(encodeSonarDescriptorCache(cache))

        assertEquals(SONAR_DESCRIPTOR_CACHE_ENTRY_LIMIT, decoded.size)
        // The 50 oldest are dropped, the newest are kept.
        assertEquals(null, decoded[0.toString(16).padStart(64, '0')])
        assertEquals(
            (overCap - 1).toLong(),
            decoded[(overCap - 1).toString(16).padStart(64, '0')]?.publishedAtSecs,
        )
    }

    /** Ties on publishedAtSecs break on the key, so the persisted blob does not
     *  churn between runs for an unchanged cache. */
    @Test
    fun pruningIsDeterministicWhenTimestampsTie() {
        val overCap = SONAR_DESCRIPTOR_CACHE_ENTRY_LIMIT + 10
        val cache = (0 until overCap).associate { i ->
            i.toString(16).padStart(64, '0') to descriptor(publishedAtSecs = 7L)
        }

        val first = encodeSonarDescriptorCache(cache)
        val second = encodeSonarDescriptorCache(cache.entries.reversed().associate { it.key to it.value })

        assertEquals(first, second)
        assertEquals(SONAR_DESCRIPTOR_CACHE_ENTRY_LIMIT, decodeSonarDescriptorCache(first).size)
    }

    private fun descriptor(
        bolt12Offer: String? = "lno1qcp4256ypq",
        paymentReceipts: List<String> = listOf("sonar.payment.receipt.v1"),
        callIdentity: String = "iroh-hkdf-sonar-call-iroh-v1",
        media: List<String> = listOf("voice", "video"),
        publishedAtSecs: Long = 1_753_000_000L,
    ) = SonarDescriptor(
        schema = 2,
        calls = true,
        media = media,
        signaling = listOf("marmot"),
        transports = listOf("iroh"),
        callIdentity = callIdentity,
        bolt12Offer = bolt12Offer,
        paymentReceipts = paymentReceipts,
        publishedAtSecs = publishedAtSecs,
    )
}
