package chat.bitchat.sonar

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue
import chat.bitchat.sonar.store.MESSAGE_STORE_CAP
import chat.bitchat.sonar.store.meshMediaUrlsForDeletion
import chat.bitchat.sonar.store.meshPeerKeyFromMediaUrl

class MeshDeletionFenceTest {
    @Test
    fun deletionTombstoneRoundTripsAcrossRestart() {
        val original = MeshDeletionTombstone(
            canonicalPeerId = "peer\nunsafe",
            npubHex = "ab12",
            aliases = setOf("old-fingerprint", "new\tfingerprint"),
            marmotGroupIds = setOf("group-a", "group-b"),
        )

        val decoded = decodeMeshDeletionTombstones(encodeMeshDeletionTombstones(listOf(original)))
        assertEquals(DeletionJournalStatus.Valid, decoded.status)
        assertEquals(listOf(original), decoded.records)
    }

    @Test
    fun marmotDeleteAndLeaveJournalsRoundTripAcrossRestart() {
        val directIds = setOf("direct-a", "direct-b")
        val direct = CoreChatDeletionTombstone(
            coreChatDeletionKey(CoreChatDeletionMode.Delete, directIds),
            directIds,
            CoreChatDeletionMode.Delete,
        )
        val groupIds = setOf("group-a")
        val group = CoreChatDeletionTombstone(
            coreChatDeletionKey(CoreChatDeletionMode.Leave, groupIds),
            groupIds,
            CoreChatDeletionMode.Leave,
        )

        assertEquals(
            listOf(direct, group).sortedBy { it.key },
            decodeCoreChatDeletionTombstones(encodeCoreChatDeletionTombstones(listOf(group, direct)))
                .records.sortedBy { it.key },
        )
    }

    @Test
    fun malformedDeletionJournalsRemainFailClosedAcrossRestart() {
        val meshRecord = MeshDeletionTombstone("peer", "ab12", setOf("peer"), setOf("group"))
        val coreIds = setOf("group")
        val coreRecord = CoreChatDeletionTombstone(
            coreChatDeletionKey(CoreChatDeletionMode.Delete, coreIds),
            coreIds,
            CoreChatDeletionMode.Delete,
        )
        val corruptMeshBlobs = listOf(
            "wrong-mesh-header",
            encodeMeshDeletionTombstones(listOf(meshRecord)) + "\nmalformed-record",
        )
        val corruptCoreBlobs = listOf(
            "wrong-core-header",
            encodeCoreChatDeletionTombstones(listOf(coreRecord)) + "\nmalformed-record",
        )

        assertEquals(DeletionJournalStatus.Absent, decodeMeshDeletionTombstones("").status)
        assertEquals(DeletionJournalStatus.Absent, decodeCoreChatDeletionTombstones("").status)
        repeat(2) { // cold-start decoding must never turn corruption into "empty"
            corruptMeshBlobs.forEach { blob ->
                val decoded = decodeMeshDeletionTombstones(blob)
                assertEquals(DeletionJournalStatus.Corrupt, decoded.status)
                assertTrue(decoded.records.isEmpty())
                assertTrue(deletionJournalRecoveryRequired(decoded))
                assertFalse(coreChatsAllowedByEraseFence(false, deletionJournalRecoveryPending = true))
            }
            corruptCoreBlobs.forEach { blob ->
                val decoded = decodeCoreChatDeletionTombstones(blob)
                assertEquals(DeletionJournalStatus.Corrupt, decoded.status)
                assertTrue(decoded.records.isEmpty())
                assertTrue(deletionJournalRecoveryRequired(decoded))
                assertFalse(coreChatsAllowedByEraseFence(false, deletionJournalRecoveryPending = true))
            }
        }
    }

    @Test
    fun crashBeforeFirstDurableSaveCannotRedactOrResurrectConversation() = runTest {
        val persistEntered = CompletableDeferred<Unit>()
        val finishPersist = CompletableDeferred<Unit>()
        var durableBlob = ""
        var redacted = false
        val deletion = async {
            commitDurableFenceBeforeEffects(
                persist = {
                    persistEntered.complete(Unit)
                    finishPersist.await()
                    durableBlob = encodeMeshDeletionTombstones(
                        listOf(MeshDeletionTombstone("peer", null, setOf("peer"), emptySet())),
                    )
                    true
                },
                effects = { redacted = true },
            )
        }

        persistEntered.await()
        deletion.cancelAndJoin() // process dies before the first durable commit

        assertEquals("", durableBlob)
        assertFalse(redacted)
    }

