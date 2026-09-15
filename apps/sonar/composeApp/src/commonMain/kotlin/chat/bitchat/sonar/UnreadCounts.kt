package chat.bitchat.sonar

/**
 * Build the chat-list unread map from core conversation summaries.
 *
 * [suppressGroupIds] are groups the host has already marked read (or is
 * actively viewing). Summary refresh must not restore their badges while the
 * async `markConversationRead` FFI is still in flight — that race is what made
 * the unread indicator flaky after opening a chat.
 */
/** A failed summaries probe must not look like a successful empty inbox. */
internal fun shouldApplyUnreadCounts(loaded: List<SonarConversationSummary>?): Boolean =
    loaded != null

/**
 * Open-time unread from the published host cache. `unreadByChat` only stores
 * groups with unread > 0, so a missing family key is ambiguous: either this
 * chat is fully read, or summaries have never applied (cold start / closed
 * node). Only a cache hit may settle. An empty cache must not look like 0
 * (fully-read / jump-to-tail) — that hid the divider on recovered 0.8 chats.
 *
 * Mirrors iOS `SonarAppStore.captureUnreadAtOpen` cache check.
 */
internal fun openChatUnreadFromCache(
    ids: Collection<String>,
    unreadByChat: Map<String, Long>,
): Long? {
    val hasCachedEntry = ids.any { it in unreadByChat }
    val cached = ids.sumOf { unreadByChat[it] ?: 0L }
    if (hasCachedEntry || cached > 0L) return cached
    return null
}

/**
 * Open-time unread from a `conversationSummaries()` probe.
 * `null` summaries must not settle as `0`. Empty success is 0.
 * Mirrors iOS `SNUnreadCounts.openCount`.
 */
internal fun openChatUnreadFromSummaries(
    summaries: List<SonarConversationSummary>?,
    wanted: Collection<String>,
): Long? {
    if (summaries == null) return null
    val wantedSet = wanted.toSet()
    return summaries
        .asSequence()
        .filter { it.groupIdHex in wantedSet }
        .sumOf { it.unreadCount }
}

/**
 * Capture policy: cache hit wins; otherwise a successful index probe.
 * Empty group ids settle 0 (mesh with no White Noise leg yet).
 * Failed / missing probe stays unset (`null`).
 */
internal fun capturedOpenChatUnread(
    ids: Collection<String>,
    unreadByChat: Map<String, Long>,
    summaries: List<SonarConversationSummary>?,
): Long? {
    openChatUnreadFromCache(ids, unreadByChat)?.let { return it }
    if (ids.isEmpty()) return 0L
    return openChatUnreadFromSummaries(summaries, ids)
}

/**
 * After persist-folds remounts hist→live, publish onto the still-open id.
 * Empty stack (probe finished before `push`) keeps [capturedFor] so first
 * paint can still settle. A different room on the stack drops the probe.
 */
internal fun openChatUnreadPublishId(
    capturedFor: String,
    stackChatIds: Collection<String>,
    historicalFolds: Map<String, String>,
    openedConversationId: String? = null,
    openedConversationPaneId: String? = null,
): String? {
    stackChatIds.firstOrNull { id ->
        conversationsMatchFoldFamily(id, capturedFor, historicalFolds)
    }?.let { return it }
    val pair = remountPairConversationIds(
        conversationId = capturedFor,
        openedConversationId = openedConversationId,
        openedConversationPaneId = openedConversationPaneId,
    )
    stackChatIds.firstOrNull { stackId ->
        pair.any { openedConversationIdMatches(it, stackId) }
    }?.let { return it }
    return capturedFor.takeIf { stackChatIds.isEmpty() }
}

/** Newest visible `SonarMsg` timestamp in a transcript feed. */
internal fun feedNewestTsSecs(rows: List<Any?>): Long =
    rows.maxOfOrNull { (it as? SonarMsg)?.tsSecs ?: 0L } ?: 0L

/**
 * Do not retire an unread divider while the painted feed is still short of
 * the fold-family index newest, or while bak / hidden 0.8 rows may still
 * carry the unread incoming messages. iOS `expectedNewestDate` gate in
 * `resolveUnreadAnchor` — Compose used to settle `0` on the first non-empty
 * live page (treated as a complete Marmot snapshot).
 */
internal fun shouldRetireOpenChatUnread(
    unreadAtOpen: Long,
    anchorIndex: Int,
    feedNewestTsSecs: Long,
    expectedNewestTsSecs: Long,
    familyHasOlder: Boolean,
): Boolean {
    if (unreadAtOpen <= 0L || anchorIndex >= 0) return false
    if (familyHasOlder) return false
    if (expectedNewestTsSecs > 0L && feedNewestTsSecs < expectedNewestTsSecs) return false
    return true
}

internal fun unreadCountsFromSummaries(
    summaries: List<SonarConversationSummary>,
    suppressGroupIds: Set<String> = emptySet(),
): Map<String, Long> {
    if (summaries.isEmpty()) return emptyMap()
    val counts = LinkedHashMap<String, Long>()
    for (summary in summaries) {
        if (summary.unreadCount <= 0L) continue
        if (summary.groupIdHex in suppressGroupIds) continue
        counts[summary.groupIdHex] = summary.unreadCount
    }
    return counts
}

/**
 * `conversation_summaries()` hides folded hist. A later live-only probe
 * (live unread 0 after restore-without-`copy_summary`) used to drop the
 * previous hist badge. Keep the hist key only while live unread is still
 * 0 — after `copy_summary` live already holds the sum, so keeping hist
 * would double-count. Callers clear on empty summaries (a live-only
 * unread-0 probe publishes an empty map and must keep hist).
 * Empty persist-folds still walk the remount pair so a live-only probe
 * cannot drop the recovered badge before wake-mute writes the blob.
 * iOS `SNUnreadCounts.remountFoldedUnread`.
 */
internal fun remountFoldedUnread(
    next: Map<String, Long>,
    previous: Map<String, Long>,
    historicalFolds: Map<String, String>,
    openedConversationId: String? = null,
    openedConversationPaneId: String? = null,
): Map<String, Long> {
    // A live-only probe with unread 0 publishes an empty map (zeros are
    // omitted). That is not empty success — callers clear on `summaries.isEmpty()`.
    val folds = remountPairHistoricalFolds(
        historicalFolds,
        openedConversationId,
        openedConversationPaneId,
    )
    if (folds.isEmpty()) return next
    var out = next
    for ((historical, live) in folds) {
        if (live.isBlank() || live == historical) continue
        if (historical in next) continue
        val histUnread = previous[historical] ?: 0L
        if (histUnread <= 0L) continue
        if ((out[live] ?: 0L) > 0L) continue
        out = out + (historical to histUnread)
    }
    return out
}

/**
 * After a summaries refresh, drop suppress entries the core has confirmed as
 * read (`unread_count == 0` or missing). Keep suppressing while the DB still
 * reports unread so an in-flight mark-read cannot flash the badge back.
 *
 * Callers must clear a mark batch from the suppress set once the FFI settles
 * (see [SonarAppState.markGroupsRead]); this prune alone must not be the only
 * release path, or a failed mark would hide unread for the whole process.
 */
internal fun pruneConfirmedUnreadSuppressions(
    suppressGroupIds: Set<String>,
    summaries: List<SonarConversationSummary>,
): Set<String> {
    if (suppressGroupIds.isEmpty()) return emptySet()
    val stillUnread = summaries.mapNotNullTo(HashSet()) { summary ->
        summary.groupIdHex.takeIf { summary.unreadCount > 0L }
    }
    return suppressGroupIds.intersect(stillUnread)
}
