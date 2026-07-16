package chat.bitchat.sonar

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NearbyDiscoveryPolicyTest {
    @Test
    fun failedMeshDrainIsContainedButCancellationPropagates() = runTest {
        var captured: Throwable? = null
        assertFalse(safeMeshDrain({ captured = it }) { error("disk failed") })
        assertEquals("disk failed", captured?.message)

        assertFailsWith<CancellationException> {
            safeMeshDrain({ error("must not observe cancellation") }) {
                throw CancellationException("stopped")
            }
        }
    }

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
        deliveries.finishTransport("peer", "message-1", accepted = true)
        assertEquals(1, deliveries.pendingCount("peer"))
        assertTrue(deliveries.acknowledge("peer", "message-1"))
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
        deliveries.finishTransport("peer", "message-1", accepted = false)

        assertEquals(1, deliveries.pendingCount("peer"))
        assertEquals("message-1", deliveries.beginNext("peer")?.messageId)
    }

    @Test
    fun controllerSuccessWaitsForSamePeerStableIdAck() {
        val deliveries = PendingMeshDeliveryTracker()
        deliveries.enqueue("peer-a", "message-1", "hello")
        deliveries.enqueue("peer-a", "message-2", "next")

        assertEquals("message-1", deliveries.beginNext("peer-a")?.messageId)
        deliveries.finishTransport("peer-a", "message-1", accepted = true)
        assertTrue(deliveries.awaitingAck("peer-a", "message-1"))
        assertEquals(2, deliveries.pendingCount("peer-a"))
        assertFalse(deliveries.acknowledge("peer-b", "message-1"))
        assertFalse(deliveries.acknowledge("peer-a", "message-2"))
        assertEquals(2, deliveries.pendingCount("peer-a"))

        assertTrue(deliveries.acknowledge("peer-a", "message-1"))
        assertEquals("message-2", deliveries.beginNext("peer-a")?.messageId)
    }

    @Test
    fun fullHostAckQueueRetainsLogicalHeadUntilAdmissionSucceeds() {
        val deliveries = PendingMeshDeliveryTracker()
        deliveries.enqueue("peer", "message-1", "hello")
        assertEquals("message-1", deliveries.beginNext("peer")?.messageId)
        deliveries.finishTransport("peer", "message-1", accepted = true)

        assertFalse(deliveries.acknowledgeIf("peer", "message-1") { false })
        assertTrue(deliveries.awaitingAck("peer", "message-1"))
        assertEquals(1, deliveries.pendingCount("peer"))

        assertTrue(deliveries.acknowledgeIf("peer", "message-1") { true })
        assertEquals(0, deliveries.pendingCount("peer"))
    }

    @Test
    fun queuedAckWinsAgainstExpiryUntilHostFinishesDurableRetirement() {
        val deliveries = PendingMeshDeliveryTracker()
        deliveries.enqueue("peer", "message-1", "hello")
        assertEquals("message-1", deliveries.beginNext("peer")?.messageId)
        deliveries.finishTransport("peer", "message-1", accepted = true)

        assertTrue(deliveries.acknowledgeIf("peer", "message-1") { true })
        assertTrue(deliveries.acknowledgementPending("peer", "message-1"))
        assertFalse(deliveries.claimExpiry("peer", "message-1"))
        assertTrue(deliveries.enqueue("peer", "message-1", "durable restore"))
        assertEquals(0, deliveries.pendingCount("peer"))

        deliveries.finishAcknowledgement("peer", "message-1")
        assertFalse(deliveries.acknowledgementPending("peer", "message-1"))
    }

    @Test
    fun expiryClaimFencesLateAckAndCanRollBackAfterDiskFailure() {
        val deliveries = PendingMeshDeliveryTracker()
        deliveries.enqueue("peer", "message-1", "hello")
        assertEquals("message-1", deliveries.beginNext("peer")?.messageId)
        deliveries.finishTransport("peer", "message-1", accepted = true)

        assertTrue(deliveries.claimExpiry("peer", "message-1"))
        assertFalse(deliveries.claimExpiry("peer", "message-1"))
        assertFalse(deliveries.acknowledgeIf("peer", "message-1") { true })
        assertNull(deliveries.beginNext("peer"))

        deliveries.releaseExpiry("peer", "message-1")
        assertEquals("message-1", deliveries.beginNext("peer")?.messageId)
        deliveries.finishTransport("peer", "message-1", accepted = true)
        assertTrue(deliveries.acknowledgeIf("peer", "message-1") { true })
    }

    @Test
    fun missingAckCanRetryWithoutDuplicatingLogicalMessage() {
        val deliveries = PendingMeshDeliveryTracker()
        deliveries.enqueue("peer", "message-1", "hello")
        deliveries.enqueue("peer", "message-1", "hello")

        assertEquals("message-1", deliveries.beginNext("peer")?.messageId)
        deliveries.finishTransport("peer", "message-1", accepted = true)
        assertTrue(deliveries.retryIfAwaiting("peer", "message-1"))
        assertEquals("message-1", deliveries.beginNext("peer")?.messageId)
        assertEquals(1, deliveries.pendingCount("peer"))
    }

    @Test
    fun stableIdDiscardRemovesHeadAndUnblocksNextDelivery() {
        val deliveries = PendingMeshDeliveryTracker()
        deliveries.enqueue("peer", "expired", "old")
        deliveries.enqueue("peer", "fresh", "new")
        assertEquals("expired", deliveries.beginNext("peer")?.messageId)
        deliveries.finishTransport("peer", "expired", accepted = true)

        assertTrue(deliveries.discard("peer", "expired"))
        assertFalse(deliveries.awaitingAck("peer", "expired"))
        assertEquals("fresh", deliveries.beginNext("peer")?.messageId)
    }

    @Test
    fun stableIdDiscardRemovesNonHeadWithoutDisturbingInflightHead() {
        val deliveries = PendingMeshDeliveryTracker()
        deliveries.enqueue("peer", "head", "first")
        deliveries.enqueue("peer", "expired-tail", "second")
        deliveries.enqueue("peer", "tail", "third")
        assertEquals("head", deliveries.beginNext("peer")?.messageId)
        deliveries.finishTransport("peer", "head", accepted = true)

        assertTrue(deliveries.discard("peer", "expired-tail"))
        assertTrue(deliveries.awaitingAck("peer", "head"))
        assertEquals(2, deliveries.pendingCount("peer"))
        assertTrue(deliveries.acknowledge("peer", "head"))
        assertEquals("tail", deliveries.beginNext("peer")?.messageId)
        assertFalse(deliveries.discard("peer", "missing"))
    }

    @Test
    fun logicalDeliveryWindowIsBoundedWithoutEvictingDurableHead() {
        val deliveries = PendingMeshDeliveryTracker()
        repeat(MESH_PENDING_PER_PEER_LIMIT) { index ->
            assertTrue(deliveries.enqueue("peer", "message-$index", "body-$index"))
        }
        assertFalse(deliveries.enqueue("peer", "overflow", "must stay durable"))
        assertEquals(MESH_PENDING_PER_PEER_LIMIT, deliveries.pendingCount("peer"))
        assertEquals("message-0", deliveries.beginNext("peer")?.messageId)
    }

    @Test
    fun duplicateInboundStableIdIsAcknowledgedAgainButSurfacedOnce() {
        val stored = mutableListOf<String>()
        assertTrue(isNewMeshMessage("message-1", stored))
        stored += "message-1"
        assertFalse(isNewMeshMessage("message-1", stored))
        assertTrue(isNewMeshMessage("message-2", stored))
    }

    @Test
    fun deliveryAckMatchesAppleNoisePayloadWireFormat() {
        val id = "73f3b85c-8549-41bc-818e-b1b34c097cd9"
        val payload = meshDeliveryAckPayload(id)
        assertEquals(0x03, payload.first().toInt())
        assertEquals(id, meshDeliveryAckMessageId(payload))
        assertEquals(null, meshDeliveryAckMessageId(byteArrayOf(0x02, 0x41)))
        assertEquals(null, meshDeliveryAckMessageId(byteArrayOf(0x03)))
    }

    @Test
    fun queuedStableIdAckWinsWhenTheDurableRecordIsAlreadyAgedOut() {
        val aged = MeshPendingDeliveryRecord(
            peerId = "peer",
            messageId = "stable-id",
            text = "hello",
            timestampSecs = 1,
            sequence = 1,
        )
        val now = OUTBOX_TTL_SECS + 2

        assertEquals(
            "Delivered",
            meshDeliveryTerminalState(
                aged,
                now,
                setOf(MeshDeliveryAck("peer", "stable-id")),
            ),
        )
        assertEquals("Couldn't send", meshDeliveryTerminalState(aged, now, emptySet()))
    }

    @Test
    fun staleSameAddressWatchdogCannotCancelFreshLinkGeneration() {
        val deliveries = PendingMeshDeliveryTracker()
        deliveries.enqueue("peer", "message-1", "hello")
        assertEquals("message-1", deliveries.beginNext("peer", "client:AA:1")?.messageId)
        deliveries.finishTransport("peer", "message-1", accepted = true, routeId = "client:AA:1")
        assertTrue(deliveries.cancelInFlightForRoute("peer", "client:AA:1"))

        assertEquals("message-1", deliveries.beginNext("peer", "client:AA:2")?.messageId)
        deliveries.finishTransport("peer", "message-1", accepted = true, routeId = "client:AA:2")
        assertFalse(deliveries.retryIfAwaiting("peer", "message-1", "client:AA:1"))
        assertTrue(deliveries.awaitingAck("peer", "message-1"))
        assertTrue(deliveries.retryIfAwaiting("peer", "message-1", "client:AA:2"))
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

    @Test
    fun watchdogBacksOffInAnEmptyRoom() {
        assertEquals(8_000L, bleWatchdogGapMs(8_000L, 0, 120_000L))
        assertEquals(16_000L, bleWatchdogGapMs(8_000L, 1, 120_000L))
        assertEquals(64_000L, bleWatchdogGapMs(8_000L, 3, 120_000L))
        assertEquals(120_000L, bleWatchdogGapMs(8_000L, 10, 120_000L))
    }

    @Test
    fun repeatingKnownAddressWithoutLinkCannotResetPixelRecoveryBackoff() {
        val afterKnownCallback = bleWatchdogBackoffAfterScanResult(
            consecutiveRestarts = 3,
            newAddress = false,
            hasUsableLink = false,
        )
        assertEquals(3, afterKnownCallback)
        assertEquals(64_000L, bleWatchdogGapMs(8_000L, afterKnownCallback, 120_000L))

        assertEquals(0, bleWatchdogBackoffAfterScanResult(3, newAddress = true, hasUsableLink = false))
        assertEquals(0, bleWatchdogBackoffAfterScanResult(3, newAddress = false, hasUsableLink = true))
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
