package chat.bitchat.sonar

import java.io.File
import java.io.FileOutputStream
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption

internal actual object PanicWipeIntent {
    private const val FILE_NAME = ".panic-wipe.intent"
    private val marker: File get() = File(AppContextHolder.ctx.filesDir, FILE_NAME)

    @Synchronized
    actual fun begin(): Boolean {
        if (marker.exists()) return runCatching {
            FileOutputStream(marker, true).use { it.fd.sync() }
            fsyncParent(marker)
            true
        }.getOrDefault(false)
        return runCatching {
            marker.parentFile?.mkdirs()
            val tmp = File(marker.parentFile, "$FILE_NAME.tmp")
            FileOutputStream(tmp, false).use { output ->
                output.write("sonar-panic-wipe-v1\n".encodeToByteArray())
                output.flush()
                output.fd.sync()
            }
            try {
                Files.move(tmp.toPath(), marker.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } catch (_: Throwable) {
                Files.move(tmp.toPath(), marker.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
            fsyncParent(marker)
            true
        }.getOrDefault(false)
    }

    actual fun isPending(): Boolean = marker.exists()

    @Synchronized
    actual fun clear(): Boolean = runCatching {
        if (!marker.exists()) return@runCatching true
        check(marker.delete()) { "failed to remove panic wipe marker" }
        fsyncParent(marker)
        true
    }.getOrDefault(false)

    private fun fsyncParent(file: File) {
        val parent = file.parentFile ?: return
        FileChannel.open(parent.toPath(), StandardOpenOption.READ).use { it.force(true) }
    }
}
