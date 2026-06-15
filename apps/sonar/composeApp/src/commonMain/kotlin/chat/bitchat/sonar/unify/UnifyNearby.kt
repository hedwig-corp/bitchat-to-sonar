package chat.bitchat.sonar.unify

/**
 * Unify nearby-payments contract + BIP321 parsing, ported 1:1 from the iOS
 * UnifyNearbyService / UnifyBIP321 (pure logic, unit-tested). The BLE GATT
 * fetch of a Unify receiver's offer layers on top (radio-dependent).
 */
object UnifyContract {
    const val PROTOCOL_VERSION = 2
    const val SERVICE_UUID = "b1f7e2a0-9c3d-4e8a-bf21-3a1c0de54f10"
    const val PAYLOAD_CHARACTERISTIC_UUID = "b1f7e2a1-9c3d-4e8a-bf21-3a1c0de54f10"
    const val MAX_CHUNK_SIZE = 180
    const val MAX_PAYLOAD_BYTES = 8 * 1024
    const val DEFAULT_NAME = "Unify user"
}

/**
 * Length-prefixed framing for a single UTF-8 payload over GATT: a 4-byte
 * big-endian length header followed by the UTF-8 bytes, split into chunks by
 * the radio. The receiver concatenates chunks until it has `4 + len` bytes.
 */
object UnifyFraming {
    const val HEADER_SIZE = 4

    fun frame(payload: String): ByteArray {
        val body = payload.encodeToByteArray()
        val n = body.size
        return byteArrayOf(
            ((n ushr 24) and 0xFF).toByte(),
            ((n ushr 16) and 0xFF).toByte(),
            ((n ushr 8) and 0xFF).toByte(),
            (n and 0xFF).toByte(),
        ) + body
    }

    /** Reassembles chunked frames; returns the payload once complete, else null. */
    class Reassembler {
        private var buffer = ByteArray(0)

        fun reset() { buffer = ByteArray(0) }

        fun append(chunk: ByteArray): String? {
            if (chunk.isEmpty()) return null
            buffer += chunk
            if (buffer.size < HEADER_SIZE) return null
            val len = ((buffer[0].toInt() and 0xFF) shl 24) or
                ((buffer[1].toInt() and 0xFF) shl 16) or
                ((buffer[2].toInt() and 0xFF) shl 8) or
                (buffer[3].toInt() and 0xFF)
            if (len < 0 || len > UnifyContract.MAX_PAYLOAD_BYTES) return null
            if (buffer.size < HEADER_SIZE + len) return null
            return buffer.copyOfRange(HEADER_SIZE, HEADER_SIZE + len).decodeToString()
        }
    }
}

/**
 * Parse a BIP321 `bitcoin:` (or bare Lightning) URI to the Lightning destination
 * we pay. Order: a `lightning=`/`lno=`/`b12=` query param, else a bare
 * `lno…`/`lnbc…`/… string, else null (on-chain-only `bitcoin:` has no LN leg).
 */
object UnifyBIP321 {
    data class Parsed(val lightning: String, val amountSats: Long?)

    private val LIGHTNING_PREFIXES = listOf("lno1", "lnbc", "lntb", "lnbcrt", "lnsb", "lntbs")

    fun parse(raw: String): Parsed? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null

        bareLightning(trimmed)?.let { return Parsed(it, null) }

        if (hasScheme(trimmed, "lightning")) {
            bareLightning(trimmed.substring("lightning:".length))?.let { return Parsed(it, null) }
        }

        if (hasScheme(trimmed, "bitcoin")) {
            val body = trimmed.substring("bitcoin:".length)
            val query = body.substringAfter('?', "")
            val params = parseQuery(query)
            val ln = params["lightning"] ?: params["lno"] ?: params["b12"]
            val bare = ln?.let { bareLightning(it) } ?: return null
            return Parsed(bare, params["amount"]?.let { btcStringToSats(it) })
        }
        return null
    }

    private fun bareLightning(s: String): String? {
        val lower = s.trim().lowercase()
        return if (LIGHTNING_PREFIXES.any { lower.startsWith(it) }) lower else null
    }

    private fun hasScheme(s: String, scheme: String) = s.lowercase().startsWith("$scheme:")

    private fun parseQuery(query: String): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for (pair in query.split("&")) {
            if (pair.isEmpty()) continue
            val i = pair.indexOf('=')
            val key = (if (i < 0) pair else pair.substring(0, i)).lowercase()
            val value = if (i < 0) "" else pair.substring(i + 1)
            if (!out.containsKey(key)) out[key] = value  // first occurrence wins
        }
        return out
    }

    /** BIP21 `amount=` is decimal BTC; convert to sats precisely (no BigDecimal
     *  in commonMain — parse the integer/fraction parts directly). */
    fun btcStringToSats(btc: String): Long? {
        val s = percentDecode(btc).trim()
        if (s.isEmpty()) return null
        val parts = s.split(".")
        if (parts.size > 2) return null
        val intStr = parts[0].ifEmpty { "0" }
        var fracStr = parts.getOrNull(1) ?: ""
        if (!intStr.all { it.isDigit() } || !fracStr.all { it.isDigit() }) return null
        // Round to 8 decimals (sat precision) on the 9th digit.
        val roundUp = fracStr.length > 8 && fracStr[8] >= '5'
        fracStr = fracStr.take(8).padEnd(8, '0')
        val sats = intStr.toLong() * 100_000_000L + fracStr.toLong() + if (roundUp) 1 else 0
        return if (sats > 0) sats else null
    }

    private fun percentDecode(s: String): String {
        if (!s.contains('%')) return s
        val out = StringBuilder()
        var i = 0
        while (i < s.length) {
            if (s[i] == '%' && i + 2 < s.length) {
                val hex = s.substring(i + 1, i + 3)
                val code = hex.toIntOrNull(16)
                if (code != null) { out.append(code.toChar()); i += 3; continue }
            }
            out.append(s[i]); i++
        }
        return out.toString()
    }
}