    @Test
    fun durableTombstoneIsPublishedBeforeRedactionEffects() = runTest {
        val record = MeshDeletionTombstone("peer", "ab12", setOf("peer"), setOf("group"))
        var durableBlob = ""
        var redacted = false

        assertTrue(commitDurableFenceBeforeEffects(
            persist = {
                durableBlob = encodeMeshDeletionTombstones(listOf(record))
                true
            },
            effects = {
                assertEquals(listOf(record), decodeMeshDeletionTombstones(durableBlob).records)
                redacted = true
            },
        ))
        assertTrue(redacted)
    }

    @Test
    fun tombstoneCannotClearAfterAnyPartialDelete() {
        assertFalse(meshDeletionCanCommit(false, true, true, true))
        assertFalse(meshDeletionCanCommit(true, false, true, true))
        assertFalse(meshDeletionCanCommit(true, true, false, true))
        assertFalse(meshDeletionCanCommit(true, true, true, false))
        assertTrue(meshDeletionCanCommit(true, true, true, true))
    }

    @Test
    fun transcriptReadStartedBeforeDeleteCannotPublishAfterResume() = runTest {
        var conversationGeneration = 4L
        var tombstoneGeneration: Long? = null
        val readStarted = CompletableDeferred<Unit>()
        val finishRead = CompletableDeferred<Unit>()
        val read = async {
            readStarted.complete(Unit)
            finishRead.await()
            meshReadFenceAllowsPublish(
                expectedAccountGeneration = 2,
                currentAccountGeneration = 2,
                expectedConversationGeneration = 4,
                currentConversationGeneration = conversationGeneration,
                expectedStorageEpoch = 8,
                currentStorageEpoch = 8,
                tombstonedAtGeneration = tombstoneGeneration,
            )
        }

        readStarted.await()
        conversationGeneration = 5
        tombstoneGeneration = 5
        finishRead.complete(Unit)

        assertFalse(read.await())
    }

    @Test
    fun tombstonedConversationInvalidationCannotPageOrPublishAfterInFlightRead() = runTest {
        val groupId = "group"
        var erasePending = false
        var journalRecoveryPending = false
        val coreDeletionIds = mutableSetOf<String>()
        val meshDeletionIds = mutableSetOf<String>()
        fun current(): Boolean = conversationChangeFenceAllows(
            groupIdHex = groupId,
            expectedAccountGeneration = 3,
            currentAccountGeneration = 3,
            panicWipePending = false,
            accountRestoreInProgress = false,
            eraseAllChatsPending = erasePending,
            deletionJournalRecoveryPending = journalRecoveryPending,
            coreDeletionChatIds = coreDeletionIds,
            meshDeletionGroupIds = meshDeletionIds,
        )

        var pageCalls = 0
        coreDeletionIds += groupId
        if (current()) pageCalls += 1
        assertEquals(0, pageCalls, "queued tombstoned invalidation paged core")

        coreDeletionIds.clear()
        val pageStarted = CompletableDeferred<Unit>()
        val finishPage = CompletableDeferred<Unit>()
        var sideEffects = 0
        val inFlight = async {
            if (!current()) return@async false
            pageCalls += 1
            pageStarted.complete(Unit)
            finishPage.await()
            if (!current()) return@async false
            sideEffects += 1
            true
        }

        pageStarted.await()
        meshDeletionIds += groupId
        finishPage.complete(Unit)

        assertFalse(inFlight.await())
        assertEquals(1, pageCalls)
        assertEquals(0, sideEffects, "in-flight tombstoned page published call/pay effects")

        val neverReleased = CompletableDeferred<Unit>()
        val queuedJob = launch { neverReleased.await() }
        val queuedJobs = mutableMapOf(groupId to queuedJob)
        cancelConversationChangeJobsForGroups(queuedJobs, setOf(groupId))
        queuedJob.join()
        assertTrue(queuedJob.isCancelled)
        assertTrue(queuedJobs.isEmpty(), "tombstone left queued conversation invalidation reachable")
    }

