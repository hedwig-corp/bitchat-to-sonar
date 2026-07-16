package chat.bitchat.sonar.store

import chat.bitchat.sonar.SonarMsg
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
    private enum class CatalogFault {
        ReuseIntent,
        ReusePage,
        Generation,
        ReuseIntentClear,
        CompactionIntent,
        CompactionTail,
        CompactionPageDelete,
        CompactionIntentClear,
    }

    private fun catalog(
        root: File,
        fault: CatalogFault? = null,
        onPageRead: () -> Unit = {},
        failPageRead: (File, Int) -> Boolean = { _, _ -> false },
    ): MeshSummaryCatalogPages {
        val pages = root.resolve("pages").apply { mkdirs() }
        val assignments = root.resolve("assignments").apply { mkdirs() }
        var faultPending = fault != null
        var pageReadCount = 0
        fun write(target: File, content: String): Boolean = runCatching {
            check(target.parentFile.isDirectory || target.parentFile.mkdirs())
            target.writeText(content)
            true
        }.getOrDefault(false)
        return MeshSummaryCatalogPages(
            pagesDir = pages,
            assignmentFile = { peer -> assignments.resolve("$peer.page-ref") },
            atomicWrite = { target, content ->
                val injected = faultPending && when (fault) {
                    CatalogFault.ReuseIntent -> target.name == "reuse-intent-v1"
                    CatalogFault.ReusePage -> target.name.startsWith("page-")
                    CatalogFault.Generation -> target.name == "generation-v1"
                    CatalogFault.CompactionIntent -> target.name == "compact-intent-v1"
                    CatalogFault.CompactionTail -> target.name == "tail"
                    CatalogFault.ReuseIntentClear,
                    CatalogFault.CompactionPageDelete,
                    CatalogFault.CompactionIntentClear,
                    null -> false
                }
                if (injected) {
                    faultPending = false
                    false
                } else {
                    write(target, content)
                }
            },
            deleteDurably = { target ->
                val injected = faultPending && when (fault) {
                    CatalogFault.ReuseIntentClear -> target.name == "reuse-intent-v1"
                    CatalogFault.CompactionPageDelete -> target.name.startsWith("page-")
                    CatalogFault.CompactionIntentClear -> target.name == "compact-intent-v1"
                    else -> false
                }
                if (injected) {
                    faultPending = false
                    false
                } else {
                    !target.exists() || target.delete()
                }
            },
            readText = { target ->
                var injectedReadFailure = false
                if (target.name.startsWith("page-")) {
                    pageReadCount += 1
                    onPageRead()
                    injectedReadFailure = failPageRead(target, pageReadCount)
                }
                if (!target.exists() || injectedReadFailure) null
                else runCatching { target.readText() }.getOrNull()
            },
        )
    }

    private fun summary(peer: String, timestamp: Long): MeshDmSummary = MeshDmSummary(
        peerKey = peer,
        latest = SonarMsg(peer, "", "preview", mine = false, tsSecs = timestamp),
    )

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

    @Test
    fun reusedCatalogSlotRepairsEveryCrashStageBeforeAdvancingAStaleCursor() {
        listOf(
            CatalogFault.ReuseIntent,
            CatalogFault.ReusePage,
            CatalogFault.Generation,
            CatalogFault.ReuseIntentClear,
        ).forEach { fault ->
            val root = createTempDirectory("sonar-catalog-reuse-${fault.name.lowercase()}").toFile()
            try {
                val summaries = mutableMapOf(
                    "old-a" to summary("old-a", 1),
                    "old-b" to summary("old-b", 2),
                )
                val seeded = catalog(root)
                assertTrue(seeded.ensureAssignment("old-a"))
                assertTrue(seeded.ensureAssignment("old-b"))
                val staleCursor = seeded.readSummaryPage(null, 1, summaries::get).nextCursor
                assertEquals("0:0:1", staleCursor)
                assertTrue(seeded.removeAssignment("old-a"))
                summaries.remove("old-a")

                val interrupted = catalog(root, fault)
                assertFalse(interrupted.ensureAssignment("new-peer"), "fault=$fault")

                // Simulate process restart. Intent failure has no redo record,
                // while every later failure is completed from the durable one.
                var pageReads = 0
                val restarted = catalog(root, onPageRead = { pageReads += 1 })
                assertTrue(restarted.recoverPendingMaintenance(), "fault=$fault")
                assertTrue(restarted.ensureAssignment("new-peer"), "fault=$fault")
                summaries["new-peer"] = summary("new-peer", 3)

                pageReads = 0
                val resumed = restarted.readSummaryPage(staleCursor, 1, summaries::get)
                assertEquals(listOf("new-peer"), resumed.summaries.map { it.peerKey }, "fault=$fault")
                assertEquals(1, pageReads, "a direct cursor must read exactly one peer page; fault=$fault")
                assertEquals("1", root.resolve("pages/generation-v1").readText())
                assertFalse(root.resolve("pages/reuse-intent-v1").exists())
                val assignment = root.resolve("assignments/new-peer.page-ref")
                assertEquals(0, MessageCodec.decodeMeshSummaryAssignment(assignment.readText()))
            } finally {
                root.deleteRecursively()
            }
        }
    }

    @Test
    fun largePeerChurnReusesPagesAndKeepsRestartHydrationBounded() {
        val root = createTempDirectory("sonar-catalog-churn").toFile()
        try {
            val peerCount = MESH_SUMMARY_CATALOG_PAGE_SIZE * 2 + 51
            val expectedPages = 3
            val summaries = mutableMapOf<String, MeshDmSummary>()
            var store = catalog(root)

            repeat(6) { generation ->
                val peers = (0 until peerCount).map { "g$generation-peer-$it" }
                peers.forEachIndexed { index, peer ->
                    summaries[peer] = summary(peer, generation * peerCount.toLong() + index)
                    assertTrue(store.ensureAssignment(peer))
                }

                var pageReads = 0
                store = catalog(root, onPageRead = { pageReads += 1 }) // process restart
                val hydrated = mutableListOf<MeshDmSummary>()
                var cursor: String? = null
                do {
                    val page = store.readSummaryPage(cursor, MESH_SUMMARY_CATALOG_PAGE_SIZE, summaries::get)
                    hydrated += page.summaries
                    cursor = page.nextCursor
                } while (cursor != null)

                assertEquals(peerCount, hydrated.distinctBy { it.peerKey }.size)
                assertEquals(expectedPages, pageReads, "restart must read one bounded page per live high-water page")
                assertEquals(
                    expectedPages,
                    root.resolve("pages").listFiles().orEmpty().count {
                        it.isFile && it.name.matches(Regex("page-[0-9]{10}"))
                    },
                    "historical churn must not append more catalog pages",
                )
                assertEquals("2", root.resolve("pages/tail").readText())

                peers.forEach { peer ->
                    assertTrue(store.removeAssignment(peer))
                    summaries.remove(peer)
                }
                store = catalog(root) // another restart before the next generation
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun legacyEmptyTailCompactionPersistsBoundedProgressAcrossRestarts() {
        val root = createTempDirectory("sonar-catalog-legacy-bloat").toFile()
        try {
            val pages = root.resolve("pages").apply { mkdirs() }
            pages.resolve("tail").writeText("130")
            pages.resolve("page-0000000000").writeText(
                MessageCodec.encodeMeshSummaryPeerPage(listOf("live-peer")),
            )
            (1..130).forEach { pageNumber ->
                pages.resolve("page-${pageNumber.toString().padStart(10, '0')}").writeText(
                    MessageCodec.encodeMeshSummaryPeerPage(emptyList()),
                )
            }

            var pageReads = 0
            var store = catalog(root, onPageRead = { pageReads += 1 })
            assertTrue(store.compactTrailingEmptyPages())
            assertEquals(64, pageReads)
            assertEquals("66", pages.resolve("tail").readText())

            pageReads = 0
            store = catalog(root, onPageRead = { pageReads += 1 })
            assertTrue(store.compactTrailingEmptyPages())
            assertEquals(64, pageReads)
            assertEquals("2", pages.resolve("tail").readText())

            pageReads = 0
            store = catalog(root, onPageRead = { pageReads += 1 })
            assertTrue(store.compactTrailingEmptyPages())
            assertEquals(2, pageReads)
            assertEquals("0", pages.resolve("tail").readText())
            assertEquals(
                listOf("page-0000000000"),
                pages.listFiles().orEmpty().filter { it.name.startsWith("page-") }.map { it.name }.sorted(),
            )

            pageReads = 0
            val summary = summary("live-peer", 1)
            val hydrated = store.readSummaryPage(null, MESH_SUMMARY_CATALOG_PAGE_SIZE) { peer ->
                summary.takeIf { peer == it.peerKey }
            }
            assertEquals(listOf("live-peer"), hydrated.summaries.map { it.peerKey })
            assertEquals(1, pageReads)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun legacyTailCompactionRepairsEveryDurabilityStageAndRestartsStaleCursor() {
        listOf(
            CatalogFault.CompactionIntent,
            CatalogFault.CompactionTail,
            CatalogFault.Generation,
            CatalogFault.CompactionPageDelete,
            CatalogFault.CompactionIntentClear,
        ).forEach { fault ->
            val root = createTempDirectory("sonar-catalog-compact-${fault.name.lowercase()}").toFile()
            try {
                val pages = root.resolve("pages").apply { mkdirs() }
                pages.resolve("tail").writeText("4")
                pages.resolve("free-page-v1").writeText("sonar-mesh-summary-free-v1\n1\n4")
                pages.resolve("page-0000000000").writeText(
                    MessageCodec.encodeMeshSummaryPeerPage(listOf("live-peer")),
                )
                (1..4).forEach { pageNumber ->
                    pages.resolve("page-${pageNumber.toString().padStart(10, '0')}").writeText(
                        MessageCodec.encodeMeshSummaryPeerPage(emptyList()),
                    )
                }
                val summaries = mapOf("live-peer" to summary("live-peer", 1))
                val staleCursor = catalog(root).readSummaryPage(null, 1, summaries::get).nextCursor
                assertEquals("0:1:0", staleCursor)

                val interrupted = catalog(root, fault)
                assertFalse(interrupted.compactTrailingEmptyPages(maxPages = 4), "fault=$fault")

                var pageReads = 0
                val restarted = catalog(root, onPageRead = { pageReads += 1 })
                assertTrue(restarted.recoverPendingMaintenance(), "fault=$fault")
                assertTrue(restarted.compactTrailingEmptyPages(maxPages = 4), "fault=$fault")
                assertEquals("0", pages.resolve("tail").readText())
                assertEquals("1", pages.resolve("generation-v1").readText())
                assertFalse(pages.resolve("compact-intent-v1").exists())
                assertFalse(pages.resolve("free-page-v1").exists())
                assertEquals(1, pages.listFiles().orEmpty().count { it.name.startsWith("page-") })

                pageReads = 0
                val resumed = restarted.readSummaryPage(staleCursor, 1, summaries::get)
                assertEquals(listOf("live-peer"), resumed.summaries.map { it.peerKey }, "fault=$fault")
                assertEquals(1, pageReads, "fault=$fault")
            } finally {
                root.deleteRecursively()
            }
        }
    }

    @Test
    fun hugeLegacyTailKeepsForegroundAssignmentReadsStrictlyBoundedAcrossRestarts() {
        val root = createTempDirectory("sonar-catalog-huge-tail").toFile()
        try {
            val pages = root.resolve("pages").apply { mkdirs() }
            val tail = 511
            pages.resolve("tail").writeText(tail.toString())
            (0..tail).forEach { pageNumber ->
                pages.resolve("page-${pageNumber.toString().padStart(10, '0')}").writeText(
                    MessageCodec.encodeMeshSummaryPeerPage(listOf("legacy-$pageNumber")),
                )
            }

            var pageReads = 0
            var store = catalog(root, onPageRead = { pageReads += 1 })
            assertTrue(store.ensureAssignment("new-a"))
            assertEquals(5, pageReads, "one tail read plus four incremental scan pages")
            assertEquals(
                "sonar-mesh-summary-free-v1\n-1\n3",
                pages.resolve("free-page-v1").readText(),
            )

            pageReads = 0
            store = catalog(root, onPageRead = { pageReads += 1 })
            assertTrue(store.ensureAssignment("new-b"))
            assertEquals(5, pageReads)
            assertEquals(
                "sonar-mesh-summary-free-v1\n-1\n7",
                pages.resolve("free-page-v1").readText(),
            )
            assertEquals(tail.toString(), pages.resolve("tail").readText())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun foregroundScanReadFailurePersistsProgressWithoutCreatingRedoIntent() {
        val root = createTempDirectory("sonar-catalog-scan-fault").toFile()
        try {
            val pages = root.resolve("pages").apply { mkdirs() }
            pages.resolve("tail").writeText("10")
            (0..10).forEach { pageNumber ->
                pages.resolve("page-${pageNumber.toString().padStart(10, '0')}").writeText(
                    MessageCodec.encodeMeshSummaryPeerPage(listOf("legacy-$pageNumber")),
                )
            }

            val interrupted = catalog(root, failPageRead = { _, count -> count == 4 })
            assertFalse(interrupted.ensureAssignment("new-peer"))
            assertEquals(
                "sonar-mesh-summary-free-v1\n-1\n1",
                pages.resolve("free-page-v1").readText(),
            )
            assertFalse(pages.resolve("reuse-intent-v1").exists())

            var pageReads = 0
            val restarted = catalog(root, onPageRead = { pageReads += 1 })
            assertTrue(restarted.ensureAssignment("new-peer"))
            assertEquals(5, pageReads)
            assertEquals(
                "sonar-mesh-summary-free-v1\n-1\n5",
                pages.resolve("free-page-v1").readText(),
            )
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun reuseCompletionDoesNotPerformLatePageReadsThatCanPinItsRedoIntent() {
        val root = createTempDirectory("sonar-catalog-reuse-late-read").toFile()
        try {
            val pages = root.resolve("pages").apply { mkdirs() }
            pages.resolve("tail").writeText("0")
            pages.resolve("free-page-v1").writeText("sonar-mesh-summary-free-v1\n0\n-1")
            pages.resolve("page-0000000000").writeText(
                MessageCodec.encodeMeshSummaryPeerPage(listOf(null, "existing")),
            )

            var pageReads = 0
            val store = catalog(
                root,
                onPageRead = { pageReads += 1 },
                failPageRead = { _, count -> count >= 4 },
            )
            assertTrue(store.ensureAssignment("new-peer"))
            assertEquals(3, pageReads)
            assertFalse(pages.resolve("reuse-intent-v1").exists())
            assertEquals(
                0,
                MessageCodec.decodeMeshSummaryAssignment(
                    root.resolve("assignments/new-peer.page-ref").readText(),
                ),
            )
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun backgroundRepairResumesIncrementalScanAndPublishesFarTombstoneHint() {
        val root = createTempDirectory("sonar-catalog-background-scan").toFile()
        try {
            val pages = root.resolve("pages").apply { mkdirs() }
            pages.resolve("tail").writeText("20")
            (0..20).forEach { pageNumber ->
                val peers = if (pageNumber == 10) listOf<String?>(null) else listOf("legacy-$pageNumber")
                pages.resolve("page-${pageNumber.toString().padStart(10, '0')}").writeText(
                    MessageCodec.encodeMeshSummaryPeerPage(peers),
                )
            }

            assertTrue(catalog(root).advanceFreeHintScan(maxPages = 8))
            assertEquals(
                "sonar-mesh-summary-free-v1\n-1\n7",
                pages.resolve("free-page-v1").readText(),
            )

            assertTrue(catalog(root).advanceFreeHintScan(maxPages = 8))
            assertEquals(
                "sonar-mesh-summary-free-v1\n10\n9",
                pages.resolve("free-page-v1").readText(),
            )

            var pageReads = 0
            val restarted = catalog(root, onPageRead = { pageReads += 1 })
            assertTrue(restarted.ensureAssignment("new-peer"))
            assertEquals(3, pageReads)
            assertEquals("20", pages.resolve("tail").readText())
            assertFalse(pages.resolve("reuse-intent-v1").exists())
        } finally {
            root.deleteRecursively()
        }
    }
}
