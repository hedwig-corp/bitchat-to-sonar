package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.payFmt

/**
 * The state machine behind the external-payment status screen, 1:1 with the
 * design's `paystatus.jsx` (design/handoff/project/sonar/paystatus.jsx +
 * `Sonar Payment Status.html`). Direction D — "resumable status" — is the one
 * that shipped: a dismissible status card plus a live wallet row that keeps
 * updating after you leave the screen.
 *
 * The design frames the brief as: every state must answer *what is happening*,
 * *where is my money*, and *what do I do next* — "failed" is never enough on
 * its own. So the copy tables below are the product, not decoration, and they
 * are reproduced verbatim (parameterized only on the payee and the amount).
 *
 * The iOS mirror is `ios/bitchat/Views/Sonar/SonarPaymentStatus.swift` — the
 * two files must stay in step (Cross-Platform Feature Rule).
 */
enum class PayPhase {
    /** Handed to us, not yet handed to the wallet. */
    Resolving,

    /** In flight inside the wallet. */
    Paying,

    /** Still in flight, past the point where that is normal. */
    Slow,

    /** Settled, proof held. */
    Sent,

    /** Rejected before any money moved. */
    FailedSafe,

    /** Money left and came back. */
    Refunded,

    /** We cannot see the outcome (process died mid-send). */
    Unknown,
    ;

    /** paystatus.jsx `live` — a spinner rather than a terminal glyph. */
    val isLive: Boolean get() = this == Resolving || this == Paying || isWarn
    val isGood: Boolean get() = this == Sent
    val isBad: Boolean get() = this == FailedSafe || this == Refunded
    val isWarn: Boolean get() = this == Slow || this == Unknown

    /**
     * paystatus.jsx `PCT`, 0…1. Failure fills the bar in the danger colour
     * rather than leaving it empty, so the row still reads as concluded.
     */
    val progress: Float
        get() = when (this) {
            Resolving -> 0.12f
            Paying -> 0.58f
            Slow -> 0.70f
            Sent -> 1f
            FailedSafe, Refunded -> 1f
            Unknown -> 0.72f
        }
}

/**
 * paystatus.jsx `MONEY[].tone` — the money line is tinted by where the sats
 * are, not by whether the payment "succeeded".
 */
enum class PayMoneyTone { Safe, Flight, Good, Warn }

/**
 * An external payment this process is sending right now.
 *
 * Everything terminal lives in [SonarPaymentActivityLedger]; this only carries
 * the part of the design's state machine the ledger has no business persisting
 * — which live sub-phase we are in, and when the send started.
 */
data class LivePayment(
    val id: String,
    val payeeName: String,
    val sats: Long,
    val startedAtSecs: Long,
    /**
     * False only in the window between the user confirming and us calling the
     * wallet. That window is the one place `Cancel` can honestly work.
     */
    val handedToWallet: Boolean,
) {
    fun phase(nowSecs: Long): PayPhase = when {
        !handedToWallet -> PayPhase.Resolving
        nowSecs - startedAtSecs >= SLOW_AFTER_SECS -> PayPhase.Slow
        else -> PayPhase.Paying
    }

    fun elapsedSecs(nowSecs: Long): Int = (nowSecs - startedAtSecs).coerceAtLeast(0L).toInt()

    companion object {
        /**
         * Lightning normally settles in well under a second. Past this it is
         * worth telling the user the first route did not answer, rather than
         * leaving a spinner that says nothing.
         */
        const val SLOW_AFTER_SECS = 20L
    }
}

/**
 * A payment as the status screen and the home strip see it. Assembled by
 * `SonarAppState.paymentStatus` from the persisted activity ledger plus
 * whatever the in-process send knows.
 */
data class PaymentStatus(
    val id: String,
    val payeeName: String,
    val sats: Long,
    val phase: PayPhase,
    /** Seconds since the send was accepted; drives "Sending · 6s". */
    val elapsedSecs: Int,
    /** Settlement proof, when the wallet handed one back. */
    val preimage: String?,
    /**
     * Whether we still hold the destination needed to re-send. Destinations are
     * only ever hashed in the ledger, so this is false after a relaunch.
     */
    val canRetry: Boolean,
)

