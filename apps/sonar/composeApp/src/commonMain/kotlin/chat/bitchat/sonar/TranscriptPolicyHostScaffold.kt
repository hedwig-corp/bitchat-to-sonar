package chat.bitchat.sonar

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.ui.sonar
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * Signal-engine Compose transcript host — the **production** ChatScreen shell
 * since the Phase 3 cutover.
 *
 * Full-height [LazyColumn], top-aligned short feeds (Spike A shape), owned
 * bottom [contentPadding] = measured composer chrome + IME. Composer is an
 * overlay sibling with [imePadding]. Does **not** enable `reverseLayout`
 * (Spike B stays separate).
 *
 * Scroll: [TranscriptScrollPolicy.decideInsetChange] → Pin / Lockstep / Ignore
 * on chrome/IME Δ (Lockstep applies `scrollBy(Δ)` — not mapped to None).
 * Open: [TranscriptOpenAction] only. loadOlder: [TranscriptContinuityToken].
 *
 * Default ON in every build. Kill switch (legacy sibling-composer shell):
 * - Desktop: `./gradlew :composeApp:run -Dsonar.transcript.policy.host=0`
 * - Env: `SONAR_TRANSCRIPT_PHASE2_HOST=0`
 */
internal object SonarTranscriptPolicyHost {
    const val PROPERTY_KEY: String = "sonar.transcript.policy.host"
    const val ENV_KEY: String = "SONAR_TRANSCRIPT_PHASE2_HOST"

    /** Test / local override. Honored only when [sonarDebugForceFlagsAllowed]. */
    @Volatile
    var forceEnabled: Boolean = false

    fun isEnabled(): Boolean =
        (forceEnabled && sonarDebugForceFlagsAllowed) ||
            sonarTranscriptPolicyHostEnabled
}

/** Android Release: false. Debug/JVM: true so unit tests may latch forceEnabled. */
internal expect val sonarDebugForceFlagsAllowed: Boolean

/** Production default ON; env/property `=0` falls back to the legacy shell. */
internal expect val sonarTranscriptPolicyHostEnabled: Boolean

/** Whether Settings may show the Phase 2 host entry (Debug builds only). */
internal expect val sonarTranscriptPolicyHostEntryVisible: Boolean

/**
 * Resolve the first-visible index for a Phase 2 open from [TranscriptOpenAction]
 * alone (no parallel unread-count gate).
 */
internal fun transcriptPhase2OpenIndex(
    openAction: TranscriptOpenAction,
    unreadAnchorIndex: Int,
    itemCount: Int,
    jumpIndex: Int = -1,
): Int {
    if (itemCount <= 0) return 0
    return when (openAction) {
        TranscriptOpenAction.LiveEdge -> itemCount - 1
        // Pending unread: -1 so callers do not treat missing anchor as top/tail.
        TranscriptOpenAction.UnreadDivider ->
            unreadAnchorIndex.takeIf { it >= 0 } ?: -1
        is TranscriptOpenAction.Jump ->
            jumpIndex.takeIf { it >= 0 } ?: unreadAnchorIndex.takeIf { it >= 0 } ?: (itemCount - 1)
    }
}

/** Pure Lockstep delta: offset += Δ (Signal inset follow). */
internal fun transcriptPhase2LockstepScrollDelta(insetDeltaPx: Int): Int = insetDeltaPx

/**
 * Full-height list under an overlaid composer. [listContent] receives the owned
 * bottom inset for LazyColumn `contentPadding.bottom`. Applies Pin + Lockstep
 * via [TranscriptPhase2ScrollEffects] (not the production Lockstep→None adapter).
 */
@Composable
internal fun TranscriptPhase2HostScaffold(
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

    TranscriptPhase2ScrollEffects(
        listState = listState,
        key = listKey,
        isPrepending = isPrepending,
        suppressPin = suppressPin,
    )
}

/**
 * Flagged-host scroll effects: layout-frame Pin (append / IME steal at tail) plus
 * real Lockstep on owned afterContentPadding Δ via [TranscriptScrollPolicy.decideInsetChange].
 *
 * Production [TranscriptTailPinning] still maps Lockstep→None; this path does not.
 */
