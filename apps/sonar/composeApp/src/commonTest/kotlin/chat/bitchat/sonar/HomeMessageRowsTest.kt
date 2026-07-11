package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class HomeMessageRowsTest {

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
}
