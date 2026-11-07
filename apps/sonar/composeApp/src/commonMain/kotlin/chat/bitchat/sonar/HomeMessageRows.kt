package chat.bitchat.sonar

/**
 * One Home / sidebar Messages row after mesh and Marmot sources are unified.
 * Sealed so LazyColumn keys never need a force-unwrap on a dual-nullable pair.
 */
internal sealed class HomeMessageRow {
    data class Mesh(val row: MeshDmRow) : HomeMessageRow()
    data class Marmot(val chat: SonarChat) : HomeMessageRow()

    val listKey: String
        get() = when (this) {
            is Mesh -> "mesh:" + row.peerId
            is Marmot -> chat.id
        }
}

/**
 * Merge BLE-mesh / folded rows with standalone Marmot chats into ONE
 * recency-ordered list (Signal-style / iOS `SonarAppStore.dmRows` parity).
 *
 * [marmotTsSecs] must be O(1) per id (cached row VM). Pending chats should
 * return their creation time, not 0, so a freshly-started secure chat does
 * not sink under history.
 */
internal fun mergeHomeMessageRows(
    meshRows: List<MeshDmRow>,
    chatRows: List<SonarChat>,
    marmotTsSecs: (chatId: String) -> Long,
): List<HomeMessageRow> =
    buildList(meshRows.size + chatRows.size) {
        meshRows.forEach { add(HomeMessageRow.Mesh(it)) }
        chatRows.forEach { add(HomeMessageRow.Marmot(it)) }
    }.sortedByDescending { row ->
        when (row) {
            is HomeMessageRow.Mesh -> row.row.tsSecs
            is HomeMessageRow.Marmot -> marmotTsSecs(row.chat.id)
        }
    }

/**
 * Order the authoritative local chat rows by their bounded transcript tails.
 *
 * [previousOrder] is the last list painted by the UI. It is the deterministic
 * fallback for equal or unavailable timestamps, so opening the local database
 * cannot reshuffle otherwise unchanged rows before their summaries arrive.
 */
internal fun orderChatsByLocalRecency(
    chats: List<SonarChat>,
    latestSecs: (chatId: String) -> Long,
    previousOrder: List<String>,
): List<SonarChat> {
    val previousRank = previousOrder.withIndex().associate { it.value to it.index }
    return chats.withIndex()
        .sortedWith(
            compareByDescending<IndexedValue<SonarChat>> { latestSecs(it.value.id) }
                .thenBy { previousRank[it.value.id] ?: Int.MAX_VALUE }
                .thenBy { it.index },
        )
        .map { it.value }
}

/** Coherent local row state built from the core-owned conversation index plus
 *  bounded transcript pages. Summaries cover every conversation in O(rows);
 *  pages enrich only the newest window with media/sticker metadata. */
internal data class LocalConversationHydration(
    val messagesByChat: Map<String, List<SonarMsg>>,
    val latestByChat: Map<String, Long>,
)

/**
 * Id prefix of a SYNTHETIC chat-list row: a stand-in minted from the core
 * conversation index for a chat outside the bounded page window, carrying only
 * the latest message's preview fields.
 *
 * These rows exist to render a chat-list subtitle. They are NOT transcript
 * content: their id is not an event id, so it can never match — and therefore
 * never dedupe against — the real row once the bounded page loads. Feeding one
 * into a transcript renders a duplicate bubble forever. Always strip them with
 * [withoutSyntheticSummaryRows] before seeding transcript state.
 */
internal const val SYNTHETIC_SUMMARY_ID_PREFIX = "summary:"

internal fun List<SonarMsg>.withoutSyntheticSummaryRows(): List<SonarMsg> =
    filterNot { it.id.startsWith(SYNTHETIC_SUMMARY_ID_PREFIX) }

/** True when [rows] already hold real event ids. A conversation-index
 *  stand-in must not replace those — persist-folds remount the hidden 0.8
 *  extract onto live before core `fold_family` exists, and chats outside
 *  the bounded home page window never get a page to put the rows back.
 *  iOS never writes synthetics into `messagesByGroup`; home paint uses
 *  `snMarmotHomeRowMessage` only (`latestAt`-or-count after `copy_summary`). */
internal fun hydrationHasRealTranscriptRows(rows: List<SonarMsg>): Boolean =
    rows.any { !it.id.startsWith(SYNTHETIC_SUMMARY_ID_PREFIX) }

/** Merge a bounded home page into remounted / leftover rows. A newer live
 *  page must not replace a remounted 0.8 extract (iOS `loadLocalSummaries`
 *  already `mergeMessages`s into `byGroup`). */
internal fun hydrateMergedPageRows(
    existing: List<SonarMsg>,
    incoming: List<SonarMsg>,
): List<SonarMsg> = mergeAllTranscriptRows(existing.withoutSyntheticSummaryRows() + incoming)

/** Listed live id that should receive a hidden 0.8 summary / page.
 *  Empty persist-folds still walk the remount pair so a hist-keyed
 *  `recentMessagePages` / index row lands on live before wake-mute.
 *  iOS `snHydrationTargetGroupId`. */
