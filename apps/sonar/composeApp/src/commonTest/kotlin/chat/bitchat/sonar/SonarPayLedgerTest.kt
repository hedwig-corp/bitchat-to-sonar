package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SonarPayLedgerTest {

    @Test
    fun pendingReceiptBecomesClaimed() {
        val l = SonarPayLedger()
        assertTrue(l.recordSealed("u1", 1000, mine = false))
        assertFalse(l.recordSealed("u1", 1000, mine = false), "idempotent: no second seal")
        assertEquals(PayStatus.Sealed, l.get("u1")!!.status)

        assertTrue(l.markClaimed("u1"))
        assertEquals(PayStatus.Claimed, l.get("u1")!!.status)
        // Terminal: marking a claimed receipt again is a no-op.
        assertFalse(l.markClaimed("u1"))
    }

    @Test
    fun outgoingReceiptIsAlreadyClaimed() {
        val l = SonarPayLedger()
        l.recordSealed("u2", 21000, mine = true)
        assertEquals(PayStatus.Claimed, l.get("u2")!!.status)
    }

    @Test
    fun serializeRoundTripSurvivesRestart() {
        val l = SonarPayLedger()
        l.recordSealed("a", 100, mine = true)
        l.recordSealed("b", 200, mine = false)
        val blob = l.serialize()

        val reloaded = SonarPayLedger(blob)
        assertEquals(2, reloaded.all().size)
        assertEquals(PayStatus.Claimed, reloaded.get("a")!!.status)
        assertTrue(reloaded.get("a")!!.mine)
        assertEquals(PayStatus.Sealed, reloaded.get("b")!!.status)
        assertEquals(200L, reloaded.get("b")!!.sats)
        assertNull(reloaded.get("missing"))
    }

    @Test
    fun unknownUuidTransitionsAreNoops() {
        val l = SonarPayLedger()
        assertFalse(l.markClaimed("nope"))
    }

    @Test
    fun doneBeforePayRecordsIncomingAsClaimed() {
        val l = SonarPayLedger()
        assertFalse(l.markClaimedOrPending("u3"))
        assertTrue(l.recordSealed("u3", 1000, mine = false))
        assertEquals(PayStatus.Claimed, l.get("u3")!!.status)
    }

    @Test
    fun payLineCodecRoundTrips() {
        assertEquals("⚡PAY|1|u1|2100", PayLine.Pay("u1", 2100).encoded())
        assertEquals("⚡PAYDONE|1|u1", PayLine.Done("u1").encoded())

        assertEquals(PayLine.Pay("u1", 2100), PayLine.decode("⚡PAY|1|u1|2100"))
        assertEquals(PayLine.Done("u1"), PayLine.decode("⚡PAYDONE|1|u1"))
        assertNull(PayLine.decode("hello world"))
        assertNull(PayLine.decode("⚡PAY|2|u1|2100"), "unknown version → plain text")
        assertNull(PayLine.decode("⚡PAYCLAIM|1|u1|lno1xxx"), "PAYCLAIM is no longer part of the protocol")
    }

    /**
     * The direct BOLT12 flow pays first, then posts PAY + PAYDONE receipts.
     * End state: Claimed on both sides, with no claim line in the transcript.
     */
    @Test
    fun twoPartyDirectReceiptConverges() {
        val sender = SonarPayLedger()
        val receiver = SonarPayLedger()

        // 1) Sender pays the receiver's published offer, then posts ⚡PAY.
        val pay = PayLine.decode("⚡PAY|1|c1|5000") as PayLine.Pay
        sender.recordSealed(pay.uuid, pay.sats, mine = true)
        receiver.recordSealed(pay.uuid, pay.sats, mine = false)

        // 2) Sender posts ⚡PAYDONE once settlement completes.
        val done = PayLine.decode("⚡PAYDONE|1|c1") as PayLine.Done
        assertTrue(receiver.markClaimed(done.uuid))

        assertEquals(PayStatus.Claimed, sender.get("c1")!!.status)
        assertEquals(PayStatus.Claimed, receiver.get("c1")!!.status)
    }
}
