package chat.bitchat.sonar

/**
 * The ⚡PAY message convention: plain control strings carried inside normal
 * encrypted chat content, so payment receipts ride the existing transport
 * (Marmot / mesh / Nostr DM):
 *
 *   ⚡PAY|1|<uuid>|<sats>             — payment receipt shown in the conversation
 *   ⚡PAYDONE|2|<uuid>                — settled receipt (no preimage available)
 *   ⚡PAYDONE|2|<uuid>|<preimage_hex> — settled receipt with cryptographic proof
 *
 * Unknown versions render as plain text (forward-compatible). Decoders accept
 * v1 PAYDONE from old peers for backward compatibility.
 */
sealed interface PayLine {
    data class Pay(val uuid: String, val sats: Long) : PayLine
    data class Done(val uuid: String, val preimage: String? = null) : PayLine

    fun encoded(): String = when (this) {
        is Pay -> "⚡PAY|1|$uuid|$sats"
        is Done -> if (preimage != null) "⚡PAYDONE|2|$uuid|$preimage" else "⚡PAYDONE|2|$uuid"
    }

    companion object {
        fun decode(content: String): PayLine? {
            val parts = content.split("|")
            if (parts.size < 3) return null
            val version = parts[1]
            return when (parts[0]) {
                "⚡PAY" -> {
                    if (version != "1") return null
                    parts.getOrNull(3)?.toLongOrNull()?.takeIf { it > 0 }?.let { Pay(parts[2], it) }
                }
                "⚡PAYDONE" -> when (version) {
                    "1" -> if (parts.size == 3) Done(parts[2]) else null
                    "2" -> when (parts.size) {
                        3 -> Done(parts[2])
                        4 -> parts[3].takeIf { isValidPreimage(it) }?.let { Done(parts[2], it) }
                        else -> null
                    }
                    else -> null
                }
                else -> null
            }
        }

        private fun isValidPreimage(s: String): Boolean =
            s.length == 64 && s.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
    }
}

internal fun randomPayId(): String =
    (0 until 16).map { "0123456789abcdef".random() }.joinToString("")

/**
 * Lifecycle of a direct payment receipt, mirrored from the iOS ledger.
 * [Claiming], [Settling], and [Failed] are vestigial — kept only for
 * deserializing previously persisted rows from older builds. New protocol
 * flows only produce [Sealed] and [Claimed] entries.
 */
enum class PayStatus { Sealed, Claiming, Settling, Claimed, Failed }

/** One tracked coin. */
data class PayEntry(val uuid: String, val sats: Long, val status: PayStatus, val mine: Boolean, val preimage: String? = null)

/**
 * The ⚡PAY ledger. States survive restart (the app persists [serialize] via
 * SonarCore.saveBlob); transitions are idempotent so replaying chat transcripts
 * after a relaunch cannot duplicate receipts. Claiming/Settling remain decodeable
 * for previously persisted rows, but new protocol messages only create Sealed
 * and Claimed receipts.
 */
class SonarPayLedger(blob: String = "") {
    private val entries = LinkedHashMap<String, PayEntry>()
    private val pendingDone = HashMap<String, String?>()

    init {
        for (line in blob.split("\n")) {
            val p = line.split("|")
            if (p.size < 4) continue
            val sats = p[1].toLongOrNull() ?: continue
            val status = runCatching { PayStatus.valueOf(p[2]) }.getOrNull() ?: continue
            val preimage = p.getOrNull(4)?.ifEmpty { null }
            entries[p[0]] = PayEntry(p[0], sats, status, p[3] == "1", preimage)
        }
    }

    fun all(): List<PayEntry> = entries.values.toList()
    fun get(uuid: String): PayEntry? = entries[uuid]

    fun serialize(): String =
        entries.values.joinToString("\n") { "${it.uuid}|${it.sats}|${it.status}|${if (it.mine) 1 else 0}|${it.preimage.orEmpty()}" }

    /** Record a receipt (idempotent). Returns true if it changed. */
    fun recordReceipt(uuid: String, sats: Long, mine: Boolean): Boolean {
        if (entries.containsKey(uuid)) return false
        val doneWasPending = pendingDone.containsKey(uuid)
        val pendingPreimage = if (doneWasPending) pendingDone.remove(uuid) else null
        val status = if (mine || doneWasPending) PayStatus.Claimed else PayStatus.Sealed
        entries[uuid] = PayEntry(uuid, sats, status, mine, pendingPreimage)
        return true
    }

    /** Coin settled (any non-terminal → Claimed). */
    fun markClaimed(uuid: String, preimage: String? = null): Boolean {
        val e = entries[uuid] ?: return false
        if (e.status == PayStatus.Claimed && preimage == null) return false
        entries[uuid] = e.copy(status = PayStatus.Claimed, preimage = preimage ?: e.preimage)
        return true
    }

    /** Mark claimed, or remember DONE when it arrives before the matching PAY. */
    fun markClaimedOrPending(uuid: String, preimage: String? = null): Boolean {
        if (!entries.containsKey(uuid)) {
            pendingDone[uuid] = preimage
            return false
        }
        return markClaimed(uuid, preimage)
    }
}
