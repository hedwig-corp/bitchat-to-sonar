package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ConversationFoldTest {
    @Test
    fun uniqueTitleMatchInfersPeer() {
        val peer = inferUniquePeerByTitle(
            groupTitle = "  Vincenzo  Palazzo ",
            peerTitles = mapOf("fp1" to "vincenzo palazzo", "fp2" to "Alice"),
            allGroupTitles = listOf("Vincenzo Palazzo", "Alice Internet"),
        )

        assertEquals("fp1", peer)
    }

    @Test
    fun duplicatePeerTitlesDoNotInfer() {
        val peer = inferUniquePeerByTitle(
            groupTitle = "Vincenzo",
            peerTitles = mapOf("fp1" to "Vincenzo", "fp2" to "vincenzo"),
            allGroupTitles = listOf("Vincenzo"),
        )

        assertNull(peer)
    }

    @Test
    fun duplicateGroupTitlesDoNotInfer() {
        val peer = inferUniquePeerByTitle(
            groupTitle = "Vincenzo",
            peerTitles = mapOf("fp1" to "Vincenzo"),
            allGroupTitles = listOf("Vincenzo", "vincenzo"),
        )

        assertNull(peer)
    }
}
