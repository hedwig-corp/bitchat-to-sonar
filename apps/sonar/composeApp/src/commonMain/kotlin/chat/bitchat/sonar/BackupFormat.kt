package chat.bitchat.sonar

/**
 * Formatting for the Settings "Data & storage" rows and the Chat backup stats.
 *
 * Pure and in `commonMain` so iOS/Android/desktop render the same string for the
 * same number — the design shows these side by side and a per-platform rounding
 * difference would read as a bug.
 */
object BackupFormat {

    /**
     * Human size, matching the design's "124 MB" shape.
     *
     * Decimal MB (1000-based), not MiB: this number sits next to the OS storage
     * settings the user just came from, and those are decimal on both platforms.
     * Returns null for an unmeasured value so callers render a dash rather than
     * a confident "0 B".
     */
    fun bytes(value: Long?): String? {
        val v = value ?: return null
        if (v < 0) return null
        if (v < 1_000) return "$v B"
        val units = listOf("kB", "MB", "GB", "TB")
        var size = v.toDouble() / 1_000.0
        var unit = 0
        while (size >= 1_000.0 && unit < units.size - 1) {
            size /= 1_000.0
            unit += 1
        }
        // One decimal below 10 so "1.2 MB" does not collapse to "1 MB"; whole
        // numbers above, where the extra digit is noise.
        return if (size < 10.0) {
            val tenths = kotlin.math.round(size * 10).toLong()
            "${tenths / 10}.${tenths % 10} ${units[unit]}"
        } else {
            "${kotlin.math.round(size).toLong()} ${units[unit]}"
        }
    }

    /** Grouped count for the stats strip ("1,204"). */
    fun count(value: Long?): String? {
        val v = value ?: return null
        val digits = v.toString()
        val out = StringBuilder()
        for ((i, c) in digits.withIndex()) {
            if (i > 0 && (digits.length - i) % 3 == 0) out.append(',')
            out.append(c)
        }
        return out.toString()
    }

    /**
     * "Today, 04:12" / "Yesterday, 22:40" / "3 d ago" for the last-backup row.
     *
     * [nowSecs] is injected so this stays pure and testable — a helper that read
     * the clock itself could not be pinned.
     */
    fun lastBackup(atSecs: Long?, nowSecs: Long, offsetSecs: Long = 0): String? {
        val at = atSecs ?: return null
        if (at <= 0) return null
        val ago = nowSecs - at
        if (ago < 0) return "Just now"
        val localAt = at + offsetSecs
        val localNow = nowSecs + offsetSecs
        val dayAt = localAt / 86_400
        val dayNow = localNow / 86_400
        val clock = clockOf(localAt)
        return when {
            ago < 60 -> "Just now"
            dayAt == dayNow -> "Today, $clock"
            dayNow - dayAt == 1L -> "Yesterday, $clock"
            else -> "${ago / 86_400} d ago"
        }
    }

    private fun clockOf(epochSecs: Long): String {
        val secondsOfDay = ((epochSecs % 86_400) + 86_400) % 86_400
        val h = secondsOfDay / 3600
        val m = (secondsOfDay % 3600) / 60
        return "${pad(h)}:${pad(m)}"
    }

    private fun pad(v: Long): String = if (v < 10) "0$v" else "$v"

    /** Settings label for the core cadence values. */
    fun frequencyLabel(frequency: String): String = when (frequency) {
        "manual" -> "Manual only"
        "weekly" -> "Weekly"
        else -> "Daily"
    }
}
