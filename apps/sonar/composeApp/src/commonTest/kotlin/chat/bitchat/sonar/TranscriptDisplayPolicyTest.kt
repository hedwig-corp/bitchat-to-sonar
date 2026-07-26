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
    fun sameTranscriptPaint_identicalHydrationPage_isNoOp() {
        val page = listOf(message("a", 1), message("b", 2, content = "hi"))
        assertTrue(sameTranscriptPaint(page, page.map { it.copy() }))
        assertTrue(
            sameTranscriptPaint(page, listOf(message("a", 1), message("b", 2, content = "hi"))),
            "open hydration must not rebuild LazyColumn when the bounded page is unchanged",
        )
    }

    @Test
    fun sameTranscriptPaint_detectsPaintRelevantChanges() {
        val base = listOf(message("a", 1), message("b", 2))
        assertFalse(sameTranscriptPaint(base, listOf(message("a", 1))))
        assertFalse(sameTranscriptPaint(base, listOf(message("a", 1), message("c", 2))))
        assertFalse(sameTranscriptPaint(base, listOf(message("a", 1), message("b", 2, content = "changed"))))
        assertFalse(sameTranscriptPaint(base, listOf(message("a", 1), message("b", 2, state = "Accepted"))))
        val withMedia = listOf(
            message("a", 1).copy(
                media = listOf(SonarMedia("https://m/1", "image/jpeg", "a.jpg", 10, 10, null)),
            ),
        )
        val otherMedia = listOf(
            message("a", 1).copy(
                media = listOf(SonarMedia("https://m/2", "image/jpeg", "a.jpg", 10, 10, null)),
            ),
        )
        assertFalse(sameTranscriptPaint(withMedia, otherMedia))
        val sameUrlNewDims = listOf(
            message("a", 1).copy(
                media = listOf(SonarMedia("https://m/1", "image/jpeg", "a.jpg", 1200, 900, null)),
            ),
        )
        assertFalse(
            sameTranscriptPaint(withMedia, sameUrlNewDims),
            "MIP-04 dim arrival must republish — reserved bubble geometry changed",
        )
        val sameUrlNewMime = listOf(
            message("a", 1).copy(
                media = listOf(SonarMedia("https://m/1", "image/gif", "a.gif", 10, 10, null)),
            ),
        )
        assertFalse(sameTranscriptPaint(withMedia, sameUrlNewMime))
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

        val filled = refreshTranscriptRows(
            existing = refreshed,
            newest = (486 until 500).map { message("live-$it", it.toLong()) },
            pinnedToOlderEdge = false,
        )
        assertEquals(500, filled.size)
        assertTrue(shouldPinOlderTranscriptEdge(filled.size))
    }

    @Test
    fun batchedLiveRowsCannotEvictAnchorWhileCrossingRetainedBudget() {
        val historical = (0 until 499).map { message("internet-$it", it.toLong()) }
        val firstLive = message("mesh-499", 499)
        val excessLive = message("mesh-500", 500)

        val filled = refreshTranscriptRows(
            existing = historical,
            newest = historical + firstLive + excessLive,
            pinnedToOlderEdge = false,
            retainedRows = 500,
            pinOlderEdgeAtCapacity = true,
        )

        assertEquals(500, filled.size)
        assertEquals("internet-0", filled.first().id)
        assertEquals(firstLive.id, filled.last().id)
        assertFalse(filled.any { it.id == excessLive.id })
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

    @Test
    fun terminalAcceptedEchoStaysVisibleUntilCanonicalRowExists() {
        val echo = message("echo-1", 100, "hello", mine = true, viaInternet = true, state = "Accepted")

        val plan = planSendEchoDisplay(
            echoes = listOf(echo),
            published = emptyList(),
            excludedPublishedIdsByEcho = emptyMap(),
            freshCanonical = emptyList(),
        )

        assertEquals(listOf(echo), plan.visibleEchoes)
        assertTrue(plan.terminalAcceptedEchoIds.isEmpty())
    }

    @Test
    fun delayedCanonicalRowFulfillsTerminalAcceptedEchoAndPermitsCleanup() {
        val echo = message("echo-1", 100, "hello", mine = true, viaInternet = true, state = "Accepted")
        val canonical = message("event-1", 180, "hello", mine = true, viaInternet = true)

        val plan = planSendEchoDisplay(
            echoes = listOf(echo),
            published = listOf(canonical),
            excludedPublishedIdsByEcho = emptyMap(),
            freshCanonical = emptyList(),
        )

        assertTrue(plan.visibleEchoes.isEmpty())
        assertEquals(setOf(echo.id), plan.terminalAcceptedEchoIds)
    }

    @Test
    fun reservedCanonicalRowDoesNotCleanUpOlderTerminalAcceptedDuplicate() {
        val older = message("echo-1", 100, "hello", mine = true, viaInternet = true, state = "Accepted")
        val canonicalForNewerSend = message("event-2", 101, "hello", mine = true, viaInternet = true)

        val plan = planSendEchoDisplay(
            echoes = listOf(older),
            published = listOf(canonicalForNewerSend),
            excludedPublishedIdsByEcho = mapOf(older.id to setOf(canonicalForNewerSend.id)),
            freshCanonical = emptyList(),
        )

        assertEquals(listOf(older), plan.visibleEchoes)
        assertTrue(plan.terminalAcceptedEchoIds.isEmpty())
    }

    @Test
    fun fulfilledSendingEchoIsHiddenButKeptPendingUntilExactOutcome() {
        val echo = message("echo-1", 100, "hello", mine = true, viaInternet = true, state = "Sending")
        val canonical = message("event-1", 100, "hello", mine = true, viaInternet = true)

        val plan = planSendEchoDisplay(
            echoes = listOf(echo),
            published = listOf(canonical),
            excludedPublishedIdsByEcho = emptyMap(),
            freshCanonical = emptyList(),
        )

        assertTrue(plan.visibleEchoes.isEmpty())
        assertTrue(plan.terminalAcceptedEchoIds.isEmpty())
    }

    @Test
    fun failedEchoStaysVisibleEvenWhenMatchingCanonicalRowExists() {
        val echo = message("echo-1", 100, "hello", mine = true, viaInternet = true, state = "Couldn't send")
        val canonical = message("event-1", 100, "hello", mine = true, viaInternet = true)

        val plan = planSendEchoDisplay(
            echoes = listOf(echo),
            published = listOf(canonical),
            excludedPublishedIdsByEcho = emptyMap(),
            freshCanonical = emptyList(),
        )

        assertEquals(listOf(echo), plan.visibleEchoes)
        assertTrue(plan.terminalAcceptedEchoIds.isEmpty())
    }

    @Test
    fun onlyNonFailedEchoesAwaitCanonicalReservation() {
        val echo = message("echo-1", 100, "hello", mine = true, viaInternet = true)

        assertTrue(sendEchoAwaitsCanonicalRow(echo.copy(state = "Sending")))
        assertTrue(sendEchoAwaitsCanonicalRow(echo.copy(state = "Accepted")))
        assertFalse(sendEchoAwaitsCanonicalRow(echo.copy(state = "Couldn't send")))
    }

    // ── Out-of-window canonical rows (the duplicate-bubble regression) ──
    // A pinned/full render window admits no new rows, so the canonical copy of
    // an outgoing send never reaches the matcher via `published` alone. Before
    // freshCanonical the echo stayed "Sending" forever beside the real row.

    @Test
    fun outOfWindowCanonicalRowFulfillsEchoAndIsAdmitted() {
        val echo = message("echo-1", 100, "ciao", mine = true, viaInternet = true, state = "Sending")
        val canonical = message("event-1", 100, "ciao", mine = true, viaInternet = true)

        val result = reconcileSendEchoes(
            echoes = listOf(echo),
            published = emptyList(),
            freshCanonical = listOf(canonical),
        )

        assertEquals(setOf("echo-1"), result.fulfilledEchoIds)
        assertEquals(listOf(canonical), result.admittedCanonical)
    }

    @Test
    fun windowedCanonicalRowIsNotAdmittedTwice() {
        val echo = message("echo-1", 100, "ciao", mine = true, viaInternet = true, state = "Sending")
        val canonical = message("event-1", 100, "ciao", mine = true, viaInternet = true)

        val result = reconcileSendEchoes(
            echoes = listOf(echo),
            published = listOf(canonical),
            freshCanonical = listOf(canonical),
        )

        assertEquals(setOf("echo-1"), result.fulfilledEchoIds)
        assertTrue(result.admittedCanonical.isEmpty())
    }

    @Test
    fun echoWithoutAnyCanonicalRowStaysVisible() {
        val echo = message("echo-1", 100, "ciao", mine = true, viaInternet = true, state = "Sending")

        val result = reconcileSendEchoes(
            echoes = listOf(echo),
            published = emptyList(),
            freshCanonical = emptyList(),
        )

        assertTrue(result.fulfilledEchoIds.isEmpty())
        assertTrue(result.admittedCanonical.isEmpty())
    }

    @Test
    fun freshEchoRowsAreNeverTreatedAsCanonical() {
        val echo = message("echo-1", 100, "ciao", mine = true, viaInternet = true, state = "Sending")
        val staleEcho = message("echo-0", 100, "ciao", mine = true, viaInternet = true, state = "Sending")

        val result = reconcileSendEchoes(
            echoes = listOf(echo),
            published = emptyList(),
            freshCanonical = listOf(staleEcho),
        )

        assertTrue(result.fulfilledEchoIds.isEmpty())
    }

    @Test
    fun identicalOutOfWindowRowsConsumeEchoesOneForOne() {
        val echoes = listOf(
            message("echo-1", 100, "ciao", mine = true, viaInternet = true, state = "Sending"),
            message("echo-2", 101, "ciao", mine = true, viaInternet = true, state = "Sending"),
        )
        val fresh = listOf(
            message("event-1", 100, "ciao", mine = true, viaInternet = true),
            message("event-2", 101, "ciao", mine = true, viaInternet = true),
        )

        val result = reconcileSendEchoes(
            echoes = echoes,
            published = emptyList(),
            freshCanonical = fresh,
        )

        assertEquals(setOf("echo-1", "echo-2"), result.fulfilledEchoIds)
        assertEquals(2, result.admittedCanonical.size)
    }

    @Test
    fun planSendEchoDisplaySurfacesAdmittedOutOfWindowRow() {
        val echo = message("echo-1", 100, "ciao", mine = true, viaInternet = true, state = "Sending")
        val canonical = message("event-1", 100, "ciao", mine = true, viaInternet = true)

        val plan = planSendEchoDisplay(
            echoes = listOf(echo),
            published = emptyList(),
            excludedPublishedIdsByEcho = emptyMap(),
            freshCanonical = listOf(canonical),
        )

        assertTrue(plan.visibleEchoes.isEmpty())
        assertEquals(listOf(canonical), plan.admittedCanonical)
    }

    // ── firstUnreadTranscriptIndex (Signal-style unread anchoring) ──

    @Test
    fun firstUnreadIndexCountsOnlyIncomingFromTail() {
        val rows = listOf(
            message("a", 1),                 // incoming, read
            message("b", 2, mine = true),    // own send, ignored
            message("c", 3),                 // incoming, unread (oldest)
            message("d", 4, mine = true),    // own send interleaved, ignored
            message("e", 5),                 // incoming, unread
        )
        assertEquals(2, firstUnreadTranscriptIndex(rows, 2))
    }

    @Test
    fun firstUnreadIndexIsMinusOneWhenNothingUnread() {
        val rows = listOf(message("a", 1), message("b", 2))
        assertEquals(-1, firstUnreadTranscriptIndex(rows, 0))
        assertEquals(-1, firstUnreadTranscriptIndex(emptyList(), 3))
    }

    @Test
    fun firstUnreadIndexClampsToOldestLoadedIncomingRow() {
        // More unread than the bounded window holds: anchor at the oldest
        // loaded incoming row instead of walking off the page.
        val rows = listOf(
            message("mine", 1, mine = true),
            message("a", 2),
            message("b", 3),
        )
        assertEquals(1, firstUnreadTranscriptIndex(rows, 99))
    }

    @Test
    fun firstUnreadIndexSkipsNonMessageRows() {
        // Call records merge into the transcript feed but never consume
        // unread budget (the core index counts messages only).
        val rows = listOf<Any?>(
            message("a", 1),
            "call-record-placeholder",
            message("b", 3),
        )
        assertEquals(0, firstUnreadTranscriptIndex(rows, 2))
    }

    @Test
    fun firstUnreadIndexOnlyMineRowsHasNoAnchor() {
        val rows = listOf(message("a", 1, mine = true), message("b", 2, mine = true))
        assertEquals(-1, firstUnreadTranscriptIndex(rows, 2))
    }

    @Test
    fun emptyReadIsUntrustedWhenLocalMetadataKnowsMessages() {
        val page = listOf(message("a", 1))
        // The reported black transcript: core is up, the store answers empty,
        // but local metadata remembers a message — that read must not be painted.
        assertTrue(transcriptReadIsUntrusted(emptyList(), coreStarted = true, knownLatestSecs = 1_700_000L))
        // Failed read is always untrusted, whatever the metadata says.
        assertTrue(transcriptReadIsUntrusted(null, coreStarted = true, knownLatestSecs = 0L))
        // Core not started yet: an empty page proves nothing (cold launch).
        assertTrue(transcriptReadIsUntrusted(emptyList(), coreStarted = false, knownLatestSecs = 0L))
        // A genuinely empty conversation must still be paintable, or a new chat
        // would hold a stale window forever.
        assertFalse(transcriptReadIsUntrusted(emptyList(), coreStarted = true, knownLatestSecs = 0L))
        // Any non-empty page is local truth.
        assertFalse(transcriptReadIsUntrusted(page, coreStarted = true, knownLatestSecs = 1_700_000L))
        assertFalse(transcriptReadIsUntrusted(page, coreStarted = false, knownLatestSecs = 0L))
    }

    private fun coreRow(content: String, klass: SonarMsgClass) = SonarMsg(
        id = "m-${content.hashCode()}",
        senderNpub = "npub",
        content = content,
        mine = false,
        tsSecs = 1L,
        viaInternet = true,
        classification = klass,
    )

    private val noCallControl: (String) -> Boolean = { false }

    @Test
    fun coreClassificationDecidesVisibilityForCoreRows() {
        assertTrue(isTranscriptVisibleRow(coreRow("hey", SonarMsgClass.Text), noCallControl))
        assertTrue(
            isTranscriptVisibleRow(
                coreRow("⚡PAY|1|abc-123|21", SonarMsgClass.PayReceipt("abc-123", 21L)),
                noCallControl,
            )
        )
        assertFalse(
            isTranscriptVisibleRow(
                coreRow("⚡PAYDONE|1|abc-123", SonarMsgClass.PayDone("abc-123", null)),
                noCallControl,
            )
        )
        assertFalse(
            isTranscriptVisibleRow(
                coreRow("☎CALL|1|END|c3a1|declined", SonarMsgClass.CallControl),
                noCallControl,
            )
        )
    }

    @Test
    fun coreClassificationWinsOverTheLocalStringDecode() {
        // Core validates the payment id, PayLine.decode does not: this row is
        // plain text to core, so it must render AND stay in the unread budget.
        val invalidId = "⚡PAYDONE|1|hello world"
        assertFalse(PayLine.decode(invalidId) is PayLine.Pay, "local decode hides this row")
        assertTrue(
            isTranscriptVisibleRow(coreRow(invalidId, SonarMsgClass.Text), noCallControl),
            "core says text — hiding it would keep the phantom-unread bug",
        )

        // Core trims leading whitespace before classifying, the local decode
        // does not: core hides this one, so it must not render either.
        val leadingSpace = " ⚡PAYDONE|1|abc-123"
        assertEquals(null, PayLine.decode(leadingSpace), "local decode shows this row")
        assertFalse(
            isTranscriptVisibleRow(
                coreRow(leadingSpace, SonarMsgClass.PayDone("abc-123", null)),
                noCallControl,
            ),
            "core hides it, so it is not in the unread budget either",
        )
    }

    @Test
    fun rowsWithoutCoreClassificationKeepTheStringDecode() {
        val meshEcho = SonarMsg(
            id = "echo-1",
            senderNpub = "npub",
            content = "⚡PAYDONE|2|abc-123",
            mine = true,
            tsSecs = 1L,
        )
        assertFalse(isTranscriptVisibleRow(meshEcho, noCallControl))

        val meshText = SonarMsg(
            id = "echo-2",
            senderNpub = "npub",
            content = "hey",
            mine = true,
            tsSecs = 1L,
        )
        assertTrue(isTranscriptVisibleRow(meshText, noCallControl))
        assertFalse(isTranscriptVisibleRow(meshText) { it == "hey" }, "injected call-control gate applies")
    }
}
