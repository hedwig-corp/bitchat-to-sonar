package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TranscriptDisplayPolicyTest {
    private fun message(id: String, ts: Long, content: String = id) = SonarMsg(
        id = id,
        senderNpub = "npub",
        content = content,
        mine = false,
        tsSecs = ts,
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
}