    @Test
    fun pausedConversationReadCannotPublishAcrossRestoreOrPanicWipe() = runTest {
        listOf("restore", "wipe").forEach { boundary ->
            val expectedGeneration = 7L
            var currentGeneration = expectedGeneration
            var panicWipePending = false
            var restoreInProgress = false
            val readStarted = CompletableDeferred<Unit>()
            val finishRead = CompletableDeferred<Unit>()
            var sideEffects = 0
            fun current(): Boolean = conversationChangeFenceAllows(
                groupIdHex = "group",
                expectedAccountGeneration = expectedGeneration,
                currentAccountGeneration = currentGeneration,
                panicWipePending = panicWipePending,
                accountRestoreInProgress = restoreInProgress,
                eraseAllChatsPending = false,
                deletionJournalRecoveryPending = false,
                coreDeletionChatIds = emptySet(),
                meshDeletionGroupIds = emptySet(),
            )
            val read = async {
                if (!current()) return@async false
                readStarted.complete(Unit)
                finishRead.await()
                if (!current()) return@async false
                sideEffects += 1
                true
            }

            readStarted.await()
            if (boundary == "restore") {
                // restore fences synchronously, before its later generation bump
                restoreInProgress = true
            } else {
                panicWipePending = true
                currentGeneration += 1
            }
            finishRead.complete(Unit)

            assertFalse(read.await(), "$boundary allowed an old-account page to publish")
            assertEquals(0, sideEffects, "$boundary leaked call/pay effects")
        }
    }

    @Test
    fun unknownDirectGroupWithDeletedNpubIsDurablyUnionedBeforeEffects() {
        val tombstone = MeshDeletionTombstone(
            canonicalPeerId = "peer",
            npubHex = "ab12",
            aliases = setOf("peer"),
            marmotGroupIds = setOf("known-group"),
        )
        val unknownGroup = "rotated-direct-group"

        val matched = meshDeletionTombstoneForDirectNpub(
            groupIdHex = unknownGroup,
            directNpubHex = "AB12",
            tombstones = listOf(tombstone),
        )
        assertSame(tombstone, matched)
        val unioned = unionMarmotGroupIntoMeshDeletion(matched!!, unknownGroup)
        val restarted = decodeMeshDeletionTombstones(
            encodeMeshDeletionTombstones(listOf(unioned)),
        )

        assertEquals(DeletionJournalStatus.Valid, restarted.status)
        assertTrue(unknownGroup in restarted.records.single().marmotGroupIds)
        assertFalse(conversationChangeFenceAllows(
            groupIdHex = unknownGroup,
            expectedAccountGeneration = 9,
            currentAccountGeneration = 9,
            panicWipePending = false,
            accountRestoreInProgress = false,
            eraseAllChatsPending = false,
            deletionJournalRecoveryPending = false,
            coreDeletionChatIds = emptySet(),
            meshDeletionGroupIds = restarted.records.single().marmotGroupIds,
        ))
        assertEquals(null, meshDeletionTombstoneForDirectNpub(
            groupIdHex = "unrelated-group",
            directNpubHex = "cd34",
            tombstones = listOf(tombstone),
        ))
    }

    @Test
    fun reconciliationInventoryCannotRaceTombstoneRetirement() = runTest {
        val mutex = Mutex()
        val unknownGroup = "rotated-group"
        var durable = MeshDeletionTombstone(
            canonicalPeerId = "peer",
            npubHex = "ab12",
            aliases = setOf("peer"),
            marmotGroupIds = setOf("known-group"),
        )
        val inventoryPaused = CompletableDeferred<Unit>()
        val releaseInventory = CompletableDeferred<Unit>()

        val reconciliation = async {
            mutex.withLock {
                inventoryPaused.complete(Unit)
                releaseInventory.await()
                durable = unionMarmotGroupIntoMeshDeletion(durable, unknownGroup)
            }
        }
        inventoryPaused.await()
        val retirement = async {
            mutex.withLock {
                unknownGroup !in durable.marmotGroupIds
            }
        }
        yield() // retirement is queued behind the in-flight inventory+union
        releaseInventory.complete(Unit)
        reconciliation.await()

        assertFalse(retirement.await(), "retirement passed a late same-npub group")
        val restarted = decodeMeshDeletionTombstones(encodeMeshDeletionTombstones(listOf(durable)))
        assertEquals(DeletionJournalStatus.Valid, restarted.status)
        assertTrue(unknownGroup in restarted.records.single().marmotGroupIds)
    }

