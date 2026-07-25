package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class BleBridgeTest {
    @Test
    fun rxParserPreservesSubscriptionTokenAndBytesRegardlessOfFieldOrder() {
        val packets = BleBridge.parseRx(
            """[{"token":42,"data":"00a1ff"},{"data":"10","token":99}]""",
        )

        assertEquals(listOf(42L, 99L), packets.map { it.subscriptionToken })
        assertContentEquals(byteArrayOf(0x00, 0xA1.toByte(), 0xFF.toByte()), packets[0].bytes)
        assertContentEquals(byteArrayOf(0x10), packets[1].bytes)
    }

    @Test
    fun rxParserDropsMalformedOrUnattributedPackets() {
        val packets = BleBridge.parseRx(
            """[{"data":"01"},{"token":7,"data":"not-hex"},{"token":8,"data":"abc"}]""",
        )

        assertEquals(emptyList(), packets)
    }

    @Test
    fun txResultParserPreservesDeliveryOutcomeRegardlessOfFieldOrder() {
        val results = BleBridge.parseTxResults(
            """[{"id":41,"accepted":true},{"accepted":false,"id":42}]""",
        )

        assertEquals(
            listOf(BleBridge.TxResult(41, accepted = true), BleBridge.TxResult(42, accepted = false)),
            results,
        )
    }

    @Test
    fun txResultParserDropsMalformedOrUntrackedResults() {
        val results = BleBridge.parseTxResults(
            """[{"id":0,"accepted":true},{"id":5},{"accepted":false}]""",
        )

        assertEquals(emptyList(), results)
    }
}
