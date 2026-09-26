package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.ConcurrencyLock
import chat.bitchat.sonar.SonarClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Announces each wallet receive once. A chat payment is already announced
 * by its ⚡PAY line, and the wallet cannot tell it from a payment made
 * outside Sonar: the payer pays the public offer, so nothing links the
 * payment to the receipt. They are paired by amount instead, one receipt to
 * one receive, and the chat line stays the only notification (Signal's
 * model: the payment message is the notification).
 *
 * - A receipt that arrives first silences the next receive of its amount
 *   within [LOOKBACK_MS] (the payee's wallet only mints in the foreground,
 *   so it can land hours after the push-delivered ⚡PAY).
 * - A receive that arrives first waits [graceMs] for its receipt, then
 *   announces.
 *
 * Feed [chatReceipt] only receipts the pay ledger records for the first
 * time: a transcript replayed after a restart must not silence a new
 * outside payment. Receives come deduplicated by payment id.
 */
class ReceiveAnnouncer(
    private val scope: CoroutineScope,
    private val graceMs: () -> Long = { GRACE_MS },
    private val nowMillis: () -> Long = { SonarClock.nowMillis() },
    private val announce: (paymentId: String, sats: Long) -> Unit,
) {
    private class Receipt(val sats: Long, val sentAtMillis: Long)
    private class Waiting(val sats: Long, val job: Job)

    private val lock = ConcurrencyLock()
    private val seenReceipts = ArrayDeque<String>()
    private val receipts = ArrayDeque<Receipt>()
    private val waiting = LinkedHashMap<String, Waiting>()

    /** An incoming ⚡PAY receipt for [sats], sent at [sentAtMillis]. */
    fun chatReceipt(id: String, sats: Long, sentAtMillis: Long) {
        if (sats <= 0 || nowMillis() - sentAtMillis > LOOKBACK_MS) return
        val silenced: Job? = lock.withLock {
            if (id in seenReceipts) return@withLock null
            seenReceipts.addLast(id)
            while (seenReceipts.size > MAX_SEEN) seenReceipts.removeFirst()
            val match = waiting.entries.firstOrNull { it.value.sats == sats }
            if (match == null) {
                receipts.addLast(Receipt(sats, sentAtMillis))
                while (receipts.size > MAX_SEEN) receipts.removeFirst()
                null
            } else {
                waiting.remove(match.key)
                match.value.job
            }
        }
        silenced?.cancel()
    }

    /** A settled incoming wallet payment, seen for the first time. */
    fun walletReceive(paymentId: String, sats: Long) {
        val pending: Job? = lock.withLock {
            val oldest = nowMillis() - LOOKBACK_MS
            receipts.removeAll { it.sentAtMillis < oldest }
            val receipt = receipts.firstOrNull { it.sats == sats }
            when {
                receipt != null -> {
                    receipts.remove(receipt)
                    null
                }
                waiting.containsKey(paymentId) -> null
                // Registered before it can run, so a receipt can always cancel it.
                else -> scope.launch(start = CoroutineStart.LAZY) {
                    delay(graceMs())
                    if (lock.withLock { waiting.remove(paymentId) } != null) announce(paymentId, sats)
                }.also { waiting[paymentId] = Waiting(sats, it) }
            }
        }
        pending?.start()
    }

    companion object {
        /** How long a receive waits for its ⚡PAY: covers a chat line
         *  delivered over the relays after the wallet saw the payment. */
        const val GRACE_MS = 30_000L
        const val LOOKBACK_MS = 24 * 60 * 60 * 1_000L
        private const val MAX_SEEN = 256
    }
}
