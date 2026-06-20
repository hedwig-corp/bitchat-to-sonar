package chat.bitchat.sonar.store

import chat.bitchat.sonar.SonarChannelMsg
import chat.bitchat.sonar.SonarMsg
import chat.bitchat.sonar.SonarStickerRef

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
    // suspend so the file I/O runs off the main thread (the Android actual
    // dispatches to Dispatchers.IO) — avoids an ANR on a cold/large store.
    suspend fun loadChannel(geohash: String): List<SonarChannelMsg>
    suspend fun saveChannel(geohash: String, msgs: List<SonarChannelMsg>)
    suspend fun loadGeoDm(geohash: String, peerHex: String): List<SonarMsg>
    suspend fun saveGeoDm(geohash: String, peerHex: String, msgs: List<SonarMsg>)
    /** All persisted BLE-mesh private transcripts, keyed by stable peer key
     *  (fingerprint). Hydrated into memory at launch so mesh DMs survive restart. */
    suspend fun loadAllMeshDms(): Map<String, List<SonarMsg>>
    /** Write-through a single peer's BLE-mesh transcript (called on every append). */
    suspend fun saveMeshDm(peerKey: String, msgs: List<SonarMsg>)
    /** Delete a single peer's BLE-mesh transcript file (per-chat delete). */
    suspend fun deleteMeshDm(peerKey: String)
    suspend fun wipe()
}

/** Cap kept on disk per conversation (matches the in-memory timeline). */
const val MESSAGE_STORE_CAP = 500

/**
 * Delimiter-safe codec for message lists. Every field is hex-encoded (so tabs /
 * newlines / pipes in message content can't corrupt the record framing), fields
 * are tab-joined, records are newline-joined. Pure + unit-tested.
 */
object MessageCodec {
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
            if (ref != null) base + "\t" + hexEnc(ref.packCoordinate) + "\t" + hexEnc(ref.shortcode) + "\t" + hexEnc(ref.plaintextSha256)
            else base
        }

    fun decodeDm(blob: String): List<SonarMsg> =
        blob.lineSequence().mapNotNull { line ->
            val f = unrow(line) ?: return@mapNotNull null
            if (f.size < 5) return@mapNotNull null
            val stickerRef = if (f.size >= 8) SonarStickerRef(f[5], f[6], f[7]) else null
            SonarMsg(
                id = f[0], senderNpub = f[1], content = f[4],
                mine = f[2] == "1", tsSecs = f[3].toLongOrNull() ?: 0L,
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