/** One action button in the status card (paystatus.jsx `acts`). */
data class PayAction(
    val label: String,
    val kind: Kind,
    val effect: Effect,
) {
    enum class Kind {
        /** `.rs-act.pri` — filled accent. */
        Primary,

        /** `.rs-act.dim` — text2 label on the plain surface. */
        Dim,

        /** `.rs-act` — plain surface, full-strength label. */
        Plain,
    }

    enum class Effect {
        /** Leave the screen; the payment keeps running. */
        Dismiss,

        /** Copy the settlement proof. */
        CopyProof,

        /** Re-send the same amount to the same destination. */
        Retry,
    }
}

/**
 * The design's copy tables. Kept as one object so the iOS mirror can be diffed
 * against it line by line.
 */
object PayStatusCopy {

    /**
     * Grouped amount without a unit, so it can be composed into a sentence
     * ("2,100 sats in flight").
     */
    fun amount(sats: Long): String = payFmt(sats)

    /** paystatus.jsx `HEAD` — headline plus the sentence under it. */
    fun headline(phase: PayPhase, payee: String, sats: Long): String = when (phase) {
        PayPhase.Resolving -> "Finding $payee"
        PayPhase.Paying -> "Sending ${amount(sats)} sats"
        PayPhase.Slow -> "Taking longer than usual"
        PayPhase.Sent -> "Paid $payee"
        PayPhase.FailedSafe -> "Couldn’t send"
        PayPhase.Refunded -> "Payment came back"
        PayPhase.Unknown -> "Still confirming"
    }

    fun hint(phase: PayPhase, payee: String, sats: Long): String = when (phase) {
        PayPhase.Resolving ->
            "Reading the code and checking the destination is payable."
        PayPhase.Paying ->
            "Your payment is hopping through the Lightning network."
        PayPhase.Slow ->
            "The first route didn’t answer. Trying another — this can take a minute."
        PayPhase.Sent ->
            "They received ${amount(sats)} sats. You have cryptographic proof of payment."
        PayPhase.FailedSafe ->
            "No route to $payee right now. You were not charged."
        PayPhase.Refunded ->
            "$payee didn’t accept in time, so the sats returned to you."
        PayPhase.Unknown ->
            "We can’t see the result yet. Lightning settles or refunds on its own " +
                "— we’ll tell you which."
    }

    /** paystatus.jsx `MONEY` — the single most important line on the screen. */
    fun money(phase: PayPhase, sats: Long): Pair<PayMoneyTone, String> = when (phase) {
        PayPhase.Resolving ->
            PayMoneyTone.Safe to "Nothing sent yet — your sats are still yours"
        PayPhase.Paying ->
            PayMoneyTone.Flight to "${amount(sats)} sats in flight — not yet settled"
        PayPhase.Slow ->
            PayMoneyTone.Warn to "Still in flight — held, not lost"
        PayPhase.Sent ->
            PayMoneyTone.Good to "${amount(sats)} sats delivered · proof received"
        PayPhase.FailedSafe ->
            PayMoneyTone.Safe to "Nothing left your wallet — balance unchanged"
        PayPhase.Refunded ->
            PayMoneyTone.Good to "${amount(sats)} sats returned to your balance"
        PayPhase.Unknown ->
            PayMoneyTone.Warn to "Sats reserved — we’ll confirm or refund automatically"
    }

    /** paystatus.jsx `rowTxt` — the "In your wallet" row's status line. */
    fun walletRow(phase: PayPhase, elapsedSecs: Int): String = when (phase) {
        PayPhase.Resolving -> "Resolving destination…"
        PayPhase.Paying -> "Sending · ${elapsed(elapsedSecs)}"
        PayPhase.Slow -> "Still trying · ${elapsed(elapsedSecs)}"
        PayPhase.Sent -> "Sent · proof stored"
        PayPhase.FailedSafe -> "Not sent · not charged"
        PayPhase.Refunded -> "Refunded to balance"
        PayPhase.Unknown -> "Confirming · ${elapsed(elapsedSecs)}"
    }

    /** The design writes elapsed time as "6s" / "48s" / "2m". */
    fun elapsed(seconds: Int): String {
        val clamped = seconds.coerceAtLeast(0)
        return if (clamped < 60) "${clamped}s" else "${clamped / 60}m"
    }

