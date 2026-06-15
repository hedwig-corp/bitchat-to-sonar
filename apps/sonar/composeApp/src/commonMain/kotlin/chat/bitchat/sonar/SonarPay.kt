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
                // Reject non-positive sats — a peer-controlled line must not seed
                // a zero/negative coin into the ledger.
                "⚡PAY" -> parts.getOrNull(3)?.toLongOrNull()?.takeIf { it > 0 }?.let { Pay(parts[2], it) }
                "⚡PAYCLAIM" -> parts.getOrNull(3)?.let { Claim(parts[2], it) }
                "⚡PAYDONE" -> Done(parts[2])
                else -> null
            }
        }
    }
}

/** Lifecycle of a sealed coin, mirrored from the iOS ledger. */
enum class PayStatus { Sealed, Claiming, Settling, Claimed, Failed }

/** One tracked coin. */
data class PayEntry(val uuid: String, val sats: Long, val status: PayStatus, val mine: Boolean)

/**
 * The ⚡PAY ledger — a 1:1 port of the iOS SonarPayLedger state machine. Coin
 * states survive restart (the app persists [serialize] via SonarCore.saveBlob);
 * transitions are idempotent so replaying chat transcripts after a relaunch
 * cannot double-settle. A claim/settle that fails reverts to Sealed.
 */
class SonarPayLedger(blob: String = "") {
    private val entries = LinkedHashMap<String, PayEntry>()

    init {
        for (line in blob.split("\n")) {
            val p = line.split("|")
            if (p.size != 4) continue
            val sats = p[1].toLongOrNull() ?: continue
            val status = runCatching { PayStatus.valueOf(p[2]) }.getOrNull() ?: continue
            entries[p[0]] = PayEntry(p[0], sats, status, p[3] == "1")
        }
    }

    fun all(): List<PayEntry> = entries.values.toList()
    fun get(uuid: String): PayEntry? = entries[uuid]

    fun serialize(): String =
        entries.values.joinToString("\n") { "${it.uuid}|${it.sats}|${it.status}|${if (it.mine) 1 else 0}" }

    /** Record a freshly-sealed coin (idempotent). Returns true if it changed. */
    fun recordSealed(uuid: String, sats: Long, mine: Boolean): Boolean {
        if (entries.containsKey(uuid)) return false
        entries[uuid] = PayEntry(uuid, sats, PayStatus.Sealed, mine)
        return true
    }

    /** Claimant began claiming (Sealed → Claiming). */
    fun markClaiming(uuid: String): Boolean = transition(uuid, PayStatus.Claiming) { it == PayStatus.Sealed }

    /** Sender received a CLAIM and is settling (Sealed → Settling). */
    fun markSettling(uuid: String): Boolean = transition(uuid, PayStatus.Settling) { it == PayStatus.Sealed }

    /** Coin settled (any non-terminal → Claimed). */
    fun markClaimed(uuid: String): Boolean = transition(uuid, PayStatus.Claimed) { it != PayStatus.Claimed }

    /** A claim/settle attempt failed — revert so it can be retried. */
    fun fail(uuid: String): Boolean =
        transition(uuid, PayStatus.Sealed) { it == PayStatus.Claiming || it == PayStatus.Settling }

    private fun transition(uuid: String, to: PayStatus, allowed: (PayStatus) -> Boolean): Boolean {
        val e = entries[uuid] ?: return false
        if (!allowed(e.status)) return false
        entries[uuid] = e.copy(status = to)
        return true
    }
}
