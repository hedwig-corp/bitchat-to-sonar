package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SonarDiscoveryTest {
    private val npub = ByteArray(32) { it.toByte() }

    @Test fun roundTripWithBip353() {
        val a = SonarAnnounce(1, npub, "vince@sonar.app", SonarAnnounce.CAP_MARMOT or SonarAnnounce.CAP_PAY)
        val decoded = SonarAnnounce.decode(a.encode())!!
        assertEquals(a, decoded)
        assertTrue(decoded.speaksMarmot)
        assertTrue(decoded.speaksPay)
    }

    @Test fun roundTripWithoutBip353() {
        val a = SonarAnnounce(1, npub, null, SonarAnnounce.CAP_MARMOT)
        val decoded = SonarAnnounce.decode(a.encode())!!
        assertEquals(a, decoded)
        assertNull(decoded.bip353)
        assertTrue(decoded.speaksMarmot)
        assertTrue(!decoded.speaksPay)
    }

    @Test fun decodeRejectsMissingNpub() {
        // Only a version TLV, no 0x02 → invalid.
        assertNull(SonarAnnounce.decode(byteArrayOf(0x01, 0x01, 0x01)))
    }

    @Test fun decodeRejectsTruncatedTlv() {
        // type 0x02 claims length 32 but no bytes follow.
        assertNull(SonarAnnounce.decode(byteArrayOf(0x02, 32)))
    }

    @Test fun ignoresUnknownTlvTypes() {
        val a = SonarAnnounce(1, npub, null, SonarAnnounce.CAP_PAY)
        // Append an unknown TLV (type 0x09) — must still decode.
        val withUnknown = a.encode() + byteArrayOf(0x09, 0x02, 0x41, 0x42)
        assertEquals(a, SonarAnnounce.decode(withUnknown))
    }
}
