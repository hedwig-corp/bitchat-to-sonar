package chat.bitchat.sonar.store

import chat.bitchat.sonar.AppContextHolder
import chat.bitchat.sonar.SonarChannelMsg
import chat.bitchat.sonar.SonarMsg
import chat.bitchat.sonar.crypto.Sha256
import java.io.File

/**
 * Android `actual`: transcripts as files under the app's private `files/messages`
 * dir (encrypted at rest by Android File-Based Encryption). Filenames are
 * sha256(key) so raw geohashes / peer keys never hit the filesystem.
 */
actual object MessageStore {
    private fun root(): File =
        File(AppContextHolder.ctx.filesDir, "messages").apply { mkdirs() }

    private fun file(kind: String, key: String): File {
        val name = Sha256.hash("$kind:$key".encodeToByteArray())
            .joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }
        return File(root(), "$name.txt")
    }

    actual fun loadChannel(geohash: String): List<SonarChannelMsg> {
        val f = file("ch", geohash.lowercase())
        if (!f.exists()) return emptyList()
        return runCatching { MessageCodec.decodeChannel(f.readText()) }.getOrDefault(emptyList())
    }

    actual fun saveChannel(geohash: String, msgs: List<SonarChannelMsg>) {
        runCatching {
            file("ch", geohash.lowercase()).writeText(
                MessageCodec.encodeChannel(msgs.takeLast(MESSAGE_STORE_CAP))
            )
        }
    }

    actual fun loadGeoDm(geohash: String, peerHex: String): List<SonarMsg> {
        val f = file("dm", "${geohash.lowercase()}:${peerHex.lowercase()}")
        if (!f.exists()) return emptyList()
        return runCatching { MessageCodec.decodeDm(f.readText()) }.getOrDefault(emptyList())
    }

    actual fun saveGeoDm(geohash: String, peerHex: String, msgs: List<SonarMsg>) {
        runCatching {
            file("dm", "${geohash.lowercase()}:${peerHex.lowercase()}").writeText(
                MessageCodec.encodeDm(msgs.takeLast(MESSAGE_STORE_CAP))
            )
        }
    }

    actual fun wipe() {
        runCatching { root().deleteRecursively() }
    }
}
