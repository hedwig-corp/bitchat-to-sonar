package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The pay sheet's fee consent (maintainer review, #614): the "Network fee: up
 * to N" the sheet shows is the most the send may pay. These are the two rules
 * [PaySheet]'s Send button applies at the tap — the iOS mirror is
 * `SNFeeQuote.blocksSend` / `SNFeeQuote.consentedCeiling`.
 */
class PaySheetFeeConsentTest {

    @Test
    fun theFeeOnScreenIsTheCeiling() {
        assertEquals(3L, consentedFeeCeiling(FeeLine.Known(3), hasQuoter = true))
        assertEquals(0L, consentedFeeCeiling(FeeLine.Known(0), hasQuoter = true))
    }

    /** No fee on screen (quote failed or not back yet): any fee must be asked about again. */
    @Test
    fun noFeeOnScreenConsentsToNoFee() {
        assertEquals(0L, consentedFeeCeiling(FeeLine.Hidden, hasQuoter = true))
        assertEquals(0L, consentedFeeCeiling(FeeLine.Checking, hasQuoter = true))
    }

    /** The legacy wallet has no quoter: no fee was ever shown, so no ceiling. */
    @Test
    fun noQuoterMeansNoCeiling() {
        assertNull(consentedFeeCeiling(FeeLine.Hidden, hasQuoter = false))
        assertNull(consentedFeeCeiling(FeeLine.Known(3), hasQuoter = false))
    }

    /** Send waits only while the fee is being checked — never on a failed quote, never without a quoter. */
    @Test
    fun sendWaitsOnlyWhileTheFeeIsChecking() {
        assertTrue(feeBlocksSend(FeeLine.Checking, hasQuoter = true))
        assertFalse(feeBlocksSend(FeeLine.Known(3), hasQuoter = true))
        assertFalse(feeBlocksSend(FeeLine.Hidden, hasQuoter = true))
        assertFalse(feeBlocksSend(FeeLine.Checking, hasQuoter = false))
    }
}
