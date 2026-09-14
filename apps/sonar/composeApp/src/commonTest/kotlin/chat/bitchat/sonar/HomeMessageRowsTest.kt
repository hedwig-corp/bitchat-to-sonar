package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HomeMessageRowsTest {

    @Test
    fun unlockedAccountWaitsForCoherentLocalHomeBeforeFirstPaint() {
        assertFalse(isFirstLocalStateReady(onboarded = true, locked = false, homeMessagesHydrated = false))
        assertTrue(isFirstLocalStateReady(onboarded = true, locked = false, homeMessagesHydrated = true))
        assertTrue(isFirstLocalStateReady(onboarded = true, locked = true, homeMessagesHydrated = false))
        assertTrue(isFirstLocalStateReady(onboarded = false, locked = false, homeMessagesHydrated = false))
    }

    private fun mesh(peerId: String, ts: Long) =
        MeshDmRow(peerId = peerId, name = peerId, preview = "m", tsSecs = ts)

    private fun chat(id: String) =
        SonarChat(id = id, name = id, members = emptyList())

    @Test
    fun mergesMeshAndMarmotByRecencyDescending() {
        val meshRows = listOf(mesh("ble-old", 100), mesh("ble-new", 300))
        val chatRows = listOf(chat("g-mid"), chat("g-newest"))
        val ts = mapOf("g-mid" to 200L, "g-newest" to 400L)

        val merged = mergeHomeMessageRows(meshRows, chatRows) { ts[it] ?: 0L }

        assertEquals(
            listOf("g-newest", "mesh:ble-new", "g-mid", "mesh:ble-old"),
            merged.map { it.listKey },
        )
    }

    @Test
    fun pendingCreationTimeSortsAboveOlderHistory() {
        // Freshly-started pending chat (createdAt=500) must not sink under a
        // mesh conversation from last week (ts=100) — iOS dmRows parity.
        val meshRows = listOf(mesh("old-ble", 100))
        val chatRows = listOf(chat("npub:pending"))
        val ts = mapOf("npub:pending" to 500L)

        val merged = mergeHomeMessageRows(meshRows, chatRows) { ts[it] ?: 0L }

        assertEquals("npub:pending", merged.first().listKey)
        assertIs<HomeMessageRow.Marmot>(merged.first())
    }

    @Test
    fun zeroTsWithoutCreationTimeSortsLast() {
        val meshRows = listOf(mesh("active", 50))
        val chatRows = listOf(chat("empty"))
        val merged = mergeHomeMessageRows(meshRows, chatRows) { 0L }
        assertEquals("mesh:active", merged.first().listKey)
        assertEquals("empty", merged.last().listKey)
    }

    @Test
    fun listKeysAreNamespacedPerTransport() {
        val merged = mergeHomeMessageRows(
            listOf(mesh("abc", 1)),
            listOf(chat("group-1")),
        ) { 1L }
        assertTrue(merged.any { it.listKey == "mesh:abc" })
        assertTrue(merged.any { it.listKey == "group-1" })
    }

    @Test
    fun localHydrationUsesPreviousPaintOrderAsRecencyTieBreaker() {
        val chats = listOf(chat("same-old"), chat("newest"), chat("same-new"), chat("new-row"))
        val timestamps = mapOf(
            "newest" to 300L,
            "same-old" to 200L,
            "same-new" to 200L,
            "new-row" to 0L,
        )

        val ordered = orderChatsByLocalRecency(
            chats = chats,
            latestSecs = { timestamps[it] ?: 0L },
            previousOrder = listOf("newest", "same-new", "same-old"),
        )

        assertEquals(
            listOf("newest", "same-new", "same-old", "new-row"),
            ordered.map { it.id },
        )
    }

    @Test
    fun restoredMetadataKeepsMixedTransportRowsInRecencyOrder() {
        val newest = chat("marmot-new")
        val oldest = chat("marmot-old")
        val blob = encodeChatSnapshot(
            chats = listOf(newest, oldest),
            messagesByChat = emptyMap(),
            latestByChat = mapOf(newest.id to 300L, oldest.id to 100L),
        )
        val restoredChats = decodeChatSnapshot(blob).first
        val restoredLatest = decodeChatSnapshotLatest(blob)

        val merged = mergeHomeMessageRows(
            meshRows = listOf(mesh("mesh-middle", 200L)),
            chatRows = restoredChats,
            marmotTsSecs = { restoredLatest[it] ?: 0L },
        )

        assertEquals(
            listOf("marmot-new", "mesh:mesh-middle", "marmot-old"),
            merged.map { it.listKey },
        )
    }

    @Test
    fun conversationIndexHydratesRowsOutsideBoundedTranscriptWindow() {
        val summaries = listOf(
            SonarConversationSummary("paged", "", "summary paged", "peer", 400L, false, 2L, 0L),
            SonarConversationSummary("outside", "", "outside preview", "peer", 300L, false, 1L, 0L),
        )
        val pageMessage = SonarMsg("page-msg", "peer", "page preview", false, 400L, viaInternet = true)

        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("paged", "outside"),
            existingMessagesByChat = emptyMap(),
            existingLatestByChat = emptyMap(),
            summaries = summaries,
            pages = listOf(SonarRecentTranscriptPage("paged", 400L, listOf(pageMessage))),
        )

        assertEquals(300L, hydration.latestByChat["outside"])
        assertEquals("outside preview", hydration.messagesByChat["outside"]?.single()?.content)
        assertEquals(listOf(pageMessage), hydration.messagesByChat["paged"])
    }

    @Test
    fun sameSecondSummaryRefreshesWhenLatestContentChanges() {
        val old = SonarMsg("summary:chat:42:1", "peer", "old", false, 42L, viaInternet = true)
        val summary = SonarConversationSummary("chat", "", "new", "peer", 42L, false, 2L, 0L)

        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("chat"),
            existingMessagesByChat = mapOf("chat" to listOf(old)),
            existingLatestByChat = mapOf("chat" to 42L),
            summaries = listOf(summary),
            pages = emptyList(),
        )

        assertEquals("new", hydration.messagesByChat["chat"]?.single()?.content)
        assertEquals("summary:chat:42:2", hydration.messagesByChat["chat"]?.single()?.id)
    }

    @Test
    fun sameSecondSummaryRefreshesSyntheticIdentityWhenCountChanges() {
        val old = SonarMsg("summary:chat:42:1", "peer", "same", false, 42L, viaInternet = true)
        val summary = SonarConversationSummary("chat", "", "same", "peer", 42L, false, 2L, 0L)

        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("chat"),
            existingMessagesByChat = mapOf("chat" to listOf(old)),
            existingLatestByChat = mapOf("chat" to 42L),
            summaries = listOf(summary),
            pages = emptyList(),
        )

        assertEquals("summary:chat:42:2", hydration.messagesByChat["chat"]?.single()?.id)
    }

    @Test
    fun hydratedPagesUseTranscriptDisplayOrderForEqualSecondRows() {
        // The chat-open snapshot paint and the async bounded DB page must agree
        // on (tsSecs, id) ordering, otherwise equal-second messages visibly
        // swap right after the transcript opens (order flicker regression).
        val later = SonarMsg("zz-fire", "peer", "🔥", true, 42L, viaInternet = true)
        val earlier = SonarMsg("aa-yoyo", "peer", "Yo yo!", true, 42L, viaInternet = true)

        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("chat"),
            existingMessagesByChat = emptyMap(),
            existingLatestByChat = emptyMap(),
            summaries = emptyList(),
            pages = listOf(SonarRecentTranscriptPage("chat", 42L, listOf(later, earlier))),
        )

        assertEquals(
            listOf("aa-yoyo", "zz-fire"),
            hydration.messagesByChat["chat"]?.map { it.id },
        )
    }

    @Test
    fun syntheticSummaryRowsAreStrippedBeforeSeedingATranscript() {
        // A synthetic chat-list placeholder carries no event id, so it can never
        // dedupe against the real row a bounded page later brings — seeding one
        // into a transcript renders a duplicate bubble forever. Only chats
        // inside LOCAL_SUMMARY_CHAT_LIMIT get real rows, so any chat below it
        // would hit this.
        val summary = SonarConversationSummary("chat", "", "hello", "peer", 42L, true, 7L, 0L)
        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("chat"),
            existingMessagesByChat = emptyMap(),
            existingLatestByChat = emptyMap(),
            summaries = listOf(summary),
            pages = emptyList(),
        )
        val cached = hydration.messagesByChat.getValue("chat")

        assertEquals(1, cached.size)
        assertTrue(cached.single().id.startsWith(SYNTHETIC_SUMMARY_ID_PREFIX))
        assertTrue(cached.withoutSyntheticSummaryRows().isEmpty())
    }

    @Test
    fun realPageRowsSurviveSyntheticStripping() {
        val real = SonarMsg("event-1", "peer", "hello", false, 42L, viaInternet = true)
        assertEquals(listOf(real), listOf(real).withoutSyntheticSummaryRows())
    }

    @Test
    fun matchingRealPageRowIsNotReplacedBySyntheticSummary() {
        val pageRow = SonarMsg("real-message", "peer", "same", false, 42L, viaInternet = true)
        val summary = SonarConversationSummary("chat", "", "same", "peer", 42L, false, 3L, 0L)

        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("chat"),
            existingMessagesByChat = mapOf("chat" to listOf(pageRow)),
            existingLatestByChat = mapOf("chat" to 42L),
            summaries = listOf(summary),
            pages = emptyList(),
        )

        assertEquals(listOf(pageRow), hydration.messagesByChat["chat"])
    }

    @Test
    fun foldedHistoricalSummaryHydratesOntoLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("group-09"),
            existingMessagesByChat = emptyMap(),
            existingLatestByChat = emptyMap(),
            summaries = listOf(
                SonarConversationSummary("group-08", "", "keep this chat", "peer", 100L, false, 3L, 3L),
            ),
            pages = emptyList(),
            historicalFolds = folds,
        )
        assertEquals("keep this chat", hydration.messagesByChat["group-09"]?.single()?.content)
        assertEquals(100L, hydration.latestByChat["group-09"])
        assertTrue(hydration.messagesByChat["group-08"].isNullOrEmpty())
        assertEquals(
            "group-09",
            hydrationTargetId("group-08", setOf("group-09"), folds),
        )
        assertEquals(
            "group-09",
            hydrationTargetId("group-09", setOf("group-09"), folds),
        )
        assertNull(hydrationTargetId("group-08", setOf("group-09"), emptyMap()))
    }

    @Test
    fun foldedHistoricalPageHydratesOntoLiveSibling() {
        val folds = mapOf("group-08" to "group-09")
        val histRow = SonarMsg("hist-msg", "peer", "recovered page", false, 80L, viaInternet = true)
        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("group-09"),
            existingMessagesByChat = emptyMap(),
            existingLatestByChat = emptyMap(),
            summaries = emptyList(),
            pages = listOf(SonarRecentTranscriptPage("group-08", 80L, listOf(histRow))),
            historicalFolds = folds,
        )
        assertEquals(listOf(histRow), hydration.messagesByChat["group-09"])
        assertEquals(80L, hydration.latestByChat["group-09"])
        assertTrue(hydration.messagesByChat["group-08"].isNullOrEmpty())
    }

    @Test
    fun remountedExtractSurvivesNewerSummaryOutsidePageWindow() {
        // Persist-folds remount newest-first leftover extract onto live.
        // last() is then the oldest row; a newer live summary must not wipe
        // the extract (chats outside the home page window never get it back).
        val folds = mapOf("group-08" to "group-09")
        val newestFirstExtract = (80 downTo 1).map { n ->
            SonarMsg("hist-$n", "peer", "row $n", false, n.toLong(), viaInternet = true)
        }
        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("group-09"),
            existingMessagesByChat = mapOf("group-08" to newestFirstExtract),
            existingLatestByChat = mapOf("group-08" to 80L),
            summaries = listOf(
                SonarConversationSummary("group-09", "", "just resumed", "me", 200L, true, 1L, 0L),
            ),
            pages = emptyList(),
            historicalFolds = folds,
        )
        val kept = hydration.messagesByChat["group-09"].orEmpty()
        assertEquals(80, kept.size)
        assertTrue(hydrationHasRealTranscriptRows(kept))
        assertEquals(newestFirstExtract.map { it.id }.toSet(), kept.map { it.id }.toSet())
        assertEquals(200L, hydration.latestByChat["group-09"])
        assertTrue(kept.none { it.id.startsWith(SYNTHETIC_SUMMARY_ID_PREFIX) })
        assertTrue(hydration.messagesByChat["group-08"].isNullOrEmpty())
    }

    @Test
    fun remountedExtractMergesNewerLivePageInsteadOfReplacing() {
        val folds = mapOf("group-08" to "group-09")
        val histRows = (1..80).map { n ->
            SonarMsg("hist-$n", "peer", "row $n", false, n.toLong(), viaInternet = true)
        }
        val liveRow = SonarMsg("live-1", "me", "resumed", true, 200L, viaInternet = true)
        val hydration = hydrateLocalConversationRows(
            activeChatIds = setOf("group-09"),
            existingMessagesByChat = mapOf("group-08" to histRows),
            existingLatestByChat = mapOf("group-08" to 80L),
            summaries = listOf(
                SonarConversationSummary("group-09", "", "resumed", "me", 200L, true, 1L, 0L),
            ),
            pages = listOf(
                SonarRecentTranscriptPage("group-09", 200L, listOf(liveRow)),
                SonarRecentTranscriptPage("group-08", 80L, histRows.takeLast(20)),
            ),
            historicalFolds = folds,
        )
        val kept = hydration.messagesByChat.getValue("group-09")
        assertTrue(kept.map { it.id }.containsAll(histRows.map { it.id }))
        assertTrue(kept.any { it.id == "live-1" })
        assertEquals(200L, hydration.latestByChat["group-09"])
        assertEquals(
            listOf("hist-1", "live-1"),
            hydrateMergedPageRows(
                existing = listOf(histRows.first()),
                incoming = listOf(liveRow),
            ).map { it.id },
        )
    }
}
