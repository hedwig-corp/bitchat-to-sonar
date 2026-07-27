package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

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
    fun clearOnSendRemovesEntryForHydrate() {
        // Send clears via empty text; a cold hydrate from the encoded blob
        // must not resurrect the sent draft.
        val afterTyping = updatedComposerDrafts(emptyMap(), "dm:a", "about to send")
        val afterSend = updatedComposerDrafts(afterTyping, "dm:a", "")
        assertEquals(emptyMap(), afterSend)
        assertEquals("", encodeComposerDrafts(afterSend))
        assertEquals(emptyMap(), decodeComposerDrafts(encodeComposerDrafts(afterSend)))
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

    @Test
    fun encodeDecodeRoundTripsIncludingNewlinesAndEquals() {
        val drafts = mapOf(
            "dm:a" to "hello\nworld",
            "dm:b" to "x=y",
            "geo:u4pruy" to "partial draft ",
        )
        val blob = encodeComposerDrafts(drafts)
        assertFalse(blob.lines().any { !it.contains('=') && it.isNotEmpty() })
        assertEquals(drafts, decodeComposerDrafts(blob))
    }

    @Test
    fun decodeEmptyBlobIsEmptyMap() {
        assertEquals(emptyMap(), decodeComposerDrafts(""))
        assertEquals("", encodeComposerDrafts(emptyMap()))
    }

    @Test
    fun deleteChatRemovesOnlyThatDraft() {
        // Per-chat delete must drop that key (and keep siblings) before persist.
        val start = mapOf("dm:a" to "gone", "dm:b" to "keep")
        assertEquals(
            mapOf("dm:b" to "keep"),
            updatedComposerDrafts(start, "dm:a", ""),
        )
    }

    @Test
    fun wipeClearsPersistedDrafts() {
        // Wipe / erase persist an empty blob; hydrate must start empty.
        val prior = encodeComposerDrafts(mapOf("dm:a" to "secret draft"))
        assertEquals(mapOf("dm:a" to "secret draft"), decodeComposerDrafts(prior))
        assertEquals(emptyMap(), decodeComposerDrafts(""))
    }
}
