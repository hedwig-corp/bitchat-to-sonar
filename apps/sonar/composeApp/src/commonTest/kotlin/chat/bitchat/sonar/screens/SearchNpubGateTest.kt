package chat.bitchat.sonar.screens

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * QA-A18: typing a partial npub raised "Start secure chat" (which can only
 * fail) and, because "npub14mrp" is also valid geohash alphabet, "Join channel
 * #npub14mrp". The chat action waits for a complete npub.
 */
class SearchNpubGateTest {
    private val full = "npub1pqm5mzn6ph0ldzd2ldflq9g9xv25yc5tqrzkyll042mggs40p5fsh2d6mz"

    @Test
    fun completeNpubStartsAChat() {
        assertTrue(isCompleteNpub(full))
        assertTrue(isCompleteNpub("  ${full.uppercase()}  "))
    }

    @Test
    fun partialNpubDoesNot() {
        assertFalse(isCompleteNpub("npub14mrp"))
        assertFalse(isCompleteNpub(full.dropLast(1)))
        assertFalse(isCompleteNpub(full + "q"))
    }

    @Test
    fun nonBech32CharactersAreRejected() {
        // 'b', 'i', 'o' and '1' are outside the bech32 data alphabet.
        assertFalse(isCompleteNpub(full.dropLast(1) + "b"))
        assertFalse(isCompleteNpub("nsec1" + full.drop(5)))
    }
}
