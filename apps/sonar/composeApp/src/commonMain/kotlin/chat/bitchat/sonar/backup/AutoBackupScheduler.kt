package chat.bitchat.sonar.backup

/** Platform periodic auto-backup (WorkManager on Android; no-op on JVM desktop). */
expect fun schedulePlatformAutoBackupWork()

expect fun cancelPlatformAutoBackupWork()

/** True while the Compose UI owns a live Marmot session (Android worker must skip). */
expect fun setLiveUiSessionForAutoBackup(live: Boolean)

/**
 * One-shot backup attempt shortly after the app leaves the foreground.
 *
 * The fallback half of opportunistic backup: the in-process attempt runs
 * immediately on background, and this survives the process being killed before
 * that attempt lands — a fresh worker process has the session gate down. The
 * worker re-checks `backup_is_due`, so when the in-process run already
 * uploaded, this no-ops.
 */
expect fun enqueueOneShotPlatformAutoBackup()
