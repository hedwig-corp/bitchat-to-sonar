package chat.bitchat.sonar

import chat.bitchat.sonar.backup.AccountBackupOutcome
import chat.bitchat.sonar.backup.AutoBackupNetworkPolicy
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * Guards the cadence/metered half of the "Sonar ate 66.3 GB of mobile data in
 * one billing period" fix. Mirror of the iOS
 * `MarmotAccountBackupFlowTests` metered-gate cases.
 */
class AutoBackupNetworkPolicyTest {
    @Test
    fun meteredLinkBlocksAutomaticBackupByDefault() {
        assertFalse(
            AutoBackupNetworkPolicy.allowsUpload(metered = true, cellularOptIn = false),
            "a full-account upload must not run on cellular unless the user asked for it",
        )
    }

    @Test
    fun optingInAllowsAutomaticBackupOnCellular() {
        assertTrue(
            AutoBackupNetworkPolicy.allowsUpload(metered = true, cellularOptIn = true),
        )
    }

    @Test
    fun unmeteredLinksAreNeverGated() {
        assertTrue(AutoBackupNetworkPolicy.allowsUpload(metered = false, cellularOptIn = false))
        assertTrue(AutoBackupNetworkPolicy.allowsUpload(metered = false, cellularOptIn = true))
    }

    @Test
    fun coreRefusalToReuploadAnUnchangedAccountIsNotAFailure() {
        // Exactly what crosses UniFFI: SonarFfiError is a flat_error, so the
        // core Display text is the whole contract.
        assertTrue(
            AutoBackupNetworkPolicy.isUnchangedAccount(
                IllegalStateException(
                    "account backup unchanged since the last successful upload",
                ),
            ),
        )
    }

    @Test
    fun realBackupFailuresAreStillFailures() {
        assertFalse(
            AutoBackupNetworkPolicy.isUnchangedAccount(
                IllegalStateException("blossom upload timed out"),
            ),
        )
        assertFalse(
            AutoBackupNetworkPolicy.isUnchangedAccount(
                IllegalStateException("no account backup found on Blossom for this key"),
            ),
        )
    }

    /**
     * "Nothing to upload" and "the backup broke" are different outcomes. A
     * boolean conflated them, so a manual tap on an already-current account
     * toasted "Backup failed — try again when online" — the exact false alarm
     * this change set exists to remove.
     */
    @Test
    fun alreadyUpToDateIsNotAFailure() {
        assertNotEquals(AccountBackupOutcome.Failed, AccountBackupOutcome.AlreadyUpToDate)
        assertNotEquals(AccountBackupOutcome.Uploaded, AccountBackupOutcome.AlreadyUpToDate)
    }

    /**
     * A seal closes the node. If it will not reopen, chat is down until restart
     * — and that outranks anything the seal itself reported. Reporting
     * "already up to date" over a dead session is the worst of the three, so
     * the reopen failure has to be its own outcome rather than collapsing into
     * either neighbour.
     */
    @Test
    fun reopenFailureIsDistinctFromBothSuccessAndPlainFailure() {
        assertNotEquals(AccountBackupOutcome.AlreadyUpToDate, AccountBackupOutcome.ReopenFailed)
        assertNotEquals(AccountBackupOutcome.Uploaded, AccountBackupOutcome.ReopenFailed)
        // Also distinct from Failed: the caller keeps the precise
        // "Could not reopen chats" toast instead of a generic backup error.
        assertNotEquals(AccountBackupOutcome.Failed, AccountBackupOutcome.ReopenFailed)
    }
}
