package chat.bitchat.sonar.store

/** Platform directory barriers use this strict adapter so open, fsync/force,
 * and close failures all remain observable to the caller. */
internal inline fun durabilityBarrier(block: () -> Unit): Boolean =
    try {
        block()
        true
    } catch (_: Throwable) {
        false
    }

/** A bounded legacy scan result. [token] is opaque to shared code and lets the
 * platform delete malformed or trimmed files without reconstructing a path. */
internal data class LegacyPendingPayload(val token: String, val payload: String)

internal data class LegacyPendingScan(
    val records: List<LegacyPendingPayload>,
    /** Last opaque token returned by this page. Pass it back to continue. */
    val nextCursor: String? = records.lastOrNull()?.token,
    /** True when at least one record exists strictly after [nextCursor]. */
    val hasMore: Boolean = false,
    val success: Boolean = true,
)

/** Strict durability boundary supplied by Android/Desktop. Every mutating call
 * returns true only after rename/delete and directory fsync (including close)
 * have succeeded. */
internal interface PendingOutboxBackend {
    fun indexExists(): Boolean
    fun readIndex(): String?
    fun writeIndex(payload: String): Boolean
    /** Snapshot and sort legacy names once. Payloads are still read in bounded
     * chunks, but migration never repeats a full directory enumerate/sort. */
    fun snapshotLegacyTokens(): List<String>?
    fun readLegacy(tokens: List<String>): List<LegacyPendingPayload>?
    fun readRecord(peerId: String, messageId: String): String?
    fun writeRecord(peerId: String, messageId: String, payload: String): Boolean
    fun deleteRecords(keys: List<Pair<String, String>>): Boolean
    fun deleteLegacy(tokens: List<String>): Boolean
}

/** Crash-safe metadata index over individual payload files. Admissions rewrite
 * at most 500 metadata rows and never enumerate the directory after the first
 * bounded legacy migration. Index-first admission makes an interrupted write a
 * harmless reservation; two-phase deletion makes an interrupted retirement a
 * durable tombstone that is completed on the next load. */