    @Test
    fun suspendedCallStagesCannotEscapeTombstoneRestoreOrWipeFence() = runTest {
        listOf("tombstone", "restore", "wipe").forEach { boundary ->
            listOf("ensure-call-started", "incoming-offer").forEach { stageName ->
                var current = true
                var published = false
                var compensations = 0
                val stagePaused = CompletableDeferred<Unit>()
                val releaseStage = CompletableDeferred<Unit>()
                val callWork = async {
                    val accepted = runFencedSuspendingCallStage(
                        isCurrent = { current },
                        stage = {
                            stagePaused.complete(Unit)
                            releaseStage.await()
                        },
                        compensate = {
                            if (stageName == "incoming-offer") compensations += 1
                        },
                    )
                    if (accepted && current) published = true
                    accepted
                }

                stagePaused.await()
                current = false // models the group/account fence changing
                releaseStage.complete(Unit)

                assertFalse(callWork.await(), "$stageName escaped $boundary")
                assertFalse(published, "$stageName published call UI after $boundary")
                assertEquals(
                    if (stageName == "incoming-offer") 1 else 0,
                    compensations,
                    "$stageName compensation after $boundary",
                )
            }
        }

        var current = true
        var compensatedAfterCancellation = false
        val nativeStagePaused = CompletableDeferred<Unit>()
        val releaseNativeStage = CompletableDeferred<Unit>()
        val structuredJob = launch {
            runFencedSuspendingCallStage(
                isCurrent = { current },
                stage = {
                    withContext(NonCancellable) {
                        nativeStagePaused.complete(Unit)
                        releaseNativeStage.await()
                    }
                },
                compensate = { compensatedAfterCancellation = true },
            )
        }
        nativeStagePaused.await()
        current = false
        structuredJob.cancel()
        releaseNativeStage.complete(Unit)
        structuredJob.join()

        assertTrue(structuredJob.isCancelled)
        assertTrue(compensatedAfterCancellation, "cancelled incoming offer was not compensated")
    }

    @Test
    fun cancelledSameGroupCallScanReleasesClaimForReplacementDebounce() = runTest {
        val messageId = "call-control"
        val claims = mutableSetOf(messageId)
        val nativeStagePaused = CompletableDeferred<Unit>()
        val releaseNativeStage = CompletableDeferred<Unit>()
        val jobs = mutableMapOf<String, kotlinx.coroutines.Job>()
        val first = launch {
            runCallControlWithClaimRecovery(messageId, claims) {
                withContext(NonCancellable) {
                    nativeStagePaused.complete(Unit)
                    releaseNativeStage.await()
                }
                kotlinx.coroutines.currentCoroutineContext().ensureActive()
            }
        }
        jobs[messageId] = first

        nativeStagePaused.await()
        var replacements = 0
        val bReachedScan = CompletableDeferred<Unit>()
        val cReachedScan = CompletableDeferred<Unit>()
        fun replacement(
            previous: kotlinx.coroutines.Job?,
            reachedScan: CompletableDeferred<Unit>,
        ): kotlinx.coroutines.Job {
            lateinit var job: kotlinx.coroutines.Job
            job = launch(start = kotlinx.coroutines.CoroutineStart.LAZY) {
                try {
                    withContext(NonCancellable) { previous?.join() }
                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                    reachedScan.complete(Unit)
                    if (claims.add(messageId)) replacements += 1
                } finally {
                    if (jobs[messageId] === job) jobs.remove(messageId)
                }
            }
            jobs[messageId] = job
            job.start()
            return job
        }

        val previousA = jobs.remove(messageId)
        previousA?.cancel()
        val second = replacement(previousA, bReachedScan)
        yield()
        assertFalse(bReachedScan.isCompleted, "B scanned before A's native stage exited")

        val previousB = jobs.remove(messageId)
        previousB?.cancel()
        val third = replacement(previousB, cReachedScan)
        val unrelated = async { "other-key-processed" }
        assertEquals("other-key-processed", unrelated.await(), "same-key chain blocked unrelated work")
        yield()

        assertFalse(bReachedScan.isCompleted, "cancelled B scanned while A was paused")
        assertFalse(cReachedScan.isCompleted, "C skipped transitively past B/A")
        assertEquals(0, replacements)
        assertTrue(messageId in claims, "A's claim disappeared before A completed")

        releaseNativeStage.complete(Unit)
        third.join()

        assertTrue(first.isCancelled)
        assertTrue(second.isCancelled)
        assertFalse(bReachedScan.isCompleted, "cancelled B processed after A release")
        assertTrue(cReachedScan.isCompleted)
        assertEquals(1, replacements, "only C may reclaim/process the stable id")
        assertTrue(jobs.isEmpty(), "transitive replacement identity cleanup left stale map state")
    }

