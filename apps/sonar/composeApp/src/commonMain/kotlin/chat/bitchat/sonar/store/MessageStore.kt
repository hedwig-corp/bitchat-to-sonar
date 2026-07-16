package chat.bitchat.sonar.store

import chat.bitchat.sonar.SonarChannelMsg
import chat.bitchat.sonar.SonarMedia
import chat.bitchat.sonar.SonarMsg
import chat.bitchat.sonar.SonarStickerRef
import chat.bitchat.sonar.MeshPendingDeliveryRecord
import chat.bitchat.sonar.QueuedMessage
import chat.bitchat.sonar.crypto.Sha256
import kotlinx.coroutines.sync.Mutex

/**
 * On-device persistence of transcripts that the relays do NOT keep, so they
 * survive an app restart — the Android twin of the iOS `MessageStore`.
 *
 * White Noise (Marmot) DMs already persist in the encrypted SQLCipher DB via
 * MDK, so they are NOT handled here. This store covers:
 *  - geohash **channels** (kind 20000 ephemeral — relays never store them; once
 *    missed they are gone),
 *  - geohash **DMs** (buffered in the Rust core in memory, reset each launch), and
 *  - **BLE-mesh private DMs** (the Noise-link conversations — they live only in
 *    app memory, so without this they vanish on restart). This brings Android to
 *    parity with the iOS `MessageStore`, which persists mesh private chats.
 *
 * Files live under the app's private storage, which Android File-Based
 * Encryption keeps encrypted at rest (analogous to iOS NSFileProtectionComplete).
 */
expect object MessageStore {
    /** Monotonic account-storage generation, changed by every committed wipe. */
    fun storageEpoch(): Long
    // suspend so the file I/O runs off the main thread (the Android actual
    // dispatches to Dispatchers.IO) — avoids an ANR on a cold/large store.
    suspend fun loadChannel(geohash: String): List<SonarChannelMsg>
    suspend fun saveChannel(geohash: String, msgs: List<SonarChannelMsg>, expectedEpoch: Long = storageEpoch())
    suspend fun loadGeoDm(geohash: String, peerHex: String): List<SonarMsg>
    suspend fun saveGeoDm(geohash: String, peerHex: String, msgs: List<SonarMsg>, expectedEpoch: Long = storageEpoch())
    /** Bounded newest-conversation metadata used for the first local paint. */
    suspend fun loadMeshDmSummaries(limit: Int = MESH_DM_SUMMARY_LIMIT): List<MeshDmSummary>
    /** Stable keyset page over the complete authoritative mesh summary catalog.
     * This is deliberately separate from [loadMeshDmSummaries]: launch reads one
     * bounded recent page, while the complete catalog hydrates in background. */
    suspend fun loadMeshDmSummaryPage(
        afterCursor: String? = null,
        limit: Int = MESH_DM_SUMMARY_LIMIT,
    ): MeshDmSummaryPage
    /** Bounded O(1)-by-key transcript read used when a mesh conversation opens. */
    suspend fun loadMeshDm(peerKey: String, limit: Int = MESSAGE_STORE_CAP): List<SonarMsg>
    /** Background-only legacy scan that rebuilds the complete catalog and its
     * bounded recent first-paint page. */
    suspend fun repairMeshDmSummaries()
    /** Write-through a single peer's BLE-mesh transcript (called on every append). */
    /** True only after the complete transcript has been written locally. */
    suspend fun saveMeshDm(peerKey: String, msgs: List<SonarMsg>, revision: Long, expectedEpoch: Long = storageEpoch()): Boolean
    /** Delete a single peer's BLE-mesh transcript file (per-chat delete). */
    suspend fun deleteMeshDm(peerKey: String, revision: Long, expectedEpoch: Long = storageEpoch()): Boolean
    suspend fun loadMeshPending(): List<MeshPendingDeliveryRecord>
    /** Atomically admits and sequences a bounded per-peer delivery, or null. */
    suspend fun saveMeshPending(record: MeshPendingDeliveryRecord, expectedEpoch: Long = storageEpoch()): MeshPendingDeliveryRecord?
    suspend fun deleteMeshPending(peerKey: String, messageId: String, expectedEpoch: Long = storageEpoch()): Boolean
    suspend fun deleteMeshPendingForPeer(peerKey: String, expectedEpoch: Long = storageEpoch()): Boolean
    suspend fun loadRoutePending(): List<QueuedMessage>
    /** Atomically admits and sequences a bounded route-agnostic message, or null. */
    suspend fun saveRoutePending(record: QueuedMessage, expectedEpoch: Long = storageEpoch()): QueuedMessage?
    suspend fun deleteRoutePending(peerKey: String, messageId: String, expectedEpoch: Long = storageEpoch()): Boolean
    suspend fun deleteRoutePendingForPeer(peerKey: String, expectedEpoch: Long = storageEpoch()): Boolean
    /** Save local bytes for a mesh media attachment referenced by `mesh-media:*`. */
    /** True only after the attachment bytes are durably committed. */
    suspend fun saveMeshMedia(mediaUrl: String, bytes: ByteArray, expectedEpoch: Long = storageEpoch()): Boolean
    /** Load local bytes for a mesh media attachment referenced by `mesh-media:*`. */
    suspend fun loadMeshMedia(mediaUrl: String): ByteArray?
    /** Quarantine is the privacy/account boundary; cleanup may be retried later. */
    suspend fun wipe(revision: Long): MessageStoreWipeResult
}