@Composable
internal fun TranscriptPhase2ScrollEffects(
    listState: LazyListState,
    key: Any? = null,
    isPrepending: () -> Boolean = { false },
    suppressPin: () -> Boolean = { false },
) {
    val prependingFn by rememberUpdatedState(isPrepending)
    val suppressFn by rememberUpdatedState(suppressPin)

    // Layout-frame pin (same semantics as TranscriptTailPinSession / R-009).
    LaunchedEffect(key, listState) {
        val session = TranscriptTailPinSession()
        snapshotFlow {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()
            val pad = info.afterContentPadding
            val tailFullyVisible = last != null &&
                last.index == info.totalItemsCount - 1 &&
                last.offset + last.size <= info.viewportEndOffset - pad
            TranscriptTailFrame(
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

    // Chrome / IME owned-pad Δ → Pin | Lockstep | Ignore (coalesced 10 ms, last-only).
    // Capture wasAtTail *before* the pad change; apply Lockstep as scrollBy(Δ).
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
            InsetPadFrame(
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
                                val scrollDelta = transcriptPhase2LockstepScrollDelta(applyDelta)
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
            // Refresh latch only when pad is stable (or after we recorded capture).
            if (delta == 0 || pendingDelta == 0) {
                prevWasAtTail = frame.wasAtTail
            }
        }
    }
}

private data class InsetPadFrame(
    val afterContentPadding: Int,
    val wasAtTail: Boolean,
    val scrolling: Boolean,
    val itemCount: Int,
)

private data class Phase2DemoRow(
    val id: String,
    val text: String,
    val mine: Boolean,
    val isUnreadAnchor: Boolean = false,
)

/**
 * Settings → Developer demo: exercises Phase 2 open / pin / lockstep / continuity
 * with sample rows. Not wired as production ChatScreen.
 */
@Composable
internal fun TranscriptPolicyHostDemo(onClose: () -> Unit) {
    val s = sonar
    var mode by remember { mutableStateOf(Phase2DemoMode.ShortRead) }
    var draft by remember { mutableStateOf("") }
    val seed = remember { phase2SeedMessages() }
    val rows = remember { mutableStateListOf<Phase2DemoRow>() }
    var olderPage by remember { mutableStateOf(0) }
    var isPrepending by remember { mutableStateOf(false) }
    var userScrolled by remember { mutableStateOf(false) }
    var didInitialScroll by remember { mutableStateOf(false) }
    var lastOpenAction by remember { mutableStateOf<TranscriptOpenAction>(TranscriptOpenAction.LiveEdge) }

    fun reloadForMode(next: Phase2DemoMode) {
        mode = next
        olderPage = 0
        didInitialScroll = false
        userScrolled = false
        val unread = if (next == Phase2DemoMode.UnreadOpen) 3 else 0
        val base = when (next) {
            Phase2DemoMode.ShortRead, Phase2DemoMode.UnreadOpen -> seed.takeLast(5)
            Phase2DemoMode.LongHistory -> seed
        }
        rows.clear()
        rows.addAll(phase2BuildFeed(base, unread))
        lastOpenAction = TranscriptScrollPolicy.resolveOpenAction(
            unreadAnchorId = rows.firstOrNull { it.isUnreadAnchor }?.id,
            unreadCountAtOpen = unread.toLong(),
        )
    }

    LaunchedEffect(Unit) { reloadForMode(Phase2DemoMode.ShortRead) }

    val unreadAnchorIndex = rows.indexOfFirst { it.isUnreadAnchor }
    val openAction = lastOpenAction
    val openIndex = transcriptPhase2OpenIndex(
        openAction = openAction,
        unreadAnchorIndex = unreadAnchorIndex,
        itemCount = rows.size,
    )
    val listState = rememberLazyListState(
        initialFirstVisibleItemIndex = openIndex.coerceAtLeast(0),
    )
    val currentRows by rememberUpdatedState(rows.toList())

    LaunchedEffect(listState) {
        listState.interactionSource.interactions.first { it is DragInteraction.Start }
        userScrolled = true
    }

    // Open driven by TranscriptOpenAction only (LiveEdge → tail pin; UnreadDivider → index).
    LaunchedEffect(mode, rows.size, openAction, unreadAnchorIndex) {
        if (rows.isEmpty()) return@LaunchedEffect
        withFrameNanos { }
        val target = transcriptPhase2OpenIndex(openAction, unreadAnchorIndex, rows.size)
        when (openAction) {
            TranscriptOpenAction.LiveEdge -> {
                listState.anchorTranscriptTail(target.coerceAtLeast(0), animate = false)
                didInitialScroll = true
            }
            TranscriptOpenAction.UnreadDivider,
            is TranscriptOpenAction.Jump,
            -> {
                if (target < 0) return@LaunchedEffect
                listState.scrollToItem(target)
                didInitialScroll = true
            }
        }
    }

    // loadOlder continuity: capture token → prepend → restore by anchorId + pixelOffset.
    LaunchedEffect(listState, mode) {
        snapshotFlow {
            didInitialScroll &&
                mode == Phase2DemoMode.LongHistory &&
                listState.layoutInfo.totalItemsCount > 0 &&
                listState.firstVisibleItemIndex <= 2
        }.distinctUntilChanged().filter { it }.collect {
            if (olderPage >= 2) return@collect
            val visible = listState.layoutInfo.visibleItemsInfo
            val anchor = visible.firstOrNull() ?: return@collect
            val anchorId = anchor.key?.toString()?.removePrefix("phase2:") ?: return@collect
            val continuity = TranscriptScrollPolicy.captureContinuityToken(
                anchorId = anchorId,
                pixelOffset = anchor.offset,
            )
            isPrepending = true
            olderPage += 1
            val older = phase2OlderPage(olderPage)
            val merged = (older + currentRows).distinctBy { it.id }
            rows.clear()
            rows.addAll(merged)
            withFrameNanos { }
            val newIndex = merged.indexOfFirst { it.id == continuity.anchorId }
            val offset = continuity.pixelOffset ?: 0
            if (newIndex >= 0) {
                listState.scrollToItem(newIndex, scrollOffset = -offset)
            }
            isPrepending = false
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(s.bg)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(
                Modifier.size(36.dp).clip(CircleShape).background(s.surface2).clickable(onClick = onClose),
                contentAlignment = Alignment.Center,
            ) { Text("←", color = s.text, fontSize = 18.sp) }
            Column(Modifier.weight(1f)) {
                Text(
                    "Transcript Phase 2 host",
                    color = s.text,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    "top-align · owned pad · Pin+Lockstep · open=${openAction::class.simpleName}",
                    color = s.text2,
                    fontSize = 12.sp,
                )
            }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(s.hairline))
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Phase2ModeChip("Short", mode == Phase2DemoMode.ShortRead) {
                reloadForMode(Phase2DemoMode.ShortRead)
            }
            Phase2ModeChip("Unread", mode == Phase2DemoMode.UnreadOpen) {
                reloadForMode(Phase2DemoMode.UnreadOpen)
            }
            Phase2ModeChip("Long", mode == Phase2DemoMode.LongHistory) {
                reloadForMode(Phase2DemoMode.LongHistory)
            }
        }
        Text(
            "Short: top-align above composer. Unread: divider @ open index. " +
                "Long: ContinuityToken on loadOlder. Focus composer for Lockstep vs Pin.",
            color = s.text3,
            fontSize = 11.sp,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
        )

        TranscriptPhase2HostScaffold(
            listState = listState,
            listKey = mode,
            isPrepending = { isPrepending },
            suppressPin = { unreadAnchorIndex >= 0 && !userScrolled },
            modifier = Modifier.weight(1f).fillMaxWidth(),
            listContent = { bottomInset ->
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    state = listState,
                    reverseLayout = false,
                    contentPadding = PaddingValues(
                        start = 14.dp,
                        end = 14.dp,
                        top = 10.dp,
                        bottom = bottomInset,
                    ),
                ) {
                    itemsIndexed(rows, key = { _, m -> "phase2:${m.id}" }) { _, m ->
                        Column(Modifier.fillMaxWidth()) {
                            if (m.isUnreadAnchor) {
                                Phase2UnreadDivider()
                            }
                            Phase2Bubble(m)
                        }
                    }
                }
            },
            bottomContent = {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 10.dp),
                    verticalAlignment = Alignment.Bottom,
                ) {
                    Box(
                        Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(19.dp))
                            .background(s.surface2)
                            .heightIn(min = 36.dp)
                            .padding(horizontal = 14.dp, vertical = 7.dp),
                        contentAlignment = Alignment.CenterStart,
                    ) {
                        if (draft.isEmpty()) {
                            Text("Phase 2 composer · IME owned pad", color = s.text3, fontSize = 16.sp)
                        }
                        BasicTextField(
                            value = draft,
                            onValueChange = { draft = it },
                            textStyle = TextStyle(color = s.text, fontSize = 16.sp),
                            cursorBrush = SolidColor(s.accent),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    Spacer(Modifier.width(8.dp))
                    Box(
                        Modifier
                            .size(34.dp)
                            .clip(CircleShape)
                            .background(if (draft.isNotBlank()) s.accentFill else s.surface2)
                            .clickable(enabled = draft.isNotBlank()) {
                                val text = draft.trim()
                                draft = ""
                                rows.add(
                                    Phase2DemoRow(
                                        id = "out-${rows.size}",
                                        text = text,
                                        mine = true,
                                    ),
                                )
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Text("↑", color = if (draft.isNotBlank()) s.onAccent else s.text3, fontSize = 16.sp)
                    }
                }
            },
        )
    }
}

