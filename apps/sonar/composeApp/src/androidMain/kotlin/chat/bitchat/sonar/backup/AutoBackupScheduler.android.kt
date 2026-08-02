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

/** `ConnectivityManager.isActiveNetworkMetered` is authoritative on Android. */
actual val meteredNetworkPolicySupported: Boolean = true

actual fun isNetworkMetered(): Boolean {
    val ctx = try {
        chat.bitchat.sonar.AppContextHolder.ctx
    } catch (_: UninitializedPropertyAccessException) {
        // No context yet ⇒ cannot prove the link is free. Assume metered.
        return true
    }
    val cm = ctx.getSystemService(android.content.Context.CONNECTIVITY_SERVICE)
        as? android.net.ConnectivityManager ?: return true
    // `isActiveNetworkMetered` already folds in the user's "treat this Wi-Fi as
    // metered" override, which a capability check on TRANSPORT_CELLULAR alone
    // would miss.
    return cm.isActiveNetworkMetered
}
