package chat.hedwig.transcript.samples.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import chat.hedwig.transcript.TranscriptOpenAction
import chat.hedwig.transcript.TranscriptScrollPolicy
import chat.hedwig.transcript.compose.TranscriptHostScaffold
import chat.hedwig.transcript.compose.anchorTranscriptTail
import chat.hedwig.transcript.compose.transcriptOpenIndex

/**
 * Minimal sample: fake string rows + [TranscriptHostScaffold].
 * Not wired into Sonar — documents drop-in library use.
 */
@Composable
fun SampleTranscript(messages: List<String>) {
    val openAction = TranscriptScrollPolicy.resolveOpenAction(
        unreadAnchorId = null,
        unreadCountAtOpen = 0L,
    )
    val listState = rememberLazyListState(
        initialFirstVisibleItemIndex = transcriptOpenIndex(openAction, -1, messages.size),
    )

    TranscriptHostScaffold(
        listState = listState,
        listContent = { bottomInset ->
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                state = listState,
                contentPadding = PaddingValues(bottom = bottomInset, start = 12.dp, end = 12.dp),
            ) {
                itemsIndexed(messages) { index, text ->
                    Text(
                        text,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 4.dp)
                            .background(Color(0xFF2A2A2A))
                            .padding(12.dp),
                        color = Color.White,
                    )
                }
            }
        },
        bottomContent = {
            Text(
                "Composer placeholder",
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Color(0xFF1A1A1A))
                    .padding(16.dp),
                color = Color.LightGray,
            )
        },
    )
}
