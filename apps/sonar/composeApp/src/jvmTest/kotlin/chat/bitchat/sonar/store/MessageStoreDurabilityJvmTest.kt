package chat.bitchat.sonar.store

import chat.bitchat.sonar.cleanupJvmDirectoryTombstones
import chat.bitchat.sonar.durablyRetireJvmDirectory
import chat.bitchat.sonar.persistDesktopPropertiesFile
import java.io.File
import java.nio.file.Files
import java.util.Properties
import kotlin.io.path.createTempDirectory
import kotlin.test.assertEquals
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MessageStoreDurabilityJvmTest {
    @Test
    fun tombstoneEnumerationFailureIsNotTreatedAsSuccessfulCleanup() {
        val parent = createTempDirectory("sonar-retirement-enumeration").toFile()
        try {
            val tombstone = File(parent, ".messages-wipe-1").apply { mkdirs() }

            assertFalse(
                cleanupJvmDirectoryTombstones(
                    parent = parent,
                    tombstonePrefix = ".messages-wipe-",
                    listFiles = { null },
                ),
            )
            assertTrue(tombstone.exists())
        } finally {
            parent.deleteRecursively()
        }
    }

    @Test
    fun directoryBarrierPropagatesForceAndCloseFailures() {
        val directory = createTempDirectory("sonar-message-store-sync").toFile()
        try {
            assertTrue(syncJvmMessageStoreDirectory(directory))
            assertFalse(syncJvmMessageStoreDirectory(directory) { error("force failed") })
            assertFalse(syncJvmMessageStoreDirectory(directory) { target ->
                Files.newByteChannel(target.toPath()).use { error("close failed") }
            })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun desktopPreferenceCommitDoesNotSwallowParentBarrierFailure() {
        val directory = createTempDirectory("sonar-prefs-sync").toFile()
        try {
            val prefs = directory.resolve("prefs.properties")
            val values = Properties().apply { setProperty("identity", "redacted-test-value") }

            assertFalse(
                persistDesktopPropertiesFile(
                    prefsFile = prefs,
                    properties = values,
                    durable = true,
                    syncDirectory = { false },
                ),
            )
            // The rename may already be visible, but callers must retain their
            // panic marker because namespace durability was not proved.
            assertTrue(prefs.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun directoryRetirementRetainsTombstoneUntilRenameBarrierCanBeProved() {
        val parent = createTempDirectory("sonar-retirement-sync").toFile()
        try {
            val root = parent.resolve("account-tree").apply { mkdirs() }
            root.resolve("secret.bin").writeText("test")
            var syncCalls = 0
            val sync: (java.io.File?) -> Boolean = {
                syncCalls += 1
                syncCalls > 1
            }

            assertFalse(durablyRetireJvmDirectory(root, ".account-wipe-", syncDirectory = sync))
            assertFalse(root.exists())
            assertEquals(1, parent.listFiles().orEmpty().count { it.name.startsWith(".account-wipe-") })

            assertTrue(durablyRetireJvmDirectory(root, ".account-wipe-"))
            assertTrue(parent.listFiles().orEmpty().none { it.name.startsWith(".account-wipe-") })
        } finally {
            parent.deleteRecursively()
        }
    }

    @Test
    fun directoryRetirementPropagatesTombstoneDeletionFailure() {
        val parent = createTempDirectory("sonar-retirement-delete").toFile()
        try {
            val root = parent.resolve("account-tree").apply { mkdirs() }
            root.resolve("secret.bin").writeText("test")

            assertFalse(
                durablyRetireJvmDirectory(
                    root,
                    ".account-wipe-",
                    deleteTree = { false },
                ),
            )
            assertTrue(parent.listFiles().orEmpty().any { it.name.startsWith(".account-wipe-") })
            assertTrue(durablyRetireJvmDirectory(root, ".account-wipe-"))
        } finally {
            parent.deleteRecursively()
        }
    }
}
