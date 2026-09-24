package chat.bitchat.sonar

import android.app.KeyguardManager
import android.content.Context

/** Holds the live Activity so [AppLock] can launch the device-credential UI. */
object ActivityBridge {
    /** Set by MainActivity: launches the confirm-device-credential flow,
     *  delivering the result to the callback. */
    @Volatile var requestUnlock: ((onResult: (Boolean) -> Unit) -> Unit)? = null

    /** Set by MainActivity: shows the system prompt for one runtime
     *  permission if it is not granted yet (no result delivered — callers
     *  re-check on the user's next attempt). */
    @Volatile var requestPermission: ((permission: String) -> Unit)? = null
}

actual object AppLock {
    private val ctx: Context get() = AppContextHolder.ctx
    private fun prefs() = ctx.getSharedPreferences("sonar", Context.MODE_PRIVATE)
    private fun keyguard() = ctx.getSystemService(KeyguardManager::class.java)

    actual fun isEnabled(): Boolean = prefs().getBoolean("applock", false) && isAvailable()

    actual fun setEnabled(value: Boolean) {
        prefs().edit().putBoolean("applock", value).apply()
    }

    actual fun isAvailable(): Boolean = keyguard()?.isDeviceSecure == true

    actual fun authenticate(onResult: (Boolean) -> Unit) {
        val req = ActivityBridge.requestUnlock
        if (req == null) { onResult(false); return }
        req(onResult)
    }
}
