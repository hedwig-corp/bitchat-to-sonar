package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The host half of the multi-account switcher. The registry's own rules (cap,
 * legacy slot, remove) are pinned in Rust (`sonar_core::accounts::tests`);
 * these pin what the Compose host adds — per-account secret naming, row
 * order, display names and the remove-the-active fallback — without the
 * native library.
 *
 * Mirror of iOS `SonarAccountRegistryTests`; keep the two in step.
 */
class AccountSwitchTest {

    private fun account(
        hex: String,
        active: Boolean = false,
        lastActive: Long = 0,
        label: String? = null,
        legacy: Boolean = false,
    ) = SonarAccount(
        pubkeyHex = hex,
        npub = "npub1" + hex.take(50) + "abcd",
        label = label,
        dbPath = if (legacy) "/data/sonar-marmot/marmot.sqlite" else "/data/sonar-marmot/accounts/$hex/marmot.sqlite",
        secretTag = if (legacy) "" else hex,
        isLegacy = legacy,
        isActive = active,
        lastActiveAt = lastActive,
    )

    private val a = "a".repeat(64)
    private val b = "b".repeat(64)
    private val c = "c".repeat(64)

    /** The legacy account keeps the exact names every build before the
     *  switcher used, so registering it never moves a secret. */
    @Test
    fun legacyTagKeepsTheBareSecretNames() {
        assertEquals("nsec", accountSecretKeyName(NSEC_SECRET_BASE, ""))
        assertEquals("dbKeyHex", accountSecretKeyName(DB_KEY_SECRET_BASE, ""))
        val legacy = account(a, legacy = true)
        assertEquals("nsec", legacy.nsecSecretKey)
        assertEquals("dbKeyHex", legacy.dbKeySecretKey)
    }

    @Test
    fun addedAccountsGetSuffixedSecretNames() {
        val added = account(b)
        assertEquals("nsec.$b", added.nsecSecretKey)
        assertEquals("dbKeyHex.$b", added.dbKeySecretKey)
    }

    /** Two accounts must never share a secret. */
    @Test
    fun distinctTagsNeverCollide() {
        assertNotEquals(account(a).nsecSecretKey, account(b).nsecSecretKey)
        assertNotEquals(account(a).nsecSecretKey, account(a, legacy = true).nsecSecretKey)
    }

    /** The switcher lists the active account first, then by recency. */
    @Test
    fun orderedPutsTheActiveFirstThenMostRecent() {
        val snap = SonarAccountRegistrySnapshot(
            accounts = listOf(account(a, lastActive = 10), account(b, active = true, lastActive = 1), account(c, lastActive = 20)),
            active = account(b, active = true, lastActive = 1),
            maxAccounts = 5,
        )
        assertEquals(listOf(b, c, a), snap.ordered.map { it.pubkeyHex })
    }

    @Test
    fun canAddStopsAtTheCapAndOnAFault() {
        val two = listOf(account(a, active = true), account(b))
        assertTrue(SonarAccountRegistrySnapshot(two, two[0], maxAccounts = 5).canAdd)
        assertTrue(!SonarAccountRegistrySnapshot(two, two[0], maxAccounts = 2).canAdd)
        assertTrue(!SonarAccountRegistrySnapshot(two, two[0], maxAccounts = 5, fault = "corrupt").canAdd)
    }

    /** Label wins; the active row shows the profile name; others the short npub. */
    @Test
    fun displayNameFallsBackLabelThenNickThenNpub() {
        assertEquals("Work", accountDisplayName(account(a, label = "Work"), activeNick = "vincenzo"))
        assertEquals("vincenzo", accountDisplayName(account(a, active = true), activeNick = "vincenzo"))
        val other = account(b)
        assertEquals(other.shortNpub, accountDisplayName(other, activeNick = "vincenzo"))
        assertTrue(other.shortNpub.startsWith("npub1"))
        assertTrue(other.shortNpub.length < other.npub.length)
    }

    /** Removing the active account hands over to the most recently active
     *  other one; the only account has no successor. */
    @Test
    fun nextActiveAfterRemovingPicksTheMostRecentOther() {
        val all = listOf(account(a, active = true, lastActive = 30), account(b, lastActive = 10), account(c, lastActive = 20))
        assertEquals(c, nextActiveAfterRemoving(all, a)?.pubkeyHex)
        assertNull(nextActiveAfterRemoving(listOf(account(a, active = true)), a))
    }
}
