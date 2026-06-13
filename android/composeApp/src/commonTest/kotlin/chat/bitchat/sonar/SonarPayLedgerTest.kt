package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SonarPayLedgerTest {

    @Test
    fun sealedClaimingClaimedFlow() {
        val l = SonarPayLedger()
        assertTrue(l.recordSealed("u1", 1000, mine = false))
        assertFalse(l.recordSealed("u1", 1000, mine = false), "idempotent: no second seal")
        assertEquals(PayStatus.Sealed, l.get("u1")!!.status)

        assertTrue(l.markClaiming("u1"))
        assertEquals(PayStatus.Claiming, l.get("u1")!!.status)
        // Can't seal-transition again from Claiming.
        assertFalse(l.markSettling("u1"))

        assertTrue(l.markClaimed("u1"))
        assertEquals(PayStatus.Claimed, l.get("u1")!!.status)
        // Terminal: claiming a claimed coin is a no-op.
        assertFalse(l.markClaiming("u1"))
        assertFalse(l.markClaimed("u1"))
    }

    @Test
    fun failureRevertsToSealedForRetry() {
        val l = SonarPayLedger()
        l.recordSealed("u2", 21000, mine = true)
        assertTrue(l.markSettling("u2"))
        assertTrue(l.fail("u2"))
        assertEquals(PayStatus.Sealed, l.get("u2")!!.status)
        // After revert it can be settled again.
        assertTrue(l.markSettling("u2"))
        // fail() only applies to in-flight states.
        l.markClaimed("u2")
        assertFalse(l.fail("u2"))
    }

    @Test
    fun serializeRoundTripSurvivesRestart() {
        val l = SonarPayLedger()
        l.recordSealed("a", 100, mine = true)
        l.recordSealed("b", 200, mine = false)
        l.markClaiming("b")
        val blob = l.serialize()

        val reloaded = SonarPayLedger(blob)
        assertEquals(2, reloaded.all().size)
        assertEquals(PayStatus.Sealed, reloaded.get("a")!!.status)
        assertTrue(reloaded.get("a")!!.mine)
        assertEquals(PayStatus.Claiming, reloaded.get("b")!!.status)
        assertEquals(200L, reloaded.get("b")!!.sats)
        assertNull(reloaded.get("missing"))
    }

    @Test
    fun unknownUuidTransitionsAreNoops() {
        val l = SonarPayLedger()
        assertFalse(l.markClaiming("nope"))
        assertFalse(l.markClaimed("nope"))
        assertFalse(l.fail("nope"))
    }
}