internal class DurablePendingOutbox<Record>(
    private val backend: PendingOutboxBackend,
    private val encodeRecord: (Record) -> String,
    private val decodeRecord: (String) -> Record?,
    private val peerId: (Record) -> String,
    private val messageId: (Record) -> String,
    private val timestampSecs: (Record) -> Long,
    private val sequence: (Record) -> Long,
    private val withSequence: (Record, Long) -> Record,
    private val equivalent: (Record, Record) -> Boolean,
    private val expiredAt: (Long) -> Boolean = { false },
) {
    private var cachedEntries: List<PendingOutboxIndexEntry>? = null

    fun invalidate() {
        cachedEntries = null
    }

    fun load(): List<Record> {
        var entries = ensureIndex() ?: return emptyList()
        val deleting = entries.filter { it.state == PendingOutboxEntryState.Deleting }
        if (deleting.isNotEmpty()) {
            entries = completeRetirement(entries, deleting) ?: entries
        }

        val valid = ArrayList<Pair<PendingOutboxIndexEntry, Record>>()
        val stale = ArrayList<PendingOutboxIndexEntry>()
        entries.filter { it.state == PendingOutboxEntryState.Active }.forEach { entry ->
            val payload = backend.readRecord(entry.peerId, entry.messageId)
            val record = payload?.takeIf {
                pendingOutboxPayloadDigest(it) == entry.payloadDigest
            }?.let(decodeRecord)
            if (expiredAt(entry.timestampSecs) || record == null ||
                peerId(record) != entry.peerId ||
                messageId(record) != entry.messageId ||
                sequence(record) != entry.sequence
            ) {
                stale += entry
            } else {
                valid += entry to record
            }
        }
        if (stale.isNotEmpty()) {
            completeRetirement(entries, stale)?.let { cachedEntries = it }
        }
        return valid.map { it.second }.sortedWith(
            compareBy<Record> { peerId(it) }.thenBy { sequence(it) }.thenBy { messageId(it) },
        )
    }

    fun save(proposed: Record): Record? {
        var entries = ensureIndex() ?: return null
        val expired = entries.filter {
            it.state == PendingOutboxEntryState.Active && expiredAt(it.timestampSecs)
        }
        if (expired.isNotEmpty()) {
            entries = completeRetirement(entries, expired) ?: return null
        }
        val peer = peerId(proposed)
        val id = messageId(proposed)
        if (peer.isBlank() || id.isBlank()) return null
        val existingEntry = entries.firstOrNull { it.peerId == peer && it.messageId == id }
        if (existingEntry != null) {
            if (existingEntry.state != PendingOutboxEntryState.Active) return null
            val admitted = withSequence(proposed, existingEntry.sequence)
            val existingPayload = backend.readRecord(peer, id)
            val recovered = if (existingPayload == null) {
                admitted
            } else {
                if (pendingOutboxPayloadDigest(existingPayload) != existingEntry.payloadDigest) return null
                val existing = decodeRecord(existingPayload) ?: return null
                existing.takeIf {
                    peerId(it) == peer && messageId(it) == id &&
                        sequence(it) == existingEntry.sequence &&
                        timestampSecs(it) == existingEntry.timestampSecs &&
                        equivalent(it, admitted)
                } ?: return null
            }
            val payload = encodeRecord(recovered)
            if (pendingOutboxPayloadDigest(payload) != existingEntry.payloadDigest) return null
            // A previous atomic rename can be visible even though its parent-dir
            // fsync failed. Recommit BOTH namespaces on every stable-id retry;
            // merely decoding the visible payload would upgrade an unproven write
            // to success and allow transport bytes without a durable obligation.
            if (!backend.writeIndex(PendingOutboxIndexCodec.encode(entries))) return null
            if (!backend.writeRecord(peer, id, payload)) return null
            return recovered
        }

        // A payload file left by a pre-index build or a crash after an older
        // index was replaced is recovered with an O(1) deterministic lookup.
        val orphanPayload = backend.readRecord(peer, id)
        val orphan = orphanPayload?.let(decodeRecord)?.takeIf {
            peerId(it) == peer && messageId(it) == id && equivalent(it, proposed)
        }
        val peerEntries = entries.count { it.peerId == peer }
        if (entries.size >= PENDING_OUTBOX_GLOBAL_LIMIT || peerEntries >= PENDING_OUTBOX_PER_PEER_LIMIT) return null
        val maxSequence = entries.asSequence().filter { it.peerId == peer }.maxOfOrNull { it.sequence } ?: 0L
        val admittedSequence = when {
            orphan != null && sequence(orphan) > 0L -> sequence(orphan)
            maxSequence == Long.MAX_VALUE -> return null
            else -> maxSequence + 1L
        }
        val admitted = withSequence(orphan ?: proposed, admittedSequence)
        val payload = encodeRecord(admitted)
        val entry = PendingOutboxIndexEntry(
            peerId = peer,
            messageId = id,
            timestampSecs = timestampSecs(admitted),
            sequence = admittedSequence,
            payloadDigest = pendingOutboxPayloadDigest(payload),
        )
        val next = entries + entry
        if (!backend.writeIndex(PendingOutboxIndexCodec.encode(next))) return null
        cachedEntries = next
        if (orphanPayload == null || orphanPayload != payload) {
            if (!backend.writeRecord(peer, id, payload)) return null
        }
        return admitted
    }

    fun delete(peer: String, id: String): Boolean {
        val entries = ensureIndex() ?: return false
        val matches = entries.filter { it.peerId == peer && it.messageId == id }
        if (matches.isEmpty()) {
            // Idempotent cleanup also removes a deterministic orphan.
            return backend.deleteRecords(listOf(peer to id))
        }
        return completeRetirement(entries, matches) != null
    }

    fun deletePeer(peer: String): Boolean {
        val entries = ensureIndex() ?: return false
        val matches = entries.filter { it.peerId == peer }
        if (matches.isEmpty()) return true
        return completeRetirement(entries, matches) != null
    }

    private fun ensureIndex(): List<PendingOutboxIndexEntry>? {
        cachedEntries?.let { return it }
        if (backend.indexExists()) {
            val decoded = backend.readIndex()?.let(PendingOutboxIndexCodec::decode) ?: return null
            cachedEntries = decoded
            return decoded
        }
        data class Candidate(val token: String, val entry: PendingOutboxIndexEntry)

        // A legacy directory can be much larger than the admission window. Walk
        // it in fixed-size pages until exhaustion while retaining only the best
        // bounded set. Creating the index after a single hash-ordered page would
        // make every later obligation permanently invisible.
        val tokens = backend.snapshotLegacyTokens() ?: return null
        var retained = emptyList<Candidate>()
        tokens.chunked(PENDING_OUTBOX_MIGRATION_SCAN_LIMIT).forEach { chunk ->
            val records = backend.readLegacy(chunk) ?: return null
            if (records.map { it.token } != chunk) return null

            val malformed = ArrayList<String>()
            val page = records.mapNotNull { legacy ->
                val record = decodeRecord(legacy.payload)
                if (record == null || peerId(record).isBlank() || messageId(record).isBlank() || sequence(record) <= 0L) {
                    malformed += legacy.token
                    null
                } else {
                    Candidate(
                        token = legacy.token,
                        entry = PendingOutboxIndexEntry(
                            peerId = peerId(record),
                            messageId = messageId(record),
                            timestampSecs = timestampSecs(record),
                            sequence = sequence(record),
                            payloadDigest = pendingOutboxPayloadDigest(encodeRecord(record)),
                        ),
                    )
                }
            }

            val combined = (retained + page)
                .sortedWith(
                    compareBy<Candidate> { it.entry.timestampSecs }
                        .thenBy { it.entry.sequence }
                        .thenBy { it.entry.peerId }
                        .thenBy { it.entry.messageId }
                        .thenBy { it.token },
                )
                .distinctBy { it.entry.peerId to it.entry.messageId }
            val retainedEntries = boundedPendingOutboxEntries(combined.map { it.entry })
            val retainedKeys = retainedEntries.mapTo(hashSetOf()) { it.peerId to it.messageId }
            val nextRetained = combined.filter { (it.entry.peerId to it.entry.messageId) in retainedKeys }
            val keptTokens = nextRetained.mapTo(hashSetOf()) { it.token }
            val retired = (retained + page).asSequence()
                .map { it.token }
                .filter { it !in keptTokens }
                .distinct()
                .toList()
            if (!backend.deleteLegacy(malformed + retired)) return null
            retained = nextRetained
        }

        val entries = retained.map { it.entry }
        if (!backend.writeIndex(PendingOutboxIndexCodec.encode(entries))) return null
        cachedEntries = entries
        return entries
    }

    private fun completeRetirement(
        entries: List<PendingOutboxIndexEntry>,
        retiring: List<PendingOutboxIndexEntry>,
    ): List<PendingOutboxIndexEntry>? {
        val keys = retiring.mapTo(hashSetOf()) { it.peerId to it.messageId }
        val tombstoned = entries.map {
            if ((it.peerId to it.messageId) in keys) it.copy(state = PendingOutboxEntryState.Deleting) else it
        }
        if (tombstoned != entries) {
            if (!backend.writeIndex(PendingOutboxIndexCodec.encode(tombstoned))) return null
            cachedEntries = tombstoned
        }
        if (!backend.deleteRecords(keys.toList())) return null
        val remaining = tombstoned.filterNot { (it.peerId to it.messageId) in keys }
        if (!backend.writeIndex(PendingOutboxIndexCodec.encode(remaining))) return null
        cachedEntries = remaining
        return remaining
    }
}
