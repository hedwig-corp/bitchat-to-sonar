package chat.bitchat.sonar

import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Ways the hardening could destroy the key it protects.
 *
 * Both scenarios here are reachable only because secrets moved into the OS
 * keystore: while they lived in prefs the file was always readable and a stale
 * copy could not win.
 */
class DesktopSecretLossTest {

    @BeforeTest
    fun isolate() {
        DesktopSecrets.useTestService("chat.bitchat.sonar.losstest")
        DesktopEnv.useTestRoot(Files.createTempDirectory("sonar-loss").toFile())
    }

    @AfterTest
    fun restore() {
        runCatching { DesktopSecrets.clear(*DesktopSecrets.MANAGED_KEYS.toTypedArray()) }
        DesktopSecrets.resetService()
        DesktopEnv.useTestRoot(null)
    }

    /**
     * A newer prefs copy must beat a stale keystore copy.
     *
     * `put` leaves the previous keystore entry in place when it falls back, so
     * after a keyring outage between two writes the keystore holds the OLD value
     * and prefs holds the NEW one. Deleting the prefs copy on a keystore hit
     * (which is what this did) let the stale value win and destroyed the current
     * key permanently.
     */
    @Test
    fun aNewerPlaintextCopyIsNotDestroyedByAStaleKeystoreCopy() {
        val key = "nsec"
        val older = "nsec1-OLD-value-stranded-in-the-keystore"
        val newer = "nsec1-NEW-value-written-while-the-keyring-was-down"

        // Keystore holds the older value (a successful earlier write).
        DesktopSecrets.put(key, older)
        // Then a keyring outage: put() falls back, so prefs holds the newer one
        // while the keystore entry is left stale. Reproduced directly.
        DesktopEnv.putString(key, newer)

        val got = DesktopSecrets.get(key)

        assertEquals(newer, got, "the newer value must win, not the stale keystore copy")
        assertTrue(
            DesktopSecrets.get(key) == newer,
            "and it must still be readable afterwards, not deleted",
        )
    }

    /**
     * Identical copies are still cleaned up, so the warning banner can clear.
     */
    @Test
    fun anIdenticalPlaintextDuplicateIsStillRemoved() {
        val key = "dbKeyHex"
        val value = "a".repeat(64)
        DesktopSecrets.put(key, value)
        DesktopEnv.putString(key, value)

        assertEquals(value, DesktopSecrets.get(key))
        assertEquals(
            emptyList(),
            DesktopSecrets.storedInPlaintext(),
            "a duplicate that matches the keystore should be dropped",
        )
    }

    /**
     * With a working keystore, absence is trustworthy, so first-run generation
     * is still allowed. (The inverse — refusing to generate on a keystore fault
     * — is enforced at the call sites in SonarCore and MeshIdentity.)
     */
    @Test
    fun absenceIsTrustworthyWhenTheKeystoreWorks() {
        assertTrue(
            DesktopSecrets.absenceIsTrustworthy(),
            "a healthy keystore must allow first-run key generation",
        )
    }
}
