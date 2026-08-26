package chat.bitchat.sonar

import java.time.Instant
import java.util.TimeZone
import kotlin.test.Test
import kotlin.test.assertEquals
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
    fun perChatOverrideBlobRoundtrips() {
        val encoded = encodeTimezoneShareMap(mapOf("abc" to true, "def" to false))
        assertEquals(mapOf("abc" to true, "def" to false), decodeTimezoneShareMap(encoded))
        assertEquals(emptyMap(), decodeTimezoneShareMap(""))
        assertEquals(emptyMap(), decodeTimezoneShareMap("bad-line"))
    }
}
