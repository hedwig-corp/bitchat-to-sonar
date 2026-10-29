package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ComposeUiTest
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.click
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import chat.bitchat.sonar.ui.SonarTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Tapping a link (or a mention) in a text bubble did nothing on Android. Since
 * #587 the bubble sits inside [ReplyDecorated], whose `combinedClickable`
 * consumes every down right after the bubble's Main pass, and the bubble's tap
 * handler checked `down.isConsumed` only after the up. The same move turned the
 * text layout into a parameter, which a running gesture loop keeps after the
 * bubble reflows. Drives the production bubble, alone and inside the row.
 */
@OptIn(ExperimentalTestApi::class)
class MessageLinkTapUiTest {

    @AfterTest
    fun restore() = DesktopEnv.useTestRoot(null)

    private class RecordingUriHandler : UriHandler {
        val opened = mutableListOf<String>()
        override fun openUri(uri: String) {
            opened += uri
        }
    }

    private fun message(content: String) = SonarMsg(
        id = "ab".repeat(32),
        senderNpub = "cd".repeat(32),
        content = content,
        mine = false,
        tsSecs = 1_700_000_000,
        viaInternet = true,
    )

    /** Pins the live layout read. The gesture loop outlives a reflow (rotation,
     *  a resized window), so it must not resolve taps against the layout it
     *  started with. */
    @Test
    fun aLinkStillOpensAfterTheBubbleReflows() = runComposeUiTest {
        val uris = RecordingUriHandler()
        val content = "plain words here then https://example.com/a"
        var maxWidth by mutableStateOf(Dp.Infinity)
        setContent {
            SonarTheme {
                CompositionLocalProvider(LocalUriHandler provides uris) {
                    MessageBubble(message(content), maxBubbleWidth = maxWidth)
                }
            }
        }
        val text = onNodeWithText("plain words", substring = true, useUnmergedTree = true)
        // Starts the gesture loop on the one-line layout, on plain text.
        text.performTouchInput { click(Offset(8f, centerY)) }
        runOnIdle { assertEquals(emptyList(), uris.opened) }

        runOnIdle { maxWidth = 160.dp }
        waitForIdle()
        val layouts = mutableListOf<TextLayoutResult>()
        text.fetchSemanticsNode().config[SemanticsActions.GetTextLayoutResult].action?.invoke(layouts)
        val linkStart = layouts.single().getBoundingBox(content.indexOf("https://"))
        assertTrue(linkStart.top > 0f, "the link must wrap off the first line")
        text.performTouchInput { click(linkStart.center) }
        runOnIdle { assertEquals(listOf("https://example.com/a"), uris.opened) }
    }

    /** Pins the consumption check: the transcript row's own tap detector
     *  consumes every down the bubble sees. */
    @Test
    fun tappingALinkInsideTheTranscriptRowOpensIt() = runComposeUiTest {
        val uris = RecordingUriHandler()
        val m = message("www.example.com")
        setTranscriptRow(m, uris) { MessageBubble(m) }
        onNodeWithText("www.example.com", substring = true, useUnmergedTree = true)
            .performTouchInput { click(Offset(8f, centerY)) }
        runOnIdle { assertEquals(listOf("https://www.example.com"), uris.opened) }
    }

    @Test
    fun tappingAMentionInsideTheTranscriptRowOpensTheMember() = runComposeUiTest {
        val member = "npub1" + "q".repeat(58)
        var tapped: String? = null
        val m = message("@alice hello")
        val mentions = MentionInfo(
            listOf(ResolvedMention(SonarMentionSpan(0, 6, "alice", null), member)),
            mentionsMe = false,
        )
        setTranscriptRow(m, RecordingUriHandler()) {
            MessageBubble(m, mentions = mentions, onMentionTap = { tapped = it })
        }
        onNodeWithText("@alice hello", substring = true, useUnmergedTree = true)
            .performTouchInput { click(Offset(8f, centerY)) }
        runOnIdle { assertEquals(member, tapped) }
    }

    /** A long press belongs to the row's message menu, never the link. */
    @Test
    fun longPressingALinkOpensTheMenuNotTheLink() = runComposeUiTest {
        val uris = RecordingUriHandler()
        val m = message("https://example.com/a")
        setTranscriptRow(m, uris) { MessageBubble(m) }
        onNodeWithText("https://example.com/a", substring = true, useUnmergedTree = true)
            .performTouchInput { longClick(Offset(8f, centerY)) }
        waitForIdle()
        onNodeWithText("Reply").assertExists()
        runOnIdle { assertEquals(emptyList(), uris.opened) }
    }

    private fun ComposeUiTest.setTranscriptRow(
        m: SonarMsg,
        uris: UriHandler,
        bubble: @Composable () -> Unit,
    ) {
        DesktopEnv.useTestRoot(kotlin.io.path.createTempDirectory("sonar-linktap").toFile())
        val state = SonarAppState(CoroutineScope(Job()))
        setContent {
            SonarTheme {
                CompositionLocalProvider(LocalUriHandler provides uris) {
                    ReplyDecorated(
                        m = m,
                        chatId = "ef".repeat(16),
                        state = state,
                        isGroup = false,
                        peerName = "Peer",
                    ) { bubble() }
                }
            }
        }
    }
}
