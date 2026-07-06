package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.PayEntry
import chat.bitchat.sonar.PayStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun activity(
    id: String,
    kind: SonarPaymentActivity.Kind = SonarPaymentActivity.Kind.SonarDirect,
    direction: SonarPaymentActivity.Direction = SonarPaymentActivity.Direction.Outgoing,
    sats: Long = 1000,
    createdAtSecs: Long = 100,
    status: SonarPaymentActivity.Status = SonarPaymentActivity.Status.Pending,
    settledAtSecs: Long? = null,
    preimage: String? = null,
) = SonarPaymentActivity(
    id = id,
    kind = kind,
    peerKey = "peer-$id",
    peerName = "Alice",
    direction = direction,
    sats = sats,
    via = "internet",
    createdAtSecs = createdAtSecs,
    destinationHash = paymentDestinationHash("lno1qqq$id"),
    status = status,
    settledAtSecs = settledAtSecs,
    preimage = preimage,
)

class SonarPaymentActivityLedgerTest {

    @Test
    fun recordPendingIsIdempotentById() {
        val l = SonarPaymentActivityLedger()
        assertTrue(l.recordPending(activity("a1")))
        // Same id again — e.g. a replayed wallet PaymentSucceeded event for
        // the same walletPaymentId — must change nothing.
        assertFalse(l.recordPending(activity("a1", sats = 999_999)))
        assertEquals(1, l.all().size)
        assertEquals(1000L, l.get("a1")!!.sats)
    }

    @Test
    fun markPaidLinksWalletPaymentAndClearsFailure() {
        val l = SonarPaymentActivityLedger()
        l.recordPending(activity("a1"))
        l.markFailed("a1", "route not found", nowSecs = 150)
        assertEquals("route not found", l.get("a1")!!.failure)

        assertTrue(l.markPaid("a1", walletPaymentId = "tx123", feesSats = 3, settledAtSecs = 200))
        val e = l.get("a1")!!
        assertEquals(SonarPaymentActivity.Status.Paid, e.status)
        assertEquals("tx123", e.walletPaymentId)
        assertEquals(3L, e.feesSats)
        assertEquals(200L, e.settledAtSecs)
        assertNull(e.failure)
    }

    @Test
    fun markPaidAndFailedAreNoopsForUnknownIds() {
        val l = SonarPaymentActivityLedger()
        assertFalse(l.markPaid("nope", null, null, 1))
        assertFalse(l.markFailed("nope", "x", nowSecs = 1))
        assertTrue(l.all().isEmpty())
    }

    @Test
    fun markFailedStampsSettledTimeLikeIOS() {
        val l = SonarPaymentActivityLedger()
        l.recordPending(activity("a1", createdAtSecs = 100))
        assertTrue(l.markFailed("a1", "no route", nowSecs = 170))
        val e = l.get("a1")!!
        assertEquals(SonarPaymentActivity.Status.Failed, e.status)
        assertEquals("no route", e.failure)
        assertEquals(170L, e.settledAtSecs)
        assertEquals(170L, e.displaySecs)
    }

    @Test
    fun serializeRoundTripSurvivesRestart() {
        val l = SonarPaymentActivityLedger()
        l.recordPending(
            activity("a1", kind = SonarPaymentActivity.Kind.UnifyNearby).copy(
                // Free text with the framing characters must survive.
                peerName = "Bob | the\nbuilder\t⚡",
                failure = null,
            )
        )
        l.markPaid("a1", walletPaymentId = "tx-9", feesSats = 2, settledAtSecs = 300)
        l.recordPending(
            activity(
                "a2",
                kind = SonarPaymentActivity.Kind.WalletIncoming,
                direction = SonarPaymentActivity.Direction.Incoming,
                preimage = "ab".repeat(32),
            ).copy(destinationHash = null)
        )
        l.markFailed("a2", "swap failed | relay\ndown", nowSecs = 400)

        val reloaded = SonarPaymentActivityLedger(l.serialize())
        assertEquals(l.all(), reloaded.all())
        assertEquals("Bob | the\nbuilder\t⚡", reloaded.get("a1")!!.peerName)
        assertEquals("swap failed | relay\ndown", reloaded.get("a2")!!.failure)
        assertNull(reloaded.get("a2")!!.destinationHash)
        assertEquals("ab".repeat(32), reloaded.get("a2")!!.preimage)
        assertNull(reloaded.get("missing"))
    }

    @Test
    fun emptyAndGarbageBlobsDecodeEmpty() {
        assertTrue(SonarPaymentActivityLedger("").all().isEmpty())
        assertTrue(SonarPaymentActivityLedger("not|a|valid|row").all().isEmpty())
    }

