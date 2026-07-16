package chat.bitchat.sonar

import java.io.File
import java.io.FileOutputStream
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption

internal class DurablePanicWipeIntent(private val marker: File) {
    @Synchronized
    fun begin(): Boolean {
        if (marker.exists()) return runCatching {
            FileOutputStream(marker, true).use { it.fd.sync() }
            fsyncParent()
            true
        }.getOrDefault(false)
        return runCatching {
            marker.parentFile?.mkdirs()
            val tmp = File(marker.parentFile, "${marker.name}.tmp")
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
            fsyncParent()
            true
        }.getOrDefault(false)
    }

    fun isPending(): Boolean = marker.exists()

    @Synchronized
    fun clear(): Boolean = runCatching {
        if (!marker.exists()) return@runCatching true
        check(marker.delete()) { "failed to remove panic wipe marker" }
        fsyncParent()
        true
    }.getOrDefault(false)

    private fun fsyncParent() {
        val parent = marker.parentFile ?: return
        FileChannel.open(parent.toPath(), StandardOpenOption.READ).use { it.force(true) }
    }
}

internal actual object PanicWipeIntent {
    private val journal by lazy { DurablePanicWipeIntent(DesktopEnv.file(".panic-wipe.intent")) }

    actual fun begin(): Boolean = journal.begin()
    actual fun isPending(): Boolean = journal.isPending()
    actual fun clear(): Boolean = journal.clear()
}