    /**
     * paystatus.jsx `acts`.
     *
     * One deliberate deviation: the design's `Cancel` / `Cancel payment` is
     * dropped once the payment has been handed to the wallet. A Lightning
     * payment in flight cannot be recalled, and a button that claims otherwise
     * is exactly the dishonesty this screen exists to remove. `Resolving` is
     * before the hand-off, so its Cancel is real and stays.
     */
    fun actions(status: PaymentStatus): List<PayAction> = when (status.phase) {
        PayPhase.Resolving -> listOf(
            PayAction("Cancel", PayAction.Kind.Dim, PayAction.Effect.Dismiss),
        )
        PayPhase.Paying -> listOf(
            PayAction("Hide — keeps sending", PayAction.Kind.Dim, PayAction.Effect.Dismiss),
        )
        PayPhase.Slow -> listOf(
            PayAction("Keep waiting", PayAction.Kind.Primary, PayAction.Effect.Dismiss),
        )
        PayPhase.Sent -> buildList {
            if (!status.preimage.isNullOrEmpty()) {
                add(PayAction("Copy proof", PayAction.Kind.Primary, PayAction.Effect.CopyProof))
            }
            add(
                PayAction(
                    "Done",
                    if (isEmpty()) PayAction.Kind.Primary else PayAction.Kind.Plain,
                    PayAction.Effect.Dismiss,
                )
            )
        }
        PayPhase.FailedSafe ->
            if (!status.canRetry) {
                listOf(PayAction("Done", PayAction.Kind.Primary, PayAction.Effect.Dismiss))
            } else {
                listOf(
                    PayAction("Try again", PayAction.Kind.Primary, PayAction.Effect.Retry),
                    PayAction("Not now", PayAction.Kind.Dim, PayAction.Effect.Dismiss),
                )
            }
        PayPhase.Refunded ->
            if (!status.canRetry) {
                listOf(PayAction("Done", PayAction.Kind.Primary, PayAction.Effect.Dismiss))
            } else {
                listOf(
                    PayAction("Try again", PayAction.Kind.Primary, PayAction.Effect.Retry),
                    PayAction("Done", PayAction.Kind.Plain, PayAction.Effect.Dismiss),
                )
            }
        PayPhase.Unknown -> listOf(
            PayAction("Hide — we’ll notify you", PayAction.Kind.Primary, PayAction.Effect.Dismiss),
        )
    }

    /** paystatus.jsx `HOME` — the H1 pinned strip above the home list. */
    fun homeStrip(phase: PayPhase, payee: String, sats: Long): Pair<String, String> = when (phase) {
        PayPhase.Resolving ->
            "Preparing payment" to "$payee · checking destination"
        PayPhase.Paying ->
            "Sending ${amount(sats)} sats" to "$payee · tap for details"
        PayPhase.Slow ->
            "Taking longer than usual" to "$payee · still in flight"
        PayPhase.Sent ->
            "Sent ${amount(sats)} sats" to "$payee · proof stored"
        PayPhase.FailedSafe ->
            "Payment didn’t go through" to "$payee · you weren’t charged"
        PayPhase.Refunded ->
            "Payment refunded" to "$payee · ${amount(sats)} sats returned"
        PayPhase.Unknown ->
            "Confirming payment" to "$payee · we’ll notify you"
    }
}

/**
 * Project a ledger row (plus an optional live send) into the design's state
 * machine. Pure, so it can be tested without an app state.
 *
 * The ledger is the source of truth: a live entry only refines a row that is
 * still `Pending`. A `Pending` row with no live send is the honest "unknown"
 * case — the process died mid-send and Lightning will settle or refund on its
 * own.
 */
fun paymentStatusOf(
    activity: SonarPaymentActivity,
    live: LivePayment?,
    nowSecs: Long,
    canRetry: Boolean,
): PaymentStatus {
    if (live != null && activity.status == SonarPaymentActivity.Status.Pending) {
        return PaymentStatus(
            id = activity.id,
            payeeName = live.payeeName,
            sats = live.sats,
            phase = live.phase(nowSecs),
            elapsedSecs = live.elapsedSecs(nowSecs),
            preimage = null,
            canRetry = canRetry,
        )
    }
    val phase = when (activity.status) {
        SonarPaymentActivity.Status.Paid -> PayPhase.Sent
        SonarPaymentActivity.Status.Failed -> PayPhase.FailedSafe
        SonarPaymentActivity.Status.Pending -> PayPhase.Unknown
    }
    val reference = activity.settledAtSecs ?: nowSecs
    return PaymentStatus(
        id = activity.id,
        payeeName = activity.peerName,
        sats = activity.sats,
        phase = phase,
        elapsedSecs = (reference - activity.createdAtSecs).coerceAtLeast(0L).toInt(),
        preimage = activity.preimage,
        canRetry = canRetry,
    )
}
