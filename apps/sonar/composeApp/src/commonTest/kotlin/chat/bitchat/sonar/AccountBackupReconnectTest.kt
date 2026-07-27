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
