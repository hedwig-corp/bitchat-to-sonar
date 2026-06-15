package chat.bitchat.sonar

/**
 * Safety-number derivation, byte-for-byte identical to the iOS
 * `SonarAppStore.safetyNumbers` (FNV-1a over both parties' keys, order
 * independent) so the two platforms show the SAME 12 five-digit groups when a
 * Sonar user verifies an iOS user. Distinct from the avatar-color `snHash`.
 */
object SafetyNumber {
    /** FNV-1a 32-bit, matching the iOS `snHash`. */
    private fun fnv1a(s: String): Long {
        var h = 2166136261L // 0x811c9dc5
        for (c in s) {
            h = h xor c.code.toLong()
            h = (h * 16777619L) and 0xFFFFFFFFL
        }
        return h
    }

    /** 12 five-digit groups from both keys, independent of argument order. */
    fun of(a: String, b: String): List<String> {
        val combined = listOf(a.lowercase(), b.lowercase()).sorted().joinToString("|")
        return (0 until 12).map { (fnv1a("$combined:$it") % 100_000).toString().padStart(5, '0') }
    }
}
