package chat.bitchat.sonar.wallet

/**
 * Fee-aware spendable-balance policy (#141).
 *
 * The pay sheet's `Max` used to set the amount to the full wallet balance,
 * but Breez needs sender-side fees ON TOP of the receiver amount, so the send
 * failed locally with `InsufficientFunds(message: "Cannot pay: not enough
 * funds")` — a raw SDK string, after the user had already committed.
 *
 * Two layers, because the exact fee is only knowable from a
 * `prepareSendPayment` against a specific destination, and `Max` must stay
 * instant (no network on a tap — local-first):
 *
 * 1. [maxSendableSats] — an instant, conservative reserve so the default
 *    `Max` amount can actually settle.
 * 2. [insufficientAfterFee] — the pre-send check once a real prepared fee is
 *    known, so the user gets "Amount + fee exceeds balance" from us instead
 *    of a raw Breez error.
 */
object SpendableBalance {

    /** Floor for the reserve: covers the smallest realistic Lightning fee. */
    const val MIN_FEE_RESERVE_SATS: Long = 10

    /** Ceiling: a large balance should not withhold an absurd amount. */
    const val MAX_FEE_RESERVE_SATS: Long = 1_000

    /**
     * Proportional part of the reserve, in basis points (0.5%). Lightning
     * routing fees are largely proportional, so the reserve tracks the amount
     * rather than being a flat guess.
     */
    const val FEE_RESERVE_BPS: Long = 50

    /**
     * Sats withheld from a `Max` send so fees have somewhere to come from.
     * Clamped to [MIN_FEE_RESERVE_SATS]..[MAX_FEE_RESERVE_SATS].
     */
    fun feeReserveSats(balanceSats: Long): Long {
        if (balanceSats <= 0) return 0
        val proportional = balanceSats * FEE_RESERVE_BPS / 10_000
        return proportional.coerceIn(MIN_FEE_RESERVE_SATS, MAX_FEE_RESERVE_SATS)
    }

    /**
     * The amount `Max` should propose: the balance minus the fee reserve, and
     * never negative. A balance at or below the reserve has nothing safely
     * sendable — 0 means "don't offer Max", which the UI honors by hiding the
     * button rather than proposing an amount that cannot settle.
     */
    fun maxSendableSats(balanceSats: Long): Long {
        if (balanceSats <= 0) return 0
        val spendable = balanceSats - feeReserveSats(balanceSats)
        return if (spendable > 0) spendable else 0
    }

    /**
     * Pre-send check against a REAL prepared fee: true when the send cannot
     * settle, so the caller blocks with a clear message instead of handing
     * Breez a doomed payment. `feeSats` comes from `prepareSendPayment`.
     */
    fun insufficientAfterFee(amountSats: Long, feeSats: Long, balanceSats: Long): Boolean =
        amountSats > 0 && amountSats + feeSats > balanceSats
}
