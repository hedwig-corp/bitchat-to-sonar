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
}
