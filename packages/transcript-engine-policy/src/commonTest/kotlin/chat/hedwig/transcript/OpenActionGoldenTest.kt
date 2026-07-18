package chat.hedwig.transcript

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Loads [open-action.json] from commonTest resources — same contract as SPM golden tests.
 */
class OpenActionGoldenTest {

    @Test
    fun openAction_matchesGoldenCases() {
        val text = checkNotNull(
            this::class.java.classLoader?.getResourceAsStream("open-action.json"),
        ) { "missing open-action.json in test resources" }
            .bufferedReader()
            .readText()

        assertCase(text, "fully_read_live_edge", TranscriptOpenAction.LiveEdge)
        assertCase(text, "pending_unread_divider", TranscriptOpenAction.UnreadDivider)
        assertCase(text, "abandoned_unread_live_edge", TranscriptOpenAction.LiveEdge)
        assertCase(text, "unset_capture_provisional_live_edge", TranscriptOpenAction.LiveEdge)
        assertJumpCase(text, "jump_wins", "m:search")
    }

    private fun assertCase(text: String, name: String, expected: TranscriptOpenAction) {
        val block = caseBlock(text, name)
        val unreadAnchorId = jsonStringOrNull(block, "unreadAnchorId")
        val unreadCount = jsonLongOrNull(block, "unreadCountAtOpen")
        val abandoned = jsonBool(block, "unreadAnchorAbandoned") ?: false
        val jumpId = jsonStringOrNull(block, "jumpMessageId")
        assertEquals(
            expected,
            TranscriptScrollPolicy.resolveOpenAction(
                unreadAnchorId = unreadAnchorId,
                unreadCountAtOpen = unreadCount,
                unreadAnchorAbandoned = abandoned,
                jumpMessageId = jumpId,
            ),
            "golden case $name",
        )
    }

    private fun assertJumpCase(text: String, name: String, jumpId: String) {
        val block = caseBlock(text, name)
        val unreadAnchorId = jsonStringOrNull(block, "unreadAnchorId")
        val unreadCount = jsonLongOrNull(block, "unreadCountAtOpen")
        val abandoned = jsonBool(block, "unreadAnchorAbandoned") ?: false
        assertEquals(
            TranscriptOpenAction.Jump(jumpId),
            TranscriptScrollPolicy.resolveOpenAction(
                unreadAnchorId = unreadAnchorId,
                unreadCountAtOpen = unreadCount,
                unreadAnchorAbandoned = abandoned,
                jumpMessageId = jumpId,
            ),
            "golden case $name",
        )
    }

    private fun caseBlock(text: String, name: String): String {
        val marker = "\"name\": \"$name\""
        val start = text.indexOf(marker)
        assertTrue(start >= 0, "case $name not found in golden JSON")
        val next = text.indexOf("\"name\":", start + marker.length).let { if (it < 0) text.length else it }
        return text.substring(start, next)
    }

    private fun jsonStringOrNull(block: String, key: String): String? {
        val re = Regex(""""$key"\s*:\s*(null|"([^"]*)")""")
        val m = re.find(block) ?: return null
        return if (m.groupValues[1] == "null") null else m.groupValues[2]
    }

    private fun jsonLongOrNull(block: String, key: String): Long? {
        val re = Regex(""""$key"\s*:\s*(null|(\d+))""")
        val m = re.find(block) ?: return null
        return if (m.groupValues[1] == "null") null else m.groupValues[2].toLong()
    }

    private fun jsonBool(block: String, key: String): Boolean? {
        val re = Regex(""""$key"\s*:\s*(true|false)""")
        return re.find(block)?.groupValues?.get(1)?.toBooleanStrict()
    }
}
