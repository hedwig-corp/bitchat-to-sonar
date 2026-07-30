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

actual fun enqueueOneShotPlatformAutoBackup() {
    enqueueOneShotAndroidAutoBackup()
}

actual fun currentUtcOffsetSecs(): Long =
    java.util.TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000L
