package chat.bitchat.sonar.store

import chat.bitchat.sonar.MeshPendingDeliveryRecord
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DurablePendingOutboxTest {
    private class FakeBackend : PendingOutboxBackend {
        var index: String? = null
        val records = linkedMapOf<Pair<String, String>, String>()
        val legacy = linkedMapOf<String, String>()
        var scans = 0
        var failIndexWrite = false
        var failRecordWrite = false
        var failRecordWriteAfterVisible = false
        var failDeleteSync = false
        var indexWrites = 0
        var recordWrites = 0
        var legacyEnumerations = 0

        override fun indexExists(): Boolean = index != null
        override fun readIndex(): String? = index
        override fun writeIndex(payload: String): Boolean {
            indexWrites += 1
            if (failIndexWrite) return false
            index = payload
            return true
        }

        override fun snapshotLegacyTokens(): List<String> {
            legacyEnumerations += 1
            return legacy.keys.sorted()
        }

        override fun readLegacy(tokens: List<String>): List<LegacyPendingPayload>? {
            scans += 1
            return tokens.map { token ->
                LegacyPendingPayload(token, legacy[token] ?: return null)
            }
        }

        override fun readRecord(peerId: String, messageId: String): String? = records[peerId to messageId]

        override fun writeRecord(peerId: String, messageId: String, payload: String): Boolean {
            recordWrites += 1
            if (failRecordWrite) return false
            records[peerId to messageId] = payload
            if (failRecordWriteAfterVisible) return false
            return true
        }

        override fun deleteRecords(keys: List<Pair<String, String>>): Boolean {
            keys.forEach(records::remove)
            return !failDeleteSync
        }

        override fun deleteLegacy(tokens: List<String>): Boolean {
            tokens.forEach { token ->
                legacy.remove(token)?.let(MessageCodec::decodeMeshPending)?.let { record ->
                    records.remove(record.peerId to record.messageId)
                }
            }
            return !failDeleteSync
        }
    }

    private fun outbox(backend: FakeBackend) = DurablePendingOutbox(
        backend = backend,
        encodeRecord = MessageCodec::encodeMeshPending,
        decodeRecord = MessageCodec::decodeMeshPending,
        peerId = MeshPendingDeliveryRecord::peerId,
        messageId = MeshPendingDeliveryRecord::messageId,
        timestampSecs = MeshPendingDeliveryRecord::timestampSecs,
        sequence = MeshPendingDeliveryRecord::sequence,
        withSequence = { record, sequence -> record.copy(sequence = sequence) },
        equivalent = { left, right ->
            left.peerId == right.peerId && left.messageId == right.messageId &&
                left.text == right.text && left.surfaceInTranscript == right.surfaceInTranscript
        },
    )

    private fun record(peer: String, id: String, sequence: Long = 0L) = MeshPendingDeliveryRecord(
        peerId = peer,
        messageId = id,
        text = "payload for $peer/$id\nwith\ttabs|and unicode ⚡",
        timestampSecs = sequence + 1_000L,
        sequence = sequence,
    )

    @Test
    fun indexCodecRoundTripsDelimiterUnsafeIdentifiersAndDeletionState() {
        val entries = listOf(
            PendingOutboxIndexEntry(
                peerId = "peer\nA\t|⚡",
                messageId = "message\t1\n|",
                timestampSecs = 123,
                sequence = 7,
                payloadDigest = "dead\tbeef\n|",
                state = PendingOutboxEntryState.Deleting,
            ),
        )
        assertEquals(entries, PendingOutboxIndexCodec.decode(PendingOutboxIndexCodec.encode(entries)))
        assertNull(PendingOutboxIndexCodec.decode("not-an-index"))
    }

    @Test
    fun durabilityBarrierPropagatesOpenFsyncAndCloseFailures() {
        assertTrue(durabilityBarrier { })
        assertFalse(durabilityBarrier { error("open failed") })
        assertFalse(durabilityBarrier { error("fsync failed") })
        assertFalse(durabilityBarrier { error("close failed") })
    }

    @Test
    fun deterministicBoundsApplyPerPeerAndGlobally() {
        val candidates = buildList {
            repeat(120) { add(indexEntry("peer-a", "a-$it", it.toLong())) }
            repeat(450) { add(indexEntry("peer-$it", "b-$it", (1_000 + it).toLong())) }
        }
        val retained = boundedPendingOutboxEntries(candidates)
        assertEquals(PENDING_OUTBOX_GLOBAL_LIMIT, retained.size)
        assertEquals(PENDING_OUTBOX_PER_PEER_LIMIT, retained.count { it.peerId == "peer-a" })
        assertEquals(retained, boundedPendingOutboxEntries(candidates.reversed()))
    }

    @Test
    fun legacyMigrationIsBoundedTrimmedAndRunsOnlyOnce() {
        val backend = FakeBackend()
        repeat(520) { index ->
            val record = record("peer-$index", "id-$index", sequence = 1)
            val payload = MessageCodec.encodeMeshPending(record)
            backend.legacy["legacy-$index.txt"] = payload
            backend.records[record.peerId to record.messageId] = payload
        }
        val outbox = outbox(backend)

        assertEquals(PENDING_OUTBOX_GLOBAL_LIMIT, outbox.load().size)
        assertEquals(1, backend.scans)
        assertEquals(1, backend.legacyEnumerations)
        assertEquals(20, 520 - backend.legacy.size)
        assertTrue(outbox.delete("peer-0", "id-0"))
        assertEquals(1, outbox.save(record("new-peer", "new-id"))?.sequence)
        assertEquals(1, backend.scans)
    }

    @Test
    fun legacyMigrationConsumesEveryChunkAndDoesNotKeepTheFirstHashSubset() {
        val backend = FakeBackend()
        repeat(PENDING_OUTBOX_MIGRATION_SCAN_LIMIT + 500) { index ->
            // Lexical file order is deliberately the reverse of obligation age:
            // the final page contains the 500 oldest records that must win.
            val age = PENDING_OUTBOX_MIGRATION_SCAN_LIMIT + 500 - index
            val pending = record("peer-$index", "id-$index", sequence = age.toLong())
            val payload = MessageCodec.encodeMeshPending(pending)
            backend.legacy["legacy-${index.toString().padStart(4, '0')}.txt"] = payload
            backend.records[pending.peerId to pending.messageId] = payload
        }

        val loaded = outbox(backend).load()

        assertEquals(PENDING_OUTBOX_GLOBAL_LIMIT, loaded.size)
        assertEquals(2, backend.scans)
        assertEquals(1, backend.legacyEnumerations)
        assertEquals((1L..500L).toList(), loaded.map { it.sequence }.sorted())
        assertEquals(PENDING_OUTBOX_GLOBAL_LIMIT, backend.legacy.size)
    }

    @Test
    fun admissionIsIdempotentAndNeverRescansAfterIndexCreation() {
        val backend = FakeBackend()
        val outbox = outbox(backend)
        val first = outbox.save(record("peer", "stable-id"))!!
        val duplicate = outbox.save(record("peer", "stable-id"))!!

        assertEquals(first, duplicate)
        assertEquals(1L, first.sequence)
        assertEquals(1, backend.records.size)
        assertEquals(0, backend.scans)
        assertEquals(1, backend.legacyEnumerations)
    }

    @Test
    fun indexFsyncFailureWithholdsAdmissionAndPayloadWrite() {
        val backend = FakeBackend().apply { failIndexWrite = true }
        val outbox = outbox(backend)

        assertNull(outbox.save(record("peer", "id")))
        assertTrue(backend.records.isEmpty())
    }

    @Test
    fun interruptedIndexFirstAdmissionCanRetrySameStableId() {
        val backend = FakeBackend().apply { failRecordWrite = true }
        val outbox = outbox(backend)
        val proposed = record("peer", "stable-id")
        assertNull(outbox.save(proposed))
        assertTrue(backend.indexExists())

        backend.failRecordWrite = false
        assertEquals(1L, outbox.save(proposed)?.sequence)
        assertEquals(1, outbox.load().size)
    }

    @Test
    fun retryRecommitsVisiblePayloadAfterPostRenameDirectorySyncFailure() {
        val backend = FakeBackend().apply { failRecordWriteAfterVisible = true }
        val outbox = outbox(backend)
        val proposed = record("peer", "stable-id")

        // Models atomic rename succeeding followed by the payload parent fsync
        // failing: bytes are visible, but admission must remain false.
        assertNull(outbox.save(proposed))
        assertTrue(backend.records.containsKey("peer" to "stable-id"))
        // Initial migration commits the empty v1 index, then admission commits
        // the stable-id reservation before the payload barrier fails.
        assertEquals(2, backend.indexWrites)
        assertEquals(1, backend.recordWrites)

        backend.failRecordWriteAfterVisible = false
        assertEquals(1L, outbox.save(proposed)?.sequence)
        // Stable-id recovery re-establishes both the index and payload barriers.
        assertEquals(3, backend.indexWrites)
        assertEquals(2, backend.recordWrites)
    }

    @Test
    fun deleteFsyncFailureLeavesTombstoneAndWithholdsCompletion() {
        val backend = FakeBackend()
        val outbox = outbox(backend)
        outbox.save(record("peer", "stable-id"))
        backend.failDeleteSync = true

        assertFalse(outbox.delete("peer", "stable-id"))
        val tombstone = PendingOutboxIndexCodec.decode(backend.index.orEmpty())!!.single()
        assertEquals(PendingOutboxEntryState.Deleting, tombstone.state)

        backend.failDeleteSync = false
        val recovered = outbox(backend)
        assertTrue(recovered.load().isEmpty())
        assertTrue(PendingOutboxIndexCodec.decode(backend.index.orEmpty())!!.isEmpty())
    }

    private fun indexEntry(peer: String, id: String, order: Long) = PendingOutboxIndexEntry(
        peerId = peer,
        messageId = id,
        timestampSecs = order,
        sequence = order + 1,
        payloadDigest = "digest-$id",
    )
}
