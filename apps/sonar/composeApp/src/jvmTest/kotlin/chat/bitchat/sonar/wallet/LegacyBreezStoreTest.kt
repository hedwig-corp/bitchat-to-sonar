package chat.bitchat.sonar.wallet

import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The legacy Breez store's disk rules on a real filesystem: presence never
 * creates anything, a store is never opened for the wrong account, and an
 * archived wallet comes back only to its own account.
 */
class LegacyBreezStoreTest {

    private val root: File = Files.createTempDirectory("sonar-legacy-store").toFile()
    private val store = LegacyBreezStore({ root.absolutePath }, platformWalletFiles())
    private val live = File(root, "sonar-wallet")

    private fun seedLiveStore(owner: String? = null) {
        File(live, "mainnet").mkdirs()
        File(live, "mainnet/storage.sql").writeText("breez")
        owner?.let { File(live, "sonar-owner").writeText(it) }
    }

    @Test
    fun presenceOnAFreshInstallCreatesNothing() {
        assertFalse(store.resolvePresent("acct-a"))
        assertEquals(emptyList(), root.list()!!.toList(), "a fresh install must not grow sonar-wallet/")
    }

    @Test
    fun anEmptyLeftoverFromAFailedConnectIsNotAStore() {
        File(live, "mainnet").mkdirs()
        assertFalse(store.resolvePresent("acct-a"))
    }

    @Test
    fun aStoreFromBeforeThisBuildBelongsToTheSignedInAccount() {
        seedLiveStore(owner = null)
        assertTrue(store.resolvePresent("acct-a"))
        assertTrue(store.claim("acct-a"))
        assertEquals("acct-a", store.owner())
    }

    @Test
    fun anotherAccountsStoreIsMovedAsideNeverOpened() {
        seedLiveStore(owner = "acct-b")
        assertFalse(store.resolvePresent("acct-a"))
        assertFalse(live.exists())
        assertTrue(File(root, "sonar-wallet-archive/acct-b/mainnet/storage.sql").isFile)
    }

    @Test
    fun anArchivedWalletComesBackToItsAccount() {
        seedLiveStore(owner = "acct-a")
        assertTrue(store.archive("acct-a"))
        assertFalse(live.exists())
        assertFalse(store.resolvePresent("acct-c"), "not another account's")
        assertTrue(store.resolvePresent("acct-a"))
        assertEquals("breez", File(live, "mainnet/storage.sql").readText())
        assertFalse(File(root, "sonar-wallet-archive/acct-a").exists())
    }

    /** An archive may hold funds: archiving again must never replace it. */
    @Test
    fun archivingNeverOverwritesAnExistingArchive() {
        File(root, "sonar-wallet-archive/acct-a/mainnet").mkdirs()
        File(root, "sonar-wallet-archive/acct-a/mainnet/storage.sql").writeText("older funds")
        seedLiveStore(owner = "acct-a")
        assertTrue(store.archive("acct-a"))
        assertFalse(live.exists())
        assertEquals(
            "older funds",
            File(root, "sonar-wallet-archive/acct-a/mainnet/storage.sql").readText(),
        )
        assertEquals("breez", File(root, "sonar-wallet-archive/acct-a-2/mainnet/storage.sql").readText())
    }

    @Test
    fun anInterruptedRestoreCheckLeavesNoWallet() {
        assertTrue(store.beginRestoreCheck())
        File(live, "mainnet/storage.sql").apply { parentFile.mkdirs(); writeText("half") }
        assertFalse(store.hasLiveStore())
        assertFalse(store.resolvePresent("acct-a"))
        assertFalse(live.exists(), "the unfinished check's store is removed")
    }

    @Test
    fun aKeptRestoreCheckIsThatAccountsWallet() {
        assertTrue(store.beginRestoreCheck())
        File(live, "mainnet/storage.sql").apply { parentFile.mkdirs(); writeText("funds") }
        assertTrue(store.keepRestoreCheck("acct-a"))
        assertTrue(store.resolvePresent("acct-a"))
        assertEquals("acct-a", store.owner())
    }

    @Test
    fun panicDeleteRemovesTheStoreAndEveryArchive() {
        seedLiveStore(owner = "acct-a")
        File(root, "sonar-wallet-archive/acct-b/mainnet").mkdirs()
        assertTrue(store.deleteEverything())
        assertFalse(live.exists())
        assertFalse(File(root, "sonar-wallet-archive").exists())
    }
}
