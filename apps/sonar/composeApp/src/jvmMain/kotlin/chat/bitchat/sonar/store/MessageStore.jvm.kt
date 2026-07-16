package chat.bitchat.sonar.store

import chat.bitchat.sonar.DesktopEnv
import chat.bitchat.sonar.MeshPendingDeliveryRecord
import chat.bitchat.sonar.OUTBOX_TTL_SECS
import chat.bitchat.sonar.QueuedMessage
import chat.bitchat.sonar.SonarChannelMsg
import chat.bitchat.sonar.SonarMsg
import chat.bitchat.sonar.cleanupJvmDirectoryTombstones
import chat.bitchat.sonar.crypto.Sha256
import chat.bitchat.sonar.syncJvmDirectoryStrict
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.nio.channels.FileChannel
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.util.concurrent.ConcurrentHashMap

internal fun syncJvmMessageStoreDirectory(
    directory: File?,
    force: (File) -> Unit = { target ->
        FileChannel.open(target.toPath(), StandardOpenOption.READ).use { it.force(true) }
    },
): Boolean = syncJvmDirectoryStrict(directory, force)

/** Fixed-page catalog storage with crash-safe reuse of deleted slots.
 *
 * Reusing an earlier slot can otherwise make an in-flight direct cursor skip a
 * newly inserted peer. The redo journal is committed before the page changes,
 * and the catalog generation is committed before the journal is cleared. A
 * cursor from an older generation restarts at page zero (duplicates are safe;
 * missing a conversation is not).
 */
