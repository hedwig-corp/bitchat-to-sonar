package chat.bitchat.sonar

import chat.bitchat.sonar.store.durabilityBarrier
import java.io.File

/** Strict Android directory barrier: open, fsync, and close failures propagate. */
internal fun syncAndroidDirectoryStrict(directory: File?): Boolean {
    if (directory == null) return false
    return durabilityBarrier {
        val fd = android.system.Os.open(
            directory.absolutePath,
            android.system.OsConstants.O_RDONLY,
            0,
        )
        try {
            android.system.Os.fsync(fd)
        } finally {
            android.system.Os.close(fd)
        }
    }
}

/** Rename a live account tree out of its addressable path and commit the rename. */
internal fun quarantineAndroidDirectory(root: File, tombstonePrefix: String): Boolean {
    if (!root.exists()) return true
    val parent = root.parentFile ?: return false
    val tombstone = generateSequence(0) { it + 1 }
        .map { attempt -> File(parent, "$tombstonePrefix${System.nanoTime()}-$attempt") }
        .first { !it.exists() }
    return durabilityBarrier {
        android.system.Os.rename(root.absolutePath, tombstone.absolutePath)
        check(syncAndroidDirectoryStrict(parent)) { "failed to sync quarantine rename" }
    }
}

/** Delete every retired generation, commit the unlinks, and prove absence. */
internal fun cleanupAndroidDirectoryTombstones(parent: File, tombstonePrefix: String): Boolean {
    val files = parent.listFiles() ?: return false
    val tombstones = files.filter { it.name.startsWith(tombstonePrefix) }
    if (tombstones.isEmpty()) return true
    val deleted = tombstones.map { it.deleteRecursively() }.all { it }
    val synced = syncAndroidDirectoryStrict(parent)
    val absent = parent.listFiles()?.none { it.name.startsWith(tombstonePrefix) } == true
    return deleted && synced && absent
}

internal fun durablyRetireAndroidDirectory(root: File, tombstonePrefix: String): Boolean {
    val parent = root.parentFile ?: return false
    return completeDurableRetirement(
        quarantine = { quarantineAndroidDirectory(root, tombstonePrefix) },
        cleanup = { cleanupAndroidDirectoryTombstones(parent, tombstonePrefix) },
        proveAbsent = {
            !root.exists() && parent.listFiles()?.none { it.name.startsWith(tombstonePrefix) } == true
        },
    )
}

/** Durable selective cleanup for exported diagnostics sharing a cache directory. */
internal fun durablyDeleteAndroidFiles(directory: File, matches: (File) -> Boolean): Boolean {
    if (!directory.exists()) return true
    val files = directory.listFiles() ?: return false
    val targets = files.filter(matches)
    if (targets.isEmpty()) return true
    val deleted = targets.map { !it.exists() || it.delete() }.all { it }
    val synced = syncAndroidDirectoryStrict(directory)
    val absent = directory.listFiles()?.none(matches) == true
    return deleted && synced && absent
}