    @Test
    fun pausedMeshIncomingOfferCannotPublishAfterPeerDelete() = runTest {
        val expectedGeneration = 12L
        var currentGeneration = expectedGeneration
        var meshDeleted = false
        var published = false
        var compensated = false
        val incomingPaused = CompletableDeferred<Unit>()
        val releaseIncoming = CompletableDeferred<Unit>()
        fun current(): Boolean = callControlFenceAllows(
            expectedAccountGeneration = expectedGeneration,
            currentAccountGeneration = currentGeneration,
            panicWipePending = false,
            accountRestoreInProgress = false,
            eraseAllChatsPending = false,
            deletionJournalRecoveryPending = false,
            chatDeletionActive = meshDeleted,
        )
        val incoming = async {
            val accepted = runFencedSuspendingCallStage(
                isCurrent = ::current,
                stage = {
                    incomingPaused.complete(Unit)
                    releaseIncoming.await()
                },
                compensate = { compensated = true },
            )
            if (accepted && current()) published = true
            accepted
        }

        incomingPaused.await()
        meshDeleted = true
        releaseIncoming.complete(Unit)

        assertFalse(incoming.await())
        assertFalse(published)
        assertTrue(compensated)
        assertEquals(expectedGeneration, currentGeneration)
    }

    @Test
    fun allReceiveTransportsRecognizeCanonicalAndNpubRotatedDeletion() {
        val tombstone = MeshDeletionTombstone(
            canonicalPeerId = "canonical",
            npubHex = "ab12",
            aliases = setOf("rotated-peer"),
            marmotGroupIds = emptySet(),
        )
        val receiveTransports = listOf("mesh-text", "nostr-direct", "mesh-media")

        receiveTransports.forEach { transport ->
            assertTrue(
                meshPeerDeletionIsActive(
                    peerId = "rotated-peer",
                    eraseAllChatsPending = false,
                    deletionPeers = emptySet(),
                    tombstones = listOf(tombstone.copy(aliases = setOf("old-peer"))),
                    canonicalPeerId = "canonical",
                    linkedNpubHex = "AB12",
                ),
                "$transport must match a rotated alias through canonical id/npub",
            )
        }
    }

    @Test
    fun coreDeleteContractPropagatesNativeFailureAndRequiresVerifiedAbsence() = runTest {
        val failure = IllegalStateException("native delete failed")
        var observed: Throwable? = null
        try {
            deleteCoreGroupOrThrow { throw failure }
        } catch (error: Throwable) {
            observed = error
        }

        assertSame(failure, observed)
        assertFalse(coreGroupsVerifiedAbsent(setOf("group"), null))
        assertFalse(coreGroupsVerifiedAbsent(setOf("group"), listOf(SonarChat("group", "", emptyList()))))
        assertTrue(coreGroupsVerifiedAbsent(setOf("group"), emptyList()))
    }

    @Test
    fun failedCoreEraseReturnsBeforeFenceRetirementAndReloadsFailClosed() = runTest {
        val durableFenceBlob = ERASE_ALL_CHATS_FENCE_PENDING
        var fenceRetirementAttempts = 0
        var failure: EraseAllChatsFailure? = null

        val completed = completeEraseAllChatsCorePhase(
            eraseCore = { false },
            retireFences = { fenceRetirementAttempts += 1; true },
            onFailure = { failure = it },
        )

        val reloadFence = eraseAllChatsFenceIsPending(durableFenceBlob)
        assertFalse(completed)
        assertEquals(EraseAllChatsFailure.CoreErase, failure)
        assertEquals(0, fenceRetirementAttempts)
        assertTrue(reloadFence)
        assertFalse(coreChatsAllowedByEraseFence(reloadFence))
    }

