package chat.bitchat.sonar

import android.content.Context
import android.os.PowerManager

actual object BatterySaver {
    actual fun enabled(): Boolean {
        val power = AppContextHolder.ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return power?.isPowerSaveMode == true
    }
}
