package chat.bitchat.sonar.backup

actual fun schedulePlatformAutoBackupWork() = Unit

actual fun cancelPlatformAutoBackupWork() = Unit

actual fun setLiveUiSessionForAutoBackup(live: Boolean) = Unit

actual fun enqueueOneShotPlatformAutoBackup() {
    // Desktop has no WorkManager and no process-death-while-backgrounded
    // problem — the in-process attempt is the whole story.
}

actual fun currentUtcOffsetSecs(): Long =
    java.util.TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000L

/**
 * The JVM has no portable way to ask whether the active route is metered, so
 * this cannot answer honestly — see [meteredNetworkPolicySupported], which is
 * `false` here precisely so the Backup screen does not offer a "wait for Wi-Fi"
 * control this platform is unable to honour.
 *
 * Returns `false` (not metered) rather than `true`: with no enforceable policy,
 * defaulting to "metered" would suppress desktop auto-backup entirely, and a
 * backup that never runs is worse than one that runs on a hotspot.
 */
actual fun isNetworkMetered(): Boolean = false

actual val meteredNetworkPolicySupported: Boolean = false
