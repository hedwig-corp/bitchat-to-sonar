package chat.hedwig.transcript.compose

import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyListState

/** Pixels the tail row still hangs below the viewport's content area after a scroll-to-tail. */
fun transcriptTailOverflowPx(
    lastOffset: Int,
    lastSize: Int,
    viewportEndOffset: Int,
    afterContentPadding: Int,
): Int = (lastOffset + lastSize - (viewportEndOffset - afterContentPadding)).coerceAtLeast(0)

/** Anchor the newest transcript row bottom-aligned, Signal-style. */
suspend fun LazyListState.anchorTranscriptTail(index: Int, animate: Boolean) {
    if (index < 0) return
    if (animate) animateScrollToItem(index) else scrollToItem(index)
    val info = layoutInfo
    val last = info.visibleItemsInfo.lastOrNull() ?: return
    if (last.index != index) return
    val overflow = transcriptTailOverflowPx(
        lastOffset = last.offset,
        lastSize = last.size,
        viewportEndOffset = info.viewportEndOffset,
        afterContentPadding = info.afterContentPadding,
    )
    if (overflow > 0) scrollBy(overflow.toFloat())
}

/** True when the newest row's bottom edge is already at the viewport end. */
fun LazyListState.isTranscriptTailAtLiveEdge(lastIndex: Int): Boolean {
    if (lastIndex < 0) return true
    val info = layoutInfo
    val last = info.visibleItemsInfo.lastOrNull() ?: return false
    if (last.index != lastIndex) return false
    return transcriptTailOverflowPx(
        lastOffset = last.offset,
        lastSize = last.size,
        viewportEndOffset = info.viewportEndOffset,
        afterContentPadding = info.afterContentPadding,
    ) == 0
}

/** Resolve the first-visible index for an open from [TranscriptOpenAction] alone. */
fun transcriptOpenIndex(
    openAction: chat.hedwig.transcript.TranscriptOpenAction,
    unreadAnchorIndex: Int,
    itemCount: Int,
    jumpIndex: Int = -1,
): Int {
    if (itemCount <= 0) return 0
    return when (openAction) {
        chat.hedwig.transcript.TranscriptOpenAction.LiveEdge -> itemCount - 1
        chat.hedwig.transcript.TranscriptOpenAction.UnreadDivider ->
            unreadAnchorIndex.takeIf { it >= 0 } ?: -1
        is chat.hedwig.transcript.TranscriptOpenAction.Jump ->
            jumpIndex.takeIf { it >= 0 } ?: unreadAnchorIndex.takeIf { it >= 0 } ?: (itemCount - 1)
    }
}

/** Pure Lockstep delta: offset += Δ (Signal inset follow). */
fun transcriptLockstepScrollDelta(insetDeltaPx: Int): Int = insetDeltaPx
