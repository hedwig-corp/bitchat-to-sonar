package chat.bitchat.sonar

import java.time.Instant
import java.util.TimeZone
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class PrivateTimezoneTest {
    @Test
    fun peerOffsetUsesRulesAtTheDisplayedInstant() {
        val previous = TimeZone.getDefault()
        try {
            TimeZone.setDefault(TimeZone.getTimeZone("America/New_York"))

            val winter = peerLocalTimeSnapshot(
                "America/Phoenix",
                Instant.parse("2026-01-15T12:00:00Z").toEpochMilli(),
            )
            val summer = peerLocalTimeSnapshot(
                "America/Phoenix",
                Instant.parse("2026-07-15T12:00:00Z").toEpochMilli(),
            )

            assertEquals(-120, assertNotNull(winter).relativeOffsetMinutes)
            assertEquals(-180, assertNotNull(summer).relativeOffsetMinutes)
        } finally {
            TimeZone.setDefault(previous)
        }
    }

    @Test
    fun invalidTimezoneDoesNotRender() {
        assertNull(peerLocalTimeSnapshot("Mars/Olympus_Mons", 0))
    }

    @Test
    fun offsetPartsIncludeFractionalHours() {
        assertEquals(5 to 30, timezoneOffsetParts(330))
        assertEquals(0 to 45, timezoneOffsetParts(45))
    }

    @Test
    fun relativeCopyMatchesDesignZoneDelta() {
        assertEquals("1 hour", timezoneOffsetAmountText(60))
        assertEquals("2 hours", timezoneOffsetAmountText(120))
        assertEquals("5h 30m", timezoneOffsetAmountText(330))
        assertEquals("0h 45m", timezoneOffsetAmountText(45))
    }

    @Test
    fun offNoteSaysWhetherTheChatOverridesTheDefault() {
        // U1 (#607 QA): with the Settings default off and no per-chat override
        // the note claimed "overrides your Settings default".
        val following = shareLocalTimeNote(sharing = false, overridden = false, zone = "Europe/Zurich", peerName = "Ana")
        val overridden = shareLocalTimeNote(sharing = false, overridden = true, zone = "Europe/Zurich", peerName = "Ana")
        val sharing = shareLocalTimeNote(sharing = true, overridden = false, zone = "Europe/Zurich", peerName = "Ana")
        assertTrue(following.startsWith("Off — follows your Settings default."))
        assertFalse("overrides" in following)
        assertTrue(overridden.startsWith("Off for this chat — overrides your Settings default."))
        assertTrue(sharing.startsWith("Sharing Europe/Zurich with Ana inside this chat’s encryption."))
    }

    @Test
    fun onlyGroupsThatStoppedSharingAreRevoked() {
        assertEquals(listOf("b"), revokedTimezoneGroups(listOf("a", "b", "b"), listOf("a", "c")))
        assertEquals(emptyList(), revokedTimezoneGroups(emptyList(), listOf("a")))
        assertEquals(listOf("a"), revokedTimezoneGroups(listOf("a"), emptyList()))
    }

    @Test
    fun peerZonesStayPerGroup() {
        // Ana shares in the DM but revoked in the group: the group must not
        // show the DM's zone, and lookups never fall back across chats.
        val index = indexPeerTimezonesByGroup(
            listOf(
                SonarPeerTimezone("npub1ana", "AABB", "Asia/Tokyo", 10),
                SonarPeerTimezone("npub1bo", "ccdd", "Europe/Rome", 11),
            ),
            canonical = { it.removePrefix("npub1") },
        )
        assertEquals("Asia/Tokyo", index["aabb"]?.get("ana")?.ianaIdentifier)
        assertNull(index["ccdd"]?.get("ana"))
        assertEquals("Europe/Rome", index["ccdd"]?.get("bo")?.ianaIdentifier)
    }

    @Test
    fun perChatOverrideBlobRoundtrips() {
        val encoded = encodeTimezoneShareMap(mapOf("abc" to true, "def" to false))
        assertEquals(mapOf("abc" to true, "def" to false), decodeTimezoneShareMap(encoded))
        assertEquals(emptyMap(), decodeTimezoneShareMap(""))
        assertEquals(emptyMap(), decodeTimezoneShareMap("bad-line"))
    }

    @Test
    fun allowlistKeepsMlsHexAndStripsMarmotPrefix() {
        val hex = "aabbccddeeff00112233445566778899"
        assertEquals(hex, normalizeMlsGroupIdHex(hex.uppercase()))
        assertEquals(hex, normalizeMlsGroupIdHex("marmot:$hex"))
        assertEquals("", normalizeMlsGroupIdHex("mesh:peer"))
    }

    @Test
    fun allowlistResolvesMeshChatsToMlsGroupsAndDropsDisabled() {
        val hex = "aabbccddeeff00112233445566778899"
        val ids = mlsTimezoneShareGroupIds(
            chatIds = listOf("mesh:peer", "marmot:$hex", "other"),
            sharesLocalTime = { it != "other" },
            resolveGroupIds = { chatId ->
                if (chatId.startsWith("mesh:")) listOf(hex) else emptyList()
            },
        )
        assertEquals(listOf(hex), ids)
    }
}