internal class MeshSummaryCatalogPages(
    private val pagesDir: File,
    private val assignmentFile: (String) -> File,
    private val atomicWrite: (File, String) -> Boolean,
    private val deleteDurably: (File) -> Boolean,
    private val readText: (File) -> String? = { target ->
        if (!target.exists()) null else runCatching { target.readText() }.getOrNull()
    },
) {
    private data class ReuseIntent(
        val peerKey: String,
        val pageNumber: Int,
        val slot: Int,
        val nextGeneration: Long,
    )

    private data class CompactionIntent(
        val oldTail: Int,
        val newTail: Int,
        val nextGeneration: Long,
    )

    private data class FreeHint(val pageNumber: Int?, val scannedThrough: Int)
    private data class FreeSlot(val pageNumber: Int, val slot: Int)
    private data class FreeSearch(val valid: Boolean, val slot: FreeSlot?)

    private companion object {
        const val FOREGROUND_FREE_SCAN_PAGE_LIMIT = 4
    }

    private val tailFile get() = File(pagesDir, "tail")
    private val generationFile get() = File(pagesDir, "generation-v1")
    private val reuseIntentFile get() = File(pagesDir, "reuse-intent-v1")
    private val compactionIntentFile get() = File(pagesDir, "compact-intent-v1")
    private val freeHintFile get() = File(pagesDir, "free-page-v1")
    private fun pageFile(pageNumber: Int): File =
        File(pagesDir, "page-${pageNumber.toString().padStart(10, '0')}")

    private fun readTailForMutation(): Int? = when {
        !tailFile.exists() -> 0
        else -> readText(tailFile)?.trim()?.toIntOrNull()?.takeIf { it >= 0 }
    }

    private fun readTailForPaging(): Int? = when {
        !tailFile.exists() -> null
        else -> readText(tailFile)?.trim()?.toIntOrNull()?.takeIf { it >= 0 }
    }

    private fun readPage(pageNumber: Int): List<String?>? {
        val target = pageFile(pageNumber)
        if (!target.exists()) return emptyList()
        return readText(target)?.let(MessageCodec::decodeMeshSummaryPeerPage)
    }

    private fun writePage(pageNumber: Int, peers: List<String?>): Boolean =
        atomicWrite(pageFile(pageNumber), MessageCodec.encodeMeshSummaryPeerPage(peers))

    private fun readGeneration(): Long? = when {
        !generationFile.exists() -> 0L
        else -> readText(generationFile)?.trim()?.toLongOrNull()?.takeIf { it >= 0L }
    }

    private fun readAssignment(peerKey: String): Int? {
        val target = assignmentFile(peerKey)
        if (!target.exists()) return null
        return readText(target)?.let(MessageCodec::decodeMeshSummaryAssignment)
    }

    private fun writeAssignment(peerKey: String, pageNumber: Int): Boolean =
        atomicWrite(assignmentFile(peerKey), MessageCodec.encodeMeshSummaryAssignment(pageNumber))

    private fun encodeIntent(intent: ReuseIntent): String = buildString {
        append("sonar-mesh-summary-reuse-v1\n")
        append(intent.peerKey.encodeToByteArray().joinToString("") {
            ((it.toInt() and 0xff) + 0x100).toString(16).substring(1)
        })
        append('\n').append(intent.pageNumber)
        append('\n').append(intent.slot)
        append('\n').append(intent.nextGeneration)
    }

    private fun decodeHex(value: String): String? {
        if (value.length % 2 != 0) return null
        val bytes = ByteArray(value.length / 2)
        for (index in bytes.indices) {
            val high = value[index * 2].digitToIntOrNull(16) ?: return null
            val low = value[index * 2 + 1].digitToIntOrNull(16) ?: return null
            bytes[index] = ((high shl 4) or low).toByte()
        }
        return runCatching { bytes.decodeToString() }.getOrNull()
    }

    private fun readIntent(): ReuseIntent? {
        if (!reuseIntentFile.exists()) return null
        val lines = readText(reuseIntentFile)?.lineSequence()?.toList() ?: return null
        if (lines.size != 5 || lines[0] != "sonar-mesh-summary-reuse-v1") return null
        val peerKey = decodeHex(lines[1])?.takeIf { it.isNotBlank() } ?: return null
        val pageNumber = lines[2].toIntOrNull()?.takeIf { it >= 0 } ?: return null
        val slot = lines[3].toIntOrNull()?.takeIf { it in 0 until MESH_SUMMARY_CATALOG_PAGE_SIZE } ?: return null
        val generation = lines[4].toLongOrNull()?.takeIf { it > 0L } ?: return null
        return ReuseIntent(peerKey, pageNumber, slot, generation)
    }

    private fun encodeCompactionIntent(intent: CompactionIntent): String =
        "sonar-mesh-summary-compact-v1\n${intent.oldTail}\n${intent.newTail}\n${intent.nextGeneration}"

    private fun readCompactionIntent(): CompactionIntent? {
        if (!compactionIntentFile.exists()) return null
        val lines = readText(compactionIntentFile)?.lineSequence()?.toList() ?: return null
        if (lines.size != 4 || lines[0] != "sonar-mesh-summary-compact-v1") return null
        val oldTail = lines[1].toIntOrNull()?.takeIf { it > 0 } ?: return null
        val newTail = lines[2].toIntOrNull()?.takeIf { it in 0 until oldTail } ?: return null
        val generation = lines[3].toLongOrNull()?.takeIf { it > 0L } ?: return null
        return CompactionIntent(oldTail, newTail, generation)
    }

    private fun encodeFreeHint(hint: FreeHint): String =
        "sonar-mesh-summary-free-v1\n${hint.pageNumber ?: -1}\n${hint.scannedThrough}"

    private fun readFreeHint(): FreeHint? {
        if (!freeHintFile.exists()) return null
        val lines = readText(freeHintFile)?.lineSequence()?.toList() ?: return null
        if (lines.size != 3 || lines[0] != "sonar-mesh-summary-free-v1") return null
        val encodedPage = lines[1].toIntOrNull() ?: return null
        val scannedThrough = lines[2].toIntOrNull()?.takeIf { it >= -1 } ?: return null
        if (encodedPage < -1) return null
        return FreeHint(encodedPage.takeIf { it >= 0 }, scannedThrough)
    }

    private fun writeFreeHint(pageNumber: Int?, scannedThrough: Int): Boolean =
        atomicWrite(freeHintFile, encodeFreeHint(FreeHint(pageNumber, scannedThrough)))

    /** Advance the persisted free-page search by a strict page budget. A failed
     * page read records all prior progress before returning, and this function
     * is always called before a reuse redo intent exists. */
    private fun findFreeSlot(tail: Int, maxPages: Int): FreeSearch {
        val budget = maxPages.coerceAtLeast(0)
        if (budget == 0) return FreeSearch(valid = true, slot = null)
        val hint = readFreeHint()
        val hintedPage = hint?.pageNumber
        var inspected = 0
        // Older v1 writers stored tail as scannedThrough beside a known page.
        // Once that page filled, trusting the legacy value skipped every other
        // tombstone. Normalize that combination to an unknown frontier.
        var scannedThrough = when {
            hint == null -> -1
            hintedPage != null && hint.scannedThrough >= hintedPage -> -1
            else -> hint.scannedThrough
        }
        if (hintedPage != null && hintedPage <= tail) {
            val peers = readPage(hintedPage) ?: return FreeSearch(false, null)
            inspected += 1
            val slot = peers.indexOfFirst { it == null }
            if (slot >= 0) return FreeSearch(true, FreeSlot(hintedPage, slot))
        }
        var pageNumber = when {
            hint == null -> 0
            scannedThrough >= tail -> return FreeSearch(true, null)
            else -> scannedThrough + 1
        }
        while (pageNumber <= tail && inspected < budget) {
            val peers = readPage(pageNumber)
            if (peers == null) {
                if (scannedThrough >= 0 && !writeFreeHint(null, scannedThrough)) {
                    return FreeSearch(valid = false, slot = null)
                }
                return FreeSearch(valid = false, slot = null)
            }
            inspected += 1
            scannedThrough = pageNumber
            val slot = peers.indexOfFirst { it == null }
            if (slot >= 0) {
                return if (writeFreeHint(pageNumber, pageNumber - 1)) {
                    FreeSearch(true, FreeSlot(pageNumber, slot))
                } else {
                    FreeSearch(false, null)
                }
            }
            pageNumber += 1
        }
        if (scannedThrough < 0) return FreeSearch(true, null)
        return if (writeFreeHint(null, scannedThrough)) FreeSearch(true, null) else FreeSearch(false, null)
    }

    /** Derive the next scan position from the page already held in memory. No
     * fallible page read is allowed after the reuse page/generation commits. */
    private fun updateFreeHintAfterReuse(pageNumber: Int, peers: List<String?>): Boolean =
        writeFreeHint(pageNumber.takeIf { peers.any { it == null } }, -1)

    private fun completeReuseIntent(): Boolean {
        if (!reuseIntentFile.exists()) return true
        val intent = readIntent() ?: return false
        val peers = readPage(intent.pageNumber) ?: return false
        if (intent.slot > peers.size || (intent.slot == peers.size && peers.size >= MESH_SUMMARY_CATALOG_PAGE_SIZE)) {
            return false
        }
        if (intent.slot < peers.size && peers[intent.slot] != null && peers[intent.slot] != intent.peerKey) {
            return false
        }
        val committed = peers.map { if (it == intent.peerKey) null else it }.toMutableList()
        if (intent.slot == committed.size) committed += intent.peerKey else committed[intent.slot] = intent.peerKey
        // Recommit every visible stage: rename visibility alone does not prove
        // that the previous parent-directory barrier completed.
        if (!writePage(intent.pageNumber, committed)) return false
        val generation = readGeneration() ?: return false
        if (generation > intent.nextGeneration) return false
        if (!atomicWrite(generationFile, intent.nextGeneration.toString())) return false
        if (!writeAssignment(intent.peerKey, intent.pageNumber)) return false
        if (!updateFreeHintAfterReuse(intent.pageNumber, committed)) return false
        return deleteDurably(reuseIntentFile)
    }

    private fun completeCompactionIntent(): Boolean {
        if (!compactionIntentFile.exists()) return true
        val intent = readCompactionIntent() ?: return false
        val visibleTail = readTailForMutation() ?: return false
        if (visibleTail > intent.oldTail || visibleTail < intent.newTail) return false
        // Tail first makes every page above it unreachable. Generation follows
        // while the journal is still durable, so an old cursor can never advance
        // past a newly compacted view after recovery.
        if (!atomicWrite(tailFile, intent.newTail.toString())) return false
        val generation = readGeneration() ?: return false
        if (generation > intent.nextGeneration) return false
        if (!atomicWrite(generationFile, intent.nextGeneration.toString())) return false
        // A free-page hint into the removed suffix is unsafe. Dropping the hint
        // causes one later bounded migration scan without touching first paint.
        if (!deleteDurably(freeHintFile)) return false
        for (pageNumber in (intent.newTail + 1)..intent.oldTail) {
            if (!deleteDurably(pageFile(pageNumber))) return false
        }
        return deleteDurably(compactionIntentFile)
    }

    private fun completePendingMaintenance(): Boolean =
        completeReuseIntent() && completeCompactionIntent()

    internal fun recoverPendingMaintenance(): Boolean = completePendingMaintenance()

    private fun beginReuse(peerKey: String, slot: FreeSlot): Boolean {
        if (!completePendingMaintenance()) return false
        val generation = readGeneration() ?: return false
        if (generation == Long.MAX_VALUE) return false
        val intent = ReuseIntent(peerKey, slot.pageNumber, slot.slot, generation + 1L)
        if (!atomicWrite(reuseIntentFile, encodeIntent(intent))) return false
        return completeReuseIntent()
    }

    internal fun ensureAssignment(peerKey: String): Boolean {
        if (!completePendingMaintenance()) return false
        val assignment = assignmentFile(peerKey)
        val assignedPage = readAssignment(peerKey)
        if (assignment.exists() && assignedPage == null) return false
        if (assignedPage != null) {
            val peers = readPage(assignedPage) ?: return false
            if (peerKey in peers) {
                // Always recommit the marker; a failed earlier parent barrier
                // can leave its rename visible without making it durable.
                return writeAssignment(peerKey, assignedPage)
            }
            val reusable = peers.indexOfFirst { it == null }.takeIf { it >= 0 }
                ?: peers.size.takeIf { it < MESH_SUMMARY_CATALOG_PAGE_SIZE }
                ?: return false
            return beginReuse(peerKey, FreeSlot(assignedPage, reusable))
        }

        var tail = readTailForMutation() ?: return false
        var tailPeers = readPage(tail) ?: return false
        if (peerKey in tailPeers) return writeAssignment(peerKey, tail)

        val free = findFreeSlot(tail, FOREGROUND_FREE_SCAN_PAGE_LIMIT)
        if (!free.valid) return false
        if (free.slot != null) return beginReuse(peerKey, free.slot)

        if (tailPeers.size >= MESH_SUMMARY_CATALOG_PAGE_SIZE) {
            tail += 1
            tailPeers = emptyList()
        }
        if (!atomicWrite(tailFile, tail.toString())) return false
        val committedPeers = meshSummaryPageWithSinglePeer(tailPeers, peerKey) ?: return false
        if (!writePage(tail, committedPeers)) return false
        return writeAssignment(peerKey, tail)
    }

    internal fun removeAssignment(peerKey: String): Boolean {
        if (!completePendingMaintenance()) return false
        val assignment = assignmentFile(peerKey)
        val pageNumber = readAssignment(peerKey)
        if (assignment.exists() && pageNumber == null) return false
        if (pageNumber == null) return true
        val peers = readPage(pageNumber) ?: return false
        if (!writePage(pageNumber, peers.map { if (it == peerKey) null else it })) return false
        val existing = readFreeHint()?.pageNumber
        val firstFreePage = listOfNotNull(existing, pageNumber).minOrNull() ?: pageNumber
        // A deletion invalidates any earlier "no tombstone" scan result. Keep
        // the earliest known free page and restart later discovery incrementally.
        if (!writeFreeHint(firstFreePage, -1)) return false
        return deleteDurably(assignment)
    }

    /** Background repair advances the legacy free-page search without charging
     * chat send/open latency. Progress is durable even when no tombstone exists
     * in this bounded batch. */
    internal fun advanceFreeHintScan(maxPages: Int = 64): Boolean {
        if (!completePendingMaintenance()) return false
        val tail = readTailForPaging() ?: return true
        val search = findFreeSlot(tail, maxPages)
        return search.valid
    }

    /** Background-only, bounded migration for catalogs bloated by the legacy
     * append-only tombstone policy. The committed tail is the progress marker,
     * so each restart can trim another bounded suffix without a boot scan. */
    internal fun compactTrailingEmptyPages(maxPages: Int = 64): Boolean {
        if (!completePendingMaintenance()) return false
        val budget = maxPages.coerceAtLeast(0)
        if (budget == 0) return true
        val oldTail = readTailForPaging() ?: return true
        var newTail = oldTail
        var inspected = 0
        while (newTail > 0 && inspected < budget) {
            val peers = readPage(newTail) ?: return false
            if (peers.any { it != null }) break
            newTail -= 1
            inspected += 1
        }
        if (newTail == oldTail) return true
        val generation = readGeneration() ?: return false
        if (generation == Long.MAX_VALUE) return false
        val intent = CompactionIntent(oldTail, newTail, generation + 1L)
        if (!atomicWrite(compactionIntentFile, encodeCompactionIntent(intent))) return false
        return completeCompactionIntent()
    }

    internal fun readSummaryPage(
        afterCursor: String?,
        limit: Int,
        readSummary: (String) -> MeshDmSummary?,
    ): MeshDmSummaryPage {
        check(completePendingMaintenance()) { "mesh summary catalog maintenance is not durably repaired" }
        val generation = checkNotNull(readGeneration()) { "mesh summary catalog generation is corrupt" }
        val directCursor = when {
            afterCursor == null -> null
            else -> {
                val parts = afterCursor.split(':')
                val cursorGeneration: Long
                val page: String
                val offset: String
                when (parts.size) {
                    2 -> {
                        cursorGeneration = 0L // legacy direct cursor
                        page = parts[0]
                        offset = parts[1]
                    }
                    3 -> {
                        cursorGeneration = parts[0].toLongOrNull()
                            ?: return MeshDmSummaryPage(emptyList(), null)
                        page = parts[1]
                        offset = parts[2]
                    }
                    else -> return MeshDmSummaryPage(emptyList(), null)
                }
                if (cursorGeneration == generation) "$page:$offset" else null
            }
        }
        val page = readBoundedMeshSummaryCatalogPage(
            afterCursor = directCursor,
            limit = limit,
            lastPage = ::readTailForPaging,
            readPeerPage = ::readPage,
            readSummary = readSummary,
        )
        return page.copy(nextCursor = page.nextCursor?.let { "$generation:$it" })
    }
}

