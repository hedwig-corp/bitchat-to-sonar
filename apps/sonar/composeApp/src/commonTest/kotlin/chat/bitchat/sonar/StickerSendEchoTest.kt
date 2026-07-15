package chat.bitchat.sonar

import chat.bitchat.sonar.screens.filterCachedStickerPacksByInstalledCoordinates
import chat.bitchat.sonar.screens.mergeRefreshedStickerPacks
import chat.bitchat.sonar.screens.shouldPreserveCachedStickerPacks
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class StickerSendEchoTest {
    @Test fun invalidatedStickerLookupNeverFallsThroughAsCacheMiss() {
        assertEquals(
            StickerCacheLookupState.INVALIDATED,
            stickerCacheLookupState(hasBytes = false, startedGeneration = 1, currentGeneration = 2),
        )
        assertEquals(
            StickerCacheLookupState.INVALIDATED,
            stickerCacheLookupState(hasBytes = true, startedGeneration = 1, currentGeneration = 2),
        )
        assertEquals(
            StickerCacheLookupState.MISS,
            stickerCacheLookupState(hasBytes = false, startedGeneration = 2, currentGeneration = 2),
        )
        assertEquals(
            StickerCacheLookupState.HIT,
            stickerCacheLookupState(hasBytes = true, startedGeneration = 2, currentGeneration = 2),
        )
    }

    @Test fun failedInstalledRefreshPreservesCachedPacks() {
        assertTrue(shouldPreserveCachedStickerPacks(hadCachedPacks = true, installedCoordinates = null))
        assertFalse(shouldPreserveCachedStickerPacks(hadCachedPacks = false, installedCoordinates = null))
        assertFalse(shouldPreserveCachedStickerPacks(hadCachedPacks = true, installedCoordinates = emptyList()))
    }

    @Test fun cachedStickerPacksFollowInstalledAuthority() {
        val coordinate = "30031:abcdef:Pack"

        // Preview/transcript metadata is not installed authority. Before the
        // local installed set is known, the composer must expose nothing.
        assertFalse(shouldExposeCachedStickerPack(coordinate, emptySet()))
        assertTrue(shouldExposeCachedStickerPack(
            coordinate,
            setOf("30031:ABCDEF:Pack").mapTo(mutableSetOf(), ::normalizeStickerPackCoordinate),
        ))
        assertFalse(shouldExposeCachedStickerPack(
            coordinate,
            emptySet(),
        ))
        assertFalse(shouldExposeCachedStickerPack(
            coordinate,
            setOf(normalizeStickerPackCoordinate("30031:abcdef:pack")),
        ))
    }

    @Test fun stickerPackCoordinateNormalizesOnlyTheAuthor() {
        assertEquals(
            "30031:abcdef:Pack",
            normalizeStickerPackCoordinate("30031:ABCDEF:Pack"),
        )
        assertEquals("invalid", normalizeStickerPackCoordinate("invalid"))
    }

    @Test fun stickerPreviewKeepsIdentifierCaseSensitive() {
        assertTrue(stickerPackInstalledState(
            coordinate = "30031:abcdef:Pack",
            refreshedCoordinates = listOf("30031:ABCDEF:Pack"),
            cachedInstalled = false,
        ))
        assertFalse(stickerPackInstalledState(
            coordinate = "30031:abcdef:Pack",
            refreshedCoordinates = listOf("30031:ABCDEF:pack"),
            cachedInstalled = true,
        ))
    }

    @Test fun successfulInstalledRefreshFiltersCachedPickerPacks() {
        val removed = SonarStickerPack("30031:author:removed", "Removed", null, null, emptyList())
        val caseCollision = SonarStickerPack("30031:author:Installed", "Wrong case", null, null, emptyList())
        val installed = SonarStickerPack("30031:author:installed", "Installed", null, null, emptyList())

        assertEquals(
            listOf(installed),
            filterCachedStickerPacksByInstalledCoordinates(
                packs = listOf(removed, caseCollision, installed),
                installedCoordinates = listOf("30031:AUTHOR:installed"),
            ),
        )
    }

    @Test fun partialMetadataRefreshPreservesEachUnrefreshedInstalledPack() {
        val cachedFirst = SonarStickerPack("30031:author:first", "Cached first", null, null, emptyList())
        val cachedSecond = SonarStickerPack("30031:author:second", "Cached second", null, null, emptyList())
        val refreshedFirst = cachedFirst.copy(title = "Fresh first")

        assertEquals(
            listOf(refreshedFirst, cachedSecond),
            mergeRefreshedStickerPacks(
                cachedPacks = listOf(cachedFirst, cachedSecond),
                refreshedPacks = listOf(refreshedFirst),
                installedCoordinates = listOf(
                    "30031:AUTHOR:first",
                    "30031:author:second",
                ),
            ),
        )
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

    @Test fun retryReconstructsStickerTransportContentFromTheRetainedReference() {
        val ref = SonarStickerRef("30031:author:pack", "wave", "aabbcc")
        val encoded = sonarRetryContent(message("failed-sticker", 100, ref))
        val decoded = encoded?.let(::meshParseStickerContent)

        assertEquals(ref.packCoordinate, decoded?.packCoordinate)
        assertEquals(ref.shortcode, decoded?.shortcode)
        assertEquals(ref.plaintextSha256, decoded?.plaintextSha256)
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