/** Cap kept on disk per conversation (matches the in-memory timeline). */
const val MESSAGE_STORE_CAP = 500

/** First paint is a fixed local page, independent of total transcript count. */
const val MESH_DM_SUMMARY_LIMIT = 200
internal const val MESH_SUMMARY_CATALOG_PAGE_SIZE = MESH_DM_SUMMARY_LIMIT

data class MeshDmSummary(val peerKey: String, val latest: SonarMsg)

data class MeshDmSummaryPage(
    val summaries: List<MeshDmSummary>,
    /** Opaque stable keyset cursor. Null means the catalog is exhausted. */
    val nextCursor: String?,
)

/** Direct page/offset cursor over fixed catalog pages. Reading any cursor calls
 * [readPeerPage] exactly once and touches at most [limit] summary records. */
internal fun readBoundedMeshSummaryCatalogPage(
    afterCursor: String?,
    limit: Int,
    lastPage: () -> Int?,
    readPeerPage: (Int) -> List<String?>?,
    readSummary: (String) -> MeshDmSummary?,
): MeshDmSummaryPage {
    val boundedLimit = limit.coerceIn(0, MESH_SUMMARY_CATALOG_PAGE_SIZE)
    if (boundedLimit == 0) return MeshDmSummaryPage(emptyList(), afterCursor)
    val tail = lastPage() ?: return MeshDmSummaryPage(emptyList(), null)
    val parts = afterCursor?.split(':')
    var pageNumber = parts?.getOrNull(0)?.toIntOrNull() ?: 0
    var offset = parts?.getOrNull(1)?.toIntOrNull() ?: 0
    if (afterCursor != null) {
        if (parts?.size != 2 || pageNumber < 0 || offset < 0) return MeshDmSummaryPage(emptyList(), null)
    }
    if (pageNumber > tail) return MeshDmSummaryPage(emptyList(), null)
    val peers = readPeerPage(pageNumber).orEmpty()
    if (offset > peers.size) return MeshDmSummaryPage(emptyList(), null)
    val selected = peers.drop(offset).take(boundedLimit)
    val summaries = selected.mapNotNull { peer -> peer?.let(readSummary) }
    offset += selected.size
    val next = when {
        offset < peers.size -> "$pageNumber:$offset"
        pageNumber < tail -> "${pageNumber + 1}:0"
        else -> null
    }
    return MeshDmSummaryPage(summaries, next)
}

data class MessageStoreWipeResult(
    /** The old namespace was visibly detached. This alone is not a durable wipe. */
    val oldNamespaceDetached: Boolean,
    /** The detach was committed by a successful parent-directory barrier. */
    val quarantined: Boolean,
    /** Tombstone removal and its parent-directory barrier also completed. */
    val cleanupComplete: Boolean,
    /** Rollback could not prove either the old or detached namespace durable. */
    val rollbackAmbiguous: Boolean,
)

