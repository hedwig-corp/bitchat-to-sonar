package chat.bitchat.sonar

import androidx.compose.ui.text.buildAnnotatedString
import kotlin.test.Test
import kotlin.test.assertTrue

class MessageBubbleMetaInlineContentTest {
    @Test
    fun bubbleMetaInlineContentSurvivesComposeNonEmptyAlternateText() {
        // #587 passed "" into appendInlineContent; Compose throws
        // IllegalArgumentException("alternateText can't be an empty string.")
        // and Android crashes on chat open (MessageBubble).
        val withBody = buildAnnotatedString {
            append("hello")
            appendBubbleMetaInlineContent()
        }
        assertTrue(withBody.length > 5)
        val emptyBody = buildAnnotatedString {
            appendBubbleMetaInlineContent()
        }
        assertTrue(emptyBody.isNotEmpty())
    }
}
