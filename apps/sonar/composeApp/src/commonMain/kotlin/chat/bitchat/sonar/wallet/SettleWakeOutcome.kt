package chat.bitchat.sonar.wallet

/**
 * What observing one incoming receive means for a Breez settle wake.
 *
 * @property endsWake stop waiting — the thing this wake was woken for has arrived.
 * @property notifies post the "Payment received" banner and write the `Paid`
 *   ledger row. Deliberately NOT the same question as [endsWake].
 */
data class SettleWakeOutcome(
    val endsWake: Boolean,
    val notifies: Boolean,
)

/**
 * The settle wake's whole decision, as a pure function.
 *
 * Extracted because this is the most-churned and least-verified logic on the
 * offline-receive path: it regressed once mid-review with every test still
 * green (the R-001 pattern — helpers pass while the real call site is wrong),
 * and it cannot be reached from a test while it lives inside a private method
 * on an Android `Service`. Everything it needs is a boolean, so there is no
 * excuse for it not being pinned.
 *
 * The three rules it encodes, and why each exists:
 *
 * 1. **A pending receive never notifies.** `recentIncomingReceives` returns
 *    `PENDING` (lockup seen, claim in flight) so a wake can stop early, but the
 *    swap can still fail or the lockup be reorged. Claiming the notify slot then
 *    would leave a permanent "received" banner for money that never arrived AND
 *    suppress the real banner when it completes.
 * 2. **The poll feed reaches 600s back, so it returns history.** A payment an
 *    earlier wake already announced must not end this wake — otherwise a wake
 *    for a *new* payment ends seconds after connect, before the new payment's
 *    lockup is even visible, and repeats on every wake until the old one ages
 *    out of the lookback window.
 * 3. **A live event always ends the wake on first sight.** It is settling right
 *    now, while we are connected. It ends the wake whether or not the ring
 *    already owns it — the foreground listener may have claimed a receive the
 *    user watched land in the UI, and the wake must still stop rather than burn
 *    its full budget polling for something already in hand.
 *
 * [alreadyNotified] is the ring read; for a settled receive, "claim succeeds"
 * is exactly `!alreadyNotified`, which is what makes this expressible purely.
 */
fun settleWakeOutcome(
    settled: Boolean,
    liveEvent: Boolean,
    firstThisWake: Boolean,
    alreadyNotified: Boolean,
): SettleWakeOutcome {
    if (!settled) {
        // Rule 1 + the stale-pending half of rule 2.
        return SettleWakeOutcome(
            endsWake = firstThisWake && !alreadyNotified,
            notifies = false,
        )
    }
    val claimed = !alreadyNotified
    // Rule 3 (liveEvent) vs rule 2 (poll must be newly claimed).
    return SettleWakeOutcome(
        endsWake = claimed || (liveEvent && firstThisWake),
        notifies = claimed,
    )
}
