package chat.bitchat.sonar.backup

actual fun schedulePlatformAutoBackupWork() = Unit

actual fun cancelPlatformAutoBackupWork() = Unit

actual fun setLiveUiSessionForAutoBackup(live: Boolean) = Unit
