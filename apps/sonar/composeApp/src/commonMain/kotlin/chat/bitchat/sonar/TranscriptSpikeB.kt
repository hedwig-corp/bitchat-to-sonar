package chat.bitchat.sonar

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.bitchat.sonar.ui.sonar
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first

/**
 * Spike B — Signal-Android reverseLayout / stack-from-end short-feed model.
 *
 * Production default is OFF. Distinct from Spike A (top-aligned Signal-iOS).
 *
 * Enable (Debug only):
 * - Flip [SonarTranscriptSpikeB.FORCE_ENABLE_IN_DEBUG] to true while iterating, or
 * - Desktop: `./gradlew :composeApp:run -Dsonar.transcript.spike.b=1`
 * - Android: `adb shell setprop debug.sonar.transcript.spike.b 1` is not read here;
 *   use FORCE or pass `-Psonar.transcript.spike.b=1` via [sonarTranscriptSpikeBEnabled].
 *
 * Open the host from Settings → Developer (Debug) → "Transcript Spike B".
 */
internal object SonarTranscriptSpikeB {
    /**
     * Local iteration latch. Keep false in shared WIP so production Debug builds
     * stay on the default transcript path unless a property/settings entry opens
     * the isolated host.
     */
    const val FORCE_ENABLE_IN_DEBUG: Boolean = false

    const val PROPERTY_KEY: String = "sonar.transcript.spike.b"
}

/** Platform Debug bit + optional process property. Release always false. */
internal expect val sonarTranscriptSpikeBEnabled: Boolean

/** Whether Settings may show the Spike B entry (Debug builds only). */
internal expect val sonarTranscriptSpikeBEntryVisible: Boolean

internal data class SpikeBMessage(
    val id: String,
    val text: String,
    val mine: Boolean,
    /** True when this row is the frozen unread-open divider target. */
    val isUnreadAnchor: Boolean = false,
)

internal enum class SpikeBTailPin { None, Snap, Animate }

/**
 * One frame of reverseLayout tail state. Newest sits at index 0 (bottom).
 * [tailFullyVisible] means the newest row's bottom edge is in the viewport.
 */
internal data class SpikeBTailFrame(
    val itemCount: Int,
    val viewportHeight: Int,
    val tailFullyVisible: Boolean,
    val scrolling: Boolean,
    val prepending: Boolean,
)

/**
 * R-009-shaped latch adapted for reverseLayout coordinates: pin tracks index 0
 * (newest / visual bottom), not lastIndex.
 */
internal class TranscriptTailPinnerSpikeB {
    private var wasPinned = false
    private var lastCount = -1

    fun onFrame(frame: SpikeBTailFrame): SpikeBTailPin {
        val countChanged = frame.itemCount != lastCount
        lastCount = frame.itemCount
        return when {
            frame.prepending || frame.scrolling -> {
                wasPinned = frame.tailFullyVisible
                SpikeBTailPin.None
            }
            frame.tailFullyVisible -> {
                wasPinned = true
                SpikeBTailPin.None
            }
            wasPinned && frame.itemCount > 0 ->
                if (countChanged) SpikeBTailPin.Animate else SpikeBTailPin.Snap
            else -> SpikeBTailPin.None
        }
    }
}

/**
 * reverseLayout LazyColumn: index 0 is at the visual bottom (newest).
 * Load-older triggers when the reader approaches the visual top — high indices.
 */
internal fun spikeBShouldLoadOlder(
    didInitialScroll: Boolean,
    totalItems: Int,
    highestVisibleIndex: Int,
    edgeSlop: Int = 2,
): Boolean {
    if (!didInitialScroll || totalItems <= 0) return false
    return highestVisibleIndex >= (totalItems - 1 - edgeSlop).coerceAtLeast(0)
}

/** Fully-read opens land on newest (index 0). Unread opens land on the divider row. */
internal fun spikeBInitialScrollIndex(
    unreadAnchorIndex: Int,
    itemCount: Int,
): Int {
    if (itemCount <= 0) return 0
    if (unreadAnchorIndex in 0 until itemCount) return unreadAnchorIndex
    return 0
}

/**
 * Build a reverse-layout feed: index 0 = newest (bottom). [unreadFromNewest]
 * counts non-mine rows from the newest edge, Signal-style.
 */
