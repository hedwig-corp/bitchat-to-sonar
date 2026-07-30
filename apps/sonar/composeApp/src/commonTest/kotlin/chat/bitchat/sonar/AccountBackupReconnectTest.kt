package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AccountBackupReconnectTest {
    @Test
    fun backup_reconnect_must_not_clear_home_hydration() {
        // Clearing homeMessagesHydrated paints LocalStateLaunchSurface and looks
        // like an app restart when Settings → Backup is tapped on Android.
        // Production path also `check(homeMessagesHydrated)` inside
        // cancelMarmotJobsForExclusiveBackup — this pins the policy constant.
        assertFalse(AccountBackupReconnect.clearsHomeMessagesHydrated())
    }

    @Test
    fun sanity_checks_flag_missing_cloud_backup_and_dirty() {
        val checks = buildBackupSanityChecks(
            hasIdentity = true,
            localDbReady = true,
            disclosed = true,
            policyReadable = true,
            autoBackupEnabled = true,
            lastSuccessAt = null,
            lastError = null,
            dirty = true,
            relayConnected = false,
        )
        assertEquals(7, checks.size)
        assertTrue(checks.first { it.key == "identity" }.ok)
        assertFalse(checks.first { it.key == "cloud" }.ok)
        assertFalse(checks.first { it.key == "dirty" }.ok)
        assertFalse(checks.first { it.key == "relay" }.ok)
    }

    @Test
    fun sanity_checks_pass_when_backup_healthy() {
        val checks = buildBackupSanityChecks(
            hasIdentity = true,
            localDbReady = true,
            disclosed = true,
            policyReadable = true,
            autoBackupEnabled = true,
            lastSuccessAt = 1_700_000_000L,
            lastError = null,
            dirty = false,
            relayConnected = true,
        )
        assertTrue(checks.all { it.ok })
    }
}

class FirstBackupDisclosureTest {

    /**
     * The case the whole thing exists for: an account that upgraded into the
     * backup feature. Onboarded on an older build, so disclosure was never
     * marked, and `lastSuccessAt` is null because no backup has ever run.
     *
     * A null timestamp must not be read as "unknown" — an early implementation
     * used `policy?.lastSuccessAt ?: return`, which bailed out on exactly this
     * input and left the account backing up never.
     */
    @Test
    fun anUpgradedAccountWithNoBackupIsDisclosed() {
        assertTrue(
            shouldDiscloseForFirstBackup(
                onboarded = true,
                alreadyDisclosed = false,
                policyReadable = true,
                lastSuccessAt = null,
            )
        )
        assertTrue(
            shouldDiscloseForFirstBackup(
                onboarded = true,
                alreadyDisclosed = false,
                policyReadable = true,
                lastSuccessAt = 0L,
            ),
            "a zero timestamp means the same as null: never backed up",
        )
    }

    /** An account that already has a backup is left alone. */
    @Test
    fun anAccountThatHasBackedUpIsNotReDisclosed() {
        assertFalse(
            shouldDiscloseForFirstBackup(
                onboarded = true,
                alreadyDisclosed = false,
                policyReadable = true,
                lastSuccessAt = 1_700_000_000L,
            )
        )
    }

    /**
     * An unreadable policy must fail closed. Treating it as "never backed up"
     * would disclose on every launch where the store happened to be busy.
     */
    @Test
    fun anUnreadablePolicyDoesNotDisclose() {
        assertFalse(
            shouldDiscloseForFirstBackup(
                onboarded = true,
                alreadyDisclosed = false,
                policyReadable = false,
                lastSuccessAt = null,
            )
        )
    }

    /** Before onboarding there is no account to protect, and no consent yet. */
    @Test
    fun anUnonboardedAccountIsNotDisclosed() {
        assertFalse(
            shouldDiscloseForFirstBackup(
                onboarded = false,
                alreadyDisclosed = false,
                policyReadable = true,
                lastSuccessAt = null,
            )
        )
    }

    /** Already disclosed is a no-op, so this never re-runs. */
    @Test
    fun anAlreadyDisclosedAccountIsANoOp() {
        assertFalse(
            shouldDiscloseForFirstBackup(
                onboarded = true,
                alreadyDisclosed = true,
                policyReadable = true,
                lastSuccessAt = null,
            )
        )
    }
}
