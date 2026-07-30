package chat.bitchat.sonar

import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * End-to-end guard on the real wipe entry point, not on the key list it happens
 * to use.
 *
 * `managedKeysCoversEverySecretTheAppStores` asserts the list is complete, but a
 * wipe that stopped calling it (or called it with a hand-written subset, which is
 * exactly what shipped) would still pass that. This drives `SonarCore.wipe()`
 * itself and asserts every secret is gone from BOTH stores afterwards.
 *
 * Regression: the mesh keys used to live in plain prefs, so `DesktopEnv.clear()`
 * removed them incidentally. Moving them into the keystore put them out of that
 * reach, and a surviving Ed25519 seed would sign the NEXT account's 0x53 Sonar
 * Discovery packet with the OLD key, letting a passive BLE listener link the two
 * accounts across a "delete everything and start over".
 */
class DesktopWipeClearsSecretsTest {

    /** Never the real namespace: `clear` would delete the developer's own nsec. */
    @BeforeTest
    fun isolate() {
        DesktopSecrets.useTestService("chat.bitchat.sonar.wipetest")
        DesktopEnv.useTestRoot(Files.createTempDirectory("sonar-wipe-e2e").toFile())
    }

    @AfterTest
    fun restore() {
        runCatching { DesktopSecrets.clear(*DesktopSecrets.MANAGED_KEYS.toTypedArray()) }
        DesktopSecrets.resetService()
        DesktopEnv.useTestRoot(null)
    }

    @Test
    fun wipeRemovesEverySecretFromBothStores() = runBlocking {
        SonarNativeLoader.ensureLoaded()

        // Populate through the real API so both backends are exercised: whatever
        // reaches the keystore lands there, the rest falls back to prefs.
        for (k in DesktopSecrets.MANAGED_KEYS) DesktopSecrets.put(k, "value-for-$k")
        for (k in DesktopSecrets.MANAGED_KEYS) {
            assertTrue(
                DesktopSecrets.get(k) != null,
                "precondition: $k must be readable before the wipe",
            )
        }

        SonarCore.wipe()

        val survivors = DesktopSecrets.MANAGED_KEYS.filter { DesktopSecrets.get(it) != null }
        assertEquals(
            emptyList(),
            survivors,
            "a wipe must leave no secret behind; these survived and would link the " +
                "next account to the old one",
        )
        assertEquals(
            emptyList(),
            DesktopSecrets.storedInPlaintext(),
            "nor any plaintext copy",
        )
    }
}
