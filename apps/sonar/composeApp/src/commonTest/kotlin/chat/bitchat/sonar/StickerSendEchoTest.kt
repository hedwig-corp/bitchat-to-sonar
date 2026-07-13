package chat.bitchat.sonar

import chat.bitchat.sonar.screens.shouldPreserveCachedStickerPacks
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class StickerSendEchoTest {
    @Test fun failedInstalledRefreshPreservesCachedPacks() {
        assertTrue(shouldPreserveCachedStickerPacks(hadCachedPacks = true, installedCoordinates = null))
        assertFalse(shouldPreserveCachedStickerPacks(hadCachedPacks = false, installedCoordinates = null))
        assertFalse(shouldPreserveCachedStickerPacks(hadCachedPacks = true, installedCoordinates = emptyList()))
    }

    @Test fun cachedStickerPacksFollowInstalledAuthority() {
        val coordinate = "30031:author:pack"

        assertTrue(shouldExposeCachedStickerPack(
            coordinate,
            emptySet(),
            installedCoordinatesLoaded = false,
        ))
        assertTrue(shouldExposeCachedStickerPack(
            coordinate,
            setOf(coordinate),
            installedCoordinatesLoaded = true,
        ))
        assertFalse(shouldExposeCachedStickerPack(
            coordinate,
            emptySet(),
            installedCoordinatesLoaded = true,
        ))
        assertFalse(shouldExposeCachedStickerPack(
            coordinate,
            setOf("30031:author:other"),
            installedCoordinatesLoaded = true,
        ))
    }

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
