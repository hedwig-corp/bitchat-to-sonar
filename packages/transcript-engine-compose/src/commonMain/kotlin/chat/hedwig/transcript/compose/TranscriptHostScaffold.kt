package chat.hedwig.transcript.compose

import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import chat.hedwig.transcript.TranscriptScrollDecision
import chat.hedwig.transcript.TranscriptScrollPolicy
import chat.hedwig.transcript.TranscriptTailPinSession
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * Full-height list under an overlaid composer. [listContent] receives the owned
 * bottom inset for LazyColumn `contentPadding.bottom`. Applies Pin + Lockstep
 * via [TranscriptHostScrollEffects].
 */
@Composable
fun TranscriptHostScaffold(
    listState: LazyListState,
    listKey: Any? = null,
    isPrepending: () -> Boolean = { false },
    suppressPin: () -> Boolean = { false },
    modifier: Modifier = Modifier,
    listContent: @Composable BoxScope.(bottomInset: Dp) -> Unit,
    bottomContent: @Composable () -> Unit,
) {
    var bottomChromePx by remember { mutableIntStateOf(0) }
    val density = LocalDensity.current
    val bottomInset = with(density) {
        if (bottomChromePx > 0) bottomChromePx.toDp() else 56.dp
    }

    Box(modifier.fillMaxSize()) {
        listContent(bottomInset)
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .imePadding()
                .onGloballyPositioned { coords ->
                    val parentH = coords.parentLayoutCoordinates?.size?.height
                        ?: return@onGloballyPositioned
                    val chrome = (parentH - coords.positionInParent().y).roundToInt().coerceAtLeast(0)
                    if (chrome != bottomChromePx) bottomChromePx = chrome
                },
        ) {
            bottomContent()
        }
    }

    TranscriptHostScrollEffects(
        listState = listState,
        key = listKey,
        isPrepending = isPrepending,
        suppressPin = suppressPin,
    )
}

/**
 * Host scroll effects: layout-frame Pin (append / IME steal at tail) plus
 * real Lockstep on owned afterContentPadding Δ via [TranscriptScrollPolicy.decideInsetChange].
 */
@Composable
fun TranscriptHostScrollEffects(
    listState: LazyListState,
    key: Any? = null,
    isPrepending: () -> Boolean = { false },
    suppressPin: () -> Boolean = { false },
) {
    val prependingFn by rememberUpdatedState(isPrepending)
    val suppressFn by rememberUpdatedState(suppressPin)

    LaunchedEffect(key, listState) {
        val session = TranscriptTailPinSession()
        snapshotFlow {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()
            val pad = info.afterContentPadding
            val tailFullyVisible = last != null &&
                last.index == info.totalItemsCount - 1 &&
                last.offset + last.size <= info.viewportEndOffset - pad
            HostTailFrame(
                itemCount = info.totalItemsCount,
                viewportHeight = info.viewportSize.height,
                tailFullyVisible = tailFullyVisible,
                scrolling = listState.isScrollInProgress,
                prepending = prependingFn() || suppressFn(),
                afterContentPadding = pad,
            )
        }.distinctUntilChanged().collect { frame ->
            val decision = session.onLayoutFrame(
                itemCount = frame.itemCount,
                tailFullyVisible = frame.tailFullyVisible,
                scrolling = frame.scrolling,
                prepending = frame.prepending,
            )
            if (decision !is TranscriptScrollDecision.Pin) return@collect
            withFrameNanos { }
            listState.anchorTranscriptTail(
                frame.itemCount - 1,
                animate = decision.animate,
            )
        }
    }

    LaunchedEffect(key, listState) {
        var prevPad = -1
        var prevWasAtTail = true
        var pendingDelta = 0
        var captureWasAtTail = true
        var coalesceJob: Job? = null
        snapshotFlow {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()
            val pad = info.afterContentPadding
            val atTail = last != null &&
                info.totalItemsCount > 0 &&
                last.index == info.totalItemsCount - 1 &&
                last.offset + last.size <= info.viewportEndOffset - pad
            HostInsetPadFrame(
                afterContentPadding = pad,
                wasAtTail = atTail,
                scrolling = listState.isScrollInProgress,
                itemCount = info.totalItemsCount,
            )
        }.distinctUntilChanged().collect { frame ->
            if (prevPad < 0) {
                prevPad = frame.afterContentPadding
                prevWasAtTail = frame.wasAtTail
                return@collect
            }
            val delta = frame.afterContentPadding - prevPad
            prevPad = frame.afterContentPadding
            if (delta != 0 && !prependingFn() && !suppressFn()) {
                if (pendingDelta == 0) captureWasAtTail = prevWasAtTail
                pendingDelta += delta
                if (coalesceJob == null) {
                    coalesceJob = launch {
                        delay(TranscriptScrollPolicy.INSET_COALESCE_MS)
                        val applyDelta = pendingDelta
                        pendingDelta = 0
                        coalesceJob = null
                        val scrollingNow = listState.isScrollInProgress
                        val count = listState.layoutInfo.totalItemsCount
                        val decision = TranscriptScrollPolicy.decideInsetChange(
                            wasAtTail = captureWasAtTail,
                            userScrolling = scrollingNow,
                            prepending = prependingFn(),
                        )
                        when (decision) {
                            is TranscriptScrollDecision.Pin -> {
                                withFrameNanos { }
                                if (count > 0) {
                                    listState.anchorTranscriptTail(count - 1, animate = false)
                                }
                            }
                            TranscriptScrollDecision.Lockstep -> {
                                val scrollDelta = transcriptLockstepScrollDelta(applyDelta)
                                if (scrollDelta != 0) {
                                    withFrameNanos { }
                                    listState.scrollBy(scrollDelta.toFloat())
                                }
                            }
                            TranscriptScrollDecision.Ignore -> Unit
                        }
                    }
                }
            }
            if (delta == 0 || pendingDelta == 0) {
                prevWasAtTail = frame.wasAtTail
            }
        }
    }
}

private data class HostTailFrame(
    val itemCount: Int,
    val viewportHeight: Int,
    val tailFullyVisible: Boolean,
    val scrolling: Boolean,
    val prepending: Boolean,
    val afterContentPadding: Int = 0,
)

private data class HostInsetPadFrame(
    val afterContentPadding: Int,
    val wasAtTail: Boolean,
    val scrolling: Boolean,
    val itemCount: Int,
)
