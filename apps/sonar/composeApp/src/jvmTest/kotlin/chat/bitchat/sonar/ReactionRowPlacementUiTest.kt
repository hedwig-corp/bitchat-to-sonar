package chat.bitchat.sonar

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.unit.dp
import chat.bitchat.sonar.ui.SonarTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Reaction chips sit UNDER the bubble, tucked 7 dp into its bottom edge
 * (design `.bc-reacts { margin-top: -7px }`, as on iOS). They were drawn as an
 * overlay aligned to the bubble's bottom and shifted up, which covered the
 * last line of text and the time/delivery marker. Drives the production
 * `ReplyDecorated` wrapper that every chat bubble goes through.
 */
@OptIn(ExperimentalTestApi::class, ExperimentalFoundationApi::class)
class ReactionRowPlacementUiTest {

    @AfterTest
    fun restore() = DesktopEnv.useTestRoot(null)

    @Test
    fun chipsSitBelowTheBubbleInsteadOfCoveringIt() = assertChipPlacement(tuck = true)

    /** A row ending in "Sent · internet" must not have the chips tucked into
     *  that footer text. */
    @Test
    fun chipsDoNotCoverADeliveryFooter() = assertChipPlacement(tuck = false)

    /**
     * A photo (or sticker, or file chip) owns its tap — it opens the viewer —
     * and its `clickable` consumed the press, so long-pressing it never opened
     * the message menu: on Android a photo could not get a reaction at all.
     * Content like that takes the row's menu opener from
     * [LocalMessageLongPress].
     */
    @Test
    fun longPressOnContentThatOwnsItsTapOpensTheReactionRow() = runComposeUiTest {
        DesktopEnv.useTestRoot(kotlin.io.path.createTempDirectory("sonar-reactmenu").toFile())
        val state = SonarAppState(CoroutineScope(Job()))
        var opens = 0
        val message = SonarMsg(
            id = "ab".repeat(32),
            senderNpub = "npub1" + "q".repeat(58),
            content = "",
            mine = false,
            tsSecs = 1_700_000_000,
            viaInternet = true,
        )
        setContent {
            SonarTheme {
                ReplyDecorated(
                    m = message,
                    chatId = "ef".repeat(16),
                    state = state,
                    isGroup = false,
                    peerName = "Peer",
                ) {
                    Box(
                        Modifier.testTag("photo").width(160.dp).height(120.dp)
                            .combinedClickable(onLongClick = LocalMessageLongPress.current) { opens++ },
                    )
                }
            }
        }
        onNodeWithTag("photo", useUnmergedTree = true).performTouchInput { longClick() }
        waitForIdle()
        onNodeWithText("😮").assertExists()
        onNodeWithText("Reply").assertExists()
        runOnIdle { assertEquals(0, opens, "a long-press must not also open the viewer") }
    }

    private fun assertChipPlacement(tuck: Boolean) = runComposeUiTest {
        DesktopEnv.useTestRoot(kotlin.io.path.createTempDirectory("sonar-reacttest").toFile())
        val state = SonarAppState(CoroutineScope(Job()))
        val message = SonarMsg(
            id = "ab".repeat(32),
            senderNpub = "cd".repeat(32),
            content = "hello",
            mine = false,
            tsSecs = 1_700_000_000,
            viaInternet = true,
            reactions = listOf(SonarReactionTally(emoji = "🔥", count = 2, mine = false)),
        )
        setContent {
            SonarTheme {
                ReplyDecorated(
                    m = message,
                    chatId = "ef".repeat(16),
                    state = state,
                    isGroup = false,
                    peerName = "Peer",
                    chipsTuckUnderBubble = tuck,
                ) {
                    Box(Modifier.testTag("bubble").width(160.dp).height(48.dp)) { Text("hello") }
                }
            }
        }
        waitForIdle()

        val bubble = onNodeWithTag("bubble", useUnmergedTree = true).getBoundsInRoot()
        val chip = onNodeWithText("🔥", useUnmergedTree = true).getBoundsInRoot()
        val allowedOverlap = if (tuck) 7.dp else 0.dp
        assertTrue(
            chip.top >= bubble.bottom - allowedOverlap,
            "chip top ${chip.top} must not rise more than $allowedOverlap into a bubble ending at ${bubble.bottom}",
        )
        assertTrue(
            chip.top < bubble.bottom + 7.dp,
            "chip top ${chip.top} must stay attached to the bubble ending at ${bubble.bottom}",
        )
    }
}
