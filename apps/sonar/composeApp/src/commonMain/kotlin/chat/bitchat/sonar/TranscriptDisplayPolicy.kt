package chat.bitchat.sonar

internal const val TRANSCRIPT_PAGE_SIZE = 30
internal const val TRANSCRIPT_PAGE_FETCH_SIZE = TRANSCRIPT_PAGE_SIZE + 1
internal const val TRANSCRIPT_RETAINED_ROWS = 500
internal const val TRANSCRIPT_PREVIEW_GRAPHEMES = 512
internal const val TRANSCRIPT_PREVIEW_NEWLINES = 15

internal data class TranscriptPreview(
    val text: String,
    val truncated: Boolean,
)

internal fun transcriptDisplayText(source: String, expanded: Boolean): String {
    if (expanded) return source
    return transcriptPreview(source).text
}

/**
 * Cheap, deterministic long-body preview shared by Android and desktop.
 *
 * The source string is never changed. The returned prefix stops before the
 * 513th conservatively detected user-perceived cluster or 16th newline, and
 * backs out of a URL token when that token would otherwise be cut in half.
 * Kotlin common code has no Unicode break iterator; this scanner deliberately
 * handles surrogate pairs, combining marks, emoji modifiers, flags, and ZWJ
 * sequences without claiming complete UAX #29 coverage.
 */
internal fun transcriptPreview(
    source: String,
    maxGraphemes: Int = TRANSCRIPT_PREVIEW_GRAPHEMES,
    maxNewlines: Int = TRANSCRIPT_PREVIEW_NEWLINES,
): TranscriptPreview {
    if (source.isEmpty()) return TranscriptPreview(source, truncated = false)

    val graphemeEnd = graphemePrefixEnd(source, maxGraphemes)
    val newlineEnd = newlinePrefixEnd(source, maxNewlines)
    var end = minOf(graphemeEnd, newlineEnd)
    if (end >= source.length) return TranscriptPreview(source, truncated = false)

    end = completeUrlBoundary(source, end)
    if (end > 0 && end < source.length && source[end - 1] == '\r' && source[end] == '\n') {
        end -= 1
    }
    return TranscriptPreview(source.substring(0, end).trimEnd() + "…", truncated = true)
}

/** Merge canonical rows by stable ID, sort deterministically for display, and bound memory. */
internal fun mergeTranscriptRows(
    existing: List<SonarMsg>,
    incoming: List<SonarMsg>,
    retainedRows: Int = TRANSCRIPT_RETAINED_ROWS,
): List<SonarMsg> {
    if (retainedRows <= 0) return emptyList()
    val byId = LinkedHashMap<String, SonarMsg>(existing.size + incoming.size)
    for (message in existing) byId[message.id] = message
    for (message in incoming) byId[message.id] = message
    return byId.values
        .sortedWith(compareBy<SonarMsg>({ it.tsSecs }, { it.id }))
        .takeLast(retainedRows)
}

/**
 * Refresh a live window from the newest edge. A reader pinned in older history
 * receives edits to retained rows without having unseen tail rows evict their
 * current anchor; reopening the conversation starts at the tail again.
 */
internal fun refreshTranscriptRows(
    existing: List<SonarMsg>,
    newest: List<SonarMsg>,
    pinnedToOlderEdge: Boolean,
    retainedRows: Int = TRANSCRIPT_RETAINED_ROWS,
): List<SonarMsg> {
    if (!pinnedToOlderEdge) return mergeTranscriptRows(existing, newest, retainedRows)
    val retainedIds = existing.mapTo(hashSetOf()) { it.id }
    return mergeTranscriptRows(existing, newest.filter { it.id in retainedIds }, retainedRows)
}

/** Prepend history while keeping the older edge when the retained window is full. */
internal fun prependTranscriptRows(
    existing: List<SonarMsg>,
    older: List<SonarMsg>,
    retainedRows: Int = TRANSCRIPT_RETAINED_ROWS,
): List<SonarMsg> {
    if (retainedRows <= 0) return emptyList()
    val byId = LinkedHashMap<String, SonarMsg>(existing.size + older.size)
    for (message in existing) byId[message.id] = message
    for (message in older) byId[message.id] = message
    return byId.values
        .sortedWith(compareBy<SonarMsg>({ it.tsSecs }, { it.id }))
        .take(retainedRows)
}

/** Apply the one conversation-wide render budget after all transport sources are merged. */
internal fun boundedTranscriptRows(
    source: List<SonarMsg>,
    visibleRows: Int,
    pinnedToOlderEdge: Boolean,
): List<SonarMsg> = if (pinnedToOlderEdge) {
    prependTranscriptRows(emptyList(), source, visibleRows)
} else {
    mergeTranscriptRows(emptyList(), source, visibleRows)
}

/** Stable de-duplication/order without applying a render-window budget yet. */
internal fun mergeAllTranscriptRows(source: List<SonarMsg>): List<SonarMsg> =
    mergeTranscriptRows(emptyList(), source, retainedRows = source.size)

/** Pick one globally adjacent older page after independently paged sources are merged. */
internal fun nearestOlderTranscriptPage(
    source: List<SonarMsg>,
    oldestVisible: SonarMsg,
    pageSize: Int = TRANSCRIPT_PAGE_SIZE,
): List<SonarMsg> = mergeAllTranscriptRows(source)
    .filter { candidate ->
        candidate.tsSecs < oldestVisible.tsSecs ||
            (candidate.tsSecs == oldestVisible.tsSecs && candidate.id < oldestVisible.id)
    }
    .takeLast(pageSize.coerceAtLeast(0))

