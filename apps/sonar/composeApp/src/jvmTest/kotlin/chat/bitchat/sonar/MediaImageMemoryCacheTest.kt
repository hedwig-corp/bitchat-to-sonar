package chat.bitchat.sonar

import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * Pins the eviction contract the Android `onTrimMemory` hook depends on
 * (`SonarApp.onTrimMemory` → `trimTo`): under memory pressure the cache must
 * actually give pixels back, must drop the least-recently-used entries first,
 * and must never evict the row being painted right now.
 *
 * `gifBytes` is used as the payload because its cost is exactly its size — a
 * bitmap's cost depends on a real ImageBitmap, which needs a graphics context.
 */
class MediaImageMemoryCacheTest {

    private fun media(sizeBytes: Int) =
        DecodedTranscriptMedia(bitmap = null, gifBytes = ByteArray(sizeBytes))

    @BeforeTest fun reset() = MediaImageMemoryCache.clear()

    @AfterTest fun cleanup() = MediaImageMemoryCache.clear()

    @Test
    fun trimEvictsLeastRecentlyUsedFirst() {
        MediaImageMemoryCache.put("a", media(100))
        MediaImageMemoryCache.put("b", media(100))
        MediaImageMemoryCache.put("c", media(100))
        assertEquals(300L, MediaImageMemoryCache.costBytes)

        // Touch "a" so "b" becomes the eldest.
        assertNotNull(MediaImageMemoryCache.get("a"))

        MediaImageMemoryCache.trimTo(150)

        assertNull(MediaImageMemoryCache.get("b"), "eldest should be evicted first")
        assertNull(MediaImageMemoryCache.get("c"))
        assertNotNull(MediaImageMemoryCache.get("a"), "recently used entry should survive")
        assertEquals(100L, MediaImageMemoryCache.costBytes)
    }

    @Test
    fun trimToZeroReleasesEverything() {
        MediaImageMemoryCache.put("a", media(100))
        MediaImageMemoryCache.put("b", media(100))

        // What onTrimMemory(TRIM_MEMORY_COMPLETE) must achieve.
        MediaImageMemoryCache.trimTo(0)

        assertEquals(0L, MediaImageMemoryCache.costBytes)
        assertNull(MediaImageMemoryCache.get("a"))
        assertNull(MediaImageMemoryCache.get("b"))
    }

    @Test
    fun keepSurvivesItsOwnInsertionWhenOversized() {
        MediaImageMemoryCache.put("old", media(100))
        MediaImageMemoryCache.trimTo(50, keep = "huge")
        // An entry larger than the whole budget must still paint: put() passes
        // itself as `keep`, so it is not evicted by its own arrival.
        MediaImageMemoryCache.put("huge", media(1_000))
        MediaImageMemoryCache.trimTo(10, keep = "huge")

        assertNotNull(MediaImageMemoryCache.get("huge"))
        assertNull(MediaImageMemoryCache.get("old"))
    }

    @Test
    fun trimIsNoOpWhenAlreadyUnderBudget() {
        MediaImageMemoryCache.put("a", media(100))
        MediaImageMemoryCache.trimTo(1_000)
        assertNotNull(MediaImageMemoryCache.get("a"))
        assertEquals(100L, MediaImageMemoryCache.costBytes)
    }
}
