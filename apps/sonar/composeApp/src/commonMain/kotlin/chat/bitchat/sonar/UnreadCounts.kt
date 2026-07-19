package chat.bitchat.sonar

/**
 * Build the chat-list unread map from core conversation summaries.
 *
 * [suppressGroupIds] are groups the host has already marked read (or is
 * actively viewing). Summary refresh must not restore their badges while the
 * async `markConversationRead` FFI is still in flight — that race is what made
 * the unread indicator flaky after opening a chat.
 */
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
 * After a summaries refresh, drop suppress entries the core has confirmed as
 * read (`unread_count == 0` or missing). Keep suppressing while the DB still
 * reports unread so an in-flight mark-read cannot flash the badge back.
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
