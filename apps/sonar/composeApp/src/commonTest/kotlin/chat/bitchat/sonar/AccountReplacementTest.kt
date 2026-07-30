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

    /**
     * bech32 is case-insensitive: `NPUB1…` and `npub1…` decode to the same key.
     * Comparing raw strings failed open on the destructive side — a
     * case-differing encoding of your own key would have wiped the account.
     *
     * Flagged independently by three review models (glm-5.2, kimi-k3).
     */
    @Test
    fun caseDoesNotMakeItADifferentAccount() {
        assertFalse(shouldReplaceAccount(currentNpub = mine, incomingNpub = mine.uppercase()))
        assertFalse(shouldReplaceAccount(currentNpub = mine.uppercase(), incomingNpub = mine))
    }

    /**
     * The two platforms must agree on what "same account" means. Kotlin's
     * `trim()` and Swift's `.whitespacesAndNewlines` disagree on U+00A0, so a
     * non-breaking space around a pasted key was a no-op on iOS and a wipe on
     * Android. Both now trim an explicit ASCII set, which means a non-breaking
     * space is *not* stripped on either — the same answer on both platforms is
     * what matters here, and refusing to guess is the safer of the two.
     */
    @Test
    fun exoticWhitespaceIsTreatedIdenticallyOnBothPlatforms() {
        val nbsp = "\u00A0"
        assertTrue(shouldReplaceAccount(currentNpub = mine, incomingNpub = nbsp + mine))
    }
}
