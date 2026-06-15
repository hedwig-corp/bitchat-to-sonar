package chat.bitchat.sonar.mesh

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BitchatPacketTest {

    @Test
    fun roundTripBroadcastNoSig() {
        val p = BitchatPacket(
            type = 1, ttl = 7, timestampMs = 0x0102030405060708L,
            senderId = ByteArray(8) { it.toByte() }, recipientId = null,
            payload = "hi".encodeToByteArray(), signature = null,
        )
        val bytes = p.encode()
        assertEquals(24, bytes.size, "14 header + 8 sender + 2 payload")
        assertEquals(1, bytes[0].toInt())   // version
        assertEquals(1, bytes[1].toInt())   // type
        assertEquals(7, bytes[2].toInt())   // ttl
        assertEquals(0, bytes[11].toInt())  // flags (none)
        // timestamp big-endian
        assertEquals(0x01, bytes[3].toInt() and 0xFF)
        assertEquals(0x08, bytes[10].toInt() and 0xFF)

        val d = assertNotNull(BitchatPacket.decode(bytes))
        assertEquals(p.type, d.type)
        assertEquals(p.ttl, d.ttl)
        assertEquals(p.timestampMs, d.timestampMs)
        assertTrue(p.senderId.contentEquals(d.senderId))
        assertNull(d.recipientId)
        assertNull(d.signature)
        assertTrue(p.payload.contentEquals(d.payload))
    }

    @Test
    fun roundTripWithRecipientAndSignature() {
        val p = BitchatPacket(
            type = 0x20, ttl = 3, timestampMs = 12345L,
            senderId = ByteArray(8) { 0x11 }, recipientId = BitchatPacket.BROADCAST,
            payload = ByteArray(100) { it.toByte() }, signature = ByteArray(64) { 0x22 },
        )
        val bytes = p.encode()
        assertEquals(0x03, bytes[11].toInt())  // hasRecipient | hasSignature
        val d = assertNotNull(BitchatPacket.decode(bytes))
        assertTrue(d.recipientId!!.contentEquals(BitchatPacket.BROADCAST))
        assertTrue(d.signature!!.contentEquals(p.signature!!))
        assertTrue(d.payload.contentEquals(p.payload))
    }

    @Test
    fun decodeRejectsTooShort() {
        assertNull(BitchatPacket.decode(ByteArray(5)))
    }

    @Test
    fun decodeIgnoresRadioPadding() {
        val p = BitchatPacket(1, 1, 1L, ByteArray(8), null, "x".encodeToByteArray(), null)
        val padded = p.encode() + ByteArray(200)  // PKCS#7-style radio padding
        val d = assertNotNull(BitchatPacket.decode(padded))
        assertTrue(d.payload.contentEquals("x".encodeToByteArray()))
    }
}
