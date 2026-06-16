package chat.bitchat.sonar

import uniffi.sonar_ffi.SonarIdentity
import uniffi.sonar_ffi.SonarNoise
import uniffi.sonar_ffi.noiseGenerateKeypair
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Proves the Rust core (sonar-ffi) loads and runs through the UniFFI/JNA bindings
 * on the desktop JVM — the same end-to-end FFI path the app uses, exercised
 * without any network (no relays). Mirrors the Android `meshNoiseSmokeTest`.
 *
 * If the bundled libsonar_ffi.<ext> is missing or the bindings mismatch, these
 * fail fast — the single most important regression guard for the desktop target.
 */
class DesktopFfiSmokeTest {

    @Test
    fun nativeLibraryLoads() {
        SonarNativeLoader.ensureLoaded()
        // A Nostr identity round-trips entirely in the Rust core (no network).
        val id = SonarIdentity.generate()
        assertTrue(id.npub().startsWith("npub1"), "expected a bech32 npub, got ${id.npub()}")
        val reimported = SonarIdentity.import(id.nsec())
        assertEquals(id.pubkeyHex(), reimported.pubkeyHex(), "nsec round-trip mismatch")
    }

    @Test
    fun noiseHandshakeOverFfi() {
        SonarNativeLoader.ensureLoaded()
        val a = noiseGenerateKeypair()
        val b = noiseGenerateKeypair()
        val ini = SonarNoise.initiator(a.privateHex)
        val res = SonarNoise.responder(b.privateHex)
        res.readMessage(ini.writeMessage())   // m1
        ini.readMessage(res.writeMessage())    // m2
        res.readMessage(ini.writeMessage())    // m3
        assertEquals(b.publicHex, ini.remoteStaticHex())
        assertEquals(a.publicHex, res.remoteStaticHex())
        ini.intoSession(); res.intoSession()
        val ct = ini.encrypt("mesh hello".encodeToByteArray())
        assertEquals("mesh hello", res.decrypt(ct).decodeToString())
    }
}
