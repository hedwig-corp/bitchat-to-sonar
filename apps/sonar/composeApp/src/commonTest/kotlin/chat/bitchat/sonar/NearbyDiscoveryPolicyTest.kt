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
    fun androidMeshRequiresVisibleStartedActivityAfterFirstDrawAndOnboarding() {
        assertTrue(
            shouldRunAndroidMeshRadio(
                activityStarted = true,
                postFirstDrawStartupReady = true,
                onboarded = true,
                radioAvailable = true,
            ),
        )
    }

    @Test
    fun androidMeshStopsForEveryLifecycleOrAccountGate() {
        val allowed = listOf(
            shouldRunAndroidMeshRadio(false, true, true, true),
            shouldRunAndroidMeshRadio(true, false, true, true),
            shouldRunAndroidMeshRadio(true, true, false, true),
            shouldRunAndroidMeshRadio(true, true, true, false),
        )

        assertFalse(allowed.any { it })
    }

    @Test
    fun androidMeshDoesNotQueryBluetoothBeforePermissionIndependentGatesOpen() {
        assertFalse(shouldQueryAndroidMeshAvailability(false, true, true))
        assertFalse(shouldQueryAndroidMeshAvailability(true, false, true))
        assertFalse(shouldQueryAndroidMeshAvailability(true, true, false))
        assertTrue(shouldQueryAndroidMeshAvailability(true, true, true))
    }

    @Test
    fun pixelStoppedActivityCannotRunOrRescheduleMeshWatchdog() {
        // Pixel evidence showed scanning work every ~8s while MainActivity was
        // STOPPED. Even if a stale tick still observes scanning=true, onStop's
        // closed lifecycle gate must make that tick terminal.
        assertFalse(shouldRunAndroidMeshRadio(false, true, true, true))
        assertFalse(shouldRunAndroidMeshWatchdog(scanning = true, lifecycleAllowed = false))
        assertTrue(shouldStopAndroidMeshRadio(allowed = false))
        assertTrue(shouldRunAndroidMeshWatchdog(scanning = true, lifecycleAllowed = true))
    }

    @Test
    fun staleGattCallbackCannotCrossStoppedOrRestartedLifecycle() {
        assertFalse(acceptsMeshLifecycleCallback(false, 4, 4))
        assertFalse(acceptsMeshLifecycleCallback(true, 5, 4))
        assertFalse(acceptsMeshLifecycleCallback(true, 5, 5, expectedConnection = false))
        assertTrue(acceptsMeshLifecycleCallback(true, 5, 5, expectedConnection = true))
    }

    @Test
    fun lifecycleStopRetainsUnacknowledgedMeshDeliveryButAccountResetDropsIt() {
        val deliveries = PendingMeshDeliveryTracker()
        deliveries.enqueue("peer", "message-1", "hello")

        assertEquals("message-1", deliveries.beginNext("peer")?.messageId)
        deliveries.cancelInFlight()
        assertEquals("message-1", deliveries.beginNext("peer")?.messageId)
        deliveries.finish("peer", "message-1", delivered = true)
        assertEquals(0, deliveries.pendingCount("peer"))

        deliveries.enqueue("peer", "message-2", "next account must not send this")
        deliveries.clear()
        assertEquals(0, deliveries.pendingCount("peer"))
    }

    @Test
    fun failedGattAcknowledgementRetainsDeliveryForTheNextLink() {
        val deliveries = PendingMeshDeliveryTracker()
        deliveries.enqueue("peer", "message-1", "hello")

        assertEquals("message-1", deliveries.beginNext("peer")?.messageId)
        deliveries.finish("peer", "message-1", delivered = false)

        assertEquals(1, deliveries.pendingCount("peer"))
        assertEquals("message-1", deliveries.beginNext("peer")?.messageId)
    }

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
