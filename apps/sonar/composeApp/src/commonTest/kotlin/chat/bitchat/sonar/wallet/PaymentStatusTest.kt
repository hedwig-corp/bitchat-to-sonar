package chat.bitchat.sonar.wallet

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The external-payment status state machine (design: paystatus.jsx Direction D,
 * `design/handoff/project/sonar/paystatus.jsx`).
 *
 * These pin two things that are easy to break silently:
 *  - the phase derivation, which is what decides whether the user is told their
 *    money is still theirs, in flight, gone, or unaccounted for;
 *  - the money-truth copy itself, which is the design's stated deliverable
 *    ("failed" is never enough on its own).
 */
class PaymentStatusTest {

    private fun activity(
        status: SonarPaymentActivity.Status,
        createdAtSecs: Long = 1_000,
        settledAtSecs: Long? = null,
        preimage: String? = null,
        sats: Long = 2_100,
    ) = SonarPaymentActivity(
        id = "a1",
        kind = SonarPaymentActivity.Kind.SonarDirect,
        peerKey = "wallet",
        peerName = "Café Lumen",
        direction = SonarPaymentActivity.Direction.Outgoing,
        sats = sats,
        via = "internet",
        createdAtSecs = createdAtSecs,
        destinationHash = "hash",
        status = status,
        settledAtSecs = settledAtSecs,
        preimage = preimage,
    )

    private fun live(startedAtSecs: Long = 1_000, handedToWallet: Boolean = true) = LivePayment(
        id = "a1",
        payeeName = "Café Lumen",
        sats = 2_100,
        startedAtSecs = startedAtSecs,
        handedToWallet = handedToWallet,
    )

    // ── phase derivation ──

    @Test
    fun beforeTheWalletIsCalledThePaymentIsResolving() {
        val status = paymentStatusOf(
            activity(SonarPaymentActivity.Status.Pending),
            live(handedToWallet = false),
            nowSecs = 1_000,
            canRetry = true,
        )
        assertEquals(PayPhase.Resolving, status.phase)
        // The whole point of this phase: nothing has moved yet.
        assertEquals(PayMoneyTone.Safe, PayStatusCopy.money(status.phase, status.sats).first)
    }

    @Test
    fun inFlightIsPayingUntilItIsUnusuallySlow() {
        val paying = paymentStatusOf(
            activity(SonarPaymentActivity.Status.Pending), live(), nowSecs = 1_006, canRetry = true
        )
        assertEquals(PayPhase.Paying, paying.phase)
        assertEquals(6, paying.elapsedSecs)

        val slow = paymentStatusOf(
            activity(SonarPaymentActivity.Status.Pending),
            live(),
            nowSecs = 1_000 + LivePayment.SLOW_AFTER_SECS,
            canRetry = true,
        )
        assertEquals(PayPhase.Slow, slow.phase)
    }

    @Test
    fun theLedgerOutranksTheLiveEntry() {
        // The wallet settled while a live entry was still around: the ledger
        // wins, so the screen can never show "sending" over a settled payment.
        val status = paymentStatusOf(
            activity(SonarPaymentActivity.Status.Paid, settledAtSecs = 1_004, preimage = "beef"),
            live(),
            nowSecs = 9_999,
            canRetry = true,
        )
        assertEquals(PayPhase.Sent, status.phase)
        assertEquals("beef", status.preimage)
        assertEquals(4, status.elapsedSecs)
    }

    @Test
    fun failedIsReportedAsNotCharged() {
        val status = paymentStatusOf(
            activity(SonarPaymentActivity.Status.Failed, settledAtSecs = 1_010),
            live = null,
            nowSecs = 2_000,
            canRetry = true,
        )
        assertEquals(PayPhase.FailedSafe, status.phase)
        assertEquals(
            "Nothing left your wallet — balance unchanged",
            PayStatusCopy.money(status.phase, status.sats).second,
        )
    }

    @Test
    fun aPendingRowWithNoLiveSendIsUnknownNotFailed() {
        // The process died mid-send. We genuinely cannot say the payment
        // failed, and saying so would be the worst possible lie here.
        val status = paymentStatusOf(
            activity(SonarPaymentActivity.Status.Pending), live = null, nowSecs = 1_120, canRetry = false
        )
        assertEquals(PayPhase.Unknown, status.phase)
        assertEquals("Confirming · 2m", PayStatusCopy.walletRow(status.phase, status.elapsedSecs))
    }

