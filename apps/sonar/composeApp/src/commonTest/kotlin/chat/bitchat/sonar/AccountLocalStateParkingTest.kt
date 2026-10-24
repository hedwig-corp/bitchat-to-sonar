package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * An account switch sets the leaving account's own values aside and brings
 * them back on return, instead of deleting them (codex review of #667: a
 * switch used to run the restore teardown and lost them for good).
 *
 * Mirror of iOS `SonarAccountLocalStateTests`; keep the two in step.
 */
class AccountLocalStateParkingTest {

    private val a = "a".repeat(64)
    private val b = "b".repeat(64)

    /** A fake blob store plus the live values the app reads. */
    private class Store {
        val blobs = mutableMapOf<String, String>()
        val live = mutableMapOf<String, String>()
        fun values(vararg names: String): List<ParkedValue> = names.map { n ->
            ParkedValue(n, { live[n] ?: "" }, { v -> live[n] = v })
        }
        val load: (String) -> String = { blobs[it] ?: "" }
        val save: (String, String) -> Unit = { k, v -> blobs[k] = v }
    }

    @Test
    fun switchAwayAndBackRestoresTheLeavingAccountsValues() {
        val s = Store()
        val values = s.values("nickname", "bip353", "payment.activity")
        s.live += mapOf("nickname" to "Alice", "bip353" to "alice@sonar", "payment.activity" to "{ledger}")

        // Switch A → B: park A, then the teardown resets the live values.
        AccountLocalStateParking.park(a, values, s.save)
        s.live.keys.forEach { s.live[it] = "" }
        // B is new: nothing to restore, its values stay reset.
        assertFalse(AccountLocalStateParking.unpark(b, values, s.load, s.save))
        assertEquals("", s.live["nickname"])
        s.live["nickname"] = "Bob"

        // Switch B → A.
        AccountLocalStateParking.park(b, values, s.save)
        s.live.keys.forEach { s.live[it] = "" }
        assertTrue(AccountLocalStateParking.unpark(a, values, s.load, s.save))
        assertEquals("Alice", s.live["nickname"])
        assertEquals("alice@sonar", s.live["bip353"])
        assertEquals("{ledger}", s.live["payment.activity"])
        // The record is consumed; B's stays parked.
        assertEquals("", s.blobs[AccountLocalStateParking.recordKey(a)])
        assertTrue(s.blobs[AccountLocalStateParking.recordKey(b)]!!.isNotEmpty())
    }

    /** A value the record does not name must not keep the previous account's
     *  value in the live slot. */
    @Test
    fun aValueMissingFromTheRecordIsReset() {
        val s = Store()
        AccountLocalStateParking.park(a, s.values("nickname"), s.save)
        s.live["bip353"] = "bob@sonar"
        AccountLocalStateParking.unpark(a, s.values("nickname", "bip353"), s.load, s.save)
        assertEquals("", s.live["bip353"])
    }

    /** Empty values and separators round-trip; a corrupt record is never
     *  half-applied. */
    @Test
    fun codecRoundTripsAndRejectsCorruptRecords() {
        val map = mapOf("nickname" to "", "x" to "tab\there\nnewline=é")
        assertEquals(map, AccountLocalStateParking.decode(AccountLocalStateParking.encode(map)))
        assertEquals(emptyMap(), AccountLocalStateParking.decode(AccountLocalStateParking.encode(emptyMap())))
        assertNull(AccountLocalStateParking.decode(""))
        assertNull(AccountLocalStateParking.decode("not-a-record"))
        assertNull(AccountLocalStateParking.decode("parked.v1\nzz\t00"))

        val s = Store()
        s.blobs[AccountLocalStateParking.recordKey(a)] = "parked.v1\nnot-hex"
        s.live["nickname"] = "Bob"
        assertFalse(AccountLocalStateParking.unpark(a, s.values("nickname"), s.load, s.save))
        assertEquals("Bob", s.live["nickname"])
    }

    @Test
    fun discardForgetsARemovedAccountsRecord() {
        val s = Store()
        AccountLocalStateParking.park(a, s.values("nickname"), s.save)
        AccountLocalStateParking.discard(a, s.save)
        assertFalse(AccountLocalStateParking.unpark(a, s.values("nickname"), s.load, s.save))
    }
}
