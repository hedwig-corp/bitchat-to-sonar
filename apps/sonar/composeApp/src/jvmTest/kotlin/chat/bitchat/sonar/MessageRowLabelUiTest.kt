package chat.bitchat.sonar

import androidx.compose.material3.Text
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.runComposeUiTest
import chat.bitchat.sonar.ui.SonarTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * QA-043: the transcript row is the node that holds the long-press menu and
 * the Reply/Copy actions, and it had no label of its own: it borrowed one from
 * its bubble. When the list clipped the bubble off-screen while a sliver of
 * the row stayed visible, TalkBack and the accessibility sweep found an
 * actionable node with nothing to read. Drives the production `ReplyDecorated`
 * wrapper every chat bubble goes through.
 */
@OptIn(ExperimentalTestApi::class)
class MessageRowLabelUiTest {

    @AfterTest
    fun restore() = DesktopEnv.useTestRoot(null)

    private fun rowLabel(message: SonarMsg, isGroup: Boolean = false): String = runComposeUiTestFor {
        DesktopEnv.useTestRoot(kotlin.io.path.createTempDirectory("sonar-rowlabel").toFile())
        val state = SonarAppState(CoroutineScope(Job()))
        setContent {
            SonarTheme {
                ReplyDecorated(
                    m = message,
                    chatId = "ef".repeat(16),
                    state = state,
                    isGroup = isGroup,
                    peerName = "Peer",
                ) { Text(message.content) }
            }
        }
        val rows = onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsActions.OnLongClick), useUnmergedTree = true)
            .fetchSemanticsNodes()
        assertEquals(1, rows.size, "exactly one actionable row")
        rows.single().config.getOrNull(SemanticsProperties.ContentDescription)?.joinToString(", ").orEmpty()
    }

    private fun <T> runComposeUiTestFor(block: androidx.compose.ui.test.ComposeUiTest.() -> T): T {
        var out: T? = null
        runComposeUiTest { out = block() }
        @Suppress("UNCHECKED_CAST")
        return out as T
    }

    @Test
    fun anIncomingRowReadsItsMessageAndTime() {
        val label = rowLabel(
            SonarMsg(
                id = "ab".repeat(32),
                senderNpub = "npub1" + "q".repeat(58),
                content = "see you at the station",
                mine = false,
                tsSecs = 1_700_000_000,
                viaInternet = true,
            ),
        )
        assertTrue("see you at the station" in label, "row label: '$label'")
        assertTrue(SonarClock.hourMinute(1_700_000_000) in label, "row label: '$label'")
    }

    @Test
    fun anOwnRowAlsoReadsItsDeliveryState() {
        val label = rowLabel(
            SonarMsg(
                id = "cd".repeat(32),
                senderNpub = "npub1" + "p".repeat(58),
                content = "on my way",
                mine = true,
                tsSecs = 1_700_000_100,
                viaInternet = true,
                state = "sent",
            ),
        )
        assertTrue("on my way" in label && "Sent" in label, "row label: '$label'")
    }

    @Test
    fun theLabelSkipsWhatIsMissing() {
        assertEquals("hi, 09:41", sonarMessageRowLabel(author = null, body = "hi", time = "09:41", delivery = null))
        assertEquals(
            "Ada, Photo, 09:41, Sent",
            sonarMessageRowLabel(author = " Ada ", body = "Photo", time = "09:41", delivery = "Sent"),
        )
    }
}
