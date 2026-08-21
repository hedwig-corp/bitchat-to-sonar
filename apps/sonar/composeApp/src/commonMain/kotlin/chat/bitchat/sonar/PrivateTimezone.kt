package chat.bitchat.sonar

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import chat.bitchat.sonar.resources.Res
import chat.bitchat.sonar.resources.ahead
import chat.bitchat.sonar.resources.behind
import chat.bitchat.sonar.resources.hours
import chat.bitchat.sonar.resources.s_1_hour
import kotlinx.coroutines.delay
import org.jetbrains.compose.resources.stringResource
import kotlin.math.abs

/** Platform-localized wall time plus the peer/viewer UTC offset difference. */
data class PeerLocalTimeSnapshot(
    val timeText: String,
    val relativeOffsetMinutes: Int,
)

expect fun currentSystemTimeZoneId(): String

/** Returns null for an invalid or unavailable IANA identifier. */
expect fun peerLocalTimeSnapshot(
    ianaIdentifier: String,
    epochMillis: Long,
): PeerLocalTimeSnapshot?

/** A minute-boundary clock which only runs while its calling screen is composed. */
@Composable
fun rememberMinuteClock(key: Any?): Long {
    var nowMillis by remember(key) { mutableLongStateOf(SonarClock.nowMillis()) }
    LaunchedEffect(key) {
        if (key == null) return@LaunchedEffect
        while (true) {
            nowMillis = SonarClock.nowMillis()
            delay(60_000L - (nowMillis % 60_000L))
        }
    }
    return nowMillis
}

@Composable
fun peerLocalTimeText(snapshot: PeerLocalTimeSnapshot, includeRelative: Boolean): String {
    if (!includeRelative || snapshot.relativeOffsetMinutes == 0) return snapshot.timeText
    val amount = timezoneOffsetAmount(abs(snapshot.relativeOffsetMinutes))
    val relative = if (snapshot.relativeOffsetMinutes > 0) {
        stringResource(Res.string.ahead, amount)
    } else {
        stringResource(Res.string.behind, amount)
    }
    return "${snapshot.timeText} · $relative"
}

@Composable
private fun timezoneOffsetAmount(minutes: Int): String {
    val (hours, remainder) = timezoneOffsetParts(minutes)
    // Mixed offsets match design `bcZoneDelta`: `5h 30m`, not "5 hours 30 minutes".
    if (remainder != 0) return timezoneOffsetCompact(hours, remainder)
    return if (hours == 1) {
        stringResource(Res.string.s_1_hour)
    } else {
        stringResource(Res.string.hours, hours)
    }
}

/** Whole hours as words; mixed minutes as `5h 30m` (`bcZoneDelta` in screens.jsx). */
internal fun timezoneOffsetAmountText(minutes: Int): String {
    val (hours, remainder) = timezoneOffsetParts(minutes)
    if (remainder != 0) return timezoneOffsetCompact(hours, remainder)
    return if (hours == 1) "1 hour" else "$hours hours"
}

private fun timezoneOffsetCompact(hours: Int, remainder: Int): String = "${hours}h ${remainder}m"

internal fun timezoneOffsetParts(minutes: Int): Pair<Int, Int> = minutes / 60 to minutes % 60

internal const val TIMEZONE_SHARE_BLOB_KEY = "timezone.shareByChat"

internal fun encodeTimezoneShareMap(map: Map<String, Boolean>): String =
    map.entries.joinToString("\n") { "${it.key}|${if (it.value) "1" else "0"}" }

internal fun decodeTimezoneShareMap(blob: String): Map<String, Boolean> =
    blob.lineSequence()
        .mapNotNull { line ->
            val i = line.lastIndexOf('|')
            if (i <= 0) return@mapNotNull null
            val on = when (line.substring(i + 1)) {
                "1" -> true
                "0" -> false
                else -> return@mapNotNull null
            }
            val chatId = line.substring(0, i)
            if (chatId.isBlank()) null else chatId to on
        }
        .toMap()