internal enum class MessageStoreRollbackOutcome {
    Restored,
    StillDetached,
    Ambiguous,
}

/** Shared transaction order used by both platform stores. A failed catalog
 * commit leaves the repair intent in place and can never be reported as a
 * successful transcript mutation. */
internal inline fun commitMeshSummaryTransaction(
    writeRepairIntent: () -> Boolean,
    mutateTranscript: () -> Boolean,
    commitCatalog: () -> Boolean,
    clearRepairIntent: () -> Boolean,
): Boolean {
    if (!writeRepairIntent()) return false
    if (!mutateTranscript()) return false
    if (!commitCatalog()) return false
    return clearRepairIntent()
}

/** Advance the active epoch immediately after the visible rename, but expose a
 * durable quarantine only after the parent directory barrier. A failed barrier
 * attempts a durable rollback; regardless of its result the advanced epoch
 * continues fencing every queued old-namespace writer. */
internal inline fun commitMessageStoreRetirement(
    detachNamespace: () -> Boolean,
    advanceEpoch: () -> Unit,
    proveDetachedDurable: () -> Boolean,
    rollbackNamespace: () -> MessageStoreRollbackOutcome,
    cleanup: () -> Boolean,
): MessageStoreWipeResult {
    if (!detachNamespace()) {
        return MessageStoreWipeResult(
            oldNamespaceDetached = false,
            quarantined = false,
            cleanupComplete = false,
            rollbackAmbiguous = false,
        )
    }
    advanceEpoch()
    if (!proveDetachedDurable()) {
        return when (rollbackNamespace()) {
            MessageStoreRollbackOutcome.Restored -> MessageStoreWipeResult(false, false, false, false)
            MessageStoreRollbackOutcome.StillDetached -> MessageStoreWipeResult(true, false, false, false)
            MessageStoreRollbackOutcome.Ambiguous -> MessageStoreWipeResult(false, false, false, true)
        }
    }
    return MessageStoreWipeResult(
        oldNamespaceDetached = true,
        quarantined = true,
        cleanupComplete = cleanup(),
        rollbackAmbiguous = false,
    )
}

/** Merge a background repair snapshot with the bounded page committed while the
 * scan was in flight. The liveness predicate is evaluated under the final short
 * commit lock, so a newly saved peer cannot be erased by an older snapshot. */
internal fun mergeRecentMeshSummaryRepair(
    scannedRecent: List<MeshDmSummary>,
    concurrentlyCommittedRecent: List<MeshDmSummary>,
    isLive: (String) -> Boolean,
): List<MeshDmSummary> {
    val newestByPeer = LinkedHashMap<String, MeshDmSummary>()
    scannedRecent.forEach { newestByPeer[it.peerKey] = it }
    // The bounded page read at final commit time wins over the stale scan.
    concurrentlyCommittedRecent.forEach { newestByPeer[it.peerKey] = it }
    return boundedMeshDmSummaries(newestByPeer.values.filter { isLive(it.peerKey) })
}

internal fun staleRepairMayRemoveCatalogPeer(
    peerKey: String,
    peersInTranscriptSnapshot: Set<String>,
    transcriptStillExists: Boolean,
): Boolean = peerKey !in peersInTranscriptSnapshot && !transcriptStillExists

/** Transcript IO and potentially large legacy outbox migration deliberately
 * use independent locks. Wipe is the only operation that takes both. */
internal class MessageStoreMutationLocks {
    private val transcript = Mutex()
    private val outbox = Mutex()

    suspend fun <T> withTranscript(block: suspend () -> T): T {
        transcript.lock()
        return try { block() } finally { transcript.unlock() }
    }

    suspend fun <T> withOutbox(block: suspend () -> T): T {
        outbox.lock()
        return try { block() } finally { outbox.unlock() }
    }

