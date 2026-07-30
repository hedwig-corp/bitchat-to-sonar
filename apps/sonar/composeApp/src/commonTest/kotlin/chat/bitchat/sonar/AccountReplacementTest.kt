package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Importing an `nsec` wipes wallet storage, host caches and the Marmot store
 * before restoring from Blossom. These tests pin the one input where that is
 * catastrophic — the key you are already signed in with — and the one where
 * refusing would break restore entirely.
 */
class AccountReplacementTest {

    private val mine = "npub1vincenzo000000000000000000000000000000000000000000000000"
    private val theirs = "npub1someoneelse00000000000000000000000000000000000000000000"

    /**
     * The whole reason this exists. Without it the import path wipes a live
     * database and then restores whatever Blossom last held — or, for an
     * account that never backed up, nothing at all.
     */
    @Test
    fun rePastingYourOwnKeyIsNotAReplacement() {
        assertFalse(shouldReplaceAccount(currentNpub = mine, incomingNpub = mine))
    }

    /** Whitespace from a paste must not turn a no-op into a wipe. */
    @Test
    fun surroundingWhitespaceDoesNotDefeatTheGuard() {
        assertFalse(shouldReplaceAccount(currentNpub = mine, incomingNpub = "  $mine\n"))
        assertFalse(shouldReplaceAccount(currentNpub = " $mine ", incomingNpub = mine))
    }

    /** A genuine account switch must still replace, or the feature is dead. */
    @Test
    fun aDifferentKeyReplacesTheAccount() {
        assertTrue(shouldReplaceAccount(currentNpub = mine, incomingNpub = theirs))
    }

    /**
     * Onboarding and restore-on-a-new-phone have no current account. Refusing
     * here would block the case backups exist for, so "unknown ⇒ replace" is
     * correct — there is nothing on the device to lose.
     */
    @Test
    fun noCurrentAccountReplaces() {
        assertTrue(shouldReplaceAccount(currentNpub = null, incomingNpub = theirs))
        assertTrue(shouldReplaceAccount(currentNpub = "", incomingNpub = theirs))
        assertTrue(shouldReplaceAccount(currentNpub = "   ", incomingNpub = theirs))
    }

    /**
     * Near-misses must replace. A guard that matched loosely would silently
     * refuse a real account switch, which looks like the app ignoring you.
     */
    @Test
    fun aPrefixOrTruncationIsNotTheSameAccount() {
        assertTrue(shouldReplaceAccount(currentNpub = mine, incomingNpub = mine.dropLast(1)))
        assertTrue(shouldReplaceAccount(currentNpub = mine.dropLast(1), incomingNpub = mine))
        assertTrue(shouldReplaceAccount(currentNpub = mine, incomingNpub = mine + "x"))
    }

    /**
     * An unusable incoming key must never authorise a wipe. Callers validate
     * the `nsec` first so this should be unreachable, but "replace the account
     * based on nothing" is the one answer that can never be right.
     *
     * Found by mutation testing: an earlier draft returned `true` here, which
     * would have wiped a live account on an empty key.
     */
    @Test
    fun anEmptyIncomingKeyNeverReplaces() {
        assertFalse(shouldReplaceAccount(currentNpub = mine, incomingNpub = ""))
        assertFalse(shouldReplaceAccount(currentNpub = mine, incomingNpub = "   "))
        assertFalse(shouldReplaceAccount(currentNpub = null, incomingNpub = ""))
    }
}
