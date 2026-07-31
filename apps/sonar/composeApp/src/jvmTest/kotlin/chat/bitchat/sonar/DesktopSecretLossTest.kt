package chat.bitchat.sonar

import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
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
     * A duplicate that MATCHES the keystore is still cleaned up, so the warning
     * can clear.
     *
     * Only meaningful where a keystore actually exists. CI runners have neither
     * `secret-tool` nor a keyring, so `put` legitimately falls back and there is
     * no keystore copy to deduplicate against; asserting unconditionally made
     * this fail on CI while passing locally, which is the environment-coupled
     * shape these tests are supposed to avoid.
     */
    @Test
    fun anIdenticalPlaintextDuplicateIsStillRemoved() {
        if (!DesktopSecrets.absenceIsTrustworthy()) return // no keystore here
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
     * The safety-critical direction, asserted without depending on whether this
     * machine has a keystore: if absence is reported as trustworthy, a real
     * round trip must actually succeed. Claiming trustworthiness wrongly is what
     * lets a generate path overwrite a live account key.
     *
     * Where there is no keystore the function claims nothing, so there is
     * nothing to check and the generate paths refuse instead.
     */
    @Test
    fun trustworthyAbsenceImpliesTheKeystoreReallyWorks() {
        if (!DesktopSecrets.absenceIsTrustworthy()) return // claims nothing
        val probe = "nsec"
        val value = "nsec1round-trip-proof"
        DesktopSecrets.put(probe, value)
        assertEquals(value, DesktopSecrets.get(probe), "the keystore must round-trip")
        assertEquals(
            emptyList(),
            DesktopSecrets.storedInPlaintext(),
            "a keystore reported as trustworthy must not have fallen back to plaintext",
        )
    }

    /**
     * The mesh announce seed must not be re-minted when the keystore is merely
     * unreadable.
     *
     * This is the two-launch failure the guard exists for. Launch one, keyring
     * locked: `get` returns null, the seed is minted and (because the keystore
     * is down) written to prefs. Launch two, keyring healthy: keystore holds the
     * ORIGINAL seed, prefs holds the fabricated one, they differ, and the
     * "prefs is newer" reconciliation pushes the fabricated seed into the
     * keystore and drops the original. One locked-keyring launch permanently
     * rotates the announce-signing identity, and peers then reject the 0x53
     * discovery packet as unverified.
     *
     * The reconciliation rule itself is correct; what violated its precondition
     * was an unguarded mint writing a FABRICATED value into prefs.
     */
    @Test
    fun anUnreadableKeystoreDoesNotMintAMeshSeed() {
        val failure = assertFailsWith<IllegalStateException> {
            MeshIdentity.requireTrustworthyAbsence(
                existing = null,
                trustworthy = false,
                what = "mesh announce seed",
            )
        }
        assertTrue(
            failure.message?.contains("refusing to regenerate") == true,
            "the refusal must say why: ${failure.message}",
        )
    }

    /** A readable keystore that genuinely has no seed must still allow a first run. */
    @Test
    fun aTrustworthyAbsenceStillAllowsFirstRunMinting() {
        MeshIdentity.requireTrustworthyAbsence(null, trustworthy = true, what = "mesh announce seed")
    }

    /** An existing value is never blocked, whatever the keystore is doing. */
    @Test
    fun anExistingSeedIsNeverBlocked() {
        MeshIdentity.requireTrustworthyAbsence("abc", trustworthy = false, what = "mesh announce seed")
    }
}