    suspend fun <T> withWipe(block: suspend () -> T): T {
        transcript.lock()
        return try {
            outbox.lock()
            try { block() } finally { outbox.unlock() }
        } finally {
            transcript.unlock()
        }
    }
}

/** Complete any pending single-peer repair while holding the transcript lock,
 * then enumerate the potentially large legacy transcript directory without
 * that lock. Every candidate is revalidated under a short lock before commit. */
internal suspend fun <T> snapshotMeshRepairCandidates(
    locks: MessageStoreMutationLocks,
    repairPending: suspend () -> Unit,
    enumerate: suspend () -> T,
): T {
    locks.withTranscript { repairPending() }
    return enumerate()
}

/** Preserve stable cursor offsets while ensuring a retry can never append the
 * same peer twice after the page write succeeded but its assignment did not. */
internal fun meshSummaryPageWithSinglePeer(
    peers: List<String?>,
    peerKey: String,
): List<String?>? {
    var found = false
    val canonical = peers.map { peer ->
        if (peer != peerKey) peer
        else if (!found) {
            found = true
            peer
        } else {
            null
        }
    }
    return when {
        found -> canonical
        canonical.size < MESH_SUMMARY_CATALOG_PAGE_SIZE -> canonical + peerKey
        else -> null
    }
}

/** A visible assignment is not necessarily durable: atomic replacement can
 * rename successfully and then fail its parent-directory barrier. Therefore a
 * retry must always recommit the marker, even when its page already has the
 * peer. The page is committed first only when it still needs the peer. */
internal inline fun commitMeshSummaryAssignment(
    pageContainsPeer: Boolean,
    commitPageIfRequired: () -> Boolean,
    commitAssignment: () -> Boolean,
): Boolean {
    if (!pageContainsPeer && !commitPageIfRequired()) return false
    return commitAssignment()
}

internal fun boundedMeshDmSummaries(
    summaries: List<MeshDmSummary>,
    limit: Int = MESH_DM_SUMMARY_LIMIT,
): List<MeshDmSummary> = summaries
    .filter { it.peerKey.isNotBlank() }
    .sortedWith(compareByDescending<MeshDmSummary> { it.latest.tsSecs }.thenBy { it.peerKey })
    .distinctBy { it.peerKey }
    .take(limit.coerceAtLeast(0))

/** Every durable send index is bounded independently. This prevents a stream of
 * distinct peer ids from bypassing the per-conversation limit and turning each
 * admission into unbounded filesystem work. */
internal const val PENDING_OUTBOX_GLOBAL_LIMIT = 500
internal const val PENDING_OUTBOX_PER_PEER_LIMIT = 100
internal const val PENDING_OUTBOX_MIGRATION_SCAN_LIMIT = 1_000

internal enum class PendingOutboxEntryState { Active, Deleting }

internal data class PendingOutboxIndexEntry(
    val peerId: String,
    val messageId: String,
    val timestampSecs: Long,
    val sequence: Long,
    val payloadDigest: String,
    val state: PendingOutboxEntryState = PendingOutboxEntryState.Active,
)

/** Versioned, delimiter-safe metadata index. Payloads remain in individual
 * fsynced files, so rewriting this bounded index never scales with message text. */
internal object PendingOutboxIndexCodec {
    private const val VERSION = "sonar-pending-index-v1"

    fun encode(entries: List<PendingOutboxIndexEntry>): String = buildString {
        append(VERSION)
        entries.forEach { entry ->
            append('\n')
            append(
                listOf(
                    entry.peerId,
                    entry.messageId,
                    entry.timestampSecs.toString(),
                    entry.sequence.toString(),
                    entry.payloadDigest,
                    if (entry.state == PendingOutboxEntryState.Active) "a" else "d",
                ).joinToString("\t") { hexEncode(it) },
            )
        }
    }

