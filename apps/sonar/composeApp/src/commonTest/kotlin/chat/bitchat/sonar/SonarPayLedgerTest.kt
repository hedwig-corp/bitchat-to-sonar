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
        assertTrue(l.recordReceipt("u1", 1000, mine = false))
        assertFalse(l.recordReceipt("u1", 1000, mine = false), "idempotent: no second seal")
        assertEquals(PayStatus.Sealed, l.get("u1")!!.status)

        assertTrue(l.markClaimed("u1"))
        assertEquals(PayStatus.Claimed, l.get("u1")!!.status)
        assertFalse(l.markClaimed("u1"), "no-op without new preimage")
    }

    @Test
    fun outgoingReceiptIsAlreadyClaimed() {
        val l = SonarPayLedger()
        l.recordReceipt("u2", 21000, mine = true)
        assertEquals(PayStatus.Claimed, l.get("u2")!!.status)
    }

    @Test
    fun serializeRoundTripSurvivesRestart() {
        val l = SonarPayLedger()
        l.recordReceipt("a", 100, mine = true)
        l.recordReceipt("b", 200, mine = false)
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
    fun serializeRoundTripWithPreimage() {
        val preimage = "a".repeat(64)
        val l = SonarPayLedger()
        l.recordReceipt("p1", 500, mine = false)
        l.markClaimed("p1", preimage)
        assertEquals(preimage, l.get("p1")!!.preimage)

        val reloaded = SonarPayLedger(l.serialize())
        assertEquals(preimage, reloaded.get("p1")!!.preimage)
        assertEquals(PayStatus.Claimed, reloaded.get("p1")!!.status)
    }

    @Test
    fun oldBlobWithoutPreimageStillLoads() {
        val blob = "u1|1000|Claimed|1"
        val l = SonarPayLedger(blob)
        assertEquals(PayStatus.Claimed, l.get("u1")!!.status)
        assertNull(l.get("u1")!!.preimage)
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
        assertTrue(l.recordReceipt("u3", 1000, mine = false))
        assertEquals(PayStatus.Claimed, l.get("u3")!!.status)
    }

    @Test
    fun doneBeforePayPreservesPreimage() {
        val preimage = "b".repeat(64)
        val l = SonarPayLedger()
        l.markClaimedOrPending("u4", preimage)
        l.recordReceipt("u4", 1000, mine = false)
        assertEquals(PayStatus.Claimed, l.get("u4")!!.status)
        assertEquals(preimage, l.get("u4")!!.preimage)
    }

    @Test
    fun markClaimedUpdatesPreimage() {
        val preimage = "c".repeat(64)
        val l = SonarPayLedger()
        l.recordReceipt("u5", 500, mine = false)
        assertNull(l.get("u5")!!.preimage)
        l.markClaimed("u5", preimage)
        assertEquals(preimage, l.get("u5")!!.preimage)
    }

    // ── PayLine codec ──

    @Test
    fun payLineCodecRoundTrips() {
        assertEquals("⚡PAY|1|u1|2100", PayLine.Pay("u1", 2100).encoded())
        assertEquals("⚡PAYDONE|2|u1", PayLine.Done("u1").encoded())

        assertEquals(PayLine.Pay("u1", 2100), PayLine.decode("⚡PAY|1|u1|2100"))
        assertEquals(PayLine.Done("u1"), PayLine.decode("⚡PAYDONE|2|u1"))
        assertNull(PayLine.decode("hello world"))
        assertNull(PayLine.decode("⚡PAY|2|u1|2100"), "unknown PAY version → plain text")
        assertNull(PayLine.decode("⚡PAYCLAIM|1|u1|lno1xxx"), "PAYCLAIM is no longer part of the protocol")
    }

    @Test
    fun payLineDoneV2WithPreimage() {
        val preimage = "d".repeat(64)
        val done = PayLine.Done("u1", preimage)
        assertEquals("⚡PAYDONE|2|u1|$preimage", done.encoded())

        val decoded = PayLine.decode(done.encoded())
        assertEquals(done, decoded)
    }

    @Test
    fun payLineDoneV2WithoutPreimage() {
        val done = PayLine.Done("u1")
        assertEquals("⚡PAYDONE|2|u1", done.encoded())
        assertEquals(done, PayLine.decode(done.encoded()))
    }

    @Test
    fun payLineDecodeV1DoneBackwardCompat() {
        val decoded = PayLine.decode("⚡PAYDONE|1|u1")
        assertEquals(PayLine.Done("u1"), decoded)
    }

    @Test
    fun payLineDecodeRejectsInvalidPreimage() {
        assertNull(PayLine.decode("⚡PAYDONE|2|u1|tooshort"), "too short")
        assertNull(PayLine.decode("⚡PAYDONE|2|u1|${"g".repeat(64)}"), "non-hex")
        assertNull(PayLine.decode("⚡PAYDONE|2|u1|${"a".repeat(63)}"), "63 chars")
        assertNull(PayLine.decode("⚡PAYDONE|2|u1|${"a".repeat(64)}|extra"), "too many parts")
    }

    @Test
    fun payLineDecodeRejectsV1DoneWithExtraParts() {
        assertNull(PayLine.decode("⚡PAYDONE|1|u1|extra"), "v1 must be exactly 3 parts")
    }

    /**
     * The direct BOLT12 flow pays first, then posts PAY + PAYDONE receipts.
     * End state: Claimed on both sides, with preimage stored on receiver.
     */
    @Test
    fun twoPartyDirectReceiptConverges() {
        val preimage = "e".repeat(64)
        val sender = SonarPayLedger()
        val receiver = SonarPayLedger()

        val pay = PayLine.decode("⚡PAY|1|c1|5000") as PayLine.Pay
        sender.recordReceipt(pay.uuid, pay.sats, mine = true)
        receiver.recordReceipt(pay.uuid, pay.sats, mine = false)

        val done = PayLine.decode("⚡PAYDONE|2|c1|$preimage") as PayLine.Done
        assertTrue(receiver.markClaimed(done.uuid, done.preimage))

        assertEquals(PayStatus.Claimed, sender.get("c1")!!.status)
        assertEquals(PayStatus.Claimed, receiver.get("c1")!!.status)
        assertEquals(preimage, receiver.get("c1")!!.preimage)
    }
}
