package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MeshLinkPolicyTest {
    @Test
    fun preAnnounceSonarQueueIsBoundedLatestAndDetached() {
        val queue = PendingSonarPacketQueue(limit = 2)
        val first = byteArrayOf(1)
        queue.offer("peer-a", first)
        first[0] = 9
        queue.offer("peer-b", byteArrayOf(2))
        queue.offer("peer-b", byteArrayOf(3))
        queue.offer("peer-c", byteArrayOf(4))

        assertEquals(2, queue.size())
        assertNull(queue.remove("peer-a"))
        assertContentEquals(byteArrayOf(3), queue.remove("peer-b"))
        assertContentEquals(byteArrayOf(4), queue.remove("peer-c"))
    }
}
