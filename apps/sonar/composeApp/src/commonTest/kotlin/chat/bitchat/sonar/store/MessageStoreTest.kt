package chat.bitchat.sonar.store

import chat.bitchat.sonar.SonarChannelMsg
import chat.bitchat.sonar.SonarMedia
import chat.bitchat.sonar.SonarMsg
import chat.bitchat.sonar.SonarStickerRef
import chat.bitchat.sonar.MeshPendingDeliveryRecord
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MessageCodecTest {
    @Test fun channelRoundTripWithNastyContent() {
        val msgs = listOf(
            SonarChannelMsg("id1", "alice", "pk1", "hello", mine = false, tsSecs = 100),
            // content with tab, newline and pipe must survive the framing.
            SonarChannelMsg("id2", "bob#1234", "pk2", "line1\nline2\twith|pipe ⚡PAY|1|x|9", mine = true, tsSecs = 200),
            SonarChannelMsg("id3", "anon", "pk3", "", mine = false, tsSecs = 300),
        )
        val decoded = MessageCodec.decodeChannel(MessageCodec.encodeChannel(msgs))
        assertEquals(msgs, decoded)
    }

    @Test fun dmRoundTrip() {
        val msgs = listOf(
            SonarMsg("a", "npub1xx", "hi 👋", mine = true, tsSecs = 1),
            SonarMsg("b", "npub1yy", "multi\nline\tmsg", mine = false, tsSecs = 2),
        )
        assertEquals(msgs, MessageCodec.decodeDm(MessageCodec.encodeDm(msgs)))
    }

    @Test fun dmRoundTripPreservesDurableDeliveryState() {
        val msgs = listOf(
            SonarMsg("sending", "me", "one", mine = true, tsSecs = 1, state = "Sending"),
            SonarMsg("delivered", "me", "two", mine = true, tsSecs = 2, state = "Delivered"),
            SonarMsg("failed", "me", "three", mine = true, tsSecs = 3, state = "Couldn't send"),
            SonarMsg("incoming", "peer", "four", mine = false, tsSecs = 4, receiveEffectsPending = true),
        )

        assertEquals(msgs, MessageCodec.decodeDm(MessageCodec.encodeDm(msgs)))
    }

    @Test fun emptyBlobDecodesEmpty() {
        assertTrue(MessageCodec.decodeChannel("").isEmpty())
        assertTrue(MessageCodec.decodeDm("").isEmpty())
    }

    @Test fun meshEnvelopeRoundTripPreservesKeyAndMessages() {
        val peerKey = "7a60f087831cb56d0011223344556677" // stable fingerprint
        val msgs = listOf(
            SonarMsg("m1", "", "Ciao da BLE", mine = false, tsSecs = 10),
            SonarMsg("m2", "", "reply\twith\ntabs|and ⚡PAY|1|x|5", mine = true, tsSecs = 20),
        )
        val (key, decoded) = MessageCodec.decodeMeshEnvelope(
            MessageCodec.encodeMeshEnvelope(peerKey, msgs)
        )!!
        assertEquals(peerKey, key)
        assertEquals(msgs, decoded)
    }

    @Test fun meshEnvelopeWithNoMessagesKeepsKey() {
        val (key, decoded) = MessageCodec.decodeMeshEnvelope(
            MessageCodec.encodeMeshEnvelope("abcd", emptyList())
        )!!
        assertEquals("abcd", key)
        assertTrue(decoded.isEmpty())
    }

    @Test fun meshEnvelopeRejectsGarbage() {
        assertEquals(null, MessageCodec.decodeMeshEnvelope(""))
    }

    @Test fun meshSummaryIndexRoundTripsUnsafeContentInNewestFirstOrder() {
        val summaries = listOf(
            MeshDmSummary(
                "peer\told\n|⚡",
                SonarMsg("old", "", "old\npreview", mine = false, tsSecs = 10),
            ),
            MeshDmSummary(
                "peer-new",
                SonarMsg("new", "", "new\tpreview|⚡", mine = true, tsSecs = 20, state = "Sending"),
            ),
        )

        assertEquals(
            summaries.reversed(),
            MessageCodec.decodeMeshSummaryIndex(MessageCodec.encodeMeshSummaryIndex(summaries)),
        )
        assertNull(MessageCodec.decodeMeshSummaryIndex("not-a-summary-index"))
    }

    @Test fun meshSummaryPageIsStrictlyBoundedAndDeterministic() {
        val summaries = (0 until MESH_DM_SUMMARY_LIMIT + 50).map { index ->
            MeshDmSummary(
                peerKey = "peer-${index.toString().padStart(3, '0')}",
                latest = SonarMsg("id-$index", "", "preview", mine = false, tsSecs = index.toLong()),
            )
        }

        val bounded = boundedMeshDmSummaries(summaries.shuffled())

        assertEquals(MESH_DM_SUMMARY_LIMIT, bounded.size)
        assertEquals((50 until 250).reversed().map { "peer-${it.toString().padStart(3, '0')}" }, bounded.map { it.peerKey })
    }

    @Test fun authoritativeSummaryCatalogPagesKeepEveryPeerBeyondFirstPaint() {
        val summaries = (0 until 451).associate { index ->
            val peer = "peer-${index.toString().padStart(3, '0')}"
            peer to MeshDmSummary(peer, SonarMsg("id-$index", "", "preview", false, index.toLong()))
        }
        val peerPages = summaries.keys.chunked(MESH_SUMMARY_CATALOG_PAGE_SIZE)
        var tailReads = 0
        var pageReads = 0
        var summaryReads = 0
        val discovered = mutableListOf<MeshDmSummary>()
        var cursor: String? = null
        do {
            val page = readBoundedMeshSummaryCatalogPage(
                afterCursor = cursor,
                limit = MESH_DM_SUMMARY_LIMIT,
                lastPage = { tailReads += 1; peerPages.lastIndex },
                readPeerPage = { pageNumber -> pageReads += 1; peerPages[pageNumber] },
                readSummary = { peer -> summaryReads += 1; summaries[peer] },
            )
            assertTrue(page.summaries.size <= MESH_DM_SUMMARY_LIMIT)
            discovered += page.summaries
            cursor = page.nextCursor
        } while (cursor != null)

        assertEquals(summaries.keys.toList(), discovered.map { it.peerKey })
        assertEquals(451, discovered.distinctBy { it.peerKey }.size)
        assertEquals(3, tailReads)
        assertEquals(3, pageReads)
        assertEquals(451, summaryReads)
    }

    @Test fun arbitraryCatalogCursorTouchesOneBoundedPageOnly() {
        val peerPages = (0 until 50).associateWith { page ->
            (0 until MESH_SUMMARY_CATALOG_PAGE_SIZE).map { "peer-$page-$it" }
        }
        var tailReads = 0
        var pageReads = 0
        var summaryReads = 0

        val page = readBoundedMeshSummaryCatalogPage(
            afterCursor = "25:0",
            limit = MESH_SUMMARY_CATALOG_PAGE_SIZE,
            lastPage = { tailReads += 1; 49 },
            readPeerPage = { pageNumber -> pageReads += 1; peerPages[pageNumber] },
            readSummary = { peer ->
                summaryReads += 1
                MeshDmSummary(peer, SonarMsg(peer, "", "preview", false, 1))
            },
        )

        assertEquals(MESH_SUMMARY_CATALOG_PAGE_SIZE, page.summaries.size)
        assertEquals("26:0", page.nextCursor)
        assertEquals(1, tailReads)
        assertEquals(1, pageReads)
        assertEquals(MESH_SUMMARY_CATALOG_PAGE_SIZE, summaryReads)
    }

    @Test fun catalogCursorOffsetsRemainStableAcrossEarlierDeletion() {
        var slots: List<String?> = (0 until MESH_SUMMARY_CATALOG_PAGE_SIZE).map { "peer-$it" }
        val first = readBoundedMeshSummaryCatalogPage(
            afterCursor = null,
            limit = 100,
            lastPage = { 0 },
            readPeerPage = { slots },
            readSummary = { peer -> MeshDmSummary(peer, SonarMsg(peer, "", "", false, 1)) },
        )
        assertEquals("0:100", first.nextCursor)

        // Durable deletion keeps the original slot as a tombstone instead of
        // compacting every later offset under an in-flight cursor.
        slots = slots.mapIndexed { index, peer -> if (index == 10) null else peer }
        val second = readBoundedMeshSummaryCatalogPage(
            afterCursor = first.nextCursor,
            limit = 100,
            lastPage = { 0 },
            readPeerPage = { slots },
            readSummary = { peer -> MeshDmSummary(peer, SonarMsg(peer, "", "", false, 1)) },
        )

        assertEquals("peer-100", second.summaries.first().peerKey)
        assertEquals("peer-199", second.summaries.last().peerKey)
    }

    @Test fun catalogPageAndAssignmentCodecsAreStrictAndDelimiterSafe() {
        val peers = listOf("peer\none", "peer\ttwo⚡")
        assertEquals(peers, MessageCodec.decodeMeshSummaryPeerPage(MessageCodec.encodeMeshSummaryPeerPage(peers)))
        assertEquals(42, MessageCodec.decodeMeshSummaryAssignment(MessageCodec.encodeMeshSummaryAssignment(42)))
        assertNull(MessageCodec.decodeMeshSummaryAssignment("broken"))
    }

    @Test fun missingAssignmentRetryKeepsExactlyOnePeerSlot() {
        val firstPageCommit = meshSummaryPageWithSinglePeer(emptyList(), "peer-retry")!!

        // Simulate a crash/failure after the page commit but before the separate
        // assignment marker commit. The next attempt sees the durable page.
        val retryPageCommit = meshSummaryPageWithSinglePeer(firstPageCommit, "peer-retry")!!

        assertEquals(firstPageCommit, retryPageCommit)
        assertEquals(1, retryPageCommit.count { it == "peer-retry" })
    }

    @Test fun visibleAssignmentAfterParentFsyncFailureIsRecommittedOnRetry() {
        var markerVisible = false
        var markerCommitAttempts = 0
        var pageCommitAttempts = 0
        fun commitMarker(parentFsyncSucceeds: Boolean): Boolean {
            markerVisible = true // rename succeeded before the injected failure
            markerCommitAttempts += 1
            return parentFsyncSucceeds
        }

        val first = commitMeshSummaryAssignment(
            pageContainsPeer = true,
            commitPageIfRequired = { pageCommitAttempts += 1; true },
            commitAssignment = { commitMarker(parentFsyncSucceeds = false) },
        )
        assertFalse(first)
        assertTrue(markerVisible)

        val retry = commitMeshSummaryAssignment(
            pageContainsPeer = true,
            commitPageIfRequired = { pageCommitAttempts += 1; true },
            commitAssignment = { commitMarker(parentFsyncSucceeds = true) },
        )

        assertTrue(retry)
        assertEquals(2, markerCommitAttempts)
        assertEquals(0, pageCommitAttempts)
    }

    @Test fun duplicatePeerSlotsDecodeAsStableTombstonesAndCanonicalize() {
        val duplicatePage = MessageCodec.encodeMeshSummaryPeerPage(
            listOf("peer-retry", "other", "peer-retry"),
        )
        val decoded = MessageCodec.decodeMeshSummaryPeerPage(duplicatePage)!!

        assertEquals(listOf("peer-retry", "other", null), decoded)
        assertEquals(decoded, meshSummaryPageWithSinglePeer(decoded, "peer-retry"))
    }

    @Test fun blockedRepairEnumerationDoesNotBlockImmediateChatOpen() = runTest {
        val locks = MessageStoreMutationLocks()
        val enumerationStarted = CompletableDeferred<Unit>()
        val finishEnumeration = CompletableDeferred<Unit>()
        val repair = launch {
            snapshotMeshRepairCandidates(
                locks = locks,
                repairPending = {},
                enumerate = {
                    enumerationStarted.complete(Unit)
                    finishEnumeration.await()
                },
            )
        }
        enumerationStarted.await()

        val opened = withTimeout(1_000) {
            locks.withTranscript { "bounded local transcript" }
        }

        assertEquals("bounded local transcript", opened)
        finishEnumeration.complete(Unit)
        repair.join()
    }

    @Test fun authoritativeSummaryRowRoundTripsUnsafePeerAndPreview() {
        val summary = MeshDmSummary(
            "peer\tunsafe\n⚡",
            SonarMsg("id", "sender", "preview\nwith\ttabs", mine = false, tsSecs = 42),
        )
        assertEquals(summary, MessageCodec.decodeMeshSummary(MessageCodec.encodeMeshSummary(summary)))
    }

    @Test fun transcriptMutationCannotSucceedWhenSummaryCatalogCommitFails() {
        val events = mutableListOf<String>()
        val committed = commitMeshSummaryTransaction(
            writeRepairIntent = { events += "intent"; true },
            mutateTranscript = { events += "transcript"; true },
            commitCatalog = { events += "summary"; false },
            clearRepairIntent = { events += "clear"; true },
        )

        assertFalse(committed)
        assertEquals(listOf("intent", "transcript", "summary"), events)
    }

    @Test fun quarantineAdvancesEpochBeforeCleanupFailureFencingQueuedOldWrite() {
        var epoch = 7L
        val queuedWriteEpoch = epoch
        val result = commitMessageStoreRetirement(
            detachNamespace = { true },
            advanceEpoch = { epoch = 8L },
            proveDetachedDurable = { true },
            rollbackNamespace = { error("rollback must not run") },
            cleanup = { false },
        )

        assertTrue(result.oldNamespaceDetached)
        assertTrue(result.quarantined)
        assertFalse(result.cleanupComplete)
        assertFalse(result.rollbackAmbiguous)
        assertFalse(queuedWriteEpoch == epoch)
    }

    @Test fun parentBarrierFailureDurablyRollsBackButKeepsOldEpochFenced() {
        var epoch = 7L
        val events = mutableListOf<String>()
        val result = commitMessageStoreRetirement(
            detachNamespace = { events += "detach"; true },
            advanceEpoch = { events += "epoch"; epoch = 8L },
            proveDetachedDurable = { events += "parent-fsync"; false },
            rollbackNamespace = { events += "rollback+fsync"; MessageStoreRollbackOutcome.Restored },
            cleanup = { events += "cleanup"; true },
        )

        assertEquals(listOf("detach", "epoch", "parent-fsync", "rollback+fsync"), events)
        assertEquals(8L, epoch)
        assertFalse(result.oldNamespaceDetached)
        assertFalse(result.quarantined)
        assertFalse(result.cleanupComplete)
        assertFalse(result.rollbackAmbiguous)
    }

    @Test fun parentBarrierAndRollbackAmbiguityKeepPanicBoundaryUncommitted() {
        var epoch = 7L
        val result = commitMessageStoreRetirement(
            detachNamespace = { true },
            advanceEpoch = { epoch = 8L },
            proveDetachedDurable = { false },
            rollbackNamespace = { MessageStoreRollbackOutcome.Ambiguous },
            cleanup = { error("cleanup must not run") },
        )

        assertEquals(8L, epoch)
        assertFalse(result.oldNamespaceDetached)
        assertFalse(result.quarantined)
        assertFalse(result.cleanupComplete)
        assertTrue(result.rollbackAmbiguous)
    }

    @Test fun staleCatalogRepairPreservesConcurrentlyCommittedRowsAndNewerPreview() {
        val stale = MeshDmSummary("existing", SonarMsg("old", "", "old", false, 1))
        val concurrentNew = MeshDmSummary("new-peer", SonarMsg("new", "", "new", false, 3))
        val concurrentUpdate = MeshDmSummary("existing", SonarMsg("updated", "", "updated", false, 4))

        val merged = mergeRecentMeshSummaryRepair(
            scannedRecent = listOf(stale),
            concurrentlyCommittedRecent = listOf(concurrentNew, concurrentUpdate),
            isLive = { true },
        )

        assertEquals(listOf("existing", "new-peer"), merged.map { it.peerKey })
        assertEquals("updated", merged.first { it.peerKey == "existing" }.latest.id)
        assertFalse(staleRepairMayRemoveCatalogPeer("new-peer", setOf("existing"), transcriptStillExists = true))
        assertTrue(staleRepairMayRemoveCatalogPeer("deleted", setOf("existing"), transcriptStillExists = false))
    }

    @Test fun largeOutboxMigrationLockDoesNotBlockTranscriptFirstPaint() = runTest {
        val locks = MessageStoreMutationLocks()
        val migrationStarted = CompletableDeferred<Unit>()
        val finishMigration = CompletableDeferred<Unit>()
        val migration = backgroundScope.launch {
            locks.withOutbox {
                migrationStarted.complete(Unit)
                finishMigration.await()
            }
        }
        migrationStarted.await()

        val painted = withTimeout(1_000) {
            locks.withTranscript { "bounded transcript page" }
        }
        assertEquals("bounded transcript page", painted)

        finishMigration.complete(Unit)
        migration.join()
    }

    @Test fun durableMeshPendingRoundTripPreservesCrashRecoveryFields() {
        val record = MeshPendingDeliveryRecord(
            peerId = "stable-peer",
            messageId = "stable-message-id",
            text = "line one\nline two\t⚡",
            timestampSecs = 1_753_011_234L,
            surfaceInTranscript = false,
            sequence = 7L,
        )
        assertEquals(record, MessageCodec.decodeMeshPending(MessageCodec.encodeMeshPending(record)))
        assertNull(MessageCodec.decodeMeshPending("not-a-valid-record"))
    }

    @Test fun durableRoutePendingRoundTripPreservesStableIdentityAndOrder() {
        val record = chat.bitchat.sonar.QueuedMessage(
            content = "queued\nmessage",
            peerId = "stable-peer",
            messageId = "stable-id",
            timestampSecs = 1_753_011_234L,
            sequence = 9L,
        )
        assertEquals(record, MessageCodec.decodeRoutePending(MessageCodec.encodeRoutePending(record)))
        assertNull(MessageCodec.decodeRoutePending("not-a-valid-record"))
    }

    @Test fun newerMeshTranscriptRevisionFencesLateDetachedWriter() {
        assertTrue(acceptsMeshStoreRevision(candidate = 8, committed = 7))
        assertTrue(acceptsMeshStoreRevision(candidate = 8, committed = 8))
        assertEquals(false, acceptsMeshStoreRevision(candidate = 7, committed = 8))
    }

    @Test fun dmRoundTripWithStickerRef() {
        val ref = SonarStickerRef("30031:abc123:pack", "wave", "deadbeef")
        val msgs = listOf(
            SonarMsg("a", "npub1xx", "", mine = true, tsSecs = 1, stickerRef = ref),
            SonarMsg("b", "npub1yy", "plain text", mine = false, tsSecs = 2),
        )
        val decoded = MessageCodec.decodeDm(MessageCodec.encodeDm(msgs))
        assertEquals(msgs.size, decoded.size)
        assertEquals(ref, decoded[0].stickerRef)
        assertNull(decoded[1].stickerRef)
        assertEquals("plain text", decoded[1].content)
    }

    @Test fun dmRoundTripWithMedia() {
        val media = SonarMedia("mesh-media:peer:message:photo.jpg", "image/jpeg", "photo.jpg", 640, 480, null)
        val msgs = listOf(
            SonarMsg("a", "npub1xx", "", mine = true, tsSecs = 1, media = listOf(media)),
            SonarMsg("b", "npub1yy", "plain text", mine = false, tsSecs = 2),
        )
        val decoded = MessageCodec.decodeDm(MessageCodec.encodeDm(msgs))
        assertEquals(msgs.size, decoded.size)
        assertEquals(media, decoded[0].media.single())
        assertEquals("plain text", decoded[1].content)
        assertTrue(decoded[1].media.isEmpty())
    }

    @Test fun dmRoundTripPreservesInternetTransportFlag() {
        val msg = SonarMsg("a", "npub1xx", "plain direct", mine = false, tsSecs = 3, viaInternet = true)
        val decoded = MessageCodec.decodeDm(MessageCodec.encodeDm(listOf(msg))).single()
        assertEquals(msg, decoded)
    }

    @Test fun meshEnvelopeRoundTripPreservesInternetTransportFlag() {
        // Slice 4: a merged mesh thread can hold both BLE legs and direct
        // NIP-17 internet legs (viaInternet drives the bubble colour). The
        // flag must survive the exact on-disk format saveMeshDm writes and
        // loadAllMeshDms reads back after an app restart.
        val peerKey = "7a60f087831cb56d0011223344556677"
        val msgs = listOf(
            SonarMsg("m1", "npub1peer", "over BLE", mine = false, tsSecs = 10),
            SonarMsg("m2", "npub1peer", "over NIP-17", mine = false, tsSecs = 20, viaInternet = true),
            SonarMsg("m3", "", "my reply via internet", mine = true, tsSecs = 30, viaInternet = true),
        )
        val (key, decoded) = MessageCodec.decodeMeshEnvelope(
            MessageCodec.encodeMeshEnvelope(peerKey, msgs)
        )!!
        assertEquals(peerKey, key)
        assertEquals(msgs, decoded)
        assertEquals(listOf(false, true, true), decoded.map { it.viaInternet })
    }

    @Test fun dmRoundTripWithStickerAndMedia() {
        val ref = SonarStickerRef("30031:abc123:pack", "wave", "deadbeef")
        val media = SonarMedia("mesh-media:peer:message:voice.m4a", "audio/mp4", "voice.m4a", null, null, 1200)
        val msg = SonarMsg("a", "npub1xx", "", mine = false, tsSecs = 3, media = listOf(media), stickerRef = ref)
        val decoded = MessageCodec.decodeDm(MessageCodec.encodeDm(listOf(msg))).single()
        assertEquals(ref, decoded.stickerRef)
        assertEquals(media, decoded.media.single())
    }

    @Test fun dmRoundTripWithMediaCaption() {
        val media = SonarMedia(
            "mesh-media:peer:message:photo.jpg", "image/jpeg", "photo.jpg", 640, 480, null,
            caption = "sunset at the pier\nwith tabs\tand |pipes| ⚡",
        )
        val msgs = listOf(
            SonarMsg("a", "npub1xx", "", mine = true, tsSecs = 1, media = listOf(media)),
            // Media WITHOUT caption in the same blob must stay caption-less.
            SonarMsg(
                "b", "npub1yy", "", mine = false, tsSecs = 2,
                media = listOf(SonarMedia("mesh-media:x:y:v.m4a", "audio/mp4", "v.m4a", null, null, 900)),
            ),
        )
        val decoded = MessageCodec.decodeDm(MessageCodec.encodeDm(msgs))
        assertEquals(msgs, decoded)
        assertEquals(media.caption, decoded[0].media.single().caption)
        assertNull(decoded[1].media.single().caption)
    }

    @Test fun dmDecodeToleratesPreCaptionEnvelopes() {
        // An envelope written by a build BEFORE the caption field (15 fields,
        // ending at viaInternet) must decode with caption = null.
        val media = SonarMedia("mesh-media:p:m:photo.jpg", "image/jpeg", "photo.jpg", 640, 480, null)
        val msg = SonarMsg("a", "npub1xx", "", mine = true, tsSecs = 1, media = listOf(media), viaInternet = true)
        val encoded = MessageCodec.encodeDm(listOf(msg))
        // Strip caption + newer delivery/effect fields to simulate the old format.
        val old = encoded.split("\t").dropLast(3).joinToString("\t")
        val decoded = MessageCodec.decodeDm(old).single()
        assertEquals(media, decoded.media.single())
        assertNull(decoded.media.single().caption)
        assertTrue(decoded.viaInternet)
    }

    @Test fun dmBackwardCompatOldFormatNoSticker() {
        val old = listOf(
            SonarMsg("a", "npub1xx", "hello", mine = true, tsSecs = 1),
        )
        val encoded = old.joinToString("\n") { m ->
            listOf(m.id, m.senderNpub, if (m.mine) "1" else "0", m.tsSecs.toString(), m.content)
                .joinToString("\t") { s -> s.encodeToByteArray().joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) } }
        }
        val decoded = MessageCodec.decodeDm(encoded)
        assertEquals(1, decoded.size)
        assertEquals("hello", decoded[0].content)
        assertNull(decoded[0].stickerRef)
    }
}

class MessageMergeTest {
    @Test fun dedupesByIdNewestWinsSortedCapped() {
        val stored = listOf(
            SonarChannelMsg("a", "x", "p", "old-a", false, 10),
            SonarChannelMsg("b", "x", "p", "b", false, 20),
        )
        val fresh = listOf(
            SonarChannelMsg("a", "x", "p", "new-a", false, 10), // same id → fresh wins
            SonarChannelMsg("c", "x", "p", "c", false, 5),       // older ts sorts first
        )
        val merged = MessageMerge.channels(stored, fresh)
        assertEquals(listOf("c", "a", "b"), merged.map { it.id })
        assertEquals("new-a", merged.first { it.id == "a" }.content)
    }

    @Test fun capLimitsToMostRecent() {
        val many = (1..600).map { SonarChannelMsg("id$it", "x", "p", "m$it", false, it.toLong()) }
        val merged = MessageMerge.channels(emptyList(), many)
        assertEquals(MESSAGE_STORE_CAP, merged.size)
        assertEquals("id600", merged.last().id) // newest kept
        assertEquals("id101", merged.first().id) // oldest 100 dropped
    }
}
