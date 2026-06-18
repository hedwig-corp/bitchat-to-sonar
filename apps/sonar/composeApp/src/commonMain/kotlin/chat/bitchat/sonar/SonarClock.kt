package chat.bitchat.sonar

/**
 * Tiny wall-clock helper for UI timestamps that have no platform-agnostic
 * primitive in commonMain (no kotlinx-datetime dependency). Used by the call
 * log to stamp a "HH:MM" time on each record, mirroring the design's `bcNow()`.
 */
expect object SonarClock {
    /** Current epoch milliseconds. */
    fun nowMillis(): Long

    /** Current epoch seconds. */
    fun nowSecs(): Long

    /** Local "HH:MM" (24h, zero-padded) label for [epochSecs] — design `bcNow`. */
    fun hourMinute(epochSecs: Long): String
}
