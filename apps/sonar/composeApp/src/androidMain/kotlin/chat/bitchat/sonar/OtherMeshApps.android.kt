package chat.bitchat.sonar

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings

actual object OtherMeshApps {
    // Visible only because AndroidManifest.xml declares each package under
    // <queries>; without that, Android 11+ reports every package as missing.
    actual fun installed(): List<OtherMeshApp> {
        val pm = AppContextHolder.ctx.packageManager
        return KNOWN_OTHER_MESH_APPS.filter { app ->
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    pm.getPackageInfo(app.packageName, PackageManager.PackageInfoFlags.of(0))
                } else {
                    @Suppress("DEPRECATION") pm.getPackageInfo(app.packageName, 0)
                }
            }.isSuccess
        }
    }

    actual fun openSettings(app: OtherMeshApp) {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", app.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { AppContextHolder.ctx.startActivity(intent) }
    }
}
