package chat.bitchat.sonar

/**
 * After Settings / auto-backup seals the Marmot DB under exclusive access, the
 * host must reopen the node without a cold-boot UI path.
 *
 * Clearing [SonarAppState.homeMessagesHydrated] paints `LocalStateLaunchSurface`
 * and looks like an app restart on Android when Backup is tapped.
 */
internal object AccountBackupReconnect {
    fun clearsHomeMessagesHydrated(): Boolean = false
}

/** One row in Settings → Chat backup sanity checklist. */
data class BackupSanityItem(
    val key: String,
    val title: String,
    val ok: Boolean,
    val detail: String,
)

/**
 * Pure checklist builder for Settings → Chat backup. Hosts supply live
 * snapshots; UI only renders the list.
 */
internal fun buildBackupSanityChecks(
    hasIdentity: Boolean,
    localDbReady: Boolean,
    disclosed: Boolean,
    policyReadable: Boolean,
    autoBackupEnabled: Boolean,
    lastSuccessAt: Long?,
    lastError: String?,
    dirty: Boolean,
    relayConnected: Boolean,
): List<BackupSanityItem> = listOf(
    BackupSanityItem(
        key = "identity",
        title = "Account key",
        ok = hasIdentity,
        detail = if (hasIdentity) "nsec present on this device" else "Missing account key",
    ),
    BackupSanityItem(
        key = "local_db",
        title = "Local chat database",
        ok = localDbReady,
        detail = if (localDbReady) "Marmot DB open" else "Chat database not ready",
    ),
    BackupSanityItem(
        key = "disclosed",
        title = "Backup settings opened",
        ok = disclosed,
        detail = if (disclosed) "Auto-backup may run when due" else "Open this page to allow auto-backup",
    ),
    BackupSanityItem(
        key = "policy",
        title = "Backup policy",
        ok = policyReadable,
        detail = when {
            !policyReadable -> "Could not read backup policy"
            autoBackupEnabled -> "Auto-backup on"
            else -> "Auto-backup off"
        },
    ),
    BackupSanityItem(
        key = "cloud",
        title = "Cloud backup",
        ok = lastSuccessAt != null && lastSuccessAt > 0L && lastError.isNullOrBlank(),
        detail = when {
            lastSuccessAt != null && lastSuccessAt > 0L && lastError.isNullOrBlank() ->
                "Last upload succeeded"
            !lastError.isNullOrBlank() -> lastError
            else -> "No successful upload yet"
        },
    ),
    BackupSanityItem(
        key = "dirty",
        title = "Pending changes",
        ok = !dirty,
        detail = if (dirty) "Chats changed since last backup" else "In sync with last backup",
    ),
    BackupSanityItem(
        key = "relay",
        title = "Internet for upload",
        ok = relayConnected,
        detail = if (relayConnected) "Online — upload can reach Blossom" else "Offline — seal works; upload needs network",
    ),
)

/**
 * Whether an existing account should be disclosed so its first backup can run.
 *
 * Disclosure used to be marked only when onboarding completed, so every install
 * that upgraded into the backup feature stayed gated forever — an account full
 * of chats and no backup, waiting for a trip to Settings most people never
 * make. Finishing onboarding on any build is the same signal the onboarding
 * path already treats as disclosure.
 *
 * @param policyReadable false when the policy could not be loaded. An
 *   unreadable policy must not be mistaken for "never backed up".
 * @param lastSuccessAt null or 0 means no backup has ever succeeded — the case
 *   this exists to handle, so it must not be confused with "unknown".
 */
internal fun shouldDiscloseForFirstBackup(
    onboarded: Boolean,
    alreadyDisclosed: Boolean,
    policyReadable: Boolean,
    lastSuccessAt: Long?,
): Boolean {
    if (!onboarded || alreadyDisclosed || !policyReadable) return false
    return (lastSuccessAt ?: 0L) <= 0L
}
