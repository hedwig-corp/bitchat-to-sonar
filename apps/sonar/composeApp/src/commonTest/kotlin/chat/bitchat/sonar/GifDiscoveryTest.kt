package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class GifDiscoveryTest {
    @Test
    fun normalizesCatalogAndDerivesStableIds() {
        val catalog = SonarGifCatalog(
            name = "  Reactions  ",
            items = listOf(
                SonarGifItem(
                    title = "  Thumbs up  ",
                    mimeType = "video/mp4; charset=utf-8",
                    mediaUrl = "HTTPS://Blossom.Example/files/thumbs-up.mp4",
                    previewUrl = "https://blossom.example/files/thumbs-up-preview.mp4",
                    stillUrl = "https://blossom.example/files/thumbs-up.jpg",
                    width = 480,
                    height = 270,
                    byteSize = 734_201,
                    source = "Nostr",
                )
            ),
        )

        val normalized = assertNotNull(catalog.normalizedOrNull())
        assertEquals("Reactions", normalized.name)
        assertEquals(1, normalized.items.size)
        val item = normalized.items.first()
        assertEquals("Thumbs up", item.title)
        assertEquals("video/mp4", item.mimeType)
        assertEquals("https://blossom.example/files/thumbs-up.mp4", item.mediaUrl)
        assertEquals(stableGifItemId(item.mediaUrl), item.id)
        assertEquals("nostr", item.source)
        assertEquals("mp4", fileExtensionForMime(item.mimeType))
    }

    @Test
    fun rejectsUnsafeCatalogItems() {
        assertNull(
            SonarGifItem(
                title = "bad",
                mimeType = "image/gif",
                mediaUrl = "http://example.com/bad.gif",
            ).normalizedOrNull()
        )
        assertNull(
            SonarGifItem(
                title = "too big",
                mimeType = "image/gif",
                mediaUrl = "https://example.com/big.gif",
                byteSize = SONAR_GIF_ITEM_MAX_BYTES + 1,
            ).normalizedOrNull()
        )
        assertNull(
            SonarGifItem(
                title = "unsupported",
                mimeType = "image/png",
                mediaUrl = "https://example.com/not-gif.gif",
            ).normalizedOrNull()
        )
        assertNull(
            SonarGifItem(
                title = "userinfo",
                mimeType = "image/gif",
                mediaUrl = "https://example.com@evil.example/bad.gif",
            ).normalizedOrNull()
        )
        assertEquals(
            "image/gif",
            assertNotNull(
                SonarGifItem(
                    title = "inferred",
                    mimeType = "",
                    mediaUrl = "https://example.com/ok.gif",
                ).normalizedOrNull()
            ).mimeType,
        )
    }

    @Test
    fun writesNostrCatalogJsonAndTags() {
        val catalog = SonarGifCatalog(
            name = "Reactions",
            items = listOf(
                SonarGifItem(
                    id = "thumbs-up",
                    title = "Thumbs \"up\"",
                    mimeType = "image/gif",
                    mediaUrl = "https://blossom.example/thumbs-up.gif",
                    width = 320,
                    height = 240,
                    source = "nostr",
                )
            ),
        )

        val json = assertNotNull(catalog.toNostrContentJson())
        assertTrue(json.contains("\"schema\":1"))
        assertTrue(json.contains("\"app\":\"sonar\""))
        assertTrue(json.contains("\"type\":\"gif_catalog\""))
        assertTrue(json.contains("\"title\":\"Thumbs \\\"up\\\"\""))
        assertTrue(json.contains("\"url\":\"https://blossom.example/thumbs-up.gif\""))

        assertEquals(
            listOf(listOf("d", SONAR_GIF_CATALOG_D_TAG), listOf("t", "sonar"), listOf("t", "gif")),
            sonarGifCatalogEventTags(),
        )
    }
}