    fun decode(blob: String): List<PendingOutboxIndexEntry>? {
        val lines = blob.lineSequence().iterator()
        if (!lines.hasNext() || lines.next() != VERSION) return null
        val entries = ArrayList<PendingOutboxIndexEntry>()
        val keys = HashSet<Pair<String, String>>()
        while (lines.hasNext()) {
            if (entries.size >= PENDING_OUTBOX_GLOBAL_LIMIT) return null
            val line = lines.next()
            if (line.isBlank()) return null
            val fields = line.split('\t').map { hexDecode(it) ?: return null }
            if (fields.size != 6 || fields[0].isBlank() || fields[1].isBlank()) return null
            val entry = PendingOutboxIndexEntry(
                peerId = fields[0],
                messageId = fields[1],
                timestampSecs = fields[2].toLongOrNull() ?: return null,
                sequence = fields[3].toLongOrNull()?.takeIf { it > 0L } ?: return null,
                payloadDigest = fields[4].takeIf { it.isNotBlank() } ?: return null,
                state = when (fields[5]) {
                    "a" -> PendingOutboxEntryState.Active
                    "d" -> PendingOutboxEntryState.Deleting
                    else -> return null
                },
            )
            if (!keys.add(entry.peerId to entry.messageId)) return null
            entries += entry
        }
        return entries
    }

    private fun hexEncode(value: String): String =
        value.encodeToByteArray().joinToString("") {
            ((it.toInt() and 0xff) + 0x100).toString(16).substring(1)
        }

    private fun hexDecode(value: String): String? {
        if (value.length % 2 != 0) return null
        val bytes = ByteArray(value.length / 2)
        for (index in bytes.indices) {
            val high = value[index * 2].digitToIntOrNull(16) ?: return null
            val low = value[index * 2 + 1].digitToIntOrNull(16) ?: return null
            bytes[index] = ((high shl 4) or low).toByte()
        }
        return bytes.decodeToString()
    }
}

internal fun pendingOutboxPayloadDigest(payload: String): String =
    Sha256.hash(payload.encodeToByteArray()).joinToString("") {
        ((it.toInt() and 0xff) + 0x100).toString(16).substring(1)
    }

/** Deterministic legacy trimming: preserve the oldest admitted obligations,
 * first respecting each peer window and then the global window. */
internal fun boundedPendingOutboxEntries(
    candidates: List<PendingOutboxIndexEntry>,
    globalLimit: Int = PENDING_OUTBOX_GLOBAL_LIMIT,
    perPeerLimit: Int = PENDING_OUTBOX_PER_PEER_LIMIT,
): List<PendingOutboxIndexEntry> {
    if (globalLimit <= 0 || perPeerLimit <= 0) return emptyList()
    val peerCounts = mutableMapOf<String, Int>()
    val retained = ArrayList<PendingOutboxIndexEntry>(minOf(globalLimit, candidates.size))
    candidates.sortedWith(
        compareBy<PendingOutboxIndexEntry> { it.timestampSecs }
            .thenBy { it.sequence }
            .thenBy { it.peerId }
            .thenBy { it.messageId },
    ).forEach { entry ->
        if (retained.size >= globalLimit) return@forEach
        val count = peerCounts[entry.peerId] ?: 0
        if (count < perPeerLimit) {
            retained += entry
            peerCounts[entry.peerId] = count + 1
        }
    }
    return retained
}

/** A later UI mutation wins even when an earlier detached IO coroutine resumes
 * afterward. Equal revisions are idempotent retries. */
internal fun acceptsMeshStoreRevision(candidate: Long, committed: Long): Boolean =
    candidate >= committed

/**
 * Delimiter-safe codec for message lists. Every field is hex-encoded (so tabs /
 * newlines / pipes in message content can't corrupt the record framing), fields
 * are tab-joined, records are newline-joined. Pure + unit-tested.
 */
object MessageCodec {
    private const val MESH_SUMMARY_INDEX_VERSION = "sonar-mesh-summary-index-v1"
    private const val MESH_SUMMARY_PAGE_VERSION = "sonar-mesh-summary-page-v1"
    private const val MESH_SUMMARY_ASSIGNMENT_VERSION = "sonar-mesh-summary-assignment-v1"
    fun encodeChannel(list: List<SonarChannelMsg>): String =
        list.joinToString("\n") { m ->
            row(m.id, m.author, m.senderPubkey, if (m.mine) "1" else "0", m.tsSecs.toString(), m.content)
        }

