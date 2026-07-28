package chat.bitchat.sonar.backup

actual fun schedulePlatformAutoBackupWork() = Unit

actual fun cancelPlatformAutoBackupWork() = Unit

actual fun setLiveUiSessionForAutoBackup(live: Boolean) = Unit

actual fun enqueueOneShotPlatformAutoBackup() {
    // Desktop has no WorkManager and no process-death-while-backgrounded
    // problem — the in-process attempt is the whole story.
}