    @Test
    fun lateOldTimestampIsForceRetainedAtFullCapForEveryReceiveTransport() {
        val full = (0 until MESSAGE_STORE_CAP).map { index ->
            SonarMsg("existing-$index", "peer", "existing", mine = false, tsSecs = 1_000L + index)
        }

        listOf("mesh-text", "nostr-direct", "mesh-media").forEachIndexed { index, transport ->
            val incoming = SonarMsg(
                id = "late-$transport",
                senderNpub = "peer",
                content = transport,
                mine = false,
                tsSecs = index.toLong(),
                receiveEffectsPending = true,
            )
            val retained = retainedPrivateTranscript(full + incoming, forceRetainIds = setOf(incoming.id))
            val rowUsedByReceiveEffects = retained.firstOrNull { it.id == incoming.id }

            assertEquals(MESSAGE_STORE_CAP, retained.size)
            assertEquals(incoming, rowUsedByReceiveEffects, "$transport stable id fell out before effects/ACK")
        }
    }

    @Test
    fun receiveBatchOverCapPersistsAndCompletesEveryStableIdInBoundedChunks() {
        val full = (0 until MESSAGE_STORE_CAP).map { index ->
            SonarMsg("existing-$index", "peer", "existing", mine = false, tsSecs = 10_000L + index)
        }
        val incoming = (0 until 512).map { index ->
            SonarMsg(
                id = "late-$index",
                senderNpub = "peer",
                content = "incoming-$index",
                mine = false,
                tsSecs = index.toLong(),
                receiveEffectsPending = true,
            )
        }
        val batches = boundedMeshReceiveBatches(incoming)
        var transcript = full
        val completed = linkedSetOf<String>()

        for (batch in batches) {
            transcript = retainedPrivateTranscript(
                transcript + batch,
                forceRetainIds = batch.mapTo(hashSetOf()) { it.id },
            )
            batch.forEach { message ->
                if (transcript.firstOrNull { it.id == message.id } != null) completed += message.id
            }
        }

        assertEquals(listOf(MESSAGE_STORE_CAP, 12), batches.map { it.size })
        assertEquals(incoming.map { it.id }.toSet(), completed)
    }

    @Test
    fun meshAndDirectPendingRedeliveriesBatchMarkerCommitsAndAckOnlyAfterRetry() = runTest {
        data class Redelivery(val stableId: String, val deliveryId: String)

        listOf("mesh", "direct").forEach { transport ->
            val rows = (0 until 512).map { index ->
                Redelivery("$transport-stable-$index", "$transport-delivery-$index")
            }
            val stableNotifications = linkedSetOf<String>()
            val acknowledged = linkedSetOf<String>()
            var failedStoreCalls = 0

            // This models a redelivery pass after the admission save succeeded
            // but the receive-effect marker commit still fails. No wire/event
            // ID may be ACKed, and persistence remains bounded to 500 + 12.
            completePendingReceiveEffectDeliveries(
                deliveries = rows,
                stableId = Redelivery::stableId,
                completeBatch = { batch ->
                    failedStoreCalls += 1
                    batch.forEach { stableNotifications += it.stableId }
                    emptySet()
                },
                acknowledge = { acknowledged += it.deliveryId },
            )
            assertEquals(2, failedStoreCalls, "$transport failed marker pass")
            assertTrue(acknowledged.isEmpty(), "$transport ACKed before marker commit")

            var retryStoreCalls = 0
            completePendingReceiveEffectDeliveries(
                deliveries = rows,
                stableId = Redelivery::stableId,
                completeBatch = { batch ->
                    retryStoreCalls += 1
                    // Stable notification IDs make replay idempotent while the
                    // durable pending marker intentionally drives this retry.
                    batch.forEach { stableNotifications += it.stableId }
                    batch.mapTo(linkedSetOf(), Redelivery::stableId)
                },
                acknowledge = { acknowledged += it.deliveryId },
            )

            assertEquals(2, retryStoreCalls, "$transport retry marker pass")
            assertEquals(512, stableNotifications.size, "$transport notification dedupe")
            assertEquals(rows.map { it.deliveryId }.toSet(), acknowledged, "$transport durable ACK set")
        }
    }

