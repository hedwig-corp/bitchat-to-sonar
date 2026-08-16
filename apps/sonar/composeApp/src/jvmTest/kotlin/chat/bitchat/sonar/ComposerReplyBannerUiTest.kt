package chat.bitchat.sonar

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.unit.dp
import kotlin.test.Test
import kotlin.test.assertTrue

@OptIn(ExperimentalTestApi::class)
class ComposerReplyBannerUiTest {
    @Test
    fun replyComposerStaysBoundedInsideATallTranscript() = runComposeUiTest {
        setContent {
            Box(Modifier.fillMaxSize()) {
                ComposerReplyBanner(
                    reply = SonarReplyRef(
                        parentId = "cd".repeat(32),
                        parentNpub = "npub1peer",
                        author = "Vincenzo-Mac",
                        preview = "https://router.hedwig.sh",
                    ),
                    onCancel = {},
                    modifier = Modifier.testTag("reply-composer"),
                )
            }
        }

        val bounds = onNodeWithTag("reply-composer").getUnclippedBoundsInRoot()
        val height = bounds.bottom - bounds.top
        assertTrue(height > 40.dp)
        assertTrue(height < 100.dp)
    }
}