    fun decodeChannel(blob: String): List<SonarChannelMsg> =
        blob.lineSequence().mapNotNull { line ->
            val f = unrow(line) ?: return@mapNotNull null
            if (f.size != 6) return@mapNotNull null
            SonarChannelMsg(
                id = f[0], author = f[1], senderPubkey = f[2],
                content = f[5], mine = f[3] == "1", tsSecs = f[4].toLongOrNull() ?: 0L,
            )
        }.toList()

    fun encodeDm(list: List<SonarMsg>): String =
        list.joinToString("\n") { m ->
            val base = row(m.id, m.senderNpub, if (m.mine) "1" else "0", m.tsSecs.toString(), m.content)
            val ref = m.stickerRef
            val media = m.media.firstOrNull()
            if (ref != null || media != null || m.viaInternet || m.state != null || m.receiveEffectsPending) {
                base + "\t" +
                    hexEnc(ref?.packCoordinate.orEmpty()) + "\t" +
                    hexEnc(ref?.shortcode.orEmpty()) + "\t" +
                    hexEnc(ref?.plaintextSha256.orEmpty()) + "\t" +
                    hexEnc(media?.url.orEmpty()) + "\t" +
                    hexEnc(media?.mimeType.orEmpty()) + "\t" +
                    hexEnc(media?.filename.orEmpty()) + "\t" +
                    hexEnc(media?.width?.toString().orEmpty()) + "\t" +
                    hexEnc(media?.height?.toString().orEmpty()) + "\t" +
                    hexEnc(media?.durationMs?.toString().orEmpty()) + "\t" +
                    hexEnc(if (m.viaInternet) "1" else "") + "\t" +
                    // Field 15 (append-only versioning, like field 14 for
                    // viaInternet): optional media caption. Old decoders
                    // ignore trailing fields; old envelopes lack it.
                    hexEnc(media?.caption.orEmpty()) + "\t" +
                    // Field 16: durable local delivery state. Keeping this
                    // append-only preserves every older transcript envelope.
                    hexEnc(m.state.orEmpty()) + "\t" +
                    // Field 17: crash-replay obligation for local receive effects.
                    hexEnc(if (m.receiveEffectsPending) "1" else "")
            } else base
        }

    fun decodeDm(blob: String): List<SonarMsg> =
        blob.lineSequence().mapNotNull { line ->
            val f = unrow(line) ?: return@mapNotNull null
            if (f.size < 5) return@mapNotNull null
            val stickerRef = if (f.size >= 8 && (f[5].isNotBlank() || f[6].isNotBlank() || f[7].isNotBlank())) {
                SonarStickerRef(f[5], f[6], f[7])
            } else null
            val media = if (f.size >= 14 && f[8].isNotBlank()) {
                listOf(
                    SonarMedia(
                        url = f[8],
                        mimeType = f[9],
                        filename = f[10],
                        width = f[11].toIntOrNull(),
                        height = f[12].toIntOrNull(),
                        durationMs = f[13].toLongOrNull(),
                        // Field 15: caption — tolerate old envelopes without it.
                        caption = f.getOrNull(15)?.takeIf { it.isNotEmpty() },
                    )
                )
            } else emptyList()
            SonarMsg(
                id = f[0], senderNpub = f[1], content = f[4],
                mine = f[2] == "1", tsSecs = f[3].toLongOrNull() ?: 0L,
                viaInternet = f.size >= 15 && f[14] == "1",
                media = media,
                state = f.getOrNull(16)?.takeIf { it.isNotEmpty() },
                receiveEffectsPending = f.getOrNull(17) == "1",
                stickerRef = stickerRef,
            )
        }.toList()

    /** Mesh-DM file format: line 1 = hex(peerKey) envelope (filenames are hashes,
     *  so the key can't be recovered from disk otherwise — mirrors the iOS
     *  `StoredPrivateChat` envelope), lines 2.. = the DM records. */
    fun encodeMeshEnvelope(peerKey: String, msgs: List<SonarMsg>): String =
        hexEnc(peerKey) + "\n" + encodeDm(msgs.takeLast(MESSAGE_STORE_CAP))

