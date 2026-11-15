package chat.bitchat.sonar

import android.os.Build

/** Zapstore / Play / GitHub release, by the package that installed this build. */
actual fun sonarAppUpdateUrl(): String {
    val installer = runCatching {
        val ctx = AppContextHolder.ctx
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            ctx.packageManager.getInstallSourceInfo(ctx.packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            ctx.packageManager.getInstallerPackageName(ctx.packageName)
        }
    }.getOrNull()
    return sonarUpdateUrlForInstaller(installer)
}