private enum class Phase2DemoMode { ShortRead, UnreadOpen, LongHistory }

@Composable
private fun Phase2ModeChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val s = sonar
    Text(
        label,
        color = if (selected) s.onAccent else s.text2,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier
            .clip(RoundedCornerShape(14.dp))
            .background(if (selected) s.accentFill else s.surface2)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    )
}

@Composable
private fun Phase2UnreadDivider() {
    val s = sonar
    Row(
        Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.weight(1f).height(1.dp).background(s.text3.copy(alpha = 0.25f)))
        Text("Unread messages", color = s.text2, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold)
        Box(Modifier.weight(1f).height(1.dp).background(s.text3.copy(alpha = 0.25f)))
    }
}

@Composable
private fun Phase2Bubble(m: Phase2DemoRow) {
    val s = sonar
    Row(
        Modifier.fillMaxWidth().padding(vertical = 3.dp),
        horizontalArrangement = if (m.mine) Arrangement.End else Arrangement.Start,
    ) {
        Text(
            m.text,
            color = if (m.mine) s.onAccent else s.text,
            fontSize = 15.sp,
            modifier = Modifier
                .clip(RoundedCornerShape(16.dp))
                .background(if (m.mine) s.accentFill else s.surface2)
                .padding(horizontal = 12.dp, vertical = 8.dp),
        )
    }
}

private fun phase2SeedMessages(): List<Phase2DemoRow> {
    val out = ArrayList<Phase2DemoRow>(40)
    for (i in 0 until 40) {
        out += Phase2DemoRow(
            id = "seed-$i",
            text = if (i % 3 == 0) "Peer note #$i — longer line to exercise wrap." else "Msg #$i",
            mine = i % 2 == 0,
        )
    }
    return out
}

private fun phase2BuildFeed(base: List<Phase2DemoRow>, unreadFromNewest: Int): List<Phase2DemoRow> {
    if (unreadFromNewest <= 0 || base.isEmpty()) return base
    val anchorIdx = (base.size - unreadFromNewest).coerceAtLeast(0)
    return base.mapIndexed { i, row ->
        if (i == anchorIdx) row.copy(isUnreadAnchor = true) else row.copy(isUnreadAnchor = false)
    }
}

private fun phase2OlderPage(page: Int): List<Phase2DemoRow> {
    val start = page * 8
    return (0 until 8).map { n ->
        val id = start + n
        Phase2DemoRow(id = "older-$id", text = "Older page $page · #$id", mine = id % 2 == 0)
    }
}
