package chat.bitchat.sonar.wallet

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class ReceiveAnnouncerTest {
    private var now = 1_790_000_000_000L
    private val announced = mutableListOf<Pair<String, Long>>()

    private fun TestScope.announcer() =
        ReceiveAnnouncer(backgroundScope, graceMs = { GRACE }, nowMillis = { now }) { id, sats ->
            announced += id to sats
        }

    private fun TestScope.pastTheGrace() {
        advanceTimeBy(GRACE + 1)
        runCurrent()
    }

    @Test
    fun aReceiveNoChatLineAnnouncedGetsItsBannerOnceTheGraceEnds() = runTest {
        val a = announcer()
        a.walletReceive("p1", 21)
        advanceTimeBy(GRACE - 1)
        runCurrent()
        assertTrue(announced.isEmpty(), "it waits for a chat line first")
        pastTheGrace()
        assertEquals(listOf("p1" to 21L), announced)
    }

    @Test
    fun aReceiptSilencesOneReceiveOfItsAmountInEitherOrder() = runTest {
        val a = announcer()
        a.chatReceipt("u1", 21, now)
        a.walletReceive("p1", 21)

        a.walletReceive("p2", 50)
        advanceTimeBy(GRACE / 2)
        a.chatReceipt("u2", 50, now)

        a.chatReceipt("u3", 7, now)
        a.walletReceive("p3", 7)
        a.walletReceive("p4", 7)
        pastTheGrace()

        assertEquals(listOf("p4" to 7L), announced, "one receipt accounts for one receive")
    }

    @Test
    fun onlyAFreshReceiptOfTheSameAmountCountsAndOnlyOnce() = runTest {
        val a = announcer()
        a.chatReceipt("old", 21, now - ReceiveAnnouncer.LOOKBACK_MS - 1)
        a.chatReceipt("other", 22, now)
        a.chatReceipt("twice", 30, now)
        a.chatReceipt("twice", 30, now)
        a.chatReceipt("aging", 40, now)
        a.walletReceive("p1", 21)
        a.walletReceive("p2", 30)
        a.walletReceive("p3", 30)
        now += ReceiveAnnouncer.LOOKBACK_MS + 1
        a.walletReceive("p4", 40)
        pastTheGrace()

        assertEquals(listOf("p1" to 21L, "p3" to 30L, "p4" to 40L), announced)
    }

    private companion object {
        const val GRACE = 1_000L
    }
}