    fun decodeMeshEnvelope(blob: String): Pair<String, List<SonarMsg>>? {
        val nl = blob.indexOf('\n')
        val keyTok = (if (nl >= 0) blob.substring(0, nl) else blob).trim()
        val key = hexDec(keyTok).takeUnless { it.isNullOrEmpty() } ?: return null
        val body = if (nl >= 0) blob.substring(nl + 1) else ""
        return key to decodeDm(body)
    }

    fun encodeMeshSummaryIndex(summaries: List<MeshDmSummary>): String = buildString {
        append(MESH_SUMMARY_INDEX_VERSION)
        boundedMeshDmSummaries(summaries).forEach { summary ->
            append('\n')
            append(hexEnc(summary.peerKey))
            append('\t')
            append(hexEnc(encodeDm(listOf(summary.latest))))
        }
    }

    fun decodeMeshSummaryIndex(blob: String): List<MeshDmSummary>? {
        val lines = blob.lineSequence().iterator()
        if (!lines.hasNext() || lines.next() != MESH_SUMMARY_INDEX_VERSION) return null
        val decoded = ArrayList<MeshDmSummary>()
        val peers = HashSet<String>()
        while (lines.hasNext()) {
            if (decoded.size >= MESH_DM_SUMMARY_LIMIT) return null
            val fields = lines.next().split('\t')
            if (fields.size != 2) return null
            val peerKey = hexDec(fields[0])?.takeIf { it.isNotBlank() } ?: return null
            val latest = hexDec(fields[1])?.let(::decodeDm)?.singleOrNull() ?: return null
            if (!peers.add(peerKey)) return null
            decoded += MeshDmSummary(peerKey, latest)
        }
        return boundedMeshDmSummaries(decoded)
    }

    /** One authoritative catalog row per file. Unlike the recent index this
     * codec has no global cardinality cap, because callers read one bounded page
     * of individual files at a time. */
    fun encodeMeshSummary(summary: MeshDmSummary): String =
        hexEnc(summary.peerKey) + "\t" + hexEnc(encodeDm(listOf(summary.latest)))

    fun decodeMeshSummary(blob: String): MeshDmSummary? {
        val fields = blob.trim().split('\t')
        if (fields.size != 2) return null
        val peerKey = hexDec(fields[0])?.takeIf { it.isNotBlank() } ?: return null
        val latest = hexDec(fields[1])?.let(::decodeDm)?.singleOrNull() ?: return null
        return MeshDmSummary(peerKey, latest)
    }

    fun encodeMeshSummaryPeerPage(peers: List<String?>): String = buildString {
        append(MESH_SUMMARY_PAGE_VERSION)
        peers.take(MESH_SUMMARY_CATALOG_PAGE_SIZE).forEach { peer ->
            append('\n')
            append(hexEnc(peer.orEmpty()))
        }
    }

    fun decodeMeshSummaryPeerPage(blob: String): List<String?>? {
        val lines = blob.lineSequence().iterator()
        if (!lines.hasNext() || lines.next() != MESH_SUMMARY_PAGE_VERSION) return null
        val peers = ArrayList<String?>()
        val unique = HashSet<String>()
        while (lines.hasNext()) {
            if (peers.size >= MESH_SUMMARY_CATALOG_PAGE_SIZE) return null
            val decoded = hexDec(lines.next()) ?: return null
            var peer = decoded.takeIf { it.isNotBlank() }
            // Older interrupted assignment retries could leave the same peer in
            // multiple slots. Treat later occurrences as stable tombstones so
            // the page remains readable and the next write canonicalizes it.
            if (peer != null && !unique.add(peer)) peer = null
            peers += peer
        }
        return peers
    }

    fun encodeMeshSummaryAssignment(pageNumber: Int): String =
        "$MESH_SUMMARY_ASSIGNMENT_VERSION\n$pageNumber"

