package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals

class MeshLinkLivenessTest {
    private val staleMs = 90_000L

    @Test
    fun cullsLinkSilentPastTheStaleWindow() {
        // Pixel 10 zombie shape: the stack stopped delivering rx without a
        // disconnect callback, so the address is still "linked".
        assertEquals(
            listOf("84:2F:57:4B:C7:95"),
            meshStaleLinkAddrs(
                nowMs = 200_000L,
                linkedAddrs = setOf("84:2F:57:4B:C7:95"),
                lastRxMsByAddr = mapOf("84:2F:57:4B:C7:95" to 100_000L),
                staleMs = staleMs,
            ),
        )
    }

    @Test
    fun keepsLinkWithRecentTraffic() {
        assertEquals(
            emptyList(),
            meshStaleLinkAddrs(
                nowMs = 200_000L,
                linkedAddrs = setOf("AA:BB:CC:DD:EE:FF"),
                lastRxMsByAddr = mapOf("AA:BB:CC:DD:EE:FF" to 150_000L),
                staleMs = staleMs,
            ),
        )
    }

    @Test
    fun neverCullsLinkWithoutASeededRxTime() {
        // A fresh link must get a full window: the sweep seeds it first, the
        // helper leaves unseeded addresses alone.
        assertEquals(
            emptyList(),
            meshStaleLinkAddrs(
                nowMs = 500_000L,
                linkedAddrs = setOf("AA:BB:CC:DD:EE:FF"),
                lastRxMsByAddr = emptyMap(),
                staleMs = staleMs,
            ),
        )
    }

    @Test
    fun ignoresStaleRxTimesForAddressesNoLongerLinked() {
        assertEquals(
            emptyList(),
            meshStaleLinkAddrs(
                nowMs = 500_000L,
                linkedAddrs = emptySet(),
                lastRxMsByAddr = mapOf("AA:BB:CC:DD:EE:FF" to 1L),
                staleMs = staleMs,
            ),
        )
    }

    @Test
    fun cullsOnlyTheSilentLinkAmongMany() {
        assertEquals(
            listOf("11:11:11:11:11:11"),
            meshStaleLinkAddrs(
                nowMs = 200_000L,
                linkedAddrs = setOf("11:11:11:11:11:11", "22:22:22:22:22:22"),
                lastRxMsByAddr = mapOf(
                    "11:11:11:11:11:11" to 10_000L,
                    "22:22:22:22:22:22" to 190_000L,
                ),
                staleMs = staleMs,
            ).sorted(),
        )
    }
}
