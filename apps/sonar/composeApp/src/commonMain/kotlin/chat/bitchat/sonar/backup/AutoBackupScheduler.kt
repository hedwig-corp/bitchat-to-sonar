package chat.bitchat.sonar.backup

/** Platform periodic auto-backup (WorkManager on Android; no-op on JVM desktop). */
expect fun schedulePlatformAutoBackupWork()

expect fun cancelPlatformAutoBackupWork()

/** True while the Compose UI owns a live Marmot session (Android worker must skip). */
expect fun setLiveUiSessionForAutoBackup(live: Boolean)