    fun decodeMeshSummaryAssignment(blob: String): Int? {
        val lines = blob.lineSequence().toList()
        if (lines.size != 2 || lines[0] != MESH_SUMMARY_ASSIGNMENT_VERSION) return null
        return lines[1].toIntOrNull()?.takeIf { it >= 0 }
    }

    fun encodeMeshSummaryRepairIntent(peerKey: String): String =
        "sonar-mesh-summary-repair-v1\n" + hexEnc(peerKey)

    fun decodeMeshSummaryRepairIntent(blob: String): String? {
        val lines = blob.lineSequence().toList()
        if (lines.size != 2 || lines[0] != "sonar-mesh-summary-repair-v1") return null
        return hexDec(lines[1])?.takeIf { it.isNotBlank() }
    }

    fun encodeMeshPending(record: MeshPendingDeliveryRecord): String =
        row(
            record.peerId,
            record.messageId,
            record.text,
            record.timestampSecs.toString(),
            if (record.surfaceInTranscript) "1" else "0",
            record.sequence.toString(),
        )

    fun decodeMeshPending(blob: String): MeshPendingDeliveryRecord? {
        val fields = unrow(blob.trim()) ?: return null
        if (fields.size != 6 || fields[0].isBlank() || fields[1].isBlank()) return null
        val timestampSecs = fields[3].toLongOrNull() ?: return null
        val sequence = fields[5].toLongOrNull()?.takeIf { it > 0L } ?: return null
        return MeshPendingDeliveryRecord(
            fields[0], fields[1], fields[2], timestampSecs,
            surfaceInTranscript = fields[4] == "1",
            sequence = sequence,
        )
    }

    fun encodeRoutePending(record: QueuedMessage): String =
        row(
            record.peerId,
            record.messageId,
            record.content,
            record.timestampSecs.toString(),
            record.sequence.toString(),
        )

    fun decodeRoutePending(blob: String): QueuedMessage? {
        val fields = unrow(blob.trim()) ?: return null
        if (fields.size != 5 || fields[0].isBlank() || fields[1].isBlank()) return null
        val timestampSecs = fields[3].toLongOrNull() ?: return null
        val sequence = fields[4].toLongOrNull()?.takeIf { it > 0L } ?: return null
        return QueuedMessage(
            peerId = fields[0],
            messageId = fields[1],
            content = fields[2],
            timestampSecs = timestampSecs,
            sequence = sequence,
        )
    }

    private fun row(vararg fields: String): String = fields.joinToString("\t") { hexEnc(it) }

    private fun unrow(line: String): List<String>? {
        if (line.isBlank()) return null
        return line.split("\t").map { hexDec(it) ?: return null }
    }

    private fun hexEnc(s: String): String =
        s.encodeToByteArray().joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }

    private fun hexDec(s: String): String? {
        if (s.isEmpty()) return ""
        if (s.length % 2 != 0) return null
        val bytes = ByteArray(s.length / 2)
        for (i in bytes.indices) {
            val hi = s[2 * i].digitToIntOrNull(16) ?: return null
            val lo = s[2 * i + 1].digitToIntOrNull(16) ?: return null
            bytes[i] = ((hi shl 4) or lo).toByte()
        }
        return bytes.decodeToString()
    }
}

/** Merge two message lists by id (newest wins), sorted oldest-first, capped. */
object MessageMerge {
    fun channels(stored: List<SonarChannelMsg>, fresh: List<SonarChannelMsg>): List<SonarChannelMsg> {
        val byId = LinkedHashMap<String, SonarChannelMsg>()
        for (m in stored) byId[m.id] = m
        for (m in fresh) byId[m.id] = m
        return byId.values.sortedBy { it.tsSecs }.takeLast(MESSAGE_STORE_CAP)
    }

    fun dms(stored: List<SonarMsg>, fresh: List<SonarMsg>): List<SonarMsg> {
        val byId = LinkedHashMap<String, SonarMsg>()
        for (m in stored) byId[m.id] = m
        for (m in fresh) byId[m.id] = m
        return byId.values.sortedBy { it.tsSecs }.takeLast(MESSAGE_STORE_CAP)
    }
}
