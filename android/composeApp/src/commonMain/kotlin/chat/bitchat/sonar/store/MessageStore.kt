package chat.bitchat.sonar.store

import chat.bitchat.sonar.SonarChannelMsg
import chat.bitchat.sonar.SonarMsg

/**
 * On-device persistence of transcripts that the relays do NOT keep, so they
 * survive an app restart — the Android twin of the iOS `MessageStore`.
 *
 * White Noise (Marmot) DMs already persist in the encrypted SQLCipher DB via
 * MDK, so they are NOT handled here. This store covers:
 *  - geohash **channels** (kind 20000 ephemeral — relays never store them; once
 *    missed they are gone), and
 *  - geohash **DMs** (buffered in the Rust core in memory, reset each launch).
 *
 * Files live under the app's private storage, which Android File-Based
 * Encryption keeps encrypted at rest (analogous to iOS NSFileProtectionComplete).
 */
expect object MessageStore {
    fun loadChannel(geohash: String): List<SonarChannelMsg>
    fun saveChannel(geohash: String, msgs: List<SonarChannelMsg>)
    fun loadGeoDm(geohash: String, peerHex: String): List<SonarMsg>
    fun saveGeoDm(geohash: String, peerHex: String, msgs: List<SonarMsg>)
    fun wipe()
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
            row(m.id, m.senderNpub, if (m.mine) "1" else "0", m.tsSecs.toString(), m.content)
        }

    fun decodeDm(blob: String): List<SonarMsg> =
        blob.lineSequence().mapNotNull { line ->
            val f = unrow(line) ?: return@mapNotNull null
            if (f.size != 5) return@mapNotNull null
            SonarMsg(
                id = f[0], senderNpub = f[1], content = f[4],
                mine = f[2] == "1", tsSecs = f[3].toLongOrNull() ?: 0L,
            )
        }.toList()

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
