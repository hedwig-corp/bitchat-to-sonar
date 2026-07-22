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
import chat.bitchat.sonar.resources.minutes
import chat.bitchat.sonar.resources.s_1_hour
import chat.bitchat.sonar.resources.s_1_minute
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
    return when {
        hours == 0 && remainder == 1 -> stringResource(Res.string.s_1_minute)
        hours == 0 -> stringResource(Res.string.minutes, remainder)
        remainder == 0 && hours == 1 -> stringResource(Res.string.s_1_hour)
        remainder == 0 -> stringResource(Res.string.hours, hours)
        else -> {
            val hourText = if (hours == 1) {
                stringResource(Res.string.s_1_hour)
            } else {
                stringResource(Res.string.hours, hours)
            }
            val minuteText = if (remainder == 1) {
                stringResource(Res.string.s_1_minute)
            } else {
                stringResource(Res.string.minutes, remainder)
            }
            "$hourText $minuteText"
        }
    }
}

internal fun timezoneOffsetParts(minutes: Int): Pair<Int, Int> = minutes / 60 to minutes % 60
