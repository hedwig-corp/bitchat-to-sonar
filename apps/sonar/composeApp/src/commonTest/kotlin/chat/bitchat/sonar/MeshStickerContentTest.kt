package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MeshStickerContentTest {
    @Test fun meshStickerContentRoundTrip() {
        val encoded = meshStickerContent(
            packCoordinate = "30031:abc123:pack",
            shortcode = "wave",
            plaintextSha256 = "deadbeef",
        )
        val decoded = meshParseStickerContent(encoded)

        assertEquals("30031:abc123:pack", decoded?.packCoordinate)
        assertEquals("wave", decoded?.shortcode)
        assertEquals("deadbeef", decoded?.plaintextSha256)
    }

    @Test fun meshStickerContentRejectsPlainText() {
        assertNull(meshParseStickerContent("hello world"))
        assertNull(meshParseStickerContent(""))
        assertNull(meshParseStickerContent("sticker:fake"))
    }

    @Test fun packAddressPartsAcceptsCanonicalAndLegacyKinds() {
        val author = "b".repeat(64)
        val canonical = SonarStickerRef("30031:$author:signal-pack", "wave", "deadbeef")
        assertEquals(author to "signal-pack", canonical.packAddressParts())

        val legacy = SonarStickerRef("30030:$author:signal-pack", "wave", "deadbeef")
        assertEquals(author to "signal-pack", legacy.packAddressParts())

        assertNull(SonarStickerRef("99999:$author:signal-pack", "wave", "deadbeef").packAddressParts())
        assertNull(SonarStickerRef("not-a-coordinate", "wave", "deadbeef").packAddressParts())
    }
}
