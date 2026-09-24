package chat.bitchat.sonar

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The chat body under the header banners: the transcript (or its empty state)
 * above ONE composer slot.
 *
 * [composer] must occupy the same composition slot whether or not the feed is
 * empty. When the empty state and the transcript each called the composer from
 * their own branch, the first message sent into a new chat flipped the branch,
 * disposed the focused text field, and closed the keyboard — every new
 * conversation lost the keyboard after its first send (QA-A10). The empty state
 * therefore renders INSIDE the Phase-2 host's list slot, padded by the owned
 * bottom inset so the overlaid composer never covers it.
 */
@Composable
internal fun ColumnScope.ChatTranscriptBody(
    feedEmpty: Boolean,
    phase2Host: Boolean,
    listState: LazyListState,
    listKey: Any?,
    isPrepending: () -> Boolean,
    suppressPin: () -> Boolean,
    emptyState: @Composable (Modifier) -> Unit,
    feedList: @Composable (modifier: Modifier, bottomInset: Dp) -> Unit,
    composer: @Composable () -> Unit,
) {
    if (phase2Host) {
        // Phase 2: owned pad + IME overlay; Pin+Lockstep; top-align (not reverseLayout).
        TranscriptPhase2HostScaffold(
            listState = listState,
            listKey = listKey,
            isPrepending = isPrepending,
            suppressPin = suppressPin,
            modifier = Modifier.weight(1f).fillMaxWidth(),
            listContent = { bottomInset ->
                if (feedEmpty) {
                    emptyState(Modifier.fillMaxSize().padding(bottom = bottomInset))
                } else {
                    feedList(Modifier.fillMaxSize(), bottomInset)
                }
            },
            bottomContent = composer,
        )
    } else {
        if (feedEmpty) {
            emptyState(Modifier.weight(1f).fillMaxWidth())
        } else {
            feedList(Modifier.weight(1f).fillMaxWidth(), 10.dp)
        }
        composer()
    }
}
