package chat.bitchat.sonar

/**
 * Sonar Discovery announce (mesh packet type 0x53), ported 1:1 from the iOS
 * `SonarAnnouncePacket` TLV codec (`docs/SONAR-DISCOVERY.md`). Lets Sonar nodes
 * advertise their Nostr identity + payment address + capabilities over the
 * bitchat mesh while stock bitchat clients harmlessly relay/ignore the unknown
 * type.
 *
 * TLV fields:
 *   0x01 version   u8 (= 1)
 *   0x02 npub      32 raw bytes (Nostr x-only pubkey)
 *   0x03 bip353    UTF-8, ≤255 bytes (optional payment address)
 *   0x04 caps      u8 bitfield — bit0 marmot-dm, bit1 ⚡PAY payments
 *
 * The packet is Ed25519-signed with the same announce key as the bitchat
 * announce and verified against the peer's signingPublicKey; that signing +
 * the on-air broadcast/parse live with the mesh link (Phase 8). This file is
 * the wire format, unit-tested independently.
 */
data class SonarAnnounce(
    val version: Int,
    val npub: ByteArray,        // 32 raw bytes
    val bip353: String?,
    val capabilities: Int,      // u8 bitfield
) {
    val speaksMarmot: Boolean get() = capabilities and CAP_MARMOT != 0
    val speaksPay: Boolean get() = capabilities and CAP_PAY != 0

    fun encode(): ByteArray {
        val out = ArrayList<Byte>()
        fun tlv(type: Int, value: ByteArray) {
            out.add(type.toByte()); out.add(value.size.toByte()); value.forEach { out.add(it) }
        }
        tlv(0x01, byteArrayOf(version.toByte()))
        tlv(0x02, npub)
        bip353?.takeIf { it.isNotEmpty() }?.let { tlv(0x03, it.encodeToByteArray().take(255).toByteArray()) }
        tlv(0x04, byteArrayOf(capabilities.toByte()))
        return out.toByteArray()
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SonarAnnounce) return false
        return version == other.version && npub.contentEquals(other.npub) &&
            bip353 == other.bip353 && capabilities == other.capabilities
    }

    override fun hashCode(): Int =
        ((version * 31 + npub.contentHashCode()) * 31 + (bip353?.hashCode() ?: 0)) * 31 + capabilities

    companion object {
        const val PACKET_TYPE = 0x53
        const val CAP_MARMOT = 0x01
        const val CAP_PAY = 0x02

        /** Decode a TLV payload. Returns null if malformed or no npub present. */
        fun decode(data: ByteArray): SonarAnnounce? {
            var i = 0
            var version = 1
            var npub: ByteArray? = null
            var bip353: String? = null
            var caps = 0
            while (i + 2 <= data.size) {
                val type = data[i].toInt() and 0xFF
                val len = data[i + 1].toInt() and 0xFF
                val start = i + 2
                if (start + len > data.size) return null
                val value = data.copyOfRange(start, start + len)
                when (type) {
                    0x01 -> if (len >= 1) version = value[0].toInt() and 0xFF
                    0x02 -> if (len == 32) npub = value
                    0x03 -> bip353 = value.decodeToString()
                    0x04 -> if (len >= 1) caps = value[0].toInt() and 0xFF
                }
                i = start + len
            }
            val key = npub ?: return null
            return SonarAnnounce(version, key, bip353?.takeIf { it.isNotEmpty() }, caps)
        }
    }
}
