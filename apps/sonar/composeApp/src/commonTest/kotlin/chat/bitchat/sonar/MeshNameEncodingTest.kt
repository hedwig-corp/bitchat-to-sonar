package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Guards the mesh-name blob invariants that were found broken live on-device:
 *  a peer's arbitrary nickname must round-trip losslessly AND must never be
 *  able to inject a second line into the blob (poisoning another peer's name),
 *  and a key-shaped fallback must never be persisted as a real name. */
class MeshNameEncodingTest {

    @Test
    fun hexRoundTripsEmojiAndUnicode() {
        for (name in listOf("Vincenzo 🦍", "Vincenzo 🪄", "Sara D", "  GM  ", "日本語")) {
            assertEquals(name, hexDecodeUtf8(hexEncodeUtf8(name)), "round-trip: $name")
        }
    }

    @Test
    fun newlineInNameCannotInjectAnExtraBlobLine() {
        // A malicious peer nickname containing a newline + a fake "id=name".
        val evil = "Bob\ndeadbeefdeadbeef=Attacker"
        val encoded = hexEncodeUtf8(evil)
        assertFalse(encoded.contains('\n'), "hex encoding must not contain a newline")
        assertFalse(encoded.contains('='), "hex encoding must not contain a delimiter")
        assertEquals(evil, hexDecodeUtf8(encoded))
    }

    @Test
    fun decodeToleratesNonHexLegacyPlainText() {
        // Pre-hex builds stored raw names; decode returns null so the loader
        // falls back to the raw value.
        assertNull(hexDecodeUtf8("Vincenzo"))     // odd length / non-hex
        assertNull(hexDecodeUtf8("zz"))            // even length, not hex digits
    }

    @Test
    fun keyShapedNamesAreFlaggedAsFallbacks() {
        assertTrue(isKeyFallbackNameValue("npub1abcdef"))
        assertTrue(isKeyFallbackNameValue("mesh·6608f8"))
        assertFalse(isKeyFallbackNameValue("Vincenzo 🦍"))
        assertFalse(isKeyFallbackNameValue("Sara D"))
    }
}
