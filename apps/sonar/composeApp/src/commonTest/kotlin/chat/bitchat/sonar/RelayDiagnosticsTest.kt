package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RelayDiagnosticsTest {

    @Test
    fun parseSnapshotExtractsRelaysAndFields() {
        val json = """
            {
              "watermark_secs": 1710000000,
              "live_marmot_enabled": true,
              "subscribed_group_count": 3,
              "relays": [
                {"url": "wss://nostr.relay.hedwig.sh/", "status": "Connected"},
                {"url": "wss://relay.damus.io", "status": "disconnected"}
              ]
            }
        """.trimIndent()
        val snap = parseSyncStateSnapshot(json)
        assertNotNull(snap)
        assertEquals(1710000000L, snap.watermarkSecs)
        assertTrue(snap.liveMarmotEnabled)
        assertEquals(3, snap.subscribedGroupCount)
        assertEquals(2, snap.relays.size)
        assertEquals("wss://nostr.relay.hedwig.sh/", snap.relays[0].url)
        assertEquals("Connected", snap.relays[0].status)
        assertEquals("disconnected", snap.relays[1].status)
    }

    @Test
    fun parseSnapshotToleratesMissingFields() {
        val snap = parseSyncStateSnapshot("""{"relays":[]}""")
        assertNotNull(snap)
        assertEquals(0L, snap.watermarkSecs)
        assertFalse(snap.liveMarmotEnabled)
        assertEquals(0, snap.subscribedGroupCount)
        assertTrue(snap.relays.isEmpty())
        assertNull(parseSyncStateSnapshot(null))
        assertNull(parseSyncStateSnapshot("   "))
    }

    @Test
    fun canonicalRelayUrlNormalizesTrailingSlashAndDefaultPort() {
        assertEquals(
            "wss://nostr.relay.hedwig.sh",
            canonicalRelayUrl("wss://nostr.relay.hedwig.sh/"),
        )
        assertEquals(
            "wss://relay.damus.io",
            canonicalRelayUrl("  WSS://Relay.Damus.IO:443  "),
        )
        assertEquals(
            "ws://example.com",
            canonicalRelayUrl("ws://example.com:80/"),
        )
        assertEquals(
            "wss://example.com:8443/path",
            canonicalRelayUrl("wss://example.com:8443/path/"),
        )
    }

    @Test
    fun displayHostAndHostsMatch() {
        assertEquals("nostr.relay.hedwig.sh", displayRelayHost("wss://nostr.relay.hedwig.sh/"))
        assertEquals("relay.damus.io", displayRelayHost("wss://relay.damus.io:443"))
        assertTrue(hostsMatch("wss://relay.damus.io/", "WSS://relay.damus.io:443"))
        assertFalse(hostsMatch("wss://relay.damus.io", "wss://nos.lol"))
    }

    @Test
    fun relayUrlsForBenchmarkAlwaysIncludesHedwigAndDefaultsWhenEmpty() {
        val empty = relayUrlsForBenchmark(null)
        assertTrue(empty.contains(HEDWIG_RELAY_URL) || empty.any { canonicalRelayUrl(it) == HEDWIG_RELAY_URL })
        assertTrue(empty.size >= DEFAULT_RELAY_URLS.size)

        val snap = RelaySyncSnapshot(
            relays = listOf(RelaySyncEntry("wss://relay.damus.io/", "Connected")),
        )
        val urls = relayUrlsForBenchmark(snap)
        assertEquals(canonicalRelayUrl("wss://relay.damus.io"), urls.first())
        assertTrue(urls.any { it == HEDWIG_RELAY_URL })
        // No duplicate hedwig / damus variants.
        assertEquals(urls.size, urls.map { canonicalRelayUrl(it) }.toSet().size)
    }

    @Test
    fun mergeBenchmarkResultCanonicalizesAndReplacesHostAliases() {
        val first = RelayBenchmarkResult(
            url = "wss://relay.damus.io/",
            success = true,
            rttMs = 120,
            measuredAtMs = 1L,
            durationMs = 130,
        )
        val map1 = mergeBenchmarkResult(emptyMap(), first)
        assertEquals(1, map1.size)
        assertEquals(120, map1[canonicalRelayUrl("wss://relay.damus.io")]?.rttMs)

        val second = RelayBenchmarkResult(
            url = "WSS://relay.damus.io:443",
            success = true,
            rttMs = 90,
            measuredAtMs = 2L,
            durationMs = 100,
        )
        val map2 = mergeBenchmarkResult(map1, second)
        assertEquals(1, map2.size)
        assertEquals(90, map2.values.single().rttMs)
    }

    @Test
    fun formatBenchmarkSummaryCoversSuccessAndFailure() {
        val ok = listOf(
            RelayBenchmarkResult("wss://a", true, 50, null, 1, 60),
            RelayBenchmarkResult("wss://b", true, 200, null, 1, 210),
            RelayBenchmarkResult("wss://c", false, null, "timeout", 1, 5000),
        )
        assertEquals("Last run · 2 up / 1 down · best 50 ms · worst 200 ms", formatBenchmarkSummary(ok))
        assertEquals(
            "No relays to measure — open a chat so relays connect, then retry",
            formatBenchmarkSummary(emptyList()),
        )
        val fail = listOf(RelayBenchmarkResult("wss://a", false, null, "timeout", 1, 5000))
        assertTrue(formatBenchmarkSummary(fail).contains("all 1 probes failed"))
    }

    @Test
    fun bestRttPicksMinimum() {
        assertNull(bestRttMs(emptyList()))
        assertEquals(
            12,
            bestRttMs(
                listOf(
                    RelayBenchmarkResult("a", true, 40),
                    RelayBenchmarkResult("b", true, 12),
                    RelayBenchmarkResult("c", false, null),
                ),
            ),
        )
    }
}
