package chat.bitchat.sonar

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

actual object MediaCache {
    private fun root(): File = File(AppContextHolder.ctx.filesDir, "media-cache")

    actual fun finalPath(url: String): String = File(root(), mediaCacheKey(url)).absolutePath

    actual fun partialPath(url: String, token: String): String =
        File(root(), ".${mediaCacheKey(url)}.$token.part").absolutePath

    actual fun thumbnailPath(url: String): String =
        File(File(root(), "thumbs"), "${mediaCacheKey(url)}.thumb").absolutePath

    actual suspend fun prepare(): Unit = withContext(Dispatchers.IO) {
        check(root().isDirectory || root().mkdirs()) { "could not create media cache" }
    }

    actual suspend fun exists(path: String): Boolean = withContext(Dispatchers.IO) {
        File(path).isFile
    }

    actual fun existsSync(path: String): Boolean = File(path).isFile

    actual suspend fun read(path: String): ByteArray? = withContext(Dispatchers.IO) {
        runCatching { File(path).takeIf(File::isFile)?.readBytes() }.getOrNull()
    }

    actual suspend fun readPrefix(path: String, maxBytes: Int): ByteArray? = withContext(Dispatchers.IO) {
        runCatching {
            File(path).inputStream().use { input ->
                val buffer = ByteArray(maxBytes.coerceAtLeast(0))
                val count = input.read(buffer)
                if (count < 0) ByteArray(0) else buffer.copyOf(count)
            }
        }.getOrNull()
    }

    actual suspend fun write(path: String, bytes: ByteArray): Boolean = withContext(Dispatchers.IO) {
        runCatching {
            val file = File(path)
            check(file.parentFile?.let { it.isDirectory || it.mkdirs() } == true)
            file.outputStream().use { it.write(bytes) }
            true
        }.getOrDefault(false)
    }

    actual suspend fun promote(partialPath: String, finalPath: String): Boolean = withContext(Dispatchers.IO) {
        runCatching {
            val partial = File(partialPath)
            val final = File(finalPath)
            if (final.isFile) {
                partial.delete()
                return@runCatching true
            }
            partial.renameTo(final) && final.isFile
        }.getOrDefault(false)
    }

    actual suspend fun remove(path: String): Unit = withContext(Dispatchers.IO) {
        runCatching { File(path).delete() }
        Unit
    }

    actual suspend fun wipe(): Unit = withContext(Dispatchers.IO) {
        runCatching { root().deleteRecursively() }
        Unit
    }
}