    @Test
    fun sortedUsesSettledTimeThenCreatedTimeNewestFirst() {
        val l = SonarPaymentActivityLedger()
        l.recordPending(activity("old", createdAtSecs = 100))
        l.recordPending(activity("newer", createdAtSecs = 200))
        // Settled later than everything created — must float to the top.
        l.recordPending(activity("settled", createdAtSecs = 50))
        l.markPaid("settled", "tx", null, settledAtSecs = 500)
        assertEquals(listOf("settled", "newer", "old"), l.sorted().map { it.id })
    }

    @Test
    fun activitiesFiltersByPeerKey() {
        val l = SonarPaymentActivityLedger()
        l.recordPending(activity("a1"))
        l.recordPending(activity("a2"))
        assertEquals(listOf("a1"), l.activities("peer-a1").map { it.id })
    }
}

class MergeWalletActivityTest {

    @Test
    fun receiptsAndActivitiesInterleaveNewestFirst() {
        val receipts = listOf(
            PayEntry("r1", 100, PayStatus.Claimed, mine = false, tsSecs = 150),
            PayEntry("r2", 200, PayStatus.Sealed, mine = false, tsSecs = 350),
        )
        val activities = listOf(
            activity("a1", createdAtSecs = 400, status = SonarPaymentActivity.Status.Paid),
            activity("a2", createdAtSecs = 250),
        )
        val merged = mergeWalletActivity(receipts, activities)
        assertEquals(listOf("a1", "r2", "a2", "r1"), merged.map { it.id })
    }

    @Test
    fun directSendRecordedInBothLedgersShowsOnce() {
        // sendPay records a chat receipt AND a sonarDirect activity under the
        // same id — the activity row (richer settlement state) wins.
        val receipts = listOf(PayEntry("shared", 100, PayStatus.Claimed, mine = true, tsSecs = 100))
        val activities = listOf(
            activity("shared", createdAtSecs = 100, status = SonarPaymentActivity.Status.Paid)
        )
        val merged = mergeWalletActivity(receipts, activities)
        assertEquals(1, merged.size)
        assertEquals(SonarPaymentActivity.Status.Paid, merged.single().status)
        assertTrue(merged.single().sent)
    }

    @Test
    fun incomingChatPaymentDedupesAgainstWalletEventByPreimage() {
        val pre = "cd".repeat(32)
        // The chat ⚡PAYDONE receipt and the wallet's incoming-payment event
        // describe the same settlement — show one row (the chat receipt).
        val receipts = listOf(PayEntry("chat-uuid", 500, PayStatus.Claimed, mine = false, preimage = pre, tsSecs = 100))
        val activities = listOf(
            activity(
                "wallet-tx1",
                kind = SonarPaymentActivity.Kind.WalletIncoming,
                direction = SonarPaymentActivity.Direction.Incoming,
                createdAtSecs = 100,
                status = SonarPaymentActivity.Status.Paid,
                preimage = pre,
            )
        )
        val merged = mergeWalletActivity(receipts, activities)
        assertEquals(1, merged.size)
        // Activity row wins (it carries fees + settled time).
        assertEquals("wallet-tx1", merged.single().id)
        assertFalse(merged.single().sent)
    }

    @Test
    fun receiptStatusesMapToTheThreeIOSStatuses() {
        val receipts = listOf(
            PayEntry("claimed", 1, PayStatus.Claimed, mine = true, tsSecs = 4),
            PayEntry("sealed", 1, PayStatus.Sealed, mine = false, tsSecs = 3),
            PayEntry("settling", 1, PayStatus.Settling, mine = false, tsSecs = 2),
            PayEntry("failed", 1, PayStatus.Failed, mine = true, tsSecs = 1),
        )
        val merged = mergeWalletActivity(receipts, emptyList())
        assertEquals(
            mapOf(
                "claimed" to SonarPaymentActivity.Status.Paid,
                "sealed" to SonarPaymentActivity.Status.Pending,
                "settling" to SonarPaymentActivity.Status.Pending,
                "failed" to SonarPaymentActivity.Status.Failed,
            ),
            merged.associate { it.id to it.status },
        )
    }

    @Test
    fun legacyReceiptsWithoutTimestampsKeepReversedInsertionOrderAtBottom() {
        // Rows persisted by older builds decode with tsSecs = 0; the merged
        // list must keep the screen's previous newest-first (reversed
        // insertion) order for them, below every timestamped row.
        val receipts = listOf(
            PayEntry("first", 1, PayStatus.Claimed, mine = true),
            PayEntry("second", 2, PayStatus.Claimed, mine = true),
            PayEntry("timed", 3, PayStatus.Claimed, mine = true, tsSecs = 100),
        )
        val merged = mergeWalletActivity(receipts, emptyList())
        assertEquals(listOf("timed", "second", "first"), merged.map { it.id })
    }

    @Test
    fun destinationHashMatchesKnownSha256() {
        // SHA-256("abc") — pins the audit-hash helper to the standard vector.
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            paymentDestinationHash("abc"),
        )
    }
}
