package chat.bitchat.sonar

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Desktop (JVM) `actual`: `SimpleDateFormat` for the call-log "HH:MM" time
 *  (same as Android — the JVM has both APIs). */
actual object SonarClock {
    actual fun nowSecs(): Long = System.currentTimeMillis() / 1000

    actual fun hourMinute(epochSecs: Long): String =
        SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(epochSecs * 1000))
}
