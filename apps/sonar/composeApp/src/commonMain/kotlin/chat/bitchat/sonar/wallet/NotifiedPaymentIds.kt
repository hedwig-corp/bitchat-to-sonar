package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.ConcurrencyLock
import chat.bitchat.sonar.SonarCore

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

/** Blob key for the persisted notified-payment-ids ring. Must not change: an
 *  existing install's ring lives under this key. */
const val NOTIFIED_PAYMENT_IDS_BLOB = "wallet.notifiedPaymentIds"

private val notifiedIdsLock = ConcurrencyLock()

/**
 * Claim [paymentId] in the persisted [NotifiedPaymentIds] ring.
 *
 * Returns true when this call newly claimed it — the caller owns the one
 * user-visible notification for that payment. Returns false when some earlier
 * path already claimed it: a previous wake, an SDK event replay, or the
 * foreground wallet listener claiming a receive the user watched land in the UI.
 *
 * Guarded because the Breez SDK callback thread and the push service's wake
 * coroutines both run this load → mark → persist round-trip.
 */
/**
 * Whether [paymentId] already produced a notification, WITHOUT claiming it.
 *
 * Needed for the PENDING case: a receive whose claim is still in flight ends
 * the wake but must not claim the notify slot (it may never complete). Reading
 * the ring lets the wake tell "pending arrival of something new" from "pending
 * re-report of a payment an earlier wake already announced", so a stale pending
 * row cannot keep ending every wake for the rest of the lookback window.
 */
fun wasPaymentNotified(paymentId: String): Boolean = notifiedIdsLock.withLock {
    NotifiedPaymentIds(SonarCore.loadBlob(NOTIFIED_PAYMENT_IDS_BLOB)).contains(paymentId)
}

fun claimNotifiedPaymentId(paymentId: String): Boolean = notifiedIdsLock.withLock {
    val ring = NotifiedPaymentIds(SonarCore.loadBlob(NOTIFIED_PAYMENT_IDS_BLOB))
    if (!ring.markNotified(paymentId)) return@withLock false
    SonarCore.saveBlob(NOTIFIED_PAYMENT_IDS_BLOB, ring.encode())
    true
}
