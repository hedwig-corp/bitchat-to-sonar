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

    /**
     * There is deliberately NO ceiling on the reserve.
     *
     * Breez sender fees are proportional, so a flat ceiling re-introduces the
     * exact bug this file exists to fix: at 1000 sats it bit from ~250k sats
     * upward, and even 25_000 still under-reserves above ~6.25M sats. A
     * proportional fee needs a proportional reserve — [FEE_RESERVE_BPS] is set
     * above the worst-case fee rate so the proposed Max always clears it.
     */
    const val NO_FEE_RESERVE_CEILING: Boolean = true

    /**
     * The reserve, in basis points (0.5%). Lightning routing fees are
     * largely proportional, so the reserve tracks the amount rather than
     * being a flat guess — and it is set ABOVE the worst-case observed fee
     * rate (~0.4%) so the Max it proposes always clears its own check.
     */
    const val FEE_RESERVE_BPS: Long = 50

    /**
     * Sats withheld from a `Max` send so fees have somewhere to come from.
     * Floored at [MIN_FEE_RESERVE_SATS]; deliberately uncapped (see
     * [NO_FEE_RESERVE_CEILING]).
     */
    fun feeReserveSats(balanceSats: Long): Long {
        if (balanceSats <= 0) return 0
        val proportional = balanceSats * FEE_RESERVE_BPS / 10_000
        return maxOf(proportional, MIN_FEE_RESERVE_SATS)
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

    /**
     * User-facing copy for the blocked case — replaces the raw
     * `InsufficientFunds(message: "Cannot pay: not enough funds")` string.
     * Mirror of the Swift `insufficientMessage`; keep the two in step.
     */
    fun insufficientMessage(amountSats: Long, feeSats: Long, balanceSats: Long): String =
        "Amount plus fee ($amountSats + $feeSats sats) exceeds your balance of $balanceSats sats."
}
