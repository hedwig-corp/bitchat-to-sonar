package chat.bitchat.sonar.wallet

/**
 * Tiny persisted ring of wallet payment ids that already produced a user
 * notification, so a receive settling across several NDS wakeups (swap_updated
 * then payment_received), a process death between wakes, or an SDK event
 * replay can never double-notify.
 *
 * The ledger row itself can't carry this signal: `WalletBridge` records the
 * payment at the event source *before* the push service observes it, so
 * "newly recorded" is already consumed by the time the notify decision runs.
 *
 * Bounded to [cap] newest ids (blob stays a few KB at most); wallet payment
 * ids are txids/payment hashes — line-safe, so newline framing needs no
 * escaping. Not thread-safe; the push service serializes each
 * load → markNotified → persist round-trip under its own lock.
 */
class NotifiedPaymentIds(blob: String = "", private val cap: Int = 64) {
    // Oldest-first so eviction pops the front and encode() round-trips order.
    private val ids = ArrayDeque<String>()

    init {
        for (line in blob.split("\n")) {
            val id = line.trim()
            if (id.isNotEmpty() && id !in ids) ids.addLast(id)
        }
        while (ids.size > cap) ids.removeFirst()
    }

    /** True when [id] was newly marked — the caller should notify and persist.
     *  False when it already notified for this payment. */
    fun markNotified(id: String): Boolean {
        if (id.isBlank() || id in ids) return false
        ids.addLast(id)
        while (ids.size > cap) ids.removeFirst()
        return true
    }

    fun contains(id: String): Boolean = id in ids

    fun encode(): String = ids.joinToString("\n")
}
