package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SonarReplyTest {
    @Test
    fun nipC7RequiresEventIdHexAndNpub() {
        val id = "a".repeat(64)
        assertTrue(sonarCanEmitNipC7(id, "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"))
        assertFalse(sonarCanEmitNipC7("optimistic-1", "npub1abc"))
        assertFalse(sonarCanEmitNipC7(id, null))
        assertFalse(sonarCanEmitNipC7(id, "hex-not-npub"))
        assertFalse(sonarCanEmitNipC7("zz".repeat(32), "npub1abc"))
    }

    @Test
    fun replyDisabledOnEchoAndSendingRows() {
        val live = SonarMsg("ab".repeat(32), "npub1peer", "hi", mine = false, tsSecs = 1)
        assertTrue(sonarCanReply(live))
        assertFalse(sonarCanReply(live.copy(id = "echo-1")))
        assertFalse(sonarCanReply(live.copy(id = "optimistic-1")))
        assertFalse(sonarCanReply(live.copy(state = "Sending")))
        assertFalse(sonarCanReply(live.copy(state = "Uploading")))
    }
}
