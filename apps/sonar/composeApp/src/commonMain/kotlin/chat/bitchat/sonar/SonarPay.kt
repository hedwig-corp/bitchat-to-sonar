package chat.bitchat.sonar

/**
 * The ⚡PAY message convention: plain control strings carried inside normal
 * encrypted chat content, so payment receipts ride the existing transport
 * (Marmot / mesh / Nostr DM):
 *
 *   ⚡PAY|1|<uuid>|<sats> — payment receipt shown in the conversation
 *   ⚡PAYDONE|1|<uuid>    — sender confirms the Lightning payment settled
 *
 * Unknown versions render as plain text (forward-compatible).
 */
sealed interface PayLine {
    data class Pay(val uuid: String, val sats: Long) : PayLine
    data class Done(val uuid: String) : PayLine

    fun encoded(): String = when (this) {
        is Pay -> "⚡PAY|1|$uuid|$sats"
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
                "⚡PAYDONE" -> Done(parts[2])
                else -> null
            }
        }
    }
}

internal fun randomPayId(): String =
    (0 until 16).map { "0123456789abcdef".random() }.joinToString("")

/** Lifecycle of a direct payment receipt, mirrored from the iOS ledger. */
enum class PayStatus { Sealed, Claiming, Settling, Claimed, Failed }

/** One tracked coin. */
data class PayEntry(val uuid: String, val sats: Long, val status: PayStatus, val mine: Boolean)

/**
 * The ⚡PAY ledger. States survive restart (the app persists [serialize] via
 * SonarCore.saveBlob); transitions are idempotent so replaying chat transcripts
 * after a relaunch cannot duplicate receipts. Claiming/Settling remain decodeable
 * for previously persisted rows, but new protocol messages only create Sealed
 * and Claimed receipts.
 */
class SonarPayLedger(blob: String = "") {
    private val entries = LinkedHashMap<String, PayEntry>()
    private val pendingDone = HashSet<String>()

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

    /** Record a receipt (idempotent). Returns true if it changed. */
    fun recordSealed(uuid: String, sats: Long, mine: Boolean): Boolean {
        if (entries.containsKey(uuid)) return false
        val doneWasPending = pendingDone.remove(uuid)
        val status = if (mine || doneWasPending) PayStatus.Claimed else PayStatus.Sealed
        entries[uuid] = PayEntry(uuid, sats, status, mine)
        return true
    }

    /** Coin settled (any non-terminal → Claimed). */
    fun markClaimed(uuid: String): Boolean = transition(uuid, PayStatus.Claimed) { it != PayStatus.Claimed }

    /** Mark claimed, or remember DONE when it arrives before the matching PAY. */
    fun markClaimedOrPending(uuid: String): Boolean {
        if (!entries.containsKey(uuid)) {
            pendingDone.add(uuid)
            return false
        }
        return markClaimed(uuid)
    }

    private fun transition(uuid: String, to: PayStatus, allowed: (PayStatus) -> Boolean): Boolean {
        val e = entries[uuid] ?: return false
        if (!allowed(e.status)) return false
        entries[uuid] = e.copy(status = to)
        return true
    }
}
