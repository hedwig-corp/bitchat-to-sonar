package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StickersTest {
    private val pubkey = "6a04ab98d9e4774ad806e302dddeb63bea16b5cb5f223ee77478e861bb583eb3"
    private val hashA = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private val hashB = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

    @Test
    fun featureGateDefaultsOff() {
        assertFalse(SONAR_STICKERS_ENABLED_BY_DEFAULT)
    }

    @Test
    fun validatesInstallsAndResolvesFixturePack() {
        val store = SonarStickerStore()
        val pack = fixturePack()
        val stickerRef = SonarStickerRef(pack.address, "cat_wave", hashA)

        assertTrue(store.install(pack))

        assertEquals(listOf(pack.address.coordinate), store.installedPacks.map { it.address.coordinate })
        assertEquals(
            SonarStickerResolution(SonarStickerResolutionState.Resolved, pack.sticker("cat_wave")),
            store.resolve(stickerRef),
        )
    }

    @Test
    fun chatMessageContractMatchesRustFixture() {
        val address = fixtureAddress()
        val stickerRef = SonarStickerRef(address, "cat_wave", hashA)
        val message = assertNotNull(SonarStickers.buildChatMessage(stickerRef))

        assertEquals(
            "[sticker] [sonar-sticker-v1] pack=30030:$pubkey:signal-0123456789abcdef0123456789abcdef shortcode=cat_wave sha256=$hashA",
            message,
        )
        assertEquals(stickerRef.normalizedOrNull(), SonarStickers.parseChatMessageOrNull(message))
        assertNull(SonarStickers.parseChatMessageOrNull("plain text"))
    }

    @Test
    fun rejectsUnsafeAndAmbiguousFixtureCases() {
        val address = fixtureAddress()
        val stickerA = fixtureSticker("cat_wave", hashA)
        val stickerB = fixtureSticker("cat_cry", hashB)

        assertNull(
            SonarSticker(
                shortcode = "bad_url",
                url = "http://blossom.example/stickers/$hashA/cat-wave.webp",
                sha256 = hashA,
                mime = "image/webp",
                width = 512,
                height = 512,
            ).normalizedOrNull()
        )
        assertNull(
            SonarStickerPack(
                address = address,
                title = "Duplicate shortcode",
                stickers = listOf(stickerA, stickerA),
            ).normalizedOrNull()
        )
        assertNull(
            SonarStickerPack(
                address = address,
                title = "Duplicate hash",
                stickers = listOf(
                    stickerA,
                    SonarSticker(
                        shortcode = "cat_other",
                        url = "https://blossom.example/stickers/$hashA/cat-other.webp",
                        sha256 = hashA,
                        mime = "image/webp",
                        width = 512,
                        height = 512,
                    ),
                ),
            ).normalizedOrNull()
        )
        assertNotNull(
            SonarStickerPack(
                address = address,
                title = "Good",
                stickers = listOf(stickerA, stickerB),
            ).normalizedOrNull()
        )
    }

    @Test
    fun mismatchStatesNeverSubstituteAnotherSticker() {
        val store = SonarStickerStore()
        val pack = fixturePack()
        store.install(pack)

        val missingSticker = SonarStickerRef(pack.address, "cat_missing", hashA)
        val mismatchedHash = SonarStickerRef(
            pack.address,
            "cat_wave",
            "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        )

        assertEquals(
            SonarStickerResolution(SonarStickerResolutionState.MissingSticker),
            store.resolve(missingSticker),
        )
        assertEquals(
            SonarStickerResolution(SonarStickerResolutionState.HashMismatch),
            store.resolve(mismatchedHash),
        )
    }

    @Test
    fun sendableRefsMustComeFromInstalledPacks() {
        val store = SonarStickerStore()
        val pack = fixturePack()
        val sticker = assertNotNull(pack.sticker("cat_wave"))

        assertNull(store.refFor(sticker, pack))

        assertTrue(store.install(pack))
        val stickerRef = assertNotNull(store.refFor(sticker, pack))

        assertEquals(SonarStickerRef(pack.address, sticker.shortcode, sticker.sha256), stickerRef)
        assertNull(store.refFor(sticker.copy(alt = "edited locally"), pack))
    }

    @Test
    fun byteCacheStoresOnlyHashVerifiedBoundedStickerBytes() {
        val abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        val sticker = fixtureSticker("abc", abcHash)
        val cache = SonarStickerByteCache(maxStickerBytes = 3)

        assertTrue(cache.putVerified(sticker, "abc".encodeToByteArray()))
        assertContentEquals("abc".encodeToByteArray(), cache.get(sticker))
        assertFalse(cache.putVerified(sticker, "abcd".encodeToByteArray()))
        assertFalse(cache.putVerified(sticker.copy(sha256 = hashA), "abc".encodeToByteArray()))
    }

    private fun fixtureAddress(): SonarStickerPackAddress =
        assertNotNull(
            SonarStickerPackAddress(pubkey, "signal-0123456789abcdef0123456789abcdef").normalizedOrNull()
        )

    private fun fixtureSticker(shortcode: String, hash: String): SonarSticker =
        assertNotNull(
            SonarSticker(
                shortcode = shortcode,
                url = "https://blossom.example/stickers/$hash/$shortcode.webp",
                sha256 = hash,
                mime = "image/webp",
                width = 512,
                height = 512,
                alt = "$shortcode sticker",
                emoji = ":)",
            ).normalizedOrNull()
        )

    private fun fixturePack(): SonarStickerPack =
        assertNotNull(
            SonarStickerPack(
                address = fixtureAddress(),
                title = "Sonar Signal Cats",
                description = "Native sticker contract fixture for Signal-style pack import.",
                cover = fixtureSticker("cat_wave", hashA),
                stickers = listOf(fixtureSticker("cat_wave", hashA), fixtureSticker("cat_cry", hashB)),
                license = "CC-BY-4.0",
            ).normalizedOrNull()
        )
}
