package chat.bitchat.sonar

/**
 * The ⚡TRILL message convention (docs/SONAR-TRILL.md) — the MSN-style "nudge".
 * A trill is a plain control line carried inside normal encrypted chat content,
 * exactly like ⚡PAY, so it rides the existing transports (Marmot / mesh /
 * NIP-17) and persists as a real conversation row:
 *
 *   ⚡TRILL|1|<id>
 *
 * - version is locked to 1: any other version is NOT a trill line and renders
 *   as plain text on old clients instead of mis-rendering.
 * - <id> is a sender-generated token, 1-64 chars of [0-9a-fA-F-] (hex-or-dash,
 *   the ⚡PAY id shape). It recognises the same trill across the mesh and
 *   Marmot legs and keys receiver-side alert throttling.
 * - No trailing fields: `⚡TRILL|1|abc|extra` is not a trill line.
 *
 * Canonical parser: `parse_trill_line` in core/sonar-core/src/notification.rs.
 */
data class TrillLine(val id: String) {
    fun encoded(): String = "⚡TRILL|1|$id"

    companion object {
        private const val PREFIX = "⚡TRILL"

        fun decode(content: String): TrillLine? {
            val parts = content.split("|")
            if (parts.size != 3) return null
            if (parts[0] != PREFIX) return null
            if (parts[1] != "1") return null
            val id = parts[2]
            if (id.isEmpty() || id.length > 64) return null
            if (!id.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' || it == '-' }) return null
            return TrillLine(id)
        }

        fun isTrillLine(content: String): Boolean = decode(content) != null
    }
}

internal fun randomTrillId(): String =
    (0 until 16).map { "0123456789abcdef".random() }.joinToString("")

/** MSN's own guard: the nudge action is disabled for 8 s per chat after sending. */
internal const val TRILL_SEND_COOLDOWN_MS = 8_000L

/** Receiver-side guard: at most one buzz/notification per chat per window.
 *  Client cooldowns cannot be trusted — the receiver enforces its own window
 *  on a monotonic clock. Excess trills still persist as rows and count unread;
 *  they just alert silently. */
internal const val TRILL_ALERT_WINDOW_MS = 8_000L

internal class TrillAlertThrottle(private val windowMs: Long = TRILL_ALERT_WINDOW_MS) {
    private val lastAlertMs = HashMap<String, Long>()

    /** True when this chat may alert now; consumes the window when it does. */
    fun tryAlert(chatId: String, nowMs: Long): Boolean {
        val last = lastAlertMs[chatId]
        if (last != null && nowMs - last < windowMs) return false
        lastAlertMs[chatId] = nowMs
        return true
    }
}