internal fun spikeBBuildReverseFeed(
    chronologicalOldestFirst: List<SpikeBMessage>,
    unreadFromNewest: Int,
): List<SpikeBMessage> {
    if (chronologicalOldestFirst.isEmpty()) return emptyList()
    val newestFirst = chronologicalOldestFirst.asReversed()
    if (unreadFromNewest <= 0) return newestFirst.map { it.copy(isUnreadAnchor = false) }
    var remaining = unreadFromNewest
    var anchorId: String? = null
    for (m in newestFirst) {
        if (!m.mine) {
            remaining -= 1
            if (remaining == 0) {
                anchorId = m.id
                break
            }
        }
    }
    return newestFirst.map { it.copy(isUnreadAnchor = it.id == anchorId) }
}

internal suspend fun LazyListState.anchorSpikeBTail(animate: Boolean) {
    if (layoutInfo.totalItemsCount <= 0) return
    // Newest is index 0 at the bottom under reverseLayout.
    if (animate) animateScrollToItem(0) else scrollToItem(0)
}

@Composable
internal fun TranscriptTailPinningSpikeB(
    listState: LazyListState,
    key: Any? = null,
    isPrepending: () -> Boolean = { false },
    suppressPin: () -> Boolean = { false },
) {
    LaunchedEffect(key, listState) {
        val pinner = TranscriptTailPinnerSpikeB()
        snapshotFlow {
            val info = listState.layoutInfo
            val newest = info.visibleItemsInfo.firstOrNull { it.index == 0 }
            val tailFullyVisible = newest != null &&
                newest.offset >= info.viewportStartOffset &&
                newest.offset + newest.size <= info.viewportEndOffset
            SpikeBTailFrame(
                itemCount = info.totalItemsCount,
                viewportHeight = info.viewportSize.height,
                tailFullyVisible = tailFullyVisible,
                scrolling = listState.isScrollInProgress,
                prepending = isPrepending() || suppressPin(),
            )
        }.distinctUntilChanged().collect { frame ->
            val pin = pinner.onFrame(frame)
            if (pin == SpikeBTailPin.None) return@collect
            withFrameNanos { }
            listState.anchorSpikeBTail(animate = pin == SpikeBTailPin.Animate)
        }
    }
}

