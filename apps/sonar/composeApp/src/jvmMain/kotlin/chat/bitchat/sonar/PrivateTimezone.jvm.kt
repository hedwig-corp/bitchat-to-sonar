package chat.bitchat.sonar

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

actual fun currentSystemTimeZoneId(): String = ZoneId.systemDefault().id

actual fun peerLocalTimeSnapshot(
    ianaIdentifier: String,
    epochMillis: Long,
): PeerLocalTimeSnapshot? = runCatching {
    val instant = Instant.ofEpochMilli(epochMillis)
    val peerZone = ZoneId.of(ianaIdentifier)
    val viewerZone = ZoneId.systemDefault()
    val formatter = DateTimeFormatter
        .ofLocalizedTime(FormatStyle.SHORT)
        .withLocale(Locale.getDefault())
        .withZone(peerZone)
    val offsetSeconds = peerZone.rules.getOffset(instant).totalSeconds -
        viewerZone.rules.getOffset(instant).totalSeconds
    PeerLocalTimeSnapshot(
        timeText = formatter.format(instant),
        relativeOffsetMinutes = offsetSeconds / 60,
    )
}.getOrNull()
