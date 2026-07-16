package chat.bitchat.sonar.store

import chat.bitchat.sonar.AppContextHolder
import chat.bitchat.sonar.MeshPendingDeliveryRecord
import chat.bitchat.sonar.OUTBOX_TTL_SECS
import chat.bitchat.sonar.QueuedMessage
import chat.bitchat.sonar.SonarChannelMsg
import chat.bitchat.sonar.SonarMsg
import chat.bitchat.sonar.cleanupAndroidDirectoryTombstones
import chat.bitchat.sonar.crypto.Sha256
import chat.bitchat.sonar.syncAndroidDirectoryStrict
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap

/**
 * Android `actual`: transcripts as files under the app's private `files/messages`
 * dir (encrypted at rest by Android File-Based Encryption). Filenames are
 * sha256(key) so raw geohashes / peer keys never hit the filesystem.
 */
actual object MessageStore {
    /** One crash-safe writer owns mesh transcript/outbox mutations and wipe.
     * This is deliberately off-main and prevents an older detached save, an ACK
     * delete, or account wipe from racing a newer durable state into oblivion. */
    private val mutationLocks = MessageStoreMutationLocks()
    private val committedMeshRevision = ConcurrentHashMap<String, Long>()
    @Volatile private var committedWipeRevision = 0L

    actual fun storageEpoch(): Long = committedWipeRevision

    private fun committedRevisionFor(peerKey: String): Long =
        maxOf(committedWipeRevision, committedMeshRevision[peerKey] ?: Long.MIN_VALUE)

    private fun root(): File =
        File(AppContextHolder.ctx.filesDir, "messages").apply { mkdirs() }

    private fun file(kind: String, key: String): File {
        val name = Sha256.hash("$kind:$key".encodeToByteArray())
            .joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }
        return File(root(), "$name.txt")
    }

    private fun hashName(input: String): String =
        Sha256.hash(input.encodeToByteArray())
            .joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }

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

    // BLE-mesh private transcripts live in their own subdir so loadAll can
    // enumerate just them (channel/geo-DM files share root() but the key can't be
    // recovered from their hashed names). Each mesh file carries a peerKey
    // envelope (MessageCodec.encodeMeshEnvelope) so the map is re-keyed on load.
    private fun meshDir(): File = File(root(), "mesh").apply { mkdirs() }

    private fun meshSummaryIndexFile(): File = File(meshDir(), ".mesh-summary-index-v1")

    private fun meshSummaryCatalogDir(): File = File(meshDir(), ".summary-catalog-v2").apply { mkdirs() }
    private fun meshSummaryCatalogFile(peerKey: String): File =
        File(meshSummaryCatalogDir(), "${hashName("mesh-summary:$peerKey")}.summary")
    private fun meshSummaryAssignmentFile(peerKey: String): File =
        File(meshSummaryCatalogDir(), "${hashName("mesh-summary:$peerKey")}.page-ref")
    private fun meshSummaryPagesDir(): File = File(meshSummaryCatalogDir(), "pages-v1").apply { mkdirs() }
    private fun meshSummaryTailFile(): File = File(meshSummaryPagesDir(), "tail")
    private fun meshSummaryPageFile(pageNumber: Int): File =
        File(meshSummaryPagesDir(), "page-${pageNumber.toString().padStart(10, '0')}")
    private fun meshSummaryRepairIntentFile(): File = File(meshDir(), ".mesh-summary-repair-v1")

    private fun meshFile(peerKey: String): File {
        val name = Sha256.hash("mesh:$peerKey".encodeToByteArray())
            .joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }
        return File(meshDir(), "$name.txt")
    }

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

        override fun readIndex(): String? =
            runCatching { indexFile().readText() }.getOrNull()

        override fun writeIndex(payload: String): Boolean =
            atomicWrite(indexFile(), payload)

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

    /** A crash may leave a fully-written temp behind before rename. Temps are
     * never committed records and must not be decoded/replayed on restart. */
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

    private fun readMeshSummaryTail(): Int? {
        val target = meshSummaryTailFile()
        if (!target.exists()) return null
        return runCatching { target.readText().trim().toInt() }.getOrNull()?.takeIf { it >= 0 }
    }

    private fun readMeshSummaryPeerPage(pageNumber: Int): List<String?>? {
        val target = meshSummaryPageFile(pageNumber)
        if (!target.exists()) return emptyList()
        return runCatching { MessageCodec.decodeMeshSummaryPeerPage(target.readText()) }.getOrNull()
    }

    private fun writeMeshSummaryPeerPage(pageNumber: Int, peers: List<String?>): Boolean =
        atomicWrite(meshSummaryPageFile(pageNumber), MessageCodec.encodeMeshSummaryPeerPage(peers))

    private fun ensureMeshSummaryPageAssignment(peerKey: String): Boolean {
        val assignment = meshSummaryAssignmentFile(peerKey)
        val assignedPage = if (!assignment.exists()) null else runCatching {
            MessageCodec.decodeMeshSummaryAssignment(assignment.readText())
        }.getOrNull()
        if (assignedPage != null) {
            val peers = readMeshSummaryPeerPage(assignedPage) ?: return false
            val committedPeers = meshSummaryPageWithSinglePeer(peers, peerKey)
            if (committedPeers != null) {
                return commitMeshSummaryAssignment(
                    pageContainsPeer = peerKey in peers,
                    commitPageIfRequired = { writeMeshSummaryPeerPage(assignedPage, committedPeers) },
                    // Visibility does not prove the earlier marker rename was
                    // committed if its parent-directory fsync failed.
                    commitAssignment = {
                        atomicWrite(assignment, MessageCodec.encodeMeshSummaryAssignment(assignedPage))
                    },
                )
            }
        }

        var tail = readMeshSummaryTail() ?: 0
        var peers: List<String?> = readMeshSummaryPeerPage(tail) ?: return false
        var committedPeers = meshSummaryPageWithSinglePeer(peers, peerKey)
        if (committedPeers == null) {
            tail += 1
            peers = emptyList()
            committedPeers = meshSummaryPageWithSinglePeer(peers, peerKey) ?: return false
        }
        if (!atomicWrite(meshSummaryTailFile(), tail.toString())) return false
        // Page first, assignment last. If the assignment write failed after a
        // successful page commit, the retry recommits that one slot rather than
        // appending a duplicate before recreating the marker.
        if (!writeMeshSummaryPeerPage(tail, committedPeers)) return false
        return atomicWrite(assignment, MessageCodec.encodeMeshSummaryAssignment(tail))
    }

    private fun removeMeshSummaryCatalogPeer(peerKey: String): Boolean {
        val assignment = meshSummaryAssignmentFile(peerKey)
        val pageNumber = if (!assignment.exists()) null else runCatching {
            MessageCodec.decodeMeshSummaryAssignment(assignment.readText())
        }.getOrNull() ?: if (assignment.exists()) return false else null
        if (pageNumber != null) {
            val peers = readMeshSummaryPeerPage(pageNumber) ?: return false
            if (!writeMeshSummaryPeerPage(pageNumber, peers.map { if (it == peerKey) null else it })) return false
            if (!deleteDurably(assignment)) return false
        }
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
        return readBoundedMeshSummaryCatalogPage(
            afterCursor = afterCursor,
            limit = limit,
            lastPage = ::readMeshSummaryTail,
            readPeerPage = ::readMeshSummaryPeerPage,
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
        android.system.Os.rename(temp.absolutePath, target.absolutePath)
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
        android.system.Os.rename(temp.absolutePath, target.absolutePath)
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
        // Directory enumeration and decoding stay outside the mutation lock.
        // An open-chat O(1) read must not queue behind a full legacy scan.
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

    actual suspend fun saveMeshMedia(mediaUrl: String, bytes: ByteArray, expectedEpoch: Long): Boolean =
        withContext(Dispatchers.IO) {
            mutationLocks.withTranscript {
                if (expectedEpoch != committedWipeRevision) return@withTranscript false
                atomicWriteBytes(meshMediaFile(mediaUrl), bytes)
            }
        }

    actual suspend fun loadMeshMedia(mediaUrl: String): ByteArray? = withContext(Dispatchers.IO) {
        mutationLocks.withTranscript {
            val f = meshMediaFile(mediaUrl)
            if (!f.exists()) null else runCatching { f.readBytes() }.getOrNull()
        }
    }

    actual suspend fun wipe(revision: Long): MessageStoreWipeResult = withContext(Dispatchers.IO) {
        mutationLocks.withWipe {
                val parent = AppContextHolder.ctx.filesDir
                val storageRoot = File(parent, "messages")
                val tombstone = File(parent, ".messages-wipe-$revision-${System.nanoTime()}")
                commitMessageStoreRetirement(
                    detachNamespace = {
                        runCatching {
                            if (storageRoot.exists()) {
                                android.system.Os.rename(storageRoot.absolutePath, tombstone.absolutePath)
                            }
                            true
                        }.getOrDefault(false)
                    },
                    advanceEpoch = {
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
                                android.system.Os.rename(tombstone.absolutePath, storageRoot.absolutePath)
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
                            check(cleanupAndroidDirectoryTombstones(parent, ".messages-wipe-"))
                            true
                        }.getOrDefault(false)
                    },
                )
        }
    }

    private fun syncDirectory(directory: File?): Boolean {
        return syncAndroidDirectoryStrict(directory)
    }
}
