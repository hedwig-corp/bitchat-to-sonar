package chat.bitchat.sonar

import chat.bitchat.sonar.store.durabilityBarrier
import java.io.File
import java.nio.channels.FileChannel
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption

/** Strict JVM directory barrier: open, force, and close failures propagate. */
internal fun syncJvmDirectoryStrict(
    directory: File?,
    force: (File) -> Unit = { target ->
        FileChannel.open(target.toPath(), StandardOpenOption.READ).use { it.force(true) }
    },
): Boolean {
    if (directory == null) return false
    return durabilityBarrier { force(directory) }
}

internal fun quarantineJvmDirectory(
    root: File,
    tombstonePrefix: String,
    syncDirectory: (File?) -> Boolean = ::syncJvmDirectoryStrict,
): Boolean {
    if (!root.exists()) return true
    val parent = root.parentFile ?: return false
    val tombstone = generateSequence(0) { it + 1 }
        .map { attempt -> File(parent, "$tombstonePrefix${System.nanoTime()}-$attempt") }
        .first { !it.exists() }
    return durabilityBarrier {
        try {
            Files.move(root.toPath(), tombstone.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(root.toPath(), tombstone.toPath())
        }
        check(syncDirectory(parent)) { "failed to sync quarantine rename" }
    }
}

internal fun cleanupJvmDirectoryTombstones(
    parent: File,
    tombstonePrefix: String,
    deleteTree: (File) -> Boolean = File::deleteRecursively,
    syncDirectory: (File?) -> Boolean = ::syncJvmDirectoryStrict,
    listFiles: (File) -> Array<File>? = File::listFiles,
): Boolean {
    val files = listFiles(parent) ?: return false
    val tombstones = files.filter { it.name.startsWith(tombstonePrefix) }
    if (tombstones.isEmpty()) return true
    val deleted = tombstones.map(deleteTree).all { it }
    val synced = syncDirectory(parent)
    val absent = parent.listFiles()?.none { it.name.startsWith(tombstonePrefix) } == true
    return deleted && synced && absent
}

internal fun durablyRetireJvmDirectory(
    root: File,
    tombstonePrefix: String,
    syncDirectory: (File?) -> Boolean = ::syncJvmDirectoryStrict,
    deleteTree: (File) -> Boolean = File::deleteRecursively,
): Boolean {
    val parent = root.parentFile ?: return false
    return completeDurableRetirement(
        quarantine = { quarantineJvmDirectory(root, tombstonePrefix, syncDirectory) },
        cleanup = { cleanupJvmDirectoryTombstones(parent, tombstonePrefix, deleteTree, syncDirectory) },
        proveAbsent = {
            !root.exists() && parent.listFiles()?.none { it.name.startsWith(tombstonePrefix) } == true
        },
    )
}