/** Isolated Spike B host — reverse LazyColumn + IME-attached composer stub. */
@Composable
fun TranscriptSpikeBDemo(onClose: () -> Unit) {
    val s = sonar
    var mode by remember { mutableStateOf(SpikeBDemoMode.ShortRead) }
    var draft by remember { mutableStateOf("") }
    val seed = remember { spikeBSeedMessages() }
    val rows = remember { mutableStateListOf<SpikeBMessage>() }
    var olderPage by remember { mutableStateOf(0) }
    var isPrepending by remember { mutableStateOf(false) }
    var userScrolled by remember { mutableStateOf(false) }
    var didInitialScroll by remember { mutableStateOf(false) }

    fun reloadForMode(next: SpikeBDemoMode) {
        mode = next
        olderPage = 0
        didInitialScroll = false
        userScrolled = false
        val unread = if (next == SpikeBDemoMode.UnreadOpen) 3 else 0
        val base = when (next) {
            SpikeBDemoMode.ShortRead, SpikeBDemoMode.UnreadOpen -> seed.takeLast(5)
            SpikeBDemoMode.LongHistory -> seed
        }
        rows.clear()
        rows.addAll(spikeBBuildReverseFeed(base, unread))
    }

    LaunchedEffect(Unit) { reloadForMode(SpikeBDemoMode.ShortRead) }

    val unreadAnchorIndex = rows.indexOfFirst { it.isUnreadAnchor }
    val listState = rememberLazyListState(
        initialFirstVisibleItemIndex = spikeBInitialScrollIndex(unreadAnchorIndex, rows.size),
    )
    val currentRows by rememberUpdatedState(rows.toList())

    LaunchedEffect(listState) {
        listState.interactionSource.interactions.first { it is DragInteraction.Start }
        userScrolled = true
    }

    LaunchedEffect(mode, rows.size, unreadAnchorIndex) {
        if (rows.isEmpty()) return@LaunchedEffect
        withFrameNanos { }
        val target = spikeBInitialScrollIndex(unreadAnchorIndex, rows.size)
        listState.scrollToItem(target)
        didInitialScroll = true
    }

    TranscriptTailPinningSpikeB(
        listState = listState,
        key = mode,
        isPrepending = { isPrepending },
        suppressPin = { unreadAnchorIndex >= 0 && !userScrolled },
    )

    // Pagination: visual top = high indices under reverseLayout.
    LaunchedEffect(listState, mode) {
        snapshotFlow {
            val info = listState.layoutInfo
            val highest = info.visibleItemsInfo.maxOfOrNull { it.index } ?: -1
            spikeBShouldLoadOlder(didInitialScroll, info.totalItemsCount, highest)
        }.distinctUntilChanged().filter { it }.collect {
            if (mode == SpikeBDemoMode.ShortRead || mode == SpikeBDemoMode.UnreadOpen) return@collect
            if (olderPage >= 2) return@collect
            val anchor = listState.layoutInfo.visibleItemsInfo.maxByOrNull { it.index } ?: return@collect
            val anchorId = anchor.key?.toString()?.removePrefix("spike-b:") ?: return@collect
            val anchorOffset = anchor.offset
            isPrepending = true
            olderPage += 1
            val older = spikeBOlderPage(olderPage)
            val mergedChrono = (older + currentRows.asReversed()).distinctBy { it.id }
            val next = spikeBBuildReverseFeed(mergedChrono, unreadFromNewest = 0)
            rows.clear()
            rows.addAll(next)
            withFrameNanos { }
            val newIndex = next.indexOfFirst { it.id == anchorId }
            if (newIndex >= 0) {
                listState.scrollToItem(newIndex, scrollOffset = anchorOffset)
            }
            isPrepending = false
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(s.bg)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding(),
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
                Text("Transcript Spike B", color = s.text, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                Text(
                    "reverseLayout · newest@0 · stack-from-end",
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
            SpikeBModeChip("Short", mode == SpikeBDemoMode.ShortRead) {
                reloadForMode(SpikeBDemoMode.ShortRead)
            }
            SpikeBModeChip("Unread", mode == SpikeBDemoMode.UnreadOpen) {
                reloadForMode(SpikeBDemoMode.UnreadOpen)
            }
            SpikeBModeChip("Long", mode == SpikeBDemoMode.LongHistory) {
                reloadForMode(SpikeBDemoMode.LongHistory)
            }
        }
        Text(
            "Short: messages sit on composer (no empty band). Unread: divider at viewport top. " +
                "Long: load-older toward visual top.",
            color = s.text3,
            fontSize = 11.sp,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
        )

        Box(Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                state = listState,
                reverseLayout = true,
                contentPadding = PaddingValues(start = 14.dp, end = 14.dp, top = 10.dp, bottom = 6.dp),
            ) {
                itemsIndexed(rows, key = { _, m -> "spike-b:${m.id}" }) { _, m ->
                    // Item top faces visual top (older). Divider above the unread bubble.
                    Column(Modifier.fillMaxWidth()) {
                        if (m.isUnreadAnchor) {
                            SpikeBUnreadDivider()
                        }
                        SpikeBBubble(m)
                    }
                }
            }
        }

        // Composer is a sibling below the reverse list; imePadding on the column
        // keeps it keyboard-attached (owned inset = 0 inside the list).
        Row(
            Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 10.dp),
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
                    Text("Spike B composer · IME attached", color = s.text3, fontSize = 16.sp)
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
                        rows.add(0, SpikeBMessage(id = "out-${rows.size}", text = text, mine = true))
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text("↑", color = if (draft.isNotBlank()) s.onAccent else s.text3, fontSize = 16.sp)
            }
        }
    }
}

private enum class SpikeBDemoMode { ShortRead, UnreadOpen, LongHistory }

@Composable
private fun SpikeBModeChip(label: String, selected: Boolean, onClick: () -> Unit) {
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
private fun SpikeBUnreadDivider() {
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
private fun SpikeBBubble(m: SpikeBMessage) {
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

private fun spikeBSeedMessages(): List<SpikeBMessage> {
    val out = ArrayList<SpikeBMessage>(40)
    for (i in 0 until 40) {
        out += SpikeBMessage(
            id = "seed-$i",
            text = if (i % 3 == 0) "Peer note #$i — longer line to exercise wrap." else "Msg #$i",
            mine = i % 2 == 0,
        )
    }
    return out
}

private fun spikeBOlderPage(page: Int): List<SpikeBMessage> {
    val base = page * 20
    return (0 until 20).map { i ->
        val n = base + i
        SpikeBMessage(id = "older-$n", text = "Older page $page · #$n", mine = n % 2 == 0)
    }
}
