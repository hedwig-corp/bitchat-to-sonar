package chat.bitchat.sonar

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermission

actual object MediaCache {
    private fun root(): File = DesktopEnv.file("media-cache")

    actual fun thumbnailPath(url: String): String =
        File(File(root(), "thumbs"), "${mediaCacheKey(url)}.thumb").absolutePath

    private fun restrictPermissions(file: File, directory: Boolean = false) {
        runCatching {
            val permissions = buildSet {
                add(PosixFilePermission.OWNER_READ)
                add(PosixFilePermission.OWNER_WRITE)
                if (directory) add(PosixFilePermission.OWNER_EXECUTE)
            }
            Files.setPosixFilePermissions(file.toPath(), permissions)
        }
    }

    actual fun finalPath(url: String): String = File(root(), mediaCacheKey(url)).absolutePath

    actual fun partialPath(url: String, token: String): String =
        File(root(), ".${mediaCacheKey(url)}.$token.part").absolutePath

    actual suspend fun prepare(): Unit = withContext(Dispatchers.IO) {
        val root = root()
        check(root.isDirectory || root.mkdirs()) { "could not create media cache" }
        restrictPermissions(root, directory = true)
    }

    actual suspend fun exists(path: String): Boolean = withContext(Dispatchers.IO) { File(path).isFile }

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
            val directory = file.parentFile
            check(directory != null && (directory.isDirectory || directory.mkdirs()))
            restrictPermissions(directory, directory = true)
            file.outputStream().use { it.write(bytes) }
            restrictPermissions(file)
            true
        }.getOrDefault(false)
    }

    actual suspend fun promote(partialPath: String, finalPath: String): Boolean = withContext(Dispatchers.IO) {
        runCatching {
            val partial = File(partialPath)
            val final = File(finalPath)
            if (final.isFile) {
                partial.delete()
                restrictPermissions(final)
                return@runCatching true
            }
            try {
                Files.move(partial.toPath(), final.toPath(), StandardCopyOption.ATOMIC_MOVE)
            } catch (_: AtomicMoveNotSupportedException) {
                // Same-directory move remains non-copying on filesystems that do
                // not advertise atomic rename support.
                Files.move(partial.toPath(), final.toPath())
            }
            restrictPermissions(final)
            final.isFile
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
