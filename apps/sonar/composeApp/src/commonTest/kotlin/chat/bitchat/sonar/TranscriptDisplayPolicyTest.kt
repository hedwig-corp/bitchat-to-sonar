package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TranscriptDisplayPolicyTest {
    private fun message(
        id: String,
        ts: Long,
        content: String = id,
        mine: Boolean = false,
        viaInternet: Boolean = false,
        state: String? = null,
    ) = SonarMsg(
        id = id,
        senderNpub = "npub",
        content = content,
        mine = mine,
        tsSecs = ts,
        viaInternet = viaInternet,
        state = state,
    )

    @Test
    fun previewLeavesShortSourceUnchanged() {
        val source = "hello\nworld"
        val preview = transcriptPreview(source)
        assertEquals(source, preview.text)
        assertFalse(preview.truncated)
    }

    @Test
    fun previewStopsAt512CommonCombiningClusters() {
        val cluster = "e\u0301"
        val source = cluster.repeat(512) + "tail"
        val preview = transcriptPreview(source)
        assertEquals(cluster.repeat(512) + "…", preview.text)
        assertTrue(preview.truncated)
        assertEquals(source, transcriptDisplayText(source, expanded = true))
    }

    @Test
    fun previewTreatsJoinedEmojiAsOneGrapheme() {
        val family = "👩‍👩‍👧‍👦"
        val preview = transcriptPreview(family.repeat(513))
        assertEquals(family.repeat(512) + "…", preview.text)
        assertTrue(preview.truncated)
    }

    @Test
    fun previewKeepsAtMost15NewlinesAndDoesNotSplitCrlf() {
        val source = (1..17).joinToString("\r\n") { "line$it" }
        val preview = transcriptPreview(source)
        assertEquals(15, preview.text.count { it == '\n' })
        assertFalse(preview.text.endsWith('\r'))
        assertTrue(preview.truncated)
    }

    @Test
    fun previewBacksOutOfCutUrl() {
        val prefix = "x".repeat(500) + " "
        val source = prefix + "https://example.com/very/long/path"
        val preview = transcriptPreview(source)
        assertEquals("x".repeat(500) + "…", preview.text)
        assertTrue(preview.truncated)
    }

    @Test
    fun mergeDedupesUpdatesAndUsesStableTimestampIdOrder() {
        val merged = mergeTranscriptRows(
            existing = listOf(message("b", 10, "old"), message("z", 20)),
            incoming = listOf(message("a", 10), message("b", 10, "updated")),
        )
        assertEquals(listOf("a", "b", "z"), merged.map { it.id })
        assertEquals("updated", merged[1].content)
    }

    @Test
    fun mergeCapsAtNewest500Rows() {
        val merged = mergeTranscriptRows(
            existing = emptyList(),
            incoming = (0 until 520).map { message(it.toString().padStart(3, '0'), it.toLong()) },
        )
        assertEquals(500, merged.size)
        assertEquals(20L, merged.first().tsSecs)
        assertEquals(519L, merged.last().tsSecs)
    }

    @Test
    fun prependAtCapacityMovesWindowTowardOlderRows() {
        val existing = (100 until 600).map { message(it.toString(), it.toLong()) }
        val older = (70 until 100).map { message(it.toString(), it.toLong()) }

        val merged = prependTranscriptRows(existing, older)

        assertEquals(500, merged.size)
        assertEquals(70L, merged.first().tsSecs)
        assertEquals(569L, merged.last().tsSecs)
    }

    @Test
    fun olderFoldedSourceAdvancesFullHistoricalWindow() {
        val olderSource = (0 until 500).map { message("internet-$it", it.toLong()) }
        val visibleNewerSource = (500 until 1000).map { message("mesh-$it", it.toLong()) }

        val page = nearestOlderTranscriptPage(
            olderSource + visibleNewerSource,
            visibleNewerSource.first(),
        )
        val moved = prependTranscriptRows(visibleNewerSource, page)

        assertEquals("internet-470", page.first().id)
        assertEquals("internet-499", page.last().id)
        assertEquals("internet-470", moved.first().id)
        assertEquals("mesh-969", moved.last().id)
        assertEquals(TRANSCRIPT_RETAINED_ROWS, moved.size)
    }

    @Test
    fun foldedSourcesAdvanceOnlyTheIncompleteGlobalFrontier() {
        val farOlder = (970 until 1000).map { message("internet-$it", it.toLong()) }
        val visibleNewer = (1970 until 2000).map { message("mesh-$it", it.toLong()) }
        val oldestVisible = visibleNewer.first()

        val initialNeeds = transcriptSourceIdsNeedingExpansion(
            listOf(
                TranscriptSourceWindow("internet", farOlder, hasMore = true),
                TranscriptSourceWindow(MESH_TRANSCRIPT_SOURCE_ID, visibleNewer, hasMore = true),
            ),
            oldestVisible,
        )
        assertEquals(setOf(MESH_TRANSCRIPT_SOURCE_ID), initialNeeds)

        val expandedNewer = (1940 until 2000).map { message("mesh-$it", it.toLong()) }
        val readyNeeds = transcriptSourceIdsNeedingExpansion(
            listOf(
                TranscriptSourceWindow("internet", farOlder, hasMore = true),
                TranscriptSourceWindow(MESH_TRANSCRIPT_SOURCE_ID, expandedNewer, hasMore = true),
            ),
            oldestVisible,
        )
        val page = nearestOlderTranscriptPage(farOlder + expandedNewer, oldestVisible)

        assertTrue(readyNeeds.isEmpty())
        assertEquals("mesh-1940", page.first().id)
        assertEquals("mesh-1969", page.last().id)
    }

    @Test
    fun partialFinalPageLeavesRoomForLiveRows() {
        val existing = (15 until 485).map { message(it.toString(), it.toLong()) }
        val partialOlder = (0 until 15).map { message(it.toString(), it.toLong()) }
        val historical = prependTranscriptRows(existing, partialOlder)

        assertEquals(485, historical.size)
        assertFalse(shouldPinOlderTranscriptEdge(historical.size))

        val refreshed = refreshTranscriptRows(
            existing = historical,
            newest = listOf(message("live", 485)),
            pinnedToOlderEdge = shouldPinOlderTranscriptEdge(historical.size),
        )
        assertEquals("live", refreshed.last().id)
        assertEquals(486, refreshed.size)
    }

    @Test
    fun liveRefreshDoesNotEvictOlderWindowAnchor() {
        val existing = (70 until 570).map { message(it.toString(), it.toLong()) }
        val refreshed = refreshTranscriptRows(
            existing = existing,
            newest = listOf(message("569", 569, "updated"), message("600", 600)),
            pinnedToOlderEdge = true,
        )

        assertEquals(70L, refreshed.first().tsSecs)
        assertEquals(569L, refreshed.last().tsSecs)
        assertEquals("updated", refreshed.last().content)
        assertFalse(refreshed.any { it.id == "600" })
    }

    @Test
    fun foldedSourcesShareOneInitialThirtyRowBudget() {
        val sourceA = (0 until 30).map { message("a$it", (it * 2).toLong()) }
        val sourceB = (0 until 30).map { message("b$it", (it * 2 + 1).toLong()) }

        val visible = boundedTranscriptRows(
            source = mergeAllTranscriptRows(sourceA + sourceB),
            visibleRows = TRANSCRIPT_PAGE_SIZE,
            pinnedToOlderEdge = false,
        )

        assertEquals(30, visible.size)
        assertEquals(30L, visible.first().tsSecs)
        assertEquals(59L, visible.last().tsSecs)
    }

    @Test
    fun conversationBudgetMovesAsOneWindowWhenPinned() {
        val allSources = (0 until 530).map { message(it.toString(), it.toLong()) }

        val visible = boundedTranscriptRows(
            source = allSources,
            visibleRows = TRANSCRIPT_RETAINED_ROWS,
            pinnedToOlderEdge = true,
        )

        assertEquals(500, visible.size)
        assertEquals(0L, visible.first().tsSecs)
        assertEquals(499L, visible.last().tsSecs)
    }

    @Test
    fun foldedOlderPagesAdvanceByThirtyGloballyNotPerSource() {
        val oldestVisible = message("visible", 100)
        val sourceA = (40 until 100 step 2).map { message("a$it", it.toLong()) }
        val sourceB = (41 until 100 step 2).map { message("b$it", it.toLong()) }

        val page = nearestOlderTranscriptPage(sourceA + sourceB, oldestVisible)

        assertEquals(30, page.size)
        assertEquals(70L, page.first().tsSecs)
        assertEquals(99L, page.last().tsSecs)
    }

    @Test
    fun loadedFoldedRowsCanExpandWithoutAnotherSourceFetch() {
        val loaded = (0 until 60).map { message(it.toString(), it.toLong()) }
        val current = boundedTranscriptRows(loaded, TRANSCRIPT_PAGE_SIZE, pinnedToOlderEdge = false)
        val older = nearestOlderTranscriptPage(loaded, current.first())

        val expanded = prependTranscriptRows(current, older, retainedRows = 60)

        assertEquals(60, expanded.size)
        assertEquals(0L, expanded.first().tsSecs)
        assertEquals(59L, expanded.last().tsSecs)
    }

    @Test
    fun newestEdgeResetReturnsOneGlobalTailPage() {
        val allSources = (0 until 530).map { message(it.toString(), it.toLong()) }

        val newest = boundedTranscriptRows(
            source = allSources,
            visibleRows = TRANSCRIPT_PAGE_SIZE,
            pinnedToOlderEdge = false,
        )

        assertEquals(30, newest.size)
        assertEquals(500L, newest.first().tsSecs)
        assertEquals(529L, newest.last().tsSecs)
    }

    @Test
    fun lookaheadIsNotRetainedAndSameSecondOrderIsDeterministic() {
        val fetched = (0..30).map { message(it.toString().padStart(2, '0'), 42) }.reversed()
        val visible = visibleTranscriptPage(fetched)
        assertEquals(30, visible.size)
        assertEquals("01", visible.first().id)
        assertEquals("30", visible.last().id)
        assertFalse(visible.any { it.id == "00" })
    }

    @Test
    fun sameSecondCanonicalRowFulfillsOptimisticEcho() {
        val echo = message("echo-1", 100, "hello", mine = true, viaInternet = true, state = "Sending")
        val canonical = message("event-1", 100, "hello", mine = true, viaInternet = true)

        assertEquals(setOf("echo-1"), fulfilledSendEchoIds(listOf(echo), listOf(canonical)))
    }

    @Test
    fun delayedCanonicalRowStillFulfillsFirstChatEcho() {
        val echo = message("echo-1", 100, "hello", mine = true, viaInternet = true, state = "Sending")
        val canonical = message("event-1", 180, "hello", mine = true, viaInternet = true)

        assertEquals(setOf("echo-1"), fulfilledSendEchoIds(listOf(echo), listOf(canonical)))
    }

    @Test
    fun priorIdenticalRowWithinFormerSlackDoesNotConsumeNewEcho() {
        val echo = message("echo-1", 100, "hello", mine = true, viaInternet = true, state = "Sending")
        val older = message("event-old", 99, "hello", mine = true, viaInternet = true)

        assertTrue(fulfilledSendEchoIds(listOf(echo), listOf(older)).isEmpty())
    }

    @Test
    fun priorSameSecondIdenticalRowDoesNotConsumeNewEcho() {
        val echo = message("echo-1", 100, "hello", mine = true, viaInternet = true, state = "Sending")
        val earlier = message("event-earlier", 100, "hello", mine = true, viaInternet = true)

        assertTrue(
            fulfilledSendEchoIds(
                echoes = listOf(echo),
                published = listOf(earlier),
                excludedPublishedIdsByEcho = mapOf(echo.id to setOf(earlier.id)),
            ).isEmpty(),
        )
    }

    @Test
    fun newestIdenticalEchoTakesCanonicalRowBeforeStaleEcho() {
        val echoes = listOf(
            message("echo-1", 100, "hello", mine = true, viaInternet = true, state = "Sending"),
            message("echo-2", 101, "hello", mine = true, viaInternet = true, state = "Sending"),
        )
        val canonical = listOf(message("event-1", 101, "hello", mine = true, viaInternet = true))

        assertEquals(setOf("echo-2"), fulfilledSendEchoIds(echoes, canonical))
    }

    @Test
    fun clearedNewerEchoReservesItsCanonicalRowForOlderPendingDuplicate() {
        val older = message("echo-1", 100, "hello", mine = true, viaInternet = true, state = "Sending")
        val newer = message("echo-2", 101, "hello", mine = true, viaInternet = true, state = "Sending")
        val canonical = message("event-2", 101, "hello", mine = true, viaInternet = true)

        val succeededCanonicalIds = eligibleCanonicalRowsForSendEcho(newer, listOf(canonical))
            .map { it.id }
            .toSet()

        assertEquals(setOf(canonical.id), succeededCanonicalIds)
        assertTrue(
            fulfilledSendEchoIds(
                echoes = listOf(older),
                published = listOf(canonical),
                excludedPublishedIdsByEcho = mapOf(older.id to succeededCanonicalIds),
            ).isEmpty(),
        )
    }
}
