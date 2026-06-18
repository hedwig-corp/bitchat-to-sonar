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
    fun recentsTrackOnlyInstalledStickersAndStayBounded() {
        val store = SonarStickerStore()
        val pack = fixturePackWithManyStickers(SONAR_MAX_RECENT_STICKERS + 2)
        val first = assertNotNull(pack.sticker("s_0"))

        assertFalse(store.recordRecent(pack, first))
        assertTrue(store.install(pack))

        pack.stickers.forEach { sticker ->
            assertTrue(store.recordRecent(pack, sticker))
        }

        assertEquals(SONAR_MAX_RECENT_STICKERS, store.recentStickers.size)
        assertEquals("s_${pack.stickers.lastIndex}", store.recentStickers.first().sticker.shortcode)
        assertNull(store.recentStickers.firstOrNull { it.sticker.shortcode == "s_0" })

        assertTrue(store.recordRecent(pack, first))

        assertEquals(SONAR_MAX_RECENT_STICKERS, store.recentStickers.size)
        assertEquals("s_0", store.recentStickers.first().sticker.shortcode)
        assertFalse(store.recordRecent(pack, first.copy(alt = "edited locally")))

        store.remove(pack.address)

        assertEquals(emptyList(), store.recentStickers)
    }

    @Test
    fun storeSnapshotPersistsPacksAndOnlyValidRecents() {
        val store = SonarStickerStore()
        val pack = fixturePack()
        val sticker = assertNotNull(pack.sticker("cat_wave"))

        assertTrue(store.install(pack))
        assertTrue(store.recordRecent(pack, sticker))

        val snapshot = store.exportSnapshot()
        val restored = SonarStickerStore()

        assertTrue(restored.restoreSnapshot(snapshot))
        assertEquals(listOf(pack.address.coordinate), restored.installedPacks.map { it.address.coordinate })
        assertEquals(listOf("cat_wave"), restored.recentStickers.map { it.sticker.shortcode })

        val staleRecentSnapshot = snapshot.lines().joinToString("\n") { line ->
            if (line.startsWith("recent|")) {
                line.substringBeforeLast('|') + "|dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
            } else {
                line
            }
        }
        val staleRecentStore = SonarStickerStore()

        assertTrue(staleRecentStore.restoreSnapshot(staleRecentSnapshot))
        assertEquals(listOf(pack.address.coordinate), staleRecentStore.installedPacks.map { it.address.coordinate })
        assertEquals(emptyList(), staleRecentStore.recentStickers)

        assertFalse(restored.restoreSnapshot("not-a-sticker-snapshot"))
        assertEquals(listOf(pack.address.coordinate), restored.installedPacks.map { it.address.coordinate })
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

    @Test
    fun parsesNostrPackEventAndInstalledPackListTags() {
        val tags = fixturePackTags()
        val pack = assertNotNull(SonarStickers.parsePackEvent(SONAR_STICKER_PACK_KIND, pubkey, tags))

        assertEquals(fixtureAddress(), pack.address)
        assertEquals("Sonar Signal Cats", pack.title)
        assertEquals("Native sticker contract fixture for Signal-style pack import.", pack.description)
        assertEquals("CC-BY-4.0", pack.license)
        assertEquals(hashA, pack.cover?.sha256)
        assertEquals(listOf("cat_wave", "cat_cry"), pack.stickers.map { it.shortcode })
        assertEquals("Cat waving", pack.sticker("cat_wave")?.alt)
        assertEquals("🙂", pack.sticker("cat_wave")?.emoji)

        val installed = SonarStickers.parseInstalledPackList(
            SONAR_USER_STICKER_PACKS_KIND,
            listOf(
                listOf("a", fixtureAddress().coordinate),
                listOf("a", fixtureAddress().coordinate),
                listOf("a", "invalid"),
            ),
        )

        assertEquals(listOf(fixtureAddress()), installed)
    }

    @Test
    fun parsesNostrPackEventJsonAndRelayEnvelope() {
        val eventJson = fixturePackEventJson()
        val pack = assertNotNull(SonarStickers.parsePackEventJsonOrNull(eventJson))

        assertEquals(fixtureAddress(), pack.address)
        assertEquals(listOf("cat_wave", "cat_cry"), pack.stickers.map { it.shortcode })
        assertEquals(pack, SonarStickers.parsePackEventJsonOrNull(eventJson.replace(",", ",\n  ")))

        val relayEnvelopeJson = """["EVENT","subscription-id",$eventJson]"""
        val envelopePack = assertNotNull(SonarStickers.parsePackEventJsonOrNull(relayEnvelopeJson))

        assertEquals(pack, envelopePack)
    }

    @Test
    fun rejectsMalformedNostrStickerPackTags() {
        assertNull(SonarStickers.parsePackEvent(SONAR_STICKER_PACK_KIND, pubkey, fixturePackTagsWithoutFormat()))
        assertNull(SonarStickers.parsePackEvent(SONAR_STICKER_PACK_KIND, pubkey, fixturePackTagsWithBadStickerDim()))
        assertNull(SonarStickers.parsePackEvent(SONAR_STICKER_PACK_KIND, "not-a-pubkey", fixturePackTags()))
        assertEquals(emptyList(), SonarStickers.parseInstalledPackList(1, listOf(listOf("a", fixtureAddress().coordinate))))
        assertNull(SonarStickers.parsePackEventJsonOrNull("""{"kind":$SONAR_STICKER_PACK_KIND,"pubkey":"$pubkey","tags":[["pack_format",1]]}"""))
        assertNull(SonarStickers.parsePackEventJsonOrNull("""["EVENT","subscription-id",${fixturePackEventJson()},"extra"]"""))
        assertNull(SonarStickers.parsePackEventJsonOrNull("x".repeat(SONAR_STICKER_IMPORT_MAX_CHARS + 1)))
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

    private fun fixturePackWithManyStickers(count: Int): SonarStickerPack =
        assertNotNull(
            SonarStickerPack(
                address = fixtureAddress(),
                title = "Many Stickers",
                stickers = (0 until count).map { i ->
                    val hash = i.toString(16).padStart(64, '0')
                    fixtureSticker("s_$i", hash)
                },
            ).normalizedOrNull()
        )

    private fun fixturePackTags(): List<List<String>> =
        listOf(
            listOf("d", "signal-0123456789abcdef0123456789abcdef"),
            listOf("title", "Sonar Signal Cats"),
            listOf("pack_format", SONAR_STICKER_PACK_FORMAT),
            listOf("description", "Native sticker contract fixture for Signal-style pack import."),
            listOf("image", "https://blossom.example/stickers/$hashA/cat-wave.webp", hashA, "512x512"),
            listOf("license", "CC-BY-4.0"),
            listOf(
                "sticker",
                "cat_wave",
                "https://blossom.example/stickers/$hashA/cat-wave.webp",
                hashA,
                "image/webp",
                "512x512",
                "Cat waving",
                "🙂",
            ),
            listOf(
                "sticker",
                "cat_cry",
                "https://blossom.example/stickers/$hashB/cat-cry.webp",
                hashB,
                "image/webp",
                "512x512",
                "Cat crying",
                "😿",
            ),
        )

    private fun fixturePackEventJson(): String {
        val tagsJson = fixturePackTags().joinToString(",") { tag ->
            tag.joinToString(prefix = "[", postfix = "]") { it.jsonString() }
        }
        return """{"kind":$SONAR_STICKER_PACK_KIND,"pubkey":"$pubkey","tags":[$tagsJson]}"""
    }

    private fun String.jsonString(): String =
        "\"" + replace("\\", "\\\\").replace("\"", "\\\"") + "\""

    private fun fixturePackTagsWithoutFormat(): List<List<String>> =
        fixturePackTags().filterNot { it.firstOrNull() == "pack_format" }

    private fun fixturePackTagsWithBadStickerDim(): List<List<String>> =
        fixturePackTags().map { tag ->
            if (tag.firstOrNull() == "sticker" && tag.getOrNull(1) == "cat_wave") {
                tag.toMutableList().also { it[5] = "large" }
            } else {
                tag
            }
        }
}
