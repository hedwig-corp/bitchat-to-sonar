package chat.bitchat.sonar.store

import chat.bitchat.sonar.DesktopEnv
import chat.bitchat.sonar.SonarChannelMsg
import chat.bitchat.sonar.SonarMsg
import chat.bitchat.sonar.crypto.Sha256
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Desktop (JVM) `actual`: transcripts as files under the app-data `messages`
 * dir. Filenames are sha256(key) so raw geohashes / peer keys never hit the
 * filesystem — identical scheme to the Android actual.
 */
actual object MessageStore {
    private fun root(): File = DesktopEnv.file("messages").apply { mkdirs() }

    private fun hashName(input: String): String =
        Sha256.hash(input.encodeToByteArray())
            .joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }

    private fun file(kind: String, key: String): File =
        File(root(), "${hashName("$kind:$key")}.txt")

    actual suspend fun loadChannel(geohash: String): List<SonarChannelMsg> = withContext(Dispatchers.IO) {
        val f = file("ch", geohash.lowercase())
        if (!f.exists()) return@withContext emptyList()
        runCatching { MessageCodec.decodeChannel(f.readText()) }.getOrDefault(emptyList())
    }

    actual suspend fun saveChannel(geohash: String, msgs: List<SonarChannelMsg>): Unit = withContext(Dispatchers.IO) {
        runCatching {
            file("ch", geohash.lowercase()).writeText(
                MessageCodec.encodeChannel(msgs.takeLast(MESSAGE_STORE_CAP))
            )
        }
        Unit
    }

    actual suspend fun loadGeoDm(geohash: String, peerHex: String): List<SonarMsg> = withContext(Dispatchers.IO) {
        val f = file("dm", "${geohash.lowercase()}:${peerHex.lowercase()}")
        if (!f.exists()) return@withContext emptyList()
        runCatching { MessageCodec.decodeDm(f.readText()) }.getOrDefault(emptyList())
    }

    actual suspend fun saveGeoDm(geohash: String, peerHex: String, msgs: List<SonarMsg>): Unit = withContext(Dispatchers.IO) {
        runCatching {
            file("dm", "${geohash.lowercase()}:${peerHex.lowercase()}").writeText(
                MessageCodec.encodeDm(msgs.takeLast(MESSAGE_STORE_CAP))
            )
        }
        Unit
    }

    private fun meshDir(): File = File(root(), "mesh").apply { mkdirs() }

    private fun meshFile(peerKey: String): File =
        File(meshDir(), "${hashName("mesh:$peerKey")}.txt")

    actual suspend fun loadAllMeshDms(): Map<String, List<SonarMsg>> = withContext(Dispatchers.IO) {
        val files = meshDir().listFiles() ?: return@withContext emptyMap()
        files.mapNotNull { f ->
            runCatching { MessageCodec.decodeMeshEnvelope(f.readText()) }.getOrNull()
        }.toMap()
    }

    actual suspend fun saveMeshDm(peerKey: String, msgs: List<SonarMsg>): Unit = withContext(Dispatchers.IO) {
        runCatching { meshFile(peerKey).writeText(MessageCodec.encodeMeshEnvelope(peerKey, msgs)) }
        Unit
    }

    actual suspend fun deleteMeshDm(peerKey: String): Unit = withContext(Dispatchers.IO) {
        runCatching { meshFile(peerKey).delete() }
        Unit
    }

    private fun meshMediaDir(): File = File(root(), "mesh-media").apply { mkdirs() }

    private fun meshMediaFile(mediaUrl: String): File =
        File(meshMediaDir(), "${hashName("mesh-media:$mediaUrl")}.bin")

    actual suspend fun saveMeshMedia(mediaUrl: String, bytes: ByteArray): Unit = withContext(Dispatchers.IO) {
        runCatching { meshMediaFile(mediaUrl).writeBytes(bytes) }
        Unit
    }

    actual suspend fun loadMeshMedia(mediaUrl: String): ByteArray? = withContext(Dispatchers.IO) {
        val f = meshMediaFile(mediaUrl)
        if (!f.exists()) return@withContext null
        runCatching { f.readBytes() }.getOrNull()
    }

    actual suspend fun wipe(): Unit = withContext(Dispatchers.IO) {
        runCatching { root().deleteRecursively() }
        Unit
    }
}
