package chat.bitchat.sonar

/**
 * Per-chat mute (docs/SONAR-TRILL.md, shipped with the trill but general):
 * a local map chatId → mute-until epoch seconds, persisted as a blob. Muting
 * suppresses notifications/sounds/haptics/shake for ALL message kinds in the
 * chat; rows and unread counts still accrue (the home row swaps the unread dot
 * for a bell-off icon). Mute state is local to the install — it does not sync
 * across linked devices (tracked gap; Signal syncs it).
 */

/** Sentinel until-value for "Until I turn it back on". */
internal const val MUTE_FOREVER_SECS = Long.MAX_VALUE

/** Blob key for the persisted mute map — read by both the app state and the
 *  killed-app push-wake drain (SonarPushProcessingService). */
internal const val MUTE_BLOB_KEY = "mute.byChat"

/** True while [untilSecs] covers [nowSecs]. Expired entries read as unmuted
 *  (lazy expiry — pruning happens off the render path). */
internal fun isMutedAt(untilSecs: Long?, nowSecs: Long): Boolean =
    untilSecs != null && nowSecs < untilSecs

/** Drop expired entries (kept pure so callers choose when to persist). */
internal fun withExpiredMutesCleared(map: Map<String, Long>, nowSecs: Long): Map<String, Long> =
    map.filterValues { nowSecs < it }

internal fun encodeMuteMap(map: Map<String, Long>): String =
    map.entries.joinToString("\n") { "${it.key}|${it.value}" }

internal fun decodeMuteMap(blob: String): Map<String, Long> =
    blob.lineSequence()
        .mapNotNull { line ->
            val i = line.lastIndexOf('|')
            if (i <= 0) return@mapNotNull null
            val until = line.substring(i + 1).toLongOrNull() ?: return@mapNotNull null
            val chatId = line.substring(0, i)
            if (chatId.isBlank()) null else chatId to until
        }
        .toMap()

/** The MuteSheet duration ladder (design MuteSheet): label + seconds, with
 *  null seconds meaning "Until I turn it back on". */
internal data class MuteDuration(val label: String, val secs: Long?)

internal val MUTE_DURATIONS: List<MuteDuration> = listOf(
    MuteDuration("1 hour", 3_600L),
    MuteDuration("8 hours", 8 * 3_600L),
    MuteDuration("1 day", 24 * 3_600L),
    MuteDuration("1 week", 7 * 24 * 3_600L),
    MuteDuration("Until I turn it back on", null),
)

/** Resolve a duration pick to the persisted until-value. */
internal fun muteUntilFor(durationSecs: Long?, nowSecs: Long): Long =
    if (durationSecs == null) MUTE_FOREVER_SECS else nowSecs + durationSecs
