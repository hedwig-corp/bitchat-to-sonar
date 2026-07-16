package chat.bitchat.sonar

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.ComposeUiTest
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Integration cover for the pinner's Compose wiring — the part the pure
 * [TranscriptTailPinnerTest] cannot reach: that the snapshotFlow observes real
 * layout frames and re-anchors the tail when the viewport shrinks (the IME
 * opening) or a row grows (media decoding). Without the pinning these tests
 * fail, which is the bug users reported.
 */
@OptIn(ExperimentalTestApi::class)
class TranscriptTailPinningUiTest {

    private fun LazyListState.tailIsVisible(): Boolean {
        val info = layoutInfo
        val last = info.visibleItemsInfo.lastOrNull() ?: return false
        return last.index == info.totalItemsCount - 1 &&
            last.offset + last.size <= info.viewportEndOffset
    }

    /** Reach the tail the way a finger does — programmatic instant scrolls can
     *  complete inside one frame, which no real gesture does. */
    private fun ComposeUiTest.scrollToTail(listState: LazyListState) {
        repeat(12) {
            if (listState.tailIsVisible()) return
            onNodeWithTag("list").performTouchInput { swipeUp() }
            waitForIdle()
        }
    }

    @Test
    fun keyboard_shrink_keeps_the_newest_row_visible() = runComposeUiTest {
        var viewport by mutableStateOf(400.dp)
        lateinit var listState: LazyListState
        setContent {
            listState = rememberLazyListState()
            TranscriptTailPinning(listState, key = "chat")
            LazyColumn(Modifier.height(viewport).testTag("list"), state = listState) {
                items((0 until 40).toList()) { i ->
                    Box(Modifier.size(width = 100.dp, height = 40.dp).testTag("row$i"))
                }
            }
        }
        scrollToTail(listState)
        assertTrue(listState.tailIsVisible(), "precondition: reader starts at the tail")

        // The IME opening: same rows, smaller viewport.
        runOnIdle { viewport = 180.dp }
        waitForIdle()
        assertTrue(
            listState.tailIsVisible(),
            "newest row must survive the viewport shrink (was index " +
                "${listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index} of " +
                "${listState.layoutInfo.totalItemsCount})",
        )
    }

    @Test
    fun row_growth_at_the_tail_keeps_the_newest_row_visible() = runComposeUiTest {
        // A media skeleton swapping to the taller decoded image.
        var tailHeight by mutableStateOf(40.dp)
        lateinit var listState: LazyListState
        setContent {
            listState = rememberLazyListState()
            TranscriptTailPinning(listState, key = "chat")
            LazyColumn(Modifier.height(400.dp).testTag("list"), state = listState) {
                items((0 until 40).toList()) { i ->
                    val h: Dp = if (i == 39) tailHeight else 40.dp
                    Box(Modifier.size(width = 100.dp, height = h).testTag("row$i"))
                }
            }
        }
        scrollToTail(listState)
        assertTrue(listState.tailIsVisible(), "precondition: reader starts at the tail")

        runOnIdle { tailHeight = 260.dp }
        waitForIdle()
        assertTrue(listState.tailIsVisible(), "newest row must survive tail-row growth")
    }

    @Test
    fun reader_in_history_is_not_yanked_to_the_tail_by_a_shrink() = runComposeUiTest {
        var viewport by mutableStateOf(400.dp)
        lateinit var listState: LazyListState
        setContent {
            listState = rememberLazyListState()
            TranscriptTailPinning(listState, key = "chat")
            LazyColumn(Modifier.height(viewport).testTag("list"), state = listState) {
                items((0 until 40).toList()) { i ->
                    Box(Modifier.size(width = 100.dp, height = 40.dp).testTag("row$i"))
                }
            }
        }
        // Reader starts at the tail, then swipes back into history.
        scrollToTail(listState)
        repeat(4) {
            onNodeWithTag("list").performTouchInput { swipeDown() }
            waitForIdle()
        }
        val before = listState.firstVisibleItemIndex
        assertTrue(!listState.tailIsVisible(), "precondition: reader left the tail")

        runOnIdle { viewport = 180.dp }
        waitForIdle()
        assertTrue(
            !listState.tailIsVisible() && listState.firstVisibleItemIndex <= before + 1,
            "reading history must not be yanked to the bottom (index " +
                "$before -> ${listState.firstVisibleItemIndex})",
        )
    }
}
