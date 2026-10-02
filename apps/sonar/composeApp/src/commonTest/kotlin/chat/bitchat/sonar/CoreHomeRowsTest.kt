package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Home renders core's screen model (`conversation_list`): the wording of its
 *  semantic previews, and the text-free startup snapshot of its rows. */
class CoreHomeRowsTest {
    private fun row(id: String, preview: SonarConversationPreview, title: String? = "Sara") =
        SonarConversationListRow(
            conversationId = id,
            kind = SonarConversationListKind.Direct,
            groupIds = listOf(id, "${id}b"),
            counterpartHex = "ab".repeat(32),
            name = "",
            title = title,
            preview = preview,
            latestContent = "secret text",
            latestSenderHex = "cd".repeat(32),
            latestAtSecs = 1_700_000_000,
            latestMine = false,
            latestGroupId = id,
            messageCount = 3,
            unreadCount = 2,
            version = 7,
        )

    @Test
    fun previewsAreWordedTheSameAsOnIos() {
        assertNull(conversationPreviewText(SonarConversationPreview.Empty))
        assertEquals("hi", conversationPreviewText(SonarConversationPreview.Text("hi")))
        assertEquals("Photo", conversationPreviewText(SonarConversationPreview.Photos(1)))
        assertEquals("3 photos", conversationPreviewText(SonarConversationPreview.Photos(3)))
        assertEquals("File", conversationPreviewText(SonarConversationPreview.File("")))
        assertEquals("a.pdf", conversationPreviewText(SonarConversationPreview.File("a.pdf")))
        assertEquals("Voice call", conversationPreviewText(SonarConversationPreview.VoiceCall))
        assertEquals("₿ Payment", conversationPreviewText(SonarConversationPreview.Payment))
    }

    @Test
    fun theSnapshotKeepsRowsButNeverMessageText() {
        val rows = listOf(
            row("g1", SonarConversationPreview.Text("secret text")),
            row("g2", SonarConversationPreview.Photos(2), title = null),
            row("g3", SonarConversationPreview.File("contract.pdf")),
        )
        val blob = encodeConversationRowSnapshot(rows)
        assertTrue("secret" !in blob && "contract" !in blob, "no message text in the plain blob")
        val back = decodeConversationRowSnapshot(blob)
        assertEquals(listOf("g1", "g2", "g3"), back.map { it.conversationId })
        assertEquals(SonarConversationPreview.Empty, back[0].preview)
        assertEquals(SonarConversationPreview.Photos(2), back[1].preview)
        assertEquals(SonarConversationPreview.Empty, back[2].preview)
        assertEquals(listOf("g1", "g1b"), back[0].groupIds)
        assertEquals("Sara", back[0].title)
        assertNull(back[1].title)
        assertEquals(2L, back[0].unreadCount)
        assertEquals(1_700_000_000L, back[0].latestAtSecs)
        // The chat lines of the same blob are untouched by the row lines.
        assertEquals(emptyList(), decodeChatSnapshot(blob).first)
    }
}
