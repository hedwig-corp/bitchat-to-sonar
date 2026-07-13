package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class StickerSendEchoTest {
    @Test fun stickerEchoMatchesOnlyTheSameSticker() {
        val expectedRef = SonarStickerRef("30031:author:pack", "wave", "aabbcc")
        val echo = message("echo", 100, expectedRef)

        assertTrue(sonarSendEchoMatches(message("canonical", 101, expectedRef), echo))
        assertFalse(sonarSendEchoMatches(
            message("other-sticker", 101, SonarStickerRef("30031:author:pack", "other", "ddeeff")),
            echo,
        ))
        assertFalse(sonarSendEchoMatches(message("empty-text", 101, null), echo))
    }

    private fun message(id: String, tsSecs: Long, stickerRef: SonarStickerRef?) = SonarMsg(
        id = id,
        senderNpub = "npub1test",
        content = "",
        mine = true,
        tsSecs = tsSecs,
        viaInternet = true,
        stickerRef = stickerRef,
    )
}
