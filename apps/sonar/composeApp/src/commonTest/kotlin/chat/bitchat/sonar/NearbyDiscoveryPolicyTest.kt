package chat.bitchat.sonar

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NearbyDiscoveryPolicyTest {
    @Test
    fun nearbyScanRequiresVisibleForegroundOnboardedRadarAndOpenDiscovery() {
        assertTrue(shouldScanForNearbyPayments(true, true, true, false))
        assertFalse(shouldScanForNearbyPayments(false, true, true, false))
        assertFalse(shouldScanForNearbyPayments(true, false, true, false))
        assertFalse(shouldScanForNearbyPayments(true, true, false, false))
        assertFalse(shouldScanForNearbyPayments(true, true, true, true))
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun nearbyRefreshPublishesPeersWithoutWaitingForHousekeepingHeartbeat() = runTest {
        val radioPeers = mutableListOf<String>()
        var publishedPeers = emptyList<String>()
        val refreshJob = launchNearbyPeerRefresh(
            intervalMs = 100,
            readPeers = { radioPeers.toList() },
            publishPeers = { publishedPeers = it },
        )

        runCurrent()
        assertTrue(publishedPeers.isEmpty())

        radioPeers += "payer"
        advanceTimeBy(100)
        runCurrent()
        assertEquals(listOf("payer"), publishedPeers)

        refreshJob.cancelAndJoin()
        radioPeers += "late payer"
        advanceTimeBy(100)
        runCurrent()
        assertEquals(listOf("payer"), publishedPeers)
    }

    @Test
    fun watchdogKeepsScanRunningForRepeatedCallbacksWithUsableLink() {
        assertNull(
            watchdogReason(
                lastCallbackMs = 19_000,
                lastNewDiscoveryMs = 1_000,
                hasUsableLink = true,
            ),
        )
    }

    @Test
    fun watchdogRestartsWhenCallbacksStopEvenWithUsableLink() {
        assertEquals(
            BleScanRestartReason.NoCallbacks,
            watchdogReason(
                lastCallbackMs = 13_000,
                lastNewDiscoveryMs = 13_000,
                hasUsableLink = true,
            ),
        )
    }

    @Test
    fun watchdogRetainsTunnelBlindRecoveryWithoutUsableLink() {
        assertEquals(
            BleScanRestartReason.RepeatingKnownWithoutUsableLink,
            watchdogReason(
                lastCallbackMs = 19_000,
                lastNewDiscoveryMs = 13_000,
                hasUsableLink = false,
            ),
        )
    }

    @Test
    fun watchdogWaitsForRestartGap() {
        assertNull(
            watchdogReason(
                nowMs = 8_999,
                lastCallbackMs = 1_000,
                lastNewDiscoveryMs = 1_000,
                lastScanStartMs = 1_000,
                hasUsableLink = false,
            ),
        )
    }

    @Test
    fun watchdogKeepsScanRunningAfterFreshDiscovery() {
        assertNull(
            watchdogReason(
                lastCallbackMs = 19_000,
                lastNewDiscoveryMs = 19_000,
                hasUsableLink = false,
            ),
        )
    }

    private fun watchdogReason(
        nowMs: Long = 20_000,
        lastCallbackMs: Long,
        lastNewDiscoveryMs: Long,
        lastScanStartMs: Long = 1_000,
        hasUsableLink: Boolean,
    ): BleScanRestartReason? = bleScanRestartReason(
        nowMs = nowMs,
        lastCallbackMs = lastCallbackMs,
        lastNewDiscoveryMs = lastNewDiscoveryMs,
        lastScanStartMs = lastScanStartMs,
        hasUsableLink = hasUsableLink,
        staleMs = 7_000,
        gapMs = 8_000,
    )
}