    // ── money-truth copy ──

    @Test
    fun everyPhaseNamesWhereTheMoneyIs() {
        val expected = mapOf(
            PayPhase.Resolving to "Nothing sent yet — your sats are still yours",
            PayPhase.Paying to "2,100 sats in flight — not yet settled",
            PayPhase.Slow to "Still in flight — held, not lost",
            PayPhase.Sent to "2,100 sats delivered · proof received",
            PayPhase.FailedSafe to "Nothing left your wallet — balance unchanged",
            PayPhase.Refunded to "2,100 sats returned to your balance",
            PayPhase.Unknown to "Sats reserved — we’ll confirm or refund automatically",
        )
        for ((phase, text) in expected) {
            assertEquals(text, PayStatusCopy.money(phase, 2_100).second, "money line for $phase")
        }
    }

    @Test
    fun headlinesMatchTheDesign() {
        assertEquals("Finding Café Lumen", PayStatusCopy.headline(PayPhase.Resolving, "Café Lumen", 2_100))
        assertEquals("Sending 2,100 sats", PayStatusCopy.headline(PayPhase.Paying, "Café Lumen", 2_100))
        assertEquals("Paid Café Lumen", PayStatusCopy.headline(PayPhase.Sent, "Café Lumen", 2_100))
        assertEquals("Couldn’t send", PayStatusCopy.headline(PayPhase.FailedSafe, "Café Lumen", 2_100))
    }

    @Test
    fun elapsedReadsAsSecondsThenMinutes() {
        assertEquals("0s", PayStatusCopy.elapsed(-5))
        assertEquals("48s", PayStatusCopy.elapsed(48))
        assertEquals("1m", PayStatusCopy.elapsed(60))
        assertEquals("2m", PayStatusCopy.elapsed(120))
    }

    // ── actions ──

    @Test
    fun cancelIsOfferedOnlyWhileTheWalletHasNotBeenCalled() {
        val resolving = paymentStatusOf(
            activity(SonarPaymentActivity.Status.Pending),
            live(handedToWallet = false),
            nowSecs = 1_000,
            canRetry = true,
        )
        assertEquals(listOf("Cancel"), PayStatusCopy.actions(resolving).map { it.label })

        // Once it is in flight, Lightning cannot recall it — so no button may
        // claim to. This is the one deliberate deviation from the design.
        for (phase in listOf(PayPhase.Paying, PayPhase.Slow)) {
            val labels = PayStatusCopy.actions(
                PaymentStatus("a1", "Café Lumen", 2_100, phase, 6, null, canRetry = true)
            ).map { it.label }
            assertFalse(labels.any { it.contains("Cancel") }, "$phase must not offer Cancel")
        }
    }

    @Test
    fun copyProofNeedsAProof() {
        val withProof = PaymentStatus("a1", "Café Lumen", 2_100, PayPhase.Sent, 4, "beef", canRetry = false)
        assertEquals(listOf("Copy proof", "Done"), PayStatusCopy.actions(withProof).map { it.label })

        val withoutProof = withProof.copy(preimage = null)
        assertEquals(listOf("Done"), PayStatusCopy.actions(withoutProof).map { it.label })
    }

    @Test
    fun retryIsHiddenWhenTheDestinationIsGone() {
        // After a relaunch the ledger only holds a hash of the destination, so
        // there is nothing to re-send to.
        val stale = PaymentStatus("a1", "Café Lumen", 2_100, PayPhase.FailedSafe, 9, null, canRetry = false)
        assertEquals(listOf("Done"), PayStatusCopy.actions(stale).map { it.label })

        val retryable = stale.copy(canRetry = true)
        assertEquals(listOf("Try again", "Not now"), PayStatusCopy.actions(retryable).map { it.label })
    }

    // ── home strip ──

    @Test
    fun onlyLivePhasesEverReachTheHomeStrip() {
        // The strip is gated on a live send, and every live phase must render
        // as a spinner rather than a terminal glyph.
        for (phase in listOf(PayPhase.Resolving, PayPhase.Paying, PayPhase.Slow)) {
            assertTrue(phase.isLive, "$phase should be live")
            assertFalse(phase.isGood || phase.isBad, "$phase must not read as terminal")
        }
        assertEquals(
            "Sending 2,100 sats" to "Café Lumen · tap for details",
            PayStatusCopy.homeStrip(PayPhase.Paying, "Café Lumen", 2_100),
        )
    }
}
