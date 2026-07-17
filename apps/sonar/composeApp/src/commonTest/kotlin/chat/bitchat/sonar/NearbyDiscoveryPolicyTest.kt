package chat.bitchat.sonar

import kotlinx.coroutines.CompletableDeferred
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
    fun unchangedKnownPeerPolicyIsACompleteNoOp() {
        assertNull(
            changedKnownMeshPeerIds(
                current = setOf("abcdef", "123456"),
                requested = setOf("ABCDEF", "123456"),
            ),
        )
        assertEquals(
            setOf("abcdef", "fedcba"),
            changedKnownMeshPeerIds(
                current = setOf("abcdef"),
                requested = setOf("ABCDEF", "FEDCBA"),
            ),
        )
    }

    @Test
    fun freshAnnounceNeverCrossesNativeLinkBoundary() {
        var linkChecks = 0
        assertFalse(
            shouldExpireAnnouncedMeshPeer(nowMs = 1_000, lastSeenMs = 900, staleMs = 200) {
                linkChecks++
                false
            },
        )
        assertEquals(0, linkChecks)

        assertTrue(
            shouldExpireAnnouncedMeshPeer(nowMs = 1_200, lastSeenMs = 900, staleMs = 200) {
                linkChecks++
                false
            },
        )
        assertEquals(1, linkChecks)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun peerUpdateBurstKeepsOnlyOnePendingRefresh() = runTest {
        val releaseFirstRefresh = CompletableDeferred<Unit>()
        var refreshCount = 0
        val queue = ConflatedRefreshQueue(this) {
            refreshCount++
            if (refreshCount == 1) releaseFirstRefresh.await()
        }

        repeat(1_000) { queue.request() }
        runCurrent()
        assertEquals(1, refreshCount)

        repeat(1_000) { queue.request() }
        releaseFirstRefresh.complete(Unit)
        runCurrent()
        assertEquals(2, refreshCount)

        queue.cancel()
    }

    @Test
    fun verifiedBitchatPeerIsVisibleBeforeSonarCapabilitiesArrive() {
        val whitewholf = MeshPeer(
            id = "mesh:whitewholf-fingerprint",
            name = "whitewholf",
            rssi = -50,
            sonar = false,
        )

        assertEquals(
            listOf(whitewholf),
            visibleRadarMeshPeers(listOf(whitewholf), isBlocked = { false }),
        )
    }

    @Test
    fun radarStillExcludesBlockedVerifiedPeers() {
        val blocked = MeshPeer("mesh:blocked-fingerprint", "blocked", -50)

        assertTrue(
            visibleRadarMeshPeers(listOf(blocked), isBlocked = { it == "blocked-fingerprint" }).isEmpty(),
        )
    }

    @Test
    fun nearbyScanRequiresVisibleForegroundOnboardedRadarAndOpenDiscovery() {
        assertTrue(shouldScanForNearbyPayments(true, true, true, false))
        assertFalse(shouldScanForNearbyPayments(false, true, true, false))
        assertFalse(shouldScanForNearbyPayments(true, false, true, false))
        assertFalse(shouldScanForNearbyPayments(true, true, false, false))
        assertFalse(shouldScanForNearbyPayments(true, true, true, true))
    }

    @Test
    fun nearbyMeshRefreshContinuesForKnownPeersWhenOpenDiscoveryIsRestricted() {
        assertTrue(shouldRefreshNearbyPeers(true, true, true))
        assertFalse(shouldRefreshNearbyPeers(false, true, true))
        assertFalse(shouldRefreshNearbyPeers(true, false, true))
        assertFalse(shouldRefreshNearbyPeers(true, true, false))
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun nearbyRefreshPublishesMeshAndUnifyPeersWithoutWaitingForHousekeepingHeartbeat() = runTest {
        val radioMeshPeers = mutableListOf<MeshPeer>()
        val radioUnifyPeers = mutableListOf<String>()
        var publishedMeshPeers = emptyList<MeshPeer>()
        var publishedUnifyPeers = emptyList<String>()
        val refreshJob = launchNearbyPeerRefresh(
            intervalMs = 100,
            readMeshPeers = { radioMeshPeers.toList() },
            publishMeshPeers = { publishedMeshPeers = it },
            readUnifyPeers = { radioUnifyPeers.toList() },
            publishUnifyPeers = { publishedUnifyPeers = it },
        )

        runCurrent()
        assertTrue(publishedMeshPeers.isEmpty())
        assertTrue(publishedUnifyPeers.isEmpty())

        radioMeshPeers += MeshPeer("mesh:whitewholf-fingerprint", "whitewholf", -50)
        radioUnifyPeers += "payer"
        advanceTimeBy(100)
        runCurrent()
        assertEquals(listOf("whitewholf"), publishedMeshPeers.map { it.name })
        assertEquals(listOf("payer"), publishedUnifyPeers)

        refreshJob.cancelAndJoin()
        radioMeshPeers += MeshPeer("mesh:late-fingerprint", "late peer", -60)
        radioUnifyPeers += "late payer"
        advanceTimeBy(100)
        runCurrent()
        assertEquals(listOf("whitewholf"), publishedMeshPeers.map { it.name })
        assertEquals(listOf("payer"), publishedUnifyPeers)
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
