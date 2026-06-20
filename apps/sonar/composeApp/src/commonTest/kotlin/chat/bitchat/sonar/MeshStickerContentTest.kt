package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MeshStickerContentTest {
    @Test fun meshStickerContentRoundTrip() {
        val encoded = meshStickerContent(
            packCoordinate = "30030:abc123:pack",
            shortcode = "wave",
            plaintextSha256 = "deadbeef",
        )
        val decoded = meshParseStickerContent(encoded)

        assertEquals("30030:abc123:pack", decoded?.packCoordinate)
        assertEquals("wave", decoded?.shortcode)
        assertEquals("deadbeef", decoded?.plaintextSha256)
    }

    @Test fun meshStickerContentRejectsPlainText() {
        assertNull(meshParseStickerContent("hello world"))
        assertNull(meshParseStickerContent(""))
        assertNull(meshParseStickerContent("sticker:fake"))
    }
}
