package chat.bitchat.sonar.backup

actual fun schedulePlatformAutoBackupWork() {
    scheduleAndroidAutoBackupWork()
}

actual fun cancelPlatformAutoBackupWork() {
    cancelAndroidAutoBackupWork()
}

actual fun setLiveUiSessionForAutoBackup(live: Boolean) {
    MarmotSessionGate.setLiveUiSession(live)
}
