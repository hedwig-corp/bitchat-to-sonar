package chat.bitchat.sonar.wallet

/**
 * #141 — fee-aware send amount.
 *
 * Tapping "Max" sets the payment amount to the full wallet balance, but Breez
 * needs sender fees on top, so amount == balance fails at sendPayment with
 * InsufficientFunds. This returns the largest amount that can actually settle
 * for a "Max"/drain send (requested == balance): balance minus the known sender
 * [feeSats]. Partial amounts and the amount-less (invoice) case are returned
 * unchanged. Conservative on purpose: it only ever reduces a drain.
 */
internal fun safeSendAmount(requestedSats: Long, balanceSats: Long, feeSats: Long): Long {
    if (requestedSats <= 0 || balanceSats <= 0) return requestedSats
    // Only the drain case (sending the entire balance) needs fee reservation.
    if (requestedSats < balanceSats) return requestedSats
    val safe = balanceSats - feeSats
    return if (safe in 1 until requestedSats) safe else requestedSats
}
