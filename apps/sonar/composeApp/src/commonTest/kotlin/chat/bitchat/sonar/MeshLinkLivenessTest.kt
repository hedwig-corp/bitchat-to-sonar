package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MeshLinkLivenessTest {
    private val staleMs = 90_000L
    private val resumeGapMs = 45_000L

    @Test
    fun ticksOnScheduleAreNotTreatedAsAFreeze() {
        assertFalse(meshSweepResumedFromGap(115_000L, lastSweepMs = 100_000L, gapMs = resumeGapMs))
    }

    @Test
    fun sweepThatMissedItsTicksIsTreatedAsAResume() {
        // Process frozen (Android caches a backgrounded app) or device dozed: the
        // monotonic clock ran on while our handler did not.
        assertTrue(meshSweepResumedFromGap(400_000L, lastSweepMs = 100_000L, gapMs = resumeGapMs))
    }

    @Test
    fun firstTickIsNeverAResume() {
        assertFalse(meshSweepResumedFromGap(999_000L, lastSweepMs = 0L, gapMs = resumeGapMs))
    }

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
    fun healthyRoleDoesNotMaskADeadRoleOnTheSameAddress() {
        // Same address, both roles live: the server role is carrying traffic while
        // the client GATT is dead. Called per role, the dead client is still culled
        // (it would otherwise hold a MAX_CLIENTS slot and stay a broken send route).
        val addr = "84:2F:57:4B:C7:95"
        assertEquals(
            listOf(addr),
            meshStaleLinkAddrs(
                nowMs = 200_000L,
                linkedAddrs = setOf(addr),
                lastRxMsByAddr = mapOf(addr to 10_000L), // client role: silent
                staleMs = staleMs,
            ),
        )
        assertEquals(
            emptyList(),
            meshStaleLinkAddrs(
                nowMs = 200_000L,
                linkedAddrs = setOf(addr),
                lastRxMsByAddr = mapOf(addr to 190_000L), // server role: healthy
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

    // Airplane mode powers the adapter down and back up. Turning it off must run
    // the full teardown — `stop()` is what clears `scanning`, and while that flag
    // stays true `MeshRadio.start()` early-returns forever, so the radio stays
    // deaf until the process is killed. Turning it back on must re-run `start()`
    // to re-acquire the scanner and advertiser the power cycle invalidated.
    @Test
    fun adapterOffTearsDownAndAdapterOnRestartsTheRadio() {
        assertEquals(BleAdapterAction.Teardown, bleAdapterAction(BleAdapterState.Off))
        assertEquals(BleAdapterAction.Restart, bleAdapterAction(BleAdapterState.On))
    }

    // STATE_TURNING_OFF / STATE_TURNING_ON must not act: tearing down on
    // TURNING_ON would kill a radio that is about to work, and starting on
    // TURNING_OFF would start one against a stack that is going away.
    @Test
    fun adapterTransitionalStatesAreIgnored() {
        assertEquals(BleAdapterAction.Ignore, bleAdapterAction(BleAdapterState.Transitioning))
    }
}
