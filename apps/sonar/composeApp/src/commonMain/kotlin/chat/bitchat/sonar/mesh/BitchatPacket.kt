package chat.bitchat.sonar.mesh

/**
 * bitchat BLE mesh packet (binary protocol v1), ported byte-for-byte from the
 * iOS BinaryProtocol so Android mesh messages are wire-compatible.
 *
 * v1 header (14 bytes): version(1) type(1) ttl(1) timestamp(8, big-endian ms)
 * flags(1) payloadLength(2, big-endian). Then: senderID(8), recipientID(8 if
 * the hasRecipient flag is set), payload(payloadLength), signature(64 if the
 * hasSignature flag is set). Broadcast recipient = 0xFF × 8.
 *
 * Compression and v2 source-routing are not handled here (v1 uncompressed is
 * the common mesh case); decode ignores any trailing padding the radio adds.
 */
class BitchatPacket(
    val type: Int,
    val ttl: Int,
    val timestampMs: Long,
    val senderId: ByteArray,
    val recipientId: ByteArray?,
    val payload: ByteArray,
    val signature: ByteArray?,
    val version: Int = 1,
) {
    fun encode(): ByteArray {
        require(senderId.size == SENDER_ID_SIZE) { "senderId must be 8 bytes" }
        var flags = 0
        if (recipientId != null) flags = flags or FLAG_HAS_RECIPIENT
        if (signature != null) flags = flags or FLAG_HAS_SIGNATURE

        val size = V1_HEADER + SENDER_ID_SIZE +
            (if (recipientId != null) RECIPIENT_ID_SIZE else 0) +
            payload.size + (if (signature != null) SIGNATURE_SIZE else 0)
        val out = ByteArray(size)
        var o = 0
        out[o++] = version.toByte()
        out[o++] = type.toByte()
        out[o++] = ttl.toByte()
        for (shift in 56 downTo 0 step 8) out[o++] = ((timestampMs ushr shift) and 0xFF).toByte()
        out[o++] = flags.toByte()
        out[o++] = ((payload.size ushr 8) and 0xFF).toByte()
        out[o++] = (payload.size and 0xFF).toByte()
        senderId.copyInto(out, o); o += SENDER_ID_SIZE
        if (recipientId != null) {
            require(recipientId.size == RECIPIENT_ID_SIZE) { "recipientId must be 8 bytes" }
            recipientId.copyInto(out, o); o += RECIPIENT_ID_SIZE
        }
        payload.copyInto(out, o); o += payload.size
        if (signature != null) {
            require(signature.size == SIGNATURE_SIZE) { "signature must be 64 bytes" }
            signature.copyInto(out, o)
        }
        return out
    }

    companion object {
        const val V1_HEADER = 14
        const val SENDER_ID_SIZE = 8
        const val RECIPIENT_ID_SIZE = 8
        const val SIGNATURE_SIZE = 64
        const val FLAG_HAS_RECIPIENT = 0x01
        const val FLAG_HAS_SIGNATURE = 0x02
        const val FLAG_IS_COMPRESSED = 0x04

        val BROADCAST: ByteArray = ByteArray(SENDER_ID_SIZE) { 0xFF.toByte() }

        fun decode(data: ByteArray): BitchatPacket? {
            if (data.size < V1_HEADER + SENDER_ID_SIZE) return null
            val version = data[0].toInt() and 0xFF
            if (version != 1) return null
            val type = data[1].toInt() and 0xFF
            val ttl = data[2].toInt() and 0xFF
            var ts = 0L
            for (i in 0 until 8) ts = (ts shl 8) or (data[3 + i].toLong() and 0xFF)
            val flags = data[11].toInt() and 0xFF
            if (flags and FLAG_IS_COMPRESSED != 0) return null // not handled here
            val payloadLength = ((data[12].toInt() and 0xFF) shl 8) or (data[13].toInt() and 0xFF)

            var o = V1_HEADER
            val hasRecipient = flags and FLAG_HAS_RECIPIENT != 0
            val hasSignature = flags and FLAG_HAS_SIGNATURE != 0
            val need = V1_HEADER + SENDER_ID_SIZE +
                (if (hasRecipient) RECIPIENT_ID_SIZE else 0) + payloadLength +
                (if (hasSignature) SIGNATURE_SIZE else 0)
            if (data.size < need) return null

            val senderId = data.copyOfRange(o, o + SENDER_ID_SIZE); o += SENDER_ID_SIZE
            var recipientId: ByteArray? = null
            if (hasRecipient) { recipientId = data.copyOfRange(o, o + RECIPIENT_ID_SIZE); o += RECIPIENT_ID_SIZE }
            val payload = data.copyOfRange(o, o + payloadLength); o += payloadLength
            var signature: ByteArray? = null
            if (hasSignature) signature = data.copyOfRange(o, o + SIGNATURE_SIZE)

            return BitchatPacket(type, ttl, ts, senderId, recipientId, payload, signature, version)
        }
    }
}
