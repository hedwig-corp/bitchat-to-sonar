package chat.bitchat.sonar

/**
 * Per-account host values that a switch sets aside instead of deleting.
 *
 * A switch is not a restore: the account being left must find its local
 * state again when the user comes back. Most host state is device-level and
 * simply stays where it is (mesh transcripts, links, mesh names, verification
 * marks, mutes, the payment-bubble ledger, peer caches: the BLE/Noise identity
 * is shared by every account on the phone). The few values that belong to ONE
 * account — its nickname, its handle, its cellular-backup consent, its wallet
 * activity — are copied into a per-account record before the teardown resets
 * them, and copied back when that account becomes active again.
 *
 * Crash safety: the record is one blob written atomically. [park] writes it
 * BEFORE the live values are reset, [unpark] writes the live values BEFORE it
 * clears the record, and every launch replays a record left for the active
 * account (see `SonarAppState.boot`). A crash anywhere in a switch therefore
 * either finds the live values untouched or finds a complete record to replay.
 *
 * Mirror of iOS `SonarAccountLocalState`; keep the value lists in step.
 */
internal class ParkedValue(
    val name: String,
    val read: () -> String,
    val write: (String) -> Unit,
)

internal object AccountLocalStateParking {
    private const val HEADER = "parked.v1"

    fun recordKey(pubkeyHex: String): String = "accounts.parked.${pubkeyHex.lowercase()}"

    /** Copy [values] into [pubkeyHex]'s record. Overwrites an older record. */
    fun park(
        pubkeyHex: String,
        values: List<ParkedValue>,
        save: (String, String) -> Unit,
    ) {
        save(recordKey(pubkeyHex), encode(values.associate { it.name to it.read() }))
    }

    /**
     * Restore [pubkeyHex]'s record into the live values, then drop it. A value
     * the record does not name is reset to empty: the live slot must never
     * keep the previous account's value. Returns false (and touches nothing)
     * when there is no record — a first visit, whose live values the teardown
     * has already reset.
     */
    fun unpark(
        pubkeyHex: String,
        values: List<ParkedValue>,
        load: (String) -> String,
        save: (String, String) -> Unit,
    ): Boolean {
        val record = decode(load(recordKey(pubkeyHex))) ?: return false
        values.forEach { it.write(record[it.name] ?: "") }
        save(recordKey(pubkeyHex), "")
        return true
    }

    /** Forget [pubkeyHex]'s record (the account was removed). */
    fun discard(pubkeyHex: String, save: (String, String) -> Unit) {
        save(recordKey(pubkeyHex), "")
    }

    internal fun encode(map: Map<String, String>): String =
        buildString {
            append(HEADER)
            for ((k, v) in map) {
                append('\n').append(hex(k)).append('\t').append(hex(v))
            }
        }

    /** Null for an absent or unreadable record: never apply a half-parsed one. */
    internal fun decode(blob: String): Map<String, String>? {
        if (blob.isEmpty()) return null
        val lines = blob.split('\n')
        if (lines.first() != HEADER) return null
        val out = LinkedHashMap<String, String>()
        for (line in lines.drop(1)) {
            val tab = line.indexOf('\t')
            if (tab < 0) return null
            val k = unhex(line.substring(0, tab)) ?: return null
            val v = unhex(line.substring(tab + 1)) ?: return null
            out[k] = v
        }
        return out
    }

    private fun hex(s: String): String =
        s.encodeToByteArray().joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }

    private fun unhex(s: String): String? {
        if (s.length % 2 != 0) return null
        val bytes = ByteArray(s.length / 2)
        for (i in bytes.indices) {
            bytes[i] = s.substring(i * 2, i * 2 + 2).toIntOrNull(16)?.toByte() ?: return null
        }
        return bytes.decodeToString()
    }
}
