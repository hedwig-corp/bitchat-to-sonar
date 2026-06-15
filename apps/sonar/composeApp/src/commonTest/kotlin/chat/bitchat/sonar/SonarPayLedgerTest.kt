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

    @Test
    fun payLineCodecRoundTrips() {
        assertEquals("⚡PAY|1|u1|2100", PayLine.Pay("u1", 2100).encoded())
        assertEquals("⚡PAYCLAIM|1|u1|lno1xxx", PayLine.Claim("u1", "lno1xxx").encoded())
        assertEquals("⚡PAYDONE|1|u1", PayLine.Done("u1").encoded())

        assertEquals(PayLine.Pay("u1", 2100), PayLine.decode("⚡PAY|1|u1|2100"))
        assertEquals(PayLine.Claim("u1", "lno1xxx"), PayLine.decode("⚡PAYCLAIM|1|u1|lno1xxx"))
        assertEquals(PayLine.Done("u1"), PayLine.decode("⚡PAYDONE|1|u1"))
        assertNull(PayLine.decode("hello world"))
        assertNull(PayLine.decode("⚡PAY|2|u1|2100"), "unknown version → plain text")
    }

    /**
     * The full auto-claim handshake, modelled as the sender + receiver ledgers
     * each consume the shared transcript. End state: Claimed on both sides.
     */
    @Test
    fun twoPartyAutoClaimConverges() {
        val sender = SonarPayLedger()   // sealed the coin (mine=true)
        val receiver = SonarPayLedger() // gets the coin (mine=false)

        // 1) Sender posts ⚡PAY. Both ledgers record it (idempotent).
        val pay = PayLine.decode("⚡PAY|1|c1|5000") as PayLine.Pay
        sender.recordSealed(pay.uuid, pay.sats, mine = true)
        receiver.recordSealed(pay.uuid, pay.sats, mine = false)

        // 2) Receiver claims → creates an offer → markClaiming + posts ⚡PAYCLAIM.
        assertTrue(receiver.markClaiming("c1"))
        val claim = PayLine.decode("⚡PAYCLAIM|1|c1|lno1offer") as PayLine.Claim

        // 3) Sender sees the CLAIM for a coin it sealed → settle → markClaimed + ⚡PAYDONE.
        assertTrue(sender.markSettling(claim.uuid))
        assertTrue(sender.markClaimed(claim.uuid))
        val done = PayLine.decode("⚡PAYDONE|1|c1") as PayLine.Done

        // 4) Receiver sees DONE → markClaimed.
        assertTrue(receiver.markClaimed(done.uuid))

        assertEquals(PayStatus.Claimed, sender.get("c1")!!.status)
        assertEquals(PayStatus.Claimed, receiver.get("c1")!!.status)
    }
}