/** The lookahead row determines has-more but is not retained in the visible page. */
internal fun visibleTranscriptPage(
    fetchedNewestFirst: List<SonarMsg>,
    pageSize: Int = TRANSCRIPT_PAGE_SIZE,
): List<SonarMsg> = fetchedNewestFirst
    .take(pageSize.coerceAtLeast(0))
    .sortedWith(compareBy<SonarMsg>({ it.tsSecs }, { it.id }))

/** Canonical rows that could represent [echo], excluding rows known to predate it. */
internal fun eligibleCanonicalRowsForSendEcho(
    echo: SonarMsg,
    published: List<SonarMsg>,
    excludedPublishedIds: Set<String> = emptySet(),
): List<SonarMsg> = published.filter {
    it.id !in excludedPublishedIds &&
        it.mine &&
        it.content == echo.content &&
        it.viaInternet == echo.viaInternet &&
        it.tsSecs >= echo.tsSecs
}

/**
 * Match optimistic outgoing echoes to canonical local-storage rows one-for-one.
 *
 * The core writes the canonical row before `send` returns, so it commonly has
 * the same whole-second timestamp as the echo. First-chat setup can also delay
 * that row well beyond 30 seconds. Only reject canonical rows that are clearly
 * older than the echo. Compose and the Rust core read whole epoch seconds from
 * the same device clock, so a row from this send can share the echo's second or
 * follow it, but cannot legitimately predate it. That lower bound prevents a
 * recent identical send from consuming the new echo before its canonical row
 * exists. Callers also exclude matching canonical rows that were already
 * visible when an echo was created: same-second timestamps alone cannot
 * distinguish an earlier identical send from the new one.
 */
internal fun fulfilledSendEchoIds(
    echoes: List<SonarMsg>,
    published: List<SonarMsg>,
    excludedPublishedIdsByEcho: Map<String, Set<String>> = emptyMap(),
): Set<String> {
    val fulfilled = mutableSetOf<String>()
    val consumedPublished = mutableSetOf<String>()
    val ownPublished = published.filter { it.mine }.groupBy { it.content }
    // Prefer the most recent pending duplicate. A newer canonical row must not
    // hide an older send whose result is still unknown.
    for (echo in echoes.asReversed()) {
        if (echo.state == "Couldn't send") continue
        val match = eligibleCanonicalRowsForSendEcho(
            echo = echo,
            published = ownPublished[echo.content].orEmpty(),
            excludedPublishedIds = excludedPublishedIdsByEcho[echo.id].orEmpty(),
        ).firstOrNull { it.id !in consumedPublished }
        if (match != null) {
            fulfilled.add(echo.id)
            consumedPublished.add(match.id)
        }
    }
    return fulfilled
}

private fun newlinePrefixEnd(source: String, maxNewlines: Int): Int {
    if (maxNewlines < 0) return 0
    var seen = 0
    source.forEachIndexed { index, char ->
        if (char == '\n') {
            if (seen == maxNewlines) return index
            seen += 1
        }
    }
    return source.length
}

private fun graphemePrefixEnd(source: String, maxGraphemes: Int): Int {
    if (maxGraphemes <= 0) return 0
    var index = 0
    var graphemes = 0
    var regionalInCluster = false
    while (index < source.length && graphemes < maxGraphemes) {
        graphemes += 1
        var codePoint = codePointAt(source, index)
        regionalInCluster = isRegionalIndicator(codePoint)
        index += codePointWidth(codePoint)

        while (index < source.length) {
            codePoint = codePointAt(source, index)
            when {
                isGraphemeExtension(codePoint) -> index += codePointWidth(codePoint)
                regionalInCluster && isRegionalIndicator(codePoint) -> {
                    index += codePointWidth(codePoint)
                    regionalInCluster = false
                }
                codePoint == 0x200D -> {
                    index += 1
                    if (index < source.length) {
                        val joined = codePointAt(source, index)
                        index += codePointWidth(joined)
                    }
                    regionalInCluster = false
                }
                else -> break
            }
        }
    }
    return index
}

private fun completeUrlBoundary(source: String, proposedEnd: Int): Int {
    if (proposedEnd <= 0 || proposedEnd >= source.length) return proposedEnd
    val tokenStart = source.lastIndexOfAny(charArrayOf(' ', '\t', '\n', '\r'), proposedEnd - 1) + 1
    val tokenPrefix = source.substring(tokenStart, proposedEnd).lowercase()
    val looksLikeUrl = tokenPrefix.startsWith("http://") ||
        tokenPrefix.startsWith("https://") ||
        tokenPrefix.startsWith("www.")
    if (!looksLikeUrl || source[proposedEnd].isWhitespace()) return proposedEnd
    return tokenStart
}

private fun codePointAt(source: String, index: Int): Int {
    val first = source[index]
    if (first.isHighSurrogate() && index + 1 < source.length && source[index + 1].isLowSurrogate()) {
        return 0x10000 + ((first.code - 0xD800) shl 10) + (source[index + 1].code - 0xDC00)
    }
    return first.code
}

private fun codePointWidth(codePoint: Int): Int = if (codePoint > 0xFFFF) 2 else 1

private fun isRegionalIndicator(codePoint: Int): Boolean = codePoint in 0x1F1E6..0x1F1FF

private fun isGraphemeExtension(codePoint: Int): Boolean =
    codePoint in 0x0300..0x036F ||
        codePoint in 0x1AB0..0x1AFF ||
        codePoint in 0x1DC0..0x1DFF ||
        codePoint in 0x20D0..0x20FF ||
        codePoint in 0xFE00..0xFE0F ||
        codePoint in 0xFE20..0xFE2F ||
        codePoint in 0x1F3FB..0x1F3FF ||
        codePoint in 0xE0100..0xE01EF ||
        codePoint == 0x20E3
