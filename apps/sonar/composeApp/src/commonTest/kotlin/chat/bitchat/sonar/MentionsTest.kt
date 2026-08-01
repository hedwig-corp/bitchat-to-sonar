package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Pins the composer-side mention rules the group chat composer renders against:
 * when the picker opens, who it offers, and what picking one puts in the draft.
 *
 * The disambiguation rule is the load-bearing one — the wire carries plain text,
 * so `@name` alone is only unambiguous when exactly one member answers to it.
 */
class MentionsTest {

    private val vincenzo = MentionCandidate(npub = "npub1aaa", name = "vincenzo", suffixHex4 = "0011")
    private val vincenzoTwin = MentionCandidate(npub = "npub1bbb", name = "Vincenzo", suffixHex4 = "beef")
    private val giulia = MentionCandidate(npub = "npub1ccc", name = "giulia", suffixHex4 = "c0de")

    private val uniqueRoster = listOf(vincenzo, giulia)
    private val ambiguousRoster = listOf(vincenzo, vincenzoTwin, giulia)

    @Test
    fun noAtMeansNoActiveQuery() {
        assertNull(Mentions.activeQuery("hello there"))
        assertNull(Mentions.activeQuery(""))
    }

    @Test
    fun trailingAtOpensThePickerWithAnEmptyQuery() {
        assertEquals("", Mentions.activeQuery("hey @"))
        assertEquals(uniqueRoster.size, Mentions.matches("hey @", uniqueRoster).size)
    }

    @Test
    fun emailDoesNotOpenThePicker() {
        // Same left boundary as the core scanner: `@` needs start-of-text or
        // whitespace before it, or every email address opens the picker.
        assertNull(Mentions.activeQuery("write to alice@example"))
        assertTrue(Mentions.matches("write to alice@example", uniqueRoster).isEmpty())
    }

    @Test
    fun queryStopsAtANonNameCharacter() {
        // The mention already ended; the caret is past it.
        assertNull(Mentions.activeQuery("hey @vincenzo how are you"))
    }

    @Test
    fun matchesArePrefixedAndCaseInsensitive() {
        val hits = Mentions.matches("hey @VIN", uniqueRoster)
        assertEquals(listOf("vincenzo"), hits.map { it.name })
    }

    @Test
    fun matchesAreCappedAndSorted() {
        val roster = (1..10).map { MentionCandidate("npub$it", "user$it", "000$it") }
        val hits = Mentions.matches("@user", roster)
        assertEquals(Mentions.MAX_SUGGESTIONS, hits.size)
        assertEquals(hits.map { it.name.lowercase() }.sorted(), hits.map { it.name.lowercase() })
    }

    @Test
    fun uniqueNameInsertsBareMention() {
        assertFalse(Mentions.needsSuffix(vincenzo, uniqueRoster))
        assertEquals("@vincenzo", Mentions.token(vincenzo, uniqueRoster))
        assertEquals("hey @vincenzo ", Mentions.applyPick("hey @vin", vincenzo, uniqueRoster))
    }

    @Test
    fun duplicateNameInsertsDisambiguatingSuffix() {
        assertTrue(Mentions.needsSuffix(vincenzo, ambiguousRoster))
        assertEquals("@vincenzo#0011", Mentions.token(vincenzo, ambiguousRoster))
        assertEquals("@Vincenzo#beef", Mentions.token(vincenzoTwin, ambiguousRoster))
        assertEquals(
            "hey @vincenzo#0011 ",
            Mentions.applyPick("hey @vin", vincenzo, ambiguousRoster),
        )
    }

    @Test
    fun duplicateDetectionIgnoresCase() {
        // "vincenzo" and "Vincenzo" are the same name to a reader, so both must
        // carry a suffix — otherwise one of them silently wins the bare form.
        assertTrue(Mentions.needsSuffix(vincenzoTwin, ambiguousRoster))
    }

    @Test
    fun memberNeedingAKeyItDoesNotHaveIsNotOffered() {
        // Ambiguous with no usable key: any token we could build resolves to
        // nobody, which looks to the sender like a mention that worked. Better
        // to not offer them than to emit a silent dead end.
        val noSuffix = MentionCandidate("npub1ddd", "vincenzo", suffixHex4 = null)
        val roster = listOf(noSuffix, vincenzoTwin)
        assertFalse(Mentions.isMentionable(noSuffix, roster))
        assertTrue(Mentions.matches("@vin", roster).none { it.npub == noSuffix.npub })
        // The twin has a key, so it is still offerable.
        assertTrue(Mentions.isMentionable(vincenzoTwin, roster))
    }

    @Test
    fun truncatedNameWithoutAKeyIsNotOffered() {
        val john = MentionCandidate("npub1ggg", "John Doe", suffixHex4 = null)
        assertFalse(Mentions.isMentionable(john, listOf(john)))
    }

    @Test
    fun unambiguousNameWithoutAKeyIsStillOffered() {
        // No key needed, so a missing suffix costs nothing.
        val solo = MentionCandidate("npub1hhh", "solo", suffixHex4 = null)
        assertTrue(Mentions.isMentionable(solo, listOf(solo)))
        assertEquals("@solo", Mentions.token(solo, listOf(solo)))
    }

    @Test
    fun pickOutsideAMentionLeavesTheDraftAlone() {
        // A tap that lands after the token stopped being a mention must not
        // rewrite unrelated text.
        assertEquals(
            "already sent @vincenzo ok",
            Mentions.applyPick("already sent @vincenzo ok", vincenzo, uniqueRoster),
        )
    }

    @Test
    fun mentionAtStartOfDraftIsPicked() {
        assertEquals("", Mentions.activeQuery("@"))
        assertEquals("@vincenzo ", Mentions.applyPick("@vin", vincenzo, uniqueRoster))
    }

    @Test
    fun aNameWithASpaceIsForcedToCarryItsKey() {
        // Display names are free text. Emitting "@John Doe" would put "@John" on
        // the wire — the scanner stops at the space — and resolve to nobody, so
        // the token is truncated to the wire-legal run AND carries the suffix,
        // which resolves by key regardless of the name.
        val john = MentionCandidate("npub1ddd", "John Doe", "d0e5")
        val roster = listOf(john, giulia)
        assertEquals("@John#d0e5", Mentions.token(john, roster))
        assertEquals("hey @John#d0e5 ", Mentions.applyPick("hey @Jo", john, roster))
    }

    @Test
    fun aNameWithPunctuationIsTruncatedAtTheFirstIllegalCharacter() {
        val alice = MentionCandidate("npub1eee", "alice(work)", "a11c")
        assertEquals("@alice#a11c", Mentions.token(alice, listOf(alice)))
    }

    @Test
    fun aNameWithNoWireLegalRunIsNotOffered() {
        // "🎉 party" has no leading run the wire grammar accepts, so there is no
        // token to build — better to not offer it than to emit "@#abcd".
        val emoji = MentionCandidate("npub1fff", "🎉 party", "beef")
        assertTrue(Mentions.matches("@", listOf(emoji)).isEmpty())
    }

    @Test
    fun anUnambiguousPlainNameStillInsertsBare() {
        // The truncation rule must not drag every mention into the suffix form.
        assertEquals("@vincenzo", Mentions.token(vincenzo, uniqueRoster))
    }

    @Test
    fun nonLatinNamesMatch() {
        val viktor = MentionCandidate("npub1eee", "Виктор", "1234")
        assertEquals(listOf(viktor), Mentions.matches("ciao @Вик", listOf(viktor, giulia)))
    }
}
