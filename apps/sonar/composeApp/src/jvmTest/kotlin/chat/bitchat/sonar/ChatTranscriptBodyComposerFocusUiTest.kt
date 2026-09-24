package chat.bitchat.sonar

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.sp
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * QA-A10: the first message sent into a new chat closed the keyboard. The empty
 * state and the transcript each hosted the composer in their own branch, so the
 * feed turning non-empty disposed the focused field. [ChatTranscriptBody] is the
 * production call site in `App.kt::ChatScreen`; this drives a real send through
 * it and requires the SAME focused composer instance to survive.
 */
@OptIn(ExperimentalTestApi::class)
class ChatTranscriptBodyComposerFocusUiTest {

    @Test
    fun firstSendKeepsComposerFocusedInPhase2Host() = assertFirstSendKeepsComposer(phase2Host = true)

    @Test
    fun firstSendKeepsComposerFocusedInLegacyHost() = assertFirstSendKeepsComposer(phase2Host = false)

    private fun assertFirstSendKeepsComposer(phase2Host: Boolean) = runComposeUiTest {
        var sent by mutableStateOf(listOf<String>())
        var draft by mutableStateOf("")
        var composerDisposals = 0
        setContent {
            val listState = rememberLazyListState()
            Column(Modifier.fillMaxSize()) {
                ChatTranscriptBody(
                    feedEmpty = sent.isEmpty(),
                    phase2Host = phase2Host,
                    listState = listState,
                    listKey = "chat",
                    isPrepending = { false },
                    suppressPin = { false },
                    emptyState = { modifier -> Box(modifier) { Text("Say hi") } },
                    feedList = { modifier, _ ->
                        LazyColumn(modifier, state = listState) {
                            items(sent.size) { Text(sent[it]) }
                        }
                    },
                    composer = {
                        DisposableEffect(Unit) { onDispose { composerDisposals += 1 } }
                        MessageComposerTextField(
                            value = draft,
                            onValueChange = { draft = it },
                            textStyle = TextStyle(fontSize = 16.sp),
                            cursorBrush = SolidColor(Color.Black),
                            modifier = Modifier.testTag("composer"),
                            onSend = {
                                sent = sent + draft
                                draft = ""
                            },
                        )
                    },
                )
            }
        }

        onNodeWithText("Say hi").assertExists()
        onNodeWithTag("composer").performClick()
        onNodeWithTag("composer").performTextInput("first message")
        onNodeWithTag("composer").performKeyInput { pressKey(Key.Enter) }
        waitForIdle()

        onNodeWithText("first message").assertExists()
        onNodeWithTag("composer").assertIsFocused()
        runOnIdle {
            assertEquals(listOf("first message"), sent)
            assertEquals(0, composerDisposals, "the composer must not be recreated when the feed fills")
        }
    }
}
