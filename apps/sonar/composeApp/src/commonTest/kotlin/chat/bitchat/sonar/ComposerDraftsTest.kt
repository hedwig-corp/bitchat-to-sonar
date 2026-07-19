package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals

class ComposerDraftsTest {
    @Test
    fun storesAndUpdatesDraftPerChat() {
        val after = updatedComposerDrafts(emptyMap(), "dm:a", "hello")
        assertEquals(mapOf("dm:a" to "hello"), after)
        val other = updatedComposerDrafts(after, "dm:b", "world")
        assertEquals(mapOf("dm:a" to "hello", "dm:b" to "world"), other)
        val edited = updatedComposerDrafts(other, "dm:a", "hello there")
        assertEquals(mapOf("dm:a" to "hello there", "dm:b" to "world"), edited)
    }

    @Test
    fun emptyTextRemovesDraft() {
        val start = mapOf("dm:a" to "partial", "dm:b" to "keep")
        assertEquals(
            mapOf("dm:b" to "keep"),
            updatedComposerDrafts(start, "dm:a", ""),
        )
        assertEquals(start, updatedComposerDrafts(start, "dm:missing", ""))
    }

    @Test
    fun channelAndGeoKeysAreNamespaced() {
        assertEquals("mesh", composerDraftKeyForChannel("mesh"))
        assertEquals("geo:u4pruy", composerDraftKeyForChannel("u4pruy"))
        assertEquals(
            "geodm:u4pruy:abc",
            composerDraftKeyForGeoDm("u4pruy", "abc"),
        )
    }
}