internal fun hydrationTargetId(
    sourceId: String,
    activeChatIds: Set<String>,
    historicalFolds: Map<String, String>,
    openedConversationId: String? = null,
    openedConversationPaneId: String? = null,
): String? {
    if (sourceId in activeChatIds) return sourceId
    val folds = remountPairHistoricalFolds(
        historicalFolds,
        openedConversationId,
        openedConversationPaneId,
    )
    val bare = sourceId.removePrefix("marmot:")
    val live = folds[bare]?.takeIf { it.isNotBlank() && it != bare }
        ?: folds[sourceId]?.takeIf { it.isNotBlank() && it != sourceId }
    return live?.takeIf { it in activeChatIds }
}

internal fun hydrateLocalConversationRows(
    activeChatIds: Set<String>,
    existingMessagesByChat: Map<String, List<SonarMsg>>,
    existingLatestByChat: Map<String, Long>,
    summaries: List<SonarConversationSummary>,
    pages: List<SonarRecentTranscriptPage>,
    historicalFolds: Map<String, String> = emptyMap(),
    openedConversationId: String? = null,
    openedConversationPaneId: String? = null,
): LocalConversationHydration {
    val folds = remountPairHistoricalFolds(
        historicalFolds,
        openedConversationId,
        openedConversationPaneId,
    )
    val messages = existingMessagesByChat.filterKeys { it in activeChatIds }.toMutableMap()
    val latest = existingLatestByChat.filterKeys { it in activeChatIds }.toMutableMap()
    for ((historical, live) in folds) {
        if (live !in activeChatIds) continue
        val incoming = existingMessagesByChat[historical].orEmpty()
        if (incoming.isNotEmpty()) {
            messages[live] = mergedFoldedMessageLists(incoming, messages[live].orEmpty()) { it.id }
        }
        val incomingTs = existingLatestByChat[historical]
            ?: incoming.maxOfOrNull { it.tsSecs }
            ?: 0L
        if (incomingTs > (latest[live] ?: 0L)) latest[live] = incomingTs
    }

    for (summary in summaries) {
        val target = hydrationTargetId(
            summary.groupIdHex,
            activeChatIds,
            folds,
            openedConversationId,
            openedConversationPaneId,
        )
            ?: continue
        if (summary.latestAtSecs <= 0L) continue
        val existing = messages[target].orEmpty()
        if (summary.latestAtSecs > (latest[target] ?: 0L)) {
            latest[target] = summary.latestAtSecs
        }
        // Remounted / paged rows are transcript content. `lastOrNull()` is not
        // necessarily newest (fold merge does not sort), so a newer summary
        // used to wipe an 80-row 0.8 extract down to one `summary:` stand-in.
        if (hydrationHasRealTranscriptRows(existing)) continue
        latest[target] = maxOf(latest[target] ?: 0L, summary.latestAtSecs)
        val previous = existing.lastOrNull()
        val summaryId =
            "$SYNTHETIC_SUMMARY_ID_PREFIX$target:${summary.latestAtSecs}:${summary.messageCount}"
        val visibleFieldsMatch = previous != null &&
            previous.tsSecs == summary.latestAtSecs &&
            previous.content == summary.latestContent &&
            previous.senderNpub == summary.latestSenderNpub &&
            previous.mine == summary.latestMine
        val staleSyntheticIdentity =
            previous?.id?.startsWith("$SYNTHETIC_SUMMARY_ID_PREFIX$target:") == true &&
            previous.id != summaryId
        // Preserve a real bounded-page row when it already represents the same
        // visible latest message. Synthetic summaries additionally track count,
        // because core timestamps have only second resolution.
        if (!visibleFieldsMatch || staleSyntheticIdentity) {
            messages[target] = listOf(
                SonarMsg(
                    id = summaryId,
                    senderNpub = summary.latestSenderNpub,
                    content = summary.latestContent,
                    mine = summary.latestMine,
                    tsSecs = summary.latestAtSecs,
                    viaInternet = true,
                )
            )
        }
    }

    for (page in pages) {
        val target = hydrationTargetId(
            page.chatId,
            activeChatIds,
            folds,
            openedConversationId,
            openedConversationPaneId,
        ) ?: continue
        if (page.messages.isEmpty()) continue
        val existingTs = latest[target] ?: 0L
        val pageTs = page.latestTsSecs.takeIf { it > 0L } ?: page.messages.maxOf { it.tsSecs }
        val existing = messages[target].orEmpty()
        // Persist-folds remount the hidden extract onto live, then a newer
        // live page (or an older hist page after that live page) must merge.
        // Replacing dropped the recovered rows for every chat in the page
        // window. iOS `loadLocalSummaries` already merges into `byGroup`.
        messages[target] = hydrateMergedPageRows(existing, page.messages)
        latest[target] = maxOf(existingTs, pageTs)
    }
    return LocalConversationHydration(messages, latest)
}
