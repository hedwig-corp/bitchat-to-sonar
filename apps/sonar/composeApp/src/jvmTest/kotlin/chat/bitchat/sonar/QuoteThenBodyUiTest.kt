package chat.bitchat.sonar

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.runComposeUiTest
import androidx.compose.ui.unit.dp
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Compose mirror of R-035: quote+body must size to content under a tall
 * transcript-like viewport, never inherit the proposed height.
 */
@OptIn(ExperimentalTestApi::class)
class QuoteThenBodyUiTest {
    @Test
    fun quotedBubbleStaysBoundedInsideATallTranscript() = runComposeUiTest {
        setContent {
            Box(Modifier.fillMaxSize()) {
                QuoteThenBody(
                    quote = {
                        Text(
                            "quoted parent preview",
                            modifier = Modifier.testTag("quote"),
                        )
                    },
                    body = {
                        Text(
                            "reply body line",
                            modifier = Modifier.width(180.dp).testTag("body"),
                        )
                    },
                )
            }
        }

        val quoteH = onNodeWithTag("quote").getUnclippedBoundsInRoot().let { it.bottom - it.top }
        val bodyH = onNodeWithTag("body").getUnclippedBoundsInRoot().let { it.bottom - it.top }
        assertTrue(quoteH > 8.dp && quoteH < 80.dp)
        assertTrue(bodyH > 8.dp && bodyH < 80.dp)
        assertTrue(quoteH + bodyH < 200.dp)
    }
}
