package chat.bitchat.sonar.store

import chat.bitchat.sonar.SonarChannelMsg
import chat.bitchat.sonar.SonarMedia
import chat.bitchat.sonar.SonarMsg
import chat.bitchat.sonar.SonarStickerRef
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
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

    @Test fun meshEnvelopeRoundTripPreservesKeyAndMessages() {
        val peerKey = "7a60f087831cb56d0011223344556677" // stable fingerprint
        val msgs = listOf(
            SonarMsg("m1", "", "Ciao da BLE", mine = false, tsSecs = 10),
            SonarMsg("m2", "", "reply\twith\ntabs|and ⚡PAY|1|x|5", mine = true, tsSecs = 20),
        )
        val (key, decoded) = MessageCodec.decodeMeshEnvelope(
            MessageCodec.encodeMeshEnvelope(peerKey, msgs)
        )!!
        assertEquals(peerKey, key)
        assertEquals(msgs, decoded)
    }

    @Test fun meshEnvelopeWithNoMessagesKeepsKey() {
        val (key, decoded) = MessageCodec.decodeMeshEnvelope(
            MessageCodec.encodeMeshEnvelope("abcd", emptyList())
        )!!
        assertEquals("abcd", key)
        assertTrue(decoded.isEmpty())
    }

    @Test fun meshEnvelopeRejectsGarbage() {
        assertEquals(null, MessageCodec.decodeMeshEnvelope(""))
    }

    @Test fun dmRoundTripWithStickerRef() {
        val ref = SonarStickerRef("30030:abc123:pack", "wave", "deadbeef")
        val msgs = listOf(
            SonarMsg("a", "npub1xx", "", mine = true, tsSecs = 1, stickerRef = ref),
            SonarMsg("b", "npub1yy", "plain text", mine = false, tsSecs = 2),
        )
        val decoded = MessageCodec.decodeDm(MessageCodec.encodeDm(msgs))
        assertEquals(msgs.size, decoded.size)
        assertEquals(ref, decoded[0].stickerRef)
        assertNull(decoded[1].stickerRef)
        assertEquals("plain text", decoded[1].content)
    }

    @Test fun dmRoundTripWithMedia() {
        val media = SonarMedia("mesh-media:peer:message:photo.jpg", "image/jpeg", "photo.jpg", 640, 480, null)
        val msgs = listOf(
            SonarMsg("a", "npub1xx", "", mine = true, tsSecs = 1, media = listOf(media)),
            SonarMsg("b", "npub1yy", "plain text", mine = false, tsSecs = 2),
        )
        val decoded = MessageCodec.decodeDm(MessageCodec.encodeDm(msgs))
        assertEquals(msgs.size, decoded.size)
        assertEquals(media, decoded[0].media.single())
        assertEquals("plain text", decoded[1].content)
        assertTrue(decoded[1].media.isEmpty())
    }

    @Test fun dmRoundTripWithStickerAndMedia() {
        val ref = SonarStickerRef("30030:abc123:pack", "wave", "deadbeef")
        val media = SonarMedia("mesh-media:peer:message:voice.m4a", "audio/mp4", "voice.m4a", null, null, 1200)
        val msg = SonarMsg("a", "npub1xx", "", mine = false, tsSecs = 3, media = listOf(media), stickerRef = ref)
        val decoded = MessageCodec.decodeDm(MessageCodec.encodeDm(listOf(msg))).single()
        assertEquals(ref, decoded.stickerRef)
        assertEquals(media, decoded.media.single())
    }

    @Test fun dmBackwardCompatOldFormatNoSticker() {
        val old = listOf(
            SonarMsg("a", "npub1xx", "hello", mine = true, tsSecs = 1),
        )
        val encoded = old.joinToString("\n") { m ->
            listOf(m.id, m.senderNpub, if (m.mine) "1" else "0", m.tsSecs.toString(), m.content)
                .joinToString("\t") { s -> s.encodeToByteArray().joinToString("") { ((it.toInt() and 0xFF) + 0x100).toString(16).substring(1) } }
        }
        val decoded = MessageCodec.decodeDm(encoded)
        assertEquals(1, decoded.size)
        assertEquals("hello", decoded[0].content)
        assertNull(decoded[0].stickerRef)
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
