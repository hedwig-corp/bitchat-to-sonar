package chat.bitchat.sonar

import chat.bitchat.sonar.wallet.settleWakeOutcome
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Pins the Breez settle wake's exit/notify decision.
 *
 * This logic regressed once mid-review of PR #295 with all 18 tests staying
 * green, which is the R-001 pattern: helper-level tests pass while the real
 * decision is wrong. The named scenarios below are the actual failures, not
 * abstract truth-table coverage.
 */
class SettleWakeOutcomeTest {

    // ── The regression: a historical receive must not end a new wake ──

    @Test
    fun historicalReceiveFromThePollFeedDoesNotEndTheWake() {
        // Payment A settled and was notified 2 min ago. A push arrives for a NEW
        // payment B; the first poll returns A (still inside the 600s lookback)
        // while B's lockup is not visible yet. If A ends the wake, B gets no
        // connected time — and A is "first this wake" on every subsequent wake
        // too, so it repeats until A ages out.
        val out = settleWakeOutcome(
            settled = true, liveEvent = false, firstThisWake = true, alreadyNotified = true,
        )
        assertFalse(out.endsWake, "an already-notified receive must not end a poll-driven wake")
        assertFalse(out.notifies)
    }

    @Test
    fun newSettledReceiveFromThePollFeedEndsTheWakeAndNotifies() {
        val out = settleWakeOutcome(
            settled = true, liveEvent = false, firstThisWake = true, alreadyNotified = false,
        )
        assertTrue(out.endsWake)
        assertTrue(out.notifies)
    }

    // ── The trap the fix had to avoid: foreground-claimed payments ──

    @Test
    fun liveEventEndsTheWakeEvenWhenTheForegroundAlreadyClaimedIt() {
        // The UI was up when this settled, so emitPaymentEvent already claimed
        // the notify slot. The wake must still END (no second banner, but also
        // no burning the full 45s budget waiting for something already in hand).
        val out = settleWakeOutcome(
            settled = true, liveEvent = true, firstThisWake = true, alreadyNotified = true,
        )
        assertTrue(out.endsWake, "a live settlement ends the wake regardless of the ring")
        assertFalse(out.notifies, "but must not post a second banner")
    }

    @Test
    fun liveEventSeenTwiceInOneWakeEndsItOnlyOnce() {
        val second = settleWakeOutcome(
            settled = true, liveEvent = true, firstThisWake = false, alreadyNotified = true,
        )
        assertFalse(second.endsWake)
        assertFalse(second.notifies)
    }

    // ── PENDING: ends the wake, never notifies ──

    @Test
    fun pendingReceiveEndsTheWakeButNeverNotifies() {
        // Lockup seen, claim in flight. Funds are arriving so stop waiting, but
        // the swap can still fail or be reorged — a banner and a permanent Paid
        // row here can never be corrected, because the ring blocks re-notifying.
        val out = settleWakeOutcome(
            settled = false, liveEvent = false, firstThisWake = true, alreadyNotified = false,
        )
        assertTrue(out.endsWake)
        assertFalse(out.notifies, "PENDING must never notify")
    }

    @Test
    fun pendingReceiveWeAlreadyAnnouncedDoesNotEndTheWake() {
        // A payment that completed and was announced in an earlier wake can
        // still be re-reported as a pending row inside the lookback window.
        // Treating that as an arrival would end every wake for 600s.
        val out = settleWakeOutcome(
            settled = false, liveEvent = false, firstThisWake = true, alreadyNotified = true,
        )
        assertFalse(out.endsWake)
        assertFalse(out.notifies)
    }

    @Test
    fun pendingReceiveSeenTwiceInOneWakeEndsItOnlyOnce() {
        val out = settleWakeOutcome(
            settled = false, liveEvent = false, firstThisWake = false, alreadyNotified = false,
        )
        assertFalse(out.endsWake)
        assertFalse(out.notifies)
    }

    // ── The invariant that must hold across every combination ──

    @Test
    fun aPendingReceiveNeverNotifiesUnderAnyCombination() {
        for (liveEvent in listOf(true, false)) {
            for (firstThisWake in listOf(true, false)) {
                for (alreadyNotified in listOf(true, false)) {
                    val out = settleWakeOutcome(
                        settled = false,
                        liveEvent = liveEvent,
                        firstThisWake = firstThisWake,
                        alreadyNotified = alreadyNotified,
                    )
                    assertFalse(
                        out.notifies,
                        "PENDING notified with live=$liveEvent first=$firstThisWake seen=$alreadyNotified",
                    )
                }
            }
        }
    }

    @Test
    fun notifyingImpliesEndingTheWake() {
        // If we told the user money arrived, the wake has no reason to keep
        // polling. Catches a future edit that decouples these the wrong way.
        for (liveEvent in listOf(true, false)) {
            for (firstThisWake in listOf(true, false)) {
                for (settled in listOf(true, false)) {
                    for (alreadyNotified in listOf(true, false)) {
                        val out = settleWakeOutcome(
                            settled, liveEvent, firstThisWake, alreadyNotified,
                        )
                        if (out.notifies) {
                            assertTrue(
                                out.endsWake,
                                "notified without ending the wake: settled=$settled live=$liveEvent " +
                                    "first=$firstThisWake seen=$alreadyNotified",
                            )
                        }
                    }
                }
            }
        }
    }
}
