package chat.bitchat.sonar.store

import chat.bitchat.sonar.SonarChannelMsg
import chat.bitchat.sonar.SonarMsg
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MessageCodecTest {
    @Test fun channelRoundTripWithNastyContent() {
        val msgs = listOf(
            SonarChannelMsg("id1", "alice", "pk1", "hello", mine = false, tsSecs = 100),
            // content with tab, newline and pipe must survive the framing.
            SonarChannelMsg("id2", "bob#1234", "pk2", "line1\nline2\twith|pipe ⚡PAY|1|x|9", mine = true, tsSecs = 200),
            SonarChannelMsg("id3", "anon", "pk3", "", mine = false, tsSecs = 300),
        )
        val decoded = MessageCodec.decodeChannel(MessageCodec.encodeChannel(msgs))
        assertEquals(msgs, decoded)
    }

    @Test fun dmRoundTrip() {
        val msgs = listOf(
            SonarMsg("a", "npub1xx", "hi 👋", mine = true, tsSecs = 1),
            SonarMsg("b", "npub1yy", "multi\nline\tmsg", mine = false, tsSecs = 2),
        )
        assertEquals(msgs, MessageCodec.decodeDm(MessageCodec.encodeDm(msgs)))
    }

    @Test fun emptyBlobDecodesEmpty() {
        assertTrue(MessageCodec.decodeChannel("").isEmpty())
        assertTrue(MessageCodec.decodeDm("").isEmpty())
    }
}

class MessageMergeTest {
    @Test fun dedupesByIdNewestWinsSortedCapped() {
        val stored = listOf(
            SonarChannelMsg("a", "x", "p", "old-a", false, 10),
            SonarChannelMsg("b", "x", "p", "b", false, 20),
        )
        val fresh = listOf(
            SonarChannelMsg("a", "x", "p", "new-a", false, 10), // same id → fresh wins
            SonarChannelMsg("c", "x", "p", "c", false, 5),       // older ts sorts first
        )
        val merged = MessageMerge.channels(stored, fresh)
        assertEquals(listOf("c", "a", "b"), merged.map { it.id })
        assertEquals("new-a", merged.first { it.id == "a" }.content)
    }

    @Test fun capLimitsToMostRecent() {
        val many = (1..600).map { SonarChannelMsg("id$it", "x", "p", "m$it", false, it.toLong()) }
        val merged = MessageMerge.channels(emptyList(), many)
        assertEquals(MESSAGE_STORE_CAP, merged.size)
        assertEquals("id600", merged.last().id) // newest kept
        assertEquals("id101", merged.first().id) // oldest 100 dropped
    }
}
