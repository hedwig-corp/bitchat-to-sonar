package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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

    /** A comma inside a list element must not split it into two elements.
     *
     *  The core's `is_protocol_token` keeps commas out of these lists today, so
     *  this is not reachable from the wire — but the encoder's contract is an
     *  exact round-trip, and the earlier join-then-encode form broke it. Under
     *  that form `signaling = ["marmot,x"]` reloaded as `["marmot", "x"]`, which
     *  would flip `supportsCurrentCalls` from false to true across a restart. */
    @Test
    fun commasInsideListElementsDoNotSplitThem() {
        val hostile = descriptor(
            media = listOf("voice,video"),
        ).copy(
            signaling = listOf("marmot,x"),
            transports = listOf("iroh,x"),
            paymentReceipts = listOf("a,b", "c"),
        )
        assertFalse(hostile.supportsCurrentCalls)

        val decoded = decodeSonarDescriptorCache(encodeSonarDescriptorCache(mapOf(npubHex to hostile)))

        assertEquals(hostile, decoded[npubHex])
        assertEquals(listOf("marmot,x"), decoded[npubHex]?.signaling)
        assertEquals(listOf("a,b", "c"), decoded[npubHex]?.paymentReceipts)
        // The round-trip must not manufacture the exact tokens calls require.
        assertFalse(decoded.getValue(npubHex).supportsCurrentCalls)
    }

    @Test
    fun roundTripsEmptyLists() {
        val bare = descriptor().copy(
            media = emptyList(),
            signaling = emptyList(),
            transports = emptyList(),
            paymentReceipts = emptyList(),
        )

        val decoded = decodeSonarDescriptorCache(encodeSonarDescriptorCache(mapOf(npubHex to bare)))

        assertEquals(bare, decoded[npubHex])
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

    /** The cap has to bound the LIVE map, not just the encoder output —
     *  otherwise `sonarDescriptorsByNpubHex` grows forever and every fetch
     *  re-encodes more of it on the Main dispatcher. */
    @Test
    fun boundingPrunesTheLiveMapItself() {
        val overCap = SONAR_DESCRIPTOR_CACHE_ENTRY_LIMIT + 50
        val live = (0 until overCap).associate { i ->
            i.toString(16).padStart(64, '0') to descriptor(publishedAtSecs = i.toLong())
        }

        val bounded = boundedSonarDescriptorCache(live)

        assertEquals(SONAR_DESCRIPTOR_CACHE_ENTRY_LIMIT, bounded.size)
        assertEquals(null, bounded[0.toString(16).padStart(64, '0')])
        assertEquals(
            (overCap - 1).toLong(),
            bounded[(overCap - 1).toString(16).padStart(64, '0')]?.publishedAtSecs,
        )
    }

    /** The bug: evicting by the peer's publish time meant a contact who
     *  published their descriptor long ago was dropped the instant we fetched
     *  them — so the fetch achieved nothing, they stayed unpayable, and every
     *  chat open refetched the same descriptor. */
    @Test
    fun theJustFetchedDescriptorSurvivesEvenWithTheOldestPublishTime() {
        val staleKey = "f".repeat(64)
        val full = (0 until SONAR_DESCRIPTOR_CACHE_ENTRY_LIMIT).associate { i ->
            i.toString(16).padStart(64, '0') to descriptor(publishedAtSecs = 9_000L + i)
        }
        // Published years before everything already cached.
        val incoming = full + (staleKey to descriptor(publishedAtSecs = 1L))

        val bounded = boundedSonarDescriptorCache(
            incoming,
            lastFetchedAtSecs = mapOf(staleKey to 5_000_000L),
            keep = staleKey,
        )

        assertEquals(SONAR_DESCRIPTOR_CACHE_ENTRY_LIMIT, bounded.size)
        assertTrue(staleKey in bounded, "the descriptor we just fetched must not be evicted")
    }

    /** Local fetch recency wins over the peer's publish time. */
    @Test
    fun evictionPrefersLocallyRecentEntriesOverRecentlyPublishedOnes() {
        val recentlyUsed = "a".repeat(63) + "1"
        val neverUsed = "b".repeat(63) + "2"
        // Filler fills every slot but one, and is locally more recent than both
        // candidates — so exactly one of the two below gets the last slot.
        val fillerKeys = (0 until SONAR_DESCRIPTOR_CACHE_ENTRY_LIMIT - 1)
            .map { it.toString(16).padStart(64, '0') }
        val filler = fillerKeys.associateWith { descriptor(publishedAtSecs = 500L) }
        val cache = filler +
            // Old publish time, but we touched it a moment ago.
            (recentlyUsed to descriptor(publishedAtSecs = 1L)) +
            // Freshly published, never fetched locally.
            (neverUsed to descriptor(publishedAtSecs = 9_999_999L))

        val bounded = boundedSonarDescriptorCache(
            cache,
            lastFetchedAtSecs = fillerKeys.associateWith { 9_000_000L } +
                (recentlyUsed to 8_000_000L),
        )

        assertEquals(SONAR_DESCRIPTOR_CACHE_ENTRY_LIMIT, bounded.size)
        assertTrue(recentlyUsed in bounded)
        assertFalse(neverUsed in bounded)
    }

    @Test
    fun boundingIsIdentityBelowTheCap() {
        val under = (0 until 10).associate { i ->
            i.toString(16).padStart(64, '0') to descriptor(publishedAtSecs = i.toLong())
        }

        assertEquals(under, boundedSonarDescriptorCache(under))
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
