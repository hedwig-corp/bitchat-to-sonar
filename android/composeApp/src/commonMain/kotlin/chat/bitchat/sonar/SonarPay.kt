package chat.bitchat.sonar

/**
 * The ⚡PAY message convention (1:1 port of the iOS SonarPayLedger codec):
 * plain control strings carried inside normal encrypted chat content, so
 * payments ride the existing transport (Marmot / mesh / Nostr DM):
 *
 *   ⚡PAY|1|<uuid>|<sats>        — a sealed coin offered to the counterpart
 *   ⚡PAYCLAIM|1|<uuid>|<bolt12> — claimant returns a BOLT12 offer to settle into
 *   ⚡PAYDONE|1|<uuid>           — sender confirms the coin was paid
 *
 * Unknown versions render as plain text (forward-compatible).
 */
sealed interface PayLine {
    data class Pay(val uuid: String, val sats: Long) : PayLine
    data class Claim(val uuid: String, val offer: String) : PayLine
    data class Done(val uuid: String) : PayLine

    fun encoded(): String = when (this) {
        is Pay -> "⚡PAY|1|$uuid|$sats"
        is Claim -> "⚡PAYCLAIM|1|$uuid|$offer"
        is Done -> "⚡PAYDONE|1|$uuid"
    }

    companion object {
        fun decode(content: String): PayLine? {
            val parts = content.split("|")
            if (parts.size < 3 || parts[1] != "1") return null
            return when (parts[0]) {
                "⚡PAY" -> parts.getOrNull(3)?.toLongOrNull()?.let { Pay(parts[2], it) }
                "⚡PAYCLAIM" -> parts.getOrNull(3)?.let { Claim(parts[2], it) }
                "⚡PAYDONE" -> Done(parts[2])
                else -> null
            }
        }
    }
}

/** Lifecycle of a sealed coin, mirrored from the iOS ledger. */
enum class PayStatus { Sealed, Claiming, Settling, Claimed, Failed }