/**
 * Desktop (JVM) `actual`: transcripts as files under the app-data `messages`
 * dir. Filenames are sha256(key) so raw geohashes / peer keys never hit the
 * filesystem — identical scheme to the Android actual.
 */
actual object MessageStore {
    private val mutationLocks = MessageStoreMutationLocks()
    private val committedMeshRevision = ConcurrentHashMap<String, Long>()
    @Volatile private var committedWipeRevision = 0L
    actual fun storageEpoch(): Long = committedWipeRevision
    private fun committedRevisionFor(peerKey: String): Long =
        maxOf(committedWipeRevision, committedMeshRevision[peerKey] ?: Long.MIN_VALUE)
    private fun root(): File = DesktopEnv.file("messages").apply { mkdirs() }

    private fun hashName(input: String): String =
        Sha256.hash(input.encodeToByteArray())
            .joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }

    private fun file(kind: String, key: String): File =
        File(root(), "${hashName("$kind:$key")}.txt")

    actual suspend fun loadChannel(geohash: String): List<SonarChannelMsg> = withContext(Dispatchers.IO) {
        mutationLocks.withTranscript {
            val f = file("ch", geohash.lowercase())
            if (!f.exists()) emptyList()
            else runCatching { MessageCodec.decodeChannel(f.readText()) }.getOrDefault(emptyList())
        }
    }

    actual suspend fun saveChannel(geohash: String, msgs: List<SonarChannelMsg>, expectedEpoch: Long) {
        withContext(Dispatchers.IO) {
            mutationLocks.withTranscript {
                if (expectedEpoch == committedWipeRevision) {
                    atomicWrite(
                        file("ch", geohash.lowercase()),
                        MessageCodec.encodeChannel(msgs.takeLast(MESSAGE_STORE_CAP)),
                    )
                }
            }
        }
    }

    actual suspend fun loadGeoDm(geohash: String, peerHex: String): List<SonarMsg> = withContext(Dispatchers.IO) {
        mutationLocks.withTranscript {
            val f = file("dm", "${geohash.lowercase()}:${peerHex.lowercase()}")
            if (!f.exists()) emptyList()
            else runCatching { MessageCodec.decodeDm(f.readText()) }.getOrDefault(emptyList())
        }
    }

    actual suspend fun saveGeoDm(geohash: String, peerHex: String, msgs: List<SonarMsg>, expectedEpoch: Long) {
        withContext(Dispatchers.IO) {
            mutationLocks.withTranscript {
                if (expectedEpoch == committedWipeRevision) {
                    atomicWrite(
                        file("dm", "${geohash.lowercase()}:${peerHex.lowercase()}"),
                        MessageCodec.encodeDm(msgs.takeLast(MESSAGE_STORE_CAP)),
                    )
                }
            }
        }
    }

    private fun meshDir(): File = File(root(), "mesh").apply { mkdirs() }

    private fun meshSummaryIndexFile(): File = File(meshDir(), ".mesh-summary-index-v1")

    private fun meshSummaryCatalogDir(): File = File(meshDir(), ".summary-catalog-v2").apply { mkdirs() }
    private fun meshSummaryCatalogFile(peerKey: String): File =
        File(meshSummaryCatalogDir(), "${hashName("mesh-summary:$peerKey")}.summary")
    private fun meshSummaryAssignmentFile(peerKey: String): File =
        File(meshSummaryCatalogDir(), "${hashName("mesh-summary:$peerKey")}.page-ref")
    private fun meshSummaryPagesDir(): File = File(meshSummaryCatalogDir(), "pages-v1").apply { mkdirs() }
    private fun meshSummaryRepairIntentFile(): File = File(meshDir(), ".mesh-summary-repair-v1")
    private val meshSummaryCatalogPages by lazy {
        MeshSummaryCatalogPages(
            pagesDir = meshSummaryPagesDir(),
            assignmentFile = ::meshSummaryAssignmentFile,
            atomicWrite = ::atomicWrite,
            deleteDurably = ::deleteDurably,
        )
    }

    private fun meshFile(peerKey: String): File =
        File(meshDir(), "${hashName("mesh:$peerKey")}.txt")

    private fun meshPendingDir(): File = File(root(), "mesh-pending").apply { mkdirs() }
    private fun meshPendingFile(peerKey: String, messageId: String): File =
        File(meshPendingDir(), "${hashName("mesh-pending:$peerKey:$messageId")}.txt")
    private fun routePendingDir(): File = File(root(), "route-pending").apply { mkdirs() }
    private fun routePendingFile(peerKey: String, messageId: String): File =
        File(routePendingDir(), "${hashName("route-pending:$peerKey:$messageId")}.txt")

    private fun pendingBackend(
        directory: () -> File,
        recordFile: (String, String) -> File,
    ): PendingOutboxBackend = object : PendingOutboxBackend {
        private fun indexFile(): File = File(directory(), ".pending-index-v1")

        override fun indexExists(): Boolean = indexFile().exists()
        override fun readIndex(): String? = runCatching { indexFile().readText() }.getOrNull()
        override fun writeIndex(payload: String): Boolean = atomicWrite(indexFile(), payload)

        override fun snapshotLegacyTokens(): List<String>? = runCatching {
            val files = directory().listFiles() ?: return@runCatching null
            files.asSequence()
                .filter { it.isFile && it.name != ".pending-index-v1" }
                .map { it.name }
                .sorted()
                .toList()
        }.getOrNull()

        override fun readLegacy(tokens: List<String>): List<LegacyPendingPayload>? = runCatching {
            val dir = directory()
            tokens.map { token ->
                val target = File(dir, token)
                check(target.parentFile == dir && target.isFile)
                LegacyPendingPayload(token, target.readText())
            }
        }.getOrNull()

        override fun readRecord(peerId: String, messageId: String): String? {
            val target = recordFile(peerId, messageId)
            return if (!target.exists()) null else runCatching { target.readText() }.getOrNull()
        }

        override fun writeRecord(peerId: String, messageId: String, payload: String): Boolean =
            atomicWrite(recordFile(peerId, messageId), payload)

        override fun deleteRecords(keys: List<Pair<String, String>>): Boolean {
            if (keys.isEmpty()) return true
            val deleted = keys.all { (peerId, messageId) ->
                val target = recordFile(peerId, messageId)
                !target.exists() || target.delete()
            }
            return deleted && syncDirectory(directory())
        }

        override fun deleteLegacy(tokens: List<String>): Boolean {
            if (tokens.isEmpty()) return true
            val dir = directory()
            val deleted = tokens.distinct().all { token ->
                val target = File(dir, token)
                target.parentFile == dir && (!target.exists() || target.delete())
            }
            return deleted && syncDirectory(dir)
        }
    }

    private val meshPendingOutbox by lazy {
        DurablePendingOutbox(
            backend = pendingBackend(::meshPendingDir, ::meshPendingFile),
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
    }

    private val routePendingOutbox by lazy {
        DurablePendingOutbox(
            backend = pendingBackend(::routePendingDir, ::routePendingFile),
            encodeRecord = MessageCodec::encodeRoutePending,
            decodeRecord = MessageCodec::decodeRoutePending,
            peerId = QueuedMessage::peerId,
            messageId = QueuedMessage::messageId,
            timestampSecs = QueuedMessage::timestampSecs,
            sequence = QueuedMessage::sequence,
            withSequence = { record, sequence -> record.copy(sequence = sequence) },
            equivalent = { left, right ->
                left.peerId == right.peerId && left.messageId == right.messageId && left.content == right.content
            },
            expiredAt = { System.currentTimeMillis() / 1_000L - it > OUTBOX_TTL_SECS },
        )
    }

    private fun committedFiles(directory: File): List<File> =
        directory.listFiles().orEmpty().mapNotNull { file ->
            if (file == meshSummaryIndexFile() || file == meshSummaryRepairIntentFile() || file == meshSummaryCatalogDir()) null
            else if (file.isFile && !file.name.startsWith(".") && file.extension == "txt") file
            else {
                if (file.isFile && file.extension == "tmp") file.delete()
                null
            }
        }

    private fun readMeshSummaries(): List<MeshDmSummary> {
        val index = meshSummaryIndexFile()
        if (!index.exists()) return emptyList()
        return runCatching { MessageCodec.decodeMeshSummaryIndex(index.readText()) }
            .getOrNull().orEmpty()
    }

    private fun writeMeshSummaries(summaries: List<MeshDmSummary>): Boolean =
        atomicWrite(meshSummaryIndexFile(), MessageCodec.encodeMeshSummaryIndex(summaries))

    private fun updateRecentMeshSummary(peerKey: String, msgs: List<SonarMsg>): Boolean {
        val updated = readMeshSummaries().filterNot { it.peerKey == peerKey }.toMutableList()
        msgs.lastOrNull()?.let { updated += MeshDmSummary(peerKey, it) }
        return writeMeshSummaries(updated)
    }

    private fun deleteDurably(target: File): Boolean =
        (!target.exists() || target.delete()) && syncDirectory(target.parentFile)

    private fun ensureMeshSummaryPageAssignment(peerKey: String): Boolean {
        return meshSummaryCatalogPages.ensureAssignment(peerKey)
    }

    private fun removeMeshSummaryCatalogPeer(peerKey: String): Boolean {
        if (!meshSummaryCatalogPages.removeAssignment(peerKey)) return false
        return deleteDurably(meshSummaryCatalogFile(peerKey))
    }

    private fun commitCatalogForPeer(peerKey: String): Boolean {
        val transcript = meshFile(peerKey)
        val decoded = if (!transcript.exists()) null else runCatching {
            MessageCodec.decodeMeshEnvelope(transcript.readText())
        }.getOrNull()?.takeIf { it.first == peerKey } ?: return false
        val latest = decoded?.second?.lastOrNull()
        val authoritative = if (latest == null) {
            removeMeshSummaryCatalogPeer(peerKey)
        } else {
            atomicWrite(
                meshSummaryCatalogFile(peerKey),
                MessageCodec.encodeMeshSummary(MeshDmSummary(peerKey, latest)),
            ) && ensureMeshSummaryPageAssignment(peerKey)
        }
        return authoritative && updateRecentMeshSummary(peerKey, decoded?.second.orEmpty())
    }

    private fun writeSummaryRepairIntent(peerKey: String): Boolean =
        atomicWrite(meshSummaryRepairIntentFile(), MessageCodec.encodeMeshSummaryRepairIntent(peerKey))

    private fun clearSummaryRepairIntent(): Boolean = deleteDurably(meshSummaryRepairIntentFile())

    private fun repairPendingSummaryTransaction(): Boolean {
        val intent = meshSummaryRepairIntentFile()
        if (!intent.exists()) return true
        val peerKey = runCatching { MessageCodec.decodeMeshSummaryRepairIntent(intent.readText()) }.getOrNull()
            ?: return false
        if (!commitCatalogForPeer(peerKey)) return false
        return clearSummaryRepairIntent()
    }

    private fun readMeshSummaryCatalogPage(afterCursor: String?, limit: Int): MeshDmSummaryPage {
        return meshSummaryCatalogPages.readSummaryPage(
            afterCursor = afterCursor,
            limit = limit,
            readSummary = { peerKey ->
                val target = meshSummaryCatalogFile(peerKey)
                if (!target.exists()) null else runCatching { MessageCodec.decodeMeshSummary(target.readText()) }
                    .getOrNull()?.takeIf { it.peerKey == peerKey }
            },
        )
    }

    private fun atomicWrite(target: File, content: String): Boolean = runCatching {
        val parent = target.parentFile ?: error("missing parent directory")
        check(parent.isDirectory || parent.mkdirs())
        val temp = File(target.parentFile, ".${target.name}.tmp")
        FileOutputStream(temp, false).use { output ->
            output.write(content.encodeToByteArray())
            output.flush()
            output.fd.sync()
        }
        try {
            Files.move(
                temp.toPath(), target.toPath(),
                StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(temp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
        check(syncDirectory(parent))
        true
    }.getOrDefault(false)

    private fun atomicWriteBytes(target: File, content: ByteArray): Boolean = runCatching {
        val parent = target.parentFile ?: error("missing parent directory")
        check(parent.isDirectory || parent.mkdirs())
        val temp = File(target.parentFile, ".${target.name}.tmp")
        FileOutputStream(temp, false).use { output ->
            output.write(content)
            output.flush()
            output.fd.sync()
        }
        try {
            Files.move(temp.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(temp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
        check(syncDirectory(parent))
        true
    }.getOrDefault(false)

    actual suspend fun loadMeshDmSummaries(limit: Int): List<MeshDmSummary> = withContext(Dispatchers.IO) {
        mutationLocks.withTranscript {
            repairPendingSummaryTransaction()
            readMeshSummaries().take(limit.coerceIn(0, MESH_DM_SUMMARY_LIMIT))
        }
    }

    actual suspend fun loadMeshDmSummaryPage(afterCursor: String?, limit: Int): MeshDmSummaryPage = withContext(Dispatchers.IO) {
        mutationLocks.withTranscript {
            repairPendingSummaryTransaction()
            readMeshSummaryCatalogPage(afterCursor, limit)
        }
    }

    actual suspend fun loadMeshDm(peerKey: String, limit: Int): List<SonarMsg> = withContext(Dispatchers.IO) {
        mutationLocks.withTranscript {
            val target = meshFile(peerKey)
            if (!target.exists()) emptyList()
            else runCatching { MessageCodec.decodeMeshEnvelope(target.readText()) }
                .getOrNull()?.takeIf { it.first == peerKey }?.second
                .orEmpty().takeLast(limit.coerceIn(0, MESSAGE_STORE_CAP))
        }
    }

    actual suspend fun repairMeshDmSummaries(): Unit = withContext(Dispatchers.IO) {
        val files = snapshotMeshRepairCandidates(
            locks = mutationLocks,
            repairPending = { repairPendingSummaryTransaction() },
            enumerate = { committedFiles(meshDir()) },
        )
        val scanned = ArrayList<MeshDmSummary>()
        files.forEach { file ->
            val decoded = runCatching { MessageCodec.decodeMeshEnvelope(file.readText()) }.getOrNull()
            val summary = decoded?.second?.lastOrNull()?.let { MeshDmSummary(decoded.first, it) }
            if (summary != null) scanned += summary
        }
        val repaired = ArrayList<MeshDmSummary>()
        scanned.distinctBy { it.peerKey }.forEach { candidate ->
            val current = mutationLocks.withTranscript {
                val target = meshFile(candidate.peerKey)
                val summary = if (!target.exists()) null else runCatching { MessageCodec.decodeMeshEnvelope(target.readText()) }
                    .getOrNull()?.takeIf { it.first == candidate.peerKey }?.second?.lastOrNull()
                    ?.let { MeshDmSummary(candidate.peerKey, it) }
                if (summary == null) null else {
                    val catalog = meshSummaryCatalogFile(summary.peerKey)
                    val payload = MessageCodec.encodeMeshSummary(summary)
                    val unchanged = catalog.exists() && runCatching { catalog.readText() }.getOrNull() == payload
                    summary.takeIf {
                        (unchanged || atomicWrite(catalog, payload)) && ensureMeshSummaryPageAssignment(summary.peerKey)
                    }
                }
            }
            if (current != null) repaired += current
        }

        // Revalidate only stale/unknown catalog rows in short commits. The
        // transcript is checked again while holding the lock, so a peer saved
        // after [files] was snapped can never be deleted by this repair.
        val scannedPeers = scanned.mapTo(hashSetOf()) { it.peerKey }
        meshSummaryCatalogDir().listFiles().orEmpty()
            .filter { it.isFile && it.extension == "summary" }
            .forEach { snapshotFile ->
            val snapshotPeer = runCatching { MessageCodec.decodeMeshSummary(snapshotFile.readText()) }
                .getOrNull()?.peerKey
            if (snapshotPeer == null || snapshotPeer !in scannedPeers) {
                mutationLocks.withTranscript {
                    val liveRow = if (!snapshotFile.exists()) null else runCatching {
                        MessageCodec.decodeMeshSummary(snapshotFile.readText())
                    }.getOrNull()
                    val liveTranscript = liveRow?.let { row ->
                        val target = meshFile(row.peerKey)
                        if (!target.exists()) null else runCatching { MessageCodec.decodeMeshEnvelope(target.readText()) }
                            .getOrNull()?.takeIf { it.first == row.peerKey }?.second?.lastOrNull()
                    }
                    if (liveRow == null || staleRepairMayRemoveCatalogPeer(
                            liveRow.peerKey,
                            scannedPeers,
                            liveTranscript != null,
                        )
                    ) {
                        if (liveRow != null) removeMeshSummaryCatalogPeer(liveRow.peerKey)
                        else deleteDurably(snapshotFile)
                    }
                }
            }
        }

        val scannedRecent = boundedMeshDmSummaries(repaired)
        mutationLocks.withTranscript {
            val merged = mergeRecentMeshSummaryRepair(scannedRecent, readMeshSummaries()) { peerKey ->
                val target = meshFile(peerKey)
                target.exists() && runCatching { MessageCodec.decodeMeshEnvelope(target.readText()) }
                    .getOrNull()?.takeIf { it.first == peerKey }?.second?.lastOrNull() != null
            }
            writeMeshSummaries(merged)
            // Legacy append-only catalogs can contain an arbitrarily long empty
            // suffix. Trim one bounded batch only on this background repair path.
            if (meshSummaryCatalogPages.compactTrailingEmptyPages()) {
                meshSummaryCatalogPages.advanceFreeHintScan()
            }
        }
    }

    actual suspend fun saveMeshDm(peerKey: String, msgs: List<SonarMsg>, revision: Long, expectedEpoch: Long): Boolean = withContext(Dispatchers.IO) {
        mutationLocks.withTranscript {
            if (expectedEpoch != committedWipeRevision) return@withTranscript false
            if (!repairPendingSummaryTransaction()) return@withTranscript false
            if (!acceptsMeshStoreRevision(revision, committedRevisionFor(peerKey))) return@withTranscript true
            commitMeshSummaryTransaction(
                writeRepairIntent = { writeSummaryRepairIntent(peerKey) },
                mutateTranscript = { atomicWrite(meshFile(peerKey), MessageCodec.encodeMeshEnvelope(peerKey, msgs)) },
                commitCatalog = { commitCatalogForPeer(peerKey) },
                clearRepairIntent = ::clearSummaryRepairIntent,
            ).also { committed -> if (committed) committedMeshRevision[peerKey] = revision }
        }
    }

    actual suspend fun deleteMeshDm(peerKey: String, revision: Long, expectedEpoch: Long): Boolean = withContext(Dispatchers.IO) {
        mutationLocks.withTranscript {
            if (expectedEpoch != committedWipeRevision) return@withTranscript false
            if (!repairPendingSummaryTransaction()) return@withTranscript false
            if (acceptsMeshStoreRevision(revision, committedRevisionFor(peerKey))) {
                commitMeshSummaryTransaction(
                    writeRepairIntent = { writeSummaryRepairIntent(peerKey) },
                    mutateTranscript = { deleteDurably(meshFile(peerKey)) },
                    commitCatalog = { commitCatalogForPeer(peerKey) },
                    clearRepairIntent = ::clearSummaryRepairIntent,
                ).also { committed -> if (committed) committedMeshRevision[peerKey] = revision }
            } else {
                true
            }
        }
    }

    actual suspend fun loadMeshPending(): List<MeshPendingDeliveryRecord> = withContext(Dispatchers.IO) {
        mutationLocks.withOutbox { meshPendingOutbox.load() }
    }

    actual suspend fun saveMeshPending(record: MeshPendingDeliveryRecord, expectedEpoch: Long): MeshPendingDeliveryRecord? = withContext(Dispatchers.IO) {
        mutationLocks.withOutbox {
            if (expectedEpoch != committedWipeRevision) return@withOutbox null
            meshPendingOutbox.save(record)
        }
    }

    actual suspend fun deleteMeshPending(peerKey: String, messageId: String, expectedEpoch: Long): Boolean = withContext(Dispatchers.IO) {
        mutationLocks.withOutbox {
            if (expectedEpoch != committedWipeRevision) return@withOutbox false
            meshPendingOutbox.delete(peerKey, messageId)
        }
    }

    actual suspend fun deleteMeshPendingForPeer(peerKey: String, expectedEpoch: Long): Boolean = withContext(Dispatchers.IO) {
        mutationLocks.withOutbox {
            if (expectedEpoch != committedWipeRevision) return@withOutbox false
            meshPendingOutbox.deletePeer(peerKey)
        }
    }

    actual suspend fun loadRoutePending(): List<QueuedMessage> = withContext(Dispatchers.IO) {
        mutationLocks.withOutbox { routePendingOutbox.load() }
    }

    actual suspend fun saveRoutePending(record: QueuedMessage, expectedEpoch: Long): QueuedMessage? = withContext(Dispatchers.IO) {
        mutationLocks.withOutbox {
            if (expectedEpoch != committedWipeRevision) return@withOutbox null
            routePendingOutbox.save(record)
        }
    }

    actual suspend fun deleteRoutePending(peerKey: String, messageId: String, expectedEpoch: Long): Boolean = withContext(Dispatchers.IO) {
        mutationLocks.withOutbox {
            if (expectedEpoch != committedWipeRevision) return@withOutbox false
            routePendingOutbox.delete(peerKey, messageId)
        }
    }

    actual suspend fun deleteRoutePendingForPeer(peerKey: String, expectedEpoch: Long): Boolean = withContext(Dispatchers.IO) {
        mutationLocks.withOutbox {
            if (expectedEpoch != committedWipeRevision) return@withOutbox false
            routePendingOutbox.deletePeer(peerKey)
        }
    }

    private fun meshMediaDir(): File = File(root(), "mesh-media").apply { mkdirs() }

    private fun meshMediaFile(mediaUrl: String): File =
        File(meshMediaDir(), "${hashName("mesh-media:$mediaUrl")}.bin")

    private fun meshMediaIndexFile(peerKey: String): File =
        File(meshMediaDir(), "${hashName("mesh-media-index:$peerKey")}.idx")

    private fun readMeshMediaIndex(peerKey: String): Set<String>? {
        val index = meshMediaIndexFile(peerKey)
        if (!index.exists()) return emptySet()
        return runCatching { index.readLines().filter(String::isNotBlank).toSet() }.getOrNull()
    }

    private fun writeMeshMediaIndex(peerKey: String, names: Set<String>): Boolean {
        val index = meshMediaIndexFile(peerKey)
        return if (names.isEmpty()) deleteDurably(index)
        else atomicWrite(index, names.sorted().joinToString("\n"))
    }

    actual suspend fun saveMeshMedia(mediaUrl: String, bytes: ByteArray, expectedEpoch: Long): Boolean =
        withContext(Dispatchers.IO) {
            mutationLocks.withTranscript {
                if (expectedEpoch != committedWipeRevision) return@withTranscript false
                val target = meshMediaFile(mediaUrl)
                if (!atomicWriteBytes(target, bytes)) return@withTranscript false
                val peerKey = meshPeerKeyFromMediaUrl(mediaUrl) ?: return@withTranscript true
                val indexed = readMeshMediaIndex(peerKey)
                if (indexed != null && writeMeshMediaIndex(peerKey, indexed + target.name)) return@withTranscript true
                deleteDurably(target)
                false
            }
        }

    actual suspend fun loadMeshMedia(mediaUrl: String): ByteArray? = withContext(Dispatchers.IO) {
        mutationLocks.withTranscript {
            val f = meshMediaFile(mediaUrl)
            if (!f.exists()) null else runCatching { f.readBytes() }.getOrNull()
        }
    }

    actual suspend fun deleteMeshMedia(mediaUrl: String, expectedEpoch: Long): Boolean =
        withContext(Dispatchers.IO) {
            mutationLocks.withTranscript {
                if (expectedEpoch != committedWipeRevision) return@withTranscript false
                val target = meshMediaFile(mediaUrl)
                val peerKey = meshPeerKeyFromMediaUrl(mediaUrl)
                val deleted = deleteDurably(target)
                if (!deleted || peerKey == null) return@withTranscript deleted
                val indexed = readMeshMediaIndex(peerKey) ?: return@withTranscript false
                writeMeshMediaIndex(peerKey, indexed - target.name)
            }
        }

    actual suspend fun deleteMeshMediaForPeer(peerKey: String, expectedEpoch: Long): Boolean =
        withContext(Dispatchers.IO) {
            mutationLocks.withTranscript {
                if (expectedEpoch != committedWipeRevision) return@withTranscript false
                val transcriptFile = meshFile(peerKey)
                val transcriptUrls = if (!transcriptFile.exists()) emptySet() else {
                    val envelope = runCatching { MessageCodec.decodeMeshEnvelope(transcriptFile.readText()) }
                        .getOrNull()?.takeIf { it.first == peerKey } ?: return@withTranscript false
                    meshMediaUrlsForDeletion(envelope.second)
                }
                val indexed = readMeshMediaIndex(peerKey) ?: return@withTranscript false
                val validIndexedFiles = indexed.mapNotNull { name ->
                    name.takeIf { it.matches(Regex("[0-9a-f]{64}\\.bin")) }?.let { File(meshMediaDir(), it) }
                }
                if (validIndexedFiles.size != indexed.size) return@withTranscript false
                val targets = validIndexedFiles + transcriptUrls.map(::meshMediaFile)
                targets.all(::deleteDurably) && deleteDurably(meshMediaIndexFile(peerKey))
            }
        }

    actual suspend fun wipe(revision: Long): MessageStoreWipeResult = withContext(Dispatchers.IO) {
        mutationLocks.withWipe {
                val parent = DesktopEnv.dataDir
                val storageRoot = DesktopEnv.file("messages")
                val tombstone = File(parent, ".messages-wipe-$revision-${System.nanoTime()}")
                commitMessageStoreRetirement(
                    detachNamespace = {
                        runCatching {
                            if (storageRoot.exists()) {
                                try {
                                    Files.move(storageRoot.toPath(), tombstone.toPath(), StandardCopyOption.ATOMIC_MOVE)
                                } catch (_: AtomicMoveNotSupportedException) {
                                    Files.move(storageRoot.toPath(), tombstone.toPath())
                                }
                            }
                            true
                        }.getOrDefault(false)
                    },
                    advanceEpoch = {
                        // The rename is already visible: fence queued work now,
                        // even if mkdir/fsync/tombstone cleanup later fails.
                        committedWipeRevision = maxOf(committedWipeRevision, revision)
                        committedMeshRevision.clear()
                        meshPendingOutbox.invalidate()
                        routePendingOutbox.invalidate()
                    },
                    proveDetachedDurable = { syncDirectory(parent) },
                    rollbackNamespace = {
                        runCatching {
                            if (tombstone.exists()) {
                                check(!storageRoot.exists()) { "active namespace recreated before rollback" }
                                try {
                                    Files.move(tombstone.toPath(), storageRoot.toPath(), StandardCopyOption.ATOMIC_MOVE)
                                } catch (_: AtomicMoveNotSupportedException) {
                                    Files.move(tombstone.toPath(), storageRoot.toPath())
                                }
                            } else {
                                check(storageRoot.mkdirs() || storageRoot.isDirectory)
                            }
                            if (syncDirectory(parent)) MessageStoreRollbackOutcome.Restored
                            else MessageStoreRollbackOutcome.Ambiguous
                        }.getOrElse {
                            if (!storageRoot.exists() && tombstone.exists()) {
                                MessageStoreRollbackOutcome.StillDetached
                            } else {
                                MessageStoreRollbackOutcome.Ambiguous
                            }
                        }
                    },
                    cleanup = {
                        runCatching {
                            check(storageRoot.mkdirs() || storageRoot.isDirectory)
                            check(syncDirectory(parent))
                            check(cleanupJvmDirectoryTombstones(parent, ".messages-wipe-"))
                            true
                        }.getOrDefault(false)
                    },
                )
        }
    }

    private fun syncDirectory(directory: File?): Boolean =
        syncJvmMessageStoreDirectory(directory)
}
