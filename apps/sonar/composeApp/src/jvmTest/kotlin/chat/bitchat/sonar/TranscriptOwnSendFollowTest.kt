package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * QA-150: a send from a chat opened at the unread divider must bring the
 * reader to the live edge once the echo is the newest row — and not touch
 * the list while the newest row is still the one from before the tap.
 */
class TranscriptOwnSendFollowTest {

    @Test
    fun noSendNoFollow() {
        assertFalse(transcriptOwnSendShouldFollow(tick = 0, tailKeyAtSend = null, newestKey = "m:peer-300"))
    }

    @Test
    fun followsOnceTheEchoIsTheNewestRow() {
        // Tap: newest row is still the last unread agent reply.
        assertFalse(transcriptOwnSendShouldFollow(tick = 1, tailKeyAtSend = "m:peer-300", newestKey = "m:peer-300"))
        // The echo landed (or the window reset to its newest page).
        assertTrue(transcriptOwnSendShouldFollow(tick = 1, tailKeyAtSend = "m:peer-300", newestKey = "m:echo-1"))
    }

    @Test
    fun emptyFeedNeverFollows() {
        assertFalse(transcriptOwnSendShouldFollow(tick = 1, tailKeyAtSend = null, newestKey = null))
    }
}
