package chat.bitchat.sonar

import chat.bitchat.sonar.wallet.SpendableBalance
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * #141 — `Max` proposed the whole balance, so the send failed locally with a
 * raw `InsufficientFunds` after the user had committed. Max must leave room
 * for fees, and a doomed send must be blocked with our own message.
 */
class SpendableBalanceTest {

    @Test
    fun maxLeavesRoomForFees() {
        // The bug: max == balance.
        for (balance in listOf(1_000L, 50_000L, 1_000_000L)) {
            val max = SpendableBalance.maxSendableSats(balance)
            assertTrue(max < balance, "max ($max) must be below balance ($balance)")
            assertEquals(balance - SpendableBalance.feeReserveSats(balance), max)
        }
    }

    @Test
    fun reserveIsFlooredButUncapped() {
        // Small balance: the floor applies, not 0.5% of nothing.
        assertEquals(SpendableBalance.MIN_FEE_RESERVE_SATS, SpendableBalance.feeReserveSats(1_000))
        // Large balance: NO ceiling — a proportional fee needs a proportional
        // reserve, and any flat cap re-introduces #141 above some balance.
        assertEquals(500_000, SpendableBalance.feeReserveSats(100_000_000))
        // Mid balance: proportional.
        assertEquals(500, SpendableBalance.feeReserveSats(100_000))
    }

    @Test
    fun dustBalancesOfferNothing() {
        // At or below the reserve there is nothing that can settle; 0 tells
        // the UI to hide Max rather than propose a doomed amount.
        assertEquals(0, SpendableBalance.maxSendableSats(SpendableBalance.MIN_FEE_RESERVE_SATS))
        assertEquals(0, SpendableBalance.maxSendableSats(5))
        assertEquals(0, SpendableBalance.maxSendableSats(0))
        assertEquals(0, SpendableBalance.maxSendableSats(-1))
    }

    @Test
    fun preSendCheckUsesTheRealFee() {
        // Exactly affordable: allowed (boundary — amount + fee == balance).
        assertFalse(SpendableBalance.insufficientAfterFee(990, 10, 1_000))
        // One sat over: blocked before Breez sees it.
        assertTrue(SpendableBalance.insufficientAfterFee(991, 10, 1_000))
        // The original report: Max == balance with any fee at all.
        assertTrue(SpendableBalance.insufficientAfterFee(1_000, 1, 1_000))
        // A zero amount is not a funding problem (validated elsewhere).
        assertFalse(SpendableBalance.insufficientAfterFee(0, 10, 1_000))
    }

    /** The proposed max must survive its own pre-send check at a plausible fee. */
    @Test
    fun proposedMaxSurvivesTheCheck() {
        for (balance in listOf(1_000L, 20_000L, 500_000L, 10_000_000L)) {
            val max = SpendableBalance.maxSendableSats(balance)
            if (max <= 0) continue
            // An INDEPENDENT fee model, not the reserve tested against itself:
            // the old version could never fail because both sides were the
            // same function. 0.4% + 10 is the upper end of Breez sender fees.
            val plausibleFee = maxOf(10L, balance * 40 / 10_000)
            assertFalse(
                SpendableBalance.insufficientAfterFee(max, plausibleFee, balance),
                "max for balance $balance must settle at a reserve-sized fee",
            )
        }
    }
}
