package chat.bitchat.sonar

import chat.bitchat.sonar.wallet.NotifiedPaymentIds
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The notify-exactly-once guard for offline wallet receives: a payment id must
 * mark exactly once across event/poll legs, repeated wakes, and process deaths
 * (via encode/decode round-trip).
 */
class NotifiedPaymentIdsTest {

    @Test
    fun firstMarkNotifiesSecondDoesNot() {
        val ids = NotifiedPaymentIds()
        assertTrue(ids.markNotified("tx1"))
        assertFalse(ids.markNotified("tx1"))
    }

    @Test
    fun blankIdNeverNotifies() {
        val ids = NotifiedPaymentIds()
        assertFalse(ids.markNotified(""))
        assertFalse(ids.markNotified("   "))
    }

    @Test
    fun roundTripSurvivesProcessDeath() {
        val before = NotifiedPaymentIds()
        before.markNotified("tx1")
        before.markNotified("tx2")
        val after = NotifiedPaymentIds(before.encode())
        assertFalse(after.markNotified("tx1"))
        assertFalse(after.markNotified("tx2"))
        assertTrue(after.markNotified("tx3"))
    }

    @Test
    fun capEvictsOldestOnly() {
        val ids = NotifiedPaymentIds(cap = 3)
        ids.markNotified("a"); ids.markNotified("b"); ids.markNotified("c")
        assertTrue(ids.markNotified("d")) // evicts "a"
        assertFalse(ids.contains("a"))
        assertTrue(ids.contains("b"))
        assertTrue(ids.contains("c"))
        assertTrue(ids.contains("d"))
        // An evicted id can re-notify — acceptable: 64 payments later is a
        // different wake epoch, and the alternative is unbounded growth.
        assertTrue(ids.markNotified("a"))
    }

    @Test
    fun decodeAppliesCapAndSkipsDuplicatesAndBlanks() {
        val ids = NotifiedPaymentIds("a\n\n b \na\nc\nd", cap = 3)
        // dedupe keeps first "a"; cap 3 evicts oldest ("a") after b, c, d.
        assertFalse(ids.contains("a"))
        assertTrue(ids.contains("b"))
        assertTrue(ids.contains("c"))
        assertTrue(ids.contains("d"))
        assertEquals("b\nc\nd", ids.encode())
    }
}
