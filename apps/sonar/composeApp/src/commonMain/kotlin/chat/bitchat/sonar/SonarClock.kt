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

    /** Monotonic milliseconds (immune to wall-clock changes) — used for the
     *  trill send-cooldown and receiver alert throttle windows. */
    fun monotonicMillis(): Long

    /** Local "HH:MM" (24h, zero-padded) label for [epochSecs] — design `bcNow`. */
    fun hourMinute(epochSecs: Long): String
}
