package chat.bitchat.sonar.crypto

/**
 * Minimal Bech32 decoder (BIP-173) — enough to turn a Nostr `nsec1…` secret key
 * into its 32 raw bytes, matching the iOS `Bech32` decode used by
 * `SonarWalletDerivation`. Decode-only; rejects bech32m.
 */
object Bech32 {
    private const val CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    data class Decoded(val hrp: String, val data: ByteArray)

    /** Decode a bech32 string into (hrp, 8-bit payload bytes). Returns null on any error. */
    fun decode(input: String): Decoded? {
        val s = input.lowercase()
        val sep = s.lastIndexOf('1')
        if (sep < 1 || sep + 7 > s.length) return null
        val hrp = s.substring(0, sep)
        val dataPart = s.substring(sep + 1)
        val values = IntArray(dataPart.length)
        for (i in dataPart.indices) {
            val v = CHARSET.indexOf(dataPart[i])
            if (v < 0) return null
            values[i] = v
        }
        if (!verifyChecksum(hrp, values)) return null
        val payload5 = values.copyOfRange(0, values.size - 6)
        val bytes = convertBits(payload5, 5, 8, false) ?: return null
        return Decoded(hrp, bytes)
    }

    /** Decode an `nsec1…` to 32-byte secret hex, or null. */
    fun nsecToSecretHex(nsec: String): String? {
        val d = decode(nsec.trim()) ?: return null
        if (d.hrp != "nsec" || d.data.size != 32) return null
        return d.data.joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) }
    }

    /** Encode 8-bit payload bytes as BIP-173 bech32. Returns null on invalid input. */
    fun encode(hrp: String, data: ByteArray): String? {
        val cleanHrp = hrp.lowercase()
        if (cleanHrp.isEmpty() || cleanHrp.any { it.code < 33 || it.code > 126 }) return null
        val fiveBit = convertBits(data.map { it.toInt() and 0xFF }.toIntArray(), 8, 5, true)
            ?: return null
        val values = fiveBit.map { it.toInt() and 0xFF }.toIntArray()
        val checksum = createChecksum(cleanHrp, values)
        return buildString {
            append(cleanHrp)
            append('1')
            for (v in values + checksum) append(CHARSET[v])
        }
    }

    private fun polymod(values: IntArray): Int {
        val gen = intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
        var chk = 1
        for (v in values) {
            val b = chk ushr 25
            chk = ((chk and 0x1ffffff) shl 5) xor v
            for (i in 0 until 5) if (((b ushr i) and 1) != 0) chk = chk xor gen[i]
        }
        return chk
    }

    private fun hrpExpand(hrp: String): IntArray {
        val out = IntArray(hrp.length * 2 + 1)
        for (i in hrp.indices) out[i] = hrp[i].code ushr 5
        out[hrp.length] = 0
        for (i in hrp.indices) out[hrp.length + 1 + i] = hrp[i].code and 31
        return out
    }

    private fun verifyChecksum(hrp: String, data: IntArray): Boolean =
        polymod(hrpExpand(hrp) + data) == 1

    private fun createChecksum(hrp: String, data: IntArray): IntArray {
        val mod = polymod(hrpExpand(hrp) + data + IntArray(6)) xor 1
        return IntArray(6) { i -> (mod ushr (5 * (5 - i))) and 31 }
    }

    private fun convertBits(data: IntArray, from: Int, to: Int, pad: Boolean): ByteArray? {
        var acc = 0
        var bits = 0
        val out = ArrayList<Byte>()
        val maxv = (1 shl to) - 1
        for (value in data) {
            if (value < 0 || (value ushr from) != 0) return null
            acc = (acc shl from) or value
            bits += from
            while (bits >= to) { bits -= to; out.add(((acc ushr bits) and maxv).toByte()) }
        }
        if (pad) { if (bits > 0) out.add(((acc shl (to - bits)) and maxv).toByte()) }
        else if (bits >= from || ((acc shl (to - bits)) and maxv) != 0) return null
        return out.toByteArray()
    }
}