    @Test
    fun wipeAndRestoreCancelRetryScheduledAtPauseBoundary() = runTest {
        repeat(2) {
            val mutex = Mutex()
            val pausedBeforeSchedule = CompletableDeferred<Unit>()
            val releaseDelete = CompletableDeferred<Unit>()
            var retryJob: kotlinx.coroutines.Job? = null
            var nativeMutationEscaped = false
            val deleteJob = launch {
                mutex.withLock {
                    pausedBeforeSchedule.complete(Unit)
                    releaseDelete.await()
                    retryJob = launch {
                        mutex.withLock { nativeMutationEscaped = true }
                    }
                }
            }
            pausedBeforeSchedule.await()
            val takeover = async {
                mutex.withLock {
                    cancelAndJoinTrackedDeletionWork(listOfNotNull(retryJob))
                }
            }
            yield() // queue takeover on the mutex before deletion schedules retry
            releaseDelete.complete(Unit)
            takeover.await()
            deleteJob.join()

            assertFalse(nativeMutationEscaped)
            assertTrue(retryJob?.isCancelled == true)
        }
    }

    @Test
    fun peerMediaDeletionIndexesOnlyLocalMeshAttachments() {
        val localA = SonarMedia("mesh-media:peer:a:file", "image/png", "a.png", null, null, null)
        val localB = SonarMedia("mesh-media:peer:b:file", "image/png", "b.png", null, null, null)
        val remote = SonarMedia("https://example.invalid/media", "image/png", "remote.png", null, null, null)
        val messages = listOf(
            SonarMsg("a", "peer", "", false, 1, media = listOf(localA, remote)),
            SonarMsg("b", "peer", "", false, 2, media = listOf(localB, localA)),
        )

        assertEquals(setOf(localA.url, localB.url), meshMediaUrlsForDeletion(messages))
        assertEquals("peer", meshPeerKeyFromMediaUrl(localA.url))
        assertEquals(null, meshPeerKeyFromMediaUrl(remote.url))
    }

    @Test
    fun mediaFailureOrStaleFencePreventsTranscriptDeletion() = runTest {
        var transcriptDeletes = 0
        assertFalse(deletePeerMediaBeforeTranscript(
            deleteMedia = { false },
            deleteTranscript = { transcriptDeletes += 1; true },
        ))
        assertFalse(deletePeerMediaBeforeTranscript(
            deleteMedia = { true },
            stillCurrent = { false },
            deleteTranscript = { transcriptDeletes += 1; true },
        ))

        assertEquals(0, transcriptDeletes)
    }

    @Test
    fun groupStartedWhileDeleteWinsIsCompensatedBeforePublication() = runTest {
        var current = true
        var compensated = false
        val startEntered = CompletableDeferred<Unit>()
        val finishStart = CompletableDeferred<Unit>()
        val result = async {
            runFencedMarmotMutation(
                isCurrent = { current },
                mutate = {
                    startEntered.complete(Unit)
                    finishStart.await()
                },
                compensate = { compensated = true },
            )
        }

        startEntered.await()
        current = false
        finishStart.complete(Unit)

        assertFalse(result.await())
        assertTrue(compensated)
    }

    @Test
    fun cancelledSendThatCommitsDuringNativeCallStillCompensates() = runTest {
        var current = true
        var compensated = false
        val sendEntered = CompletableDeferred<Unit>()
        val finishSend = CompletableDeferred<Unit>()
        val send = async {
            runFencedMarmotMutation(
                isCurrent = { current },
                mutate = {
                    withContext(NonCancellable) {
                        sendEntered.complete(Unit)
                        finishSend.await()
                    }
                },
                compensate = { compensated = true },
            )
        }

        sendEntered.await()
        current = false
        send.cancel()
        finishSend.complete(Unit)
        send.cancelAndJoin()

        assertTrue(compensated)
    }
}
