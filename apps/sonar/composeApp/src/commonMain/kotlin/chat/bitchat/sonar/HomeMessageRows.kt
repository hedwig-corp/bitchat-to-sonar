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

internal fun hydrateLocalConversationRows(
    activeChatIds: Set<String>,
    existingMessagesByChat: Map<String, List<SonarMsg>>,
    existingLatestByChat: Map<String, Long>,
    summaries: List<SonarConversationSummary>,
    pages: List<SonarRecentTranscriptPage>,
): LocalConversationHydration {
    val messages = existingMessagesByChat.filterKeys { it in activeChatIds }.toMutableMap()
    val latest = existingLatestByChat.filterKeys { it in activeChatIds }.toMutableMap()

    for (summary in summaries) {
        if (summary.groupIdHex !in activeChatIds || summary.latestAtSecs <= 0L) continue
        latest[summary.groupIdHex] = summary.latestAtSecs
        val existing = messages[summary.groupIdHex]
        val previous = existing?.lastOrNull()
        val summaryId = "summary:${summary.groupIdHex}:${summary.latestAtSecs}:${summary.messageCount}"
        val visibleFieldsMatch = previous != null &&
            previous.tsSecs == summary.latestAtSecs &&
            previous.content == summary.latestContent &&
            previous.senderNpub == summary.latestSenderNpub &&
            previous.mine == summary.latestMine
        val staleSyntheticIdentity = previous?.id?.startsWith("summary:${summary.groupIdHex}:") == true &&
            previous.id != summaryId
        // Preserve a real bounded-page row when it already represents the same
        // visible latest message. Synthetic summaries additionally track count,
        // because core timestamps have only second resolution.
        if (!visibleFieldsMatch || staleSyntheticIdentity) {
            messages[summary.groupIdHex] = listOf(
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
        if (page.chatId !in activeChatIds || page.messages.isEmpty()) continue
        messages[page.chatId] = page.messages
        latest[page.chatId] = page.latestTsSecs.takeIf { it > 0L }
            ?: page.messages.maxOf { it.tsSecs }
    }
    return LocalConversationHydration(messages, latest)
}
