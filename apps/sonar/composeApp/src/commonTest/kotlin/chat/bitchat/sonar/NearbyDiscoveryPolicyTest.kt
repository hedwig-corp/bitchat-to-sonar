package chat.bitchat.sonar

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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
}
