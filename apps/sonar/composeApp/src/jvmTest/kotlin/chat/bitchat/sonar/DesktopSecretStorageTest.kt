package chat.bitchat.sonar

import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The desktop app stores the account nsec, the SQLCipher DB key and the mesh
 * signing keys. When no OS keystore is available (a default Linux install has no
 * `secret-tool`) they fall back to a local prefs file, which must not then be
 * readable by other users on the machine.
 *
 * Regression: the shipped .deb wrote `mesh.noise.priv` and `mesh.ed25519.seed`
 * into `prefs.properties` at mode 664.
 */
class DesktopSecretStorageTest {

    /**
     * The keystore namespace is GLOBAL and unaffected by the data-dir override,
     * so without this a test calling `DesktopSecrets.clear` would irreversibly
     * delete the developer's real nsec from their login keyring.
     */
    @BeforeTest
    fun isolate() {
        DesktopSecrets.useTestService("chat.bitchat.sonar.test")
    }

    @AfterTest
    fun restore() {
        DesktopSecrets.resetService()
        DesktopEnv.useTestRoot(null)
    }

    @Test
    fun secretsFileIsNotReadableByOtherUsers() {
        val dir = Files.createTempDirectory("sonar-perm-test").toFile()
        val f = File(dir, "prefs.properties")
        f.writeText("nsec=secret")
        // Simulate the umask default the bug shipped with.
        f.setReadable(true, false)

        DesktopEnv.restrictToOwner(f)

        assertFalse(
            isOtherReadable(f),
            "a file holding the account key must not be world-readable",
        )
        assertTrue(f.canRead(), "the owner must still be able to read it")
        dir.deleteRecursively()
    }

    @Test
    fun dataDirectoryIsNotTraversableByOtherUsers() {
        val dir = Files.createTempDirectory("sonar-perm-dir").toFile()
        dir.setReadable(true, false)
        dir.setExecutable(true, false)

        DesktopEnv.restrictToOwner(dir, ownerExecutable = true)

        assertFalse(isOtherReadable(dir), "the data directory must not be world-readable")
        assertTrue(dir.canRead() && dir.canExecute(), "the owner must retain access")
        dir.deleteRecursively()
    }

    /** True when the POSIX "others" class can read [f]. */
    private fun isOtherReadable(f: File): Boolean {
        val perms = Files.getPosixFilePermissions(f.toPath())
        return perms.contains(java.nio.file.attribute.PosixFilePermission.OTHERS_READ)
    }

    /**
     * Every secret DesktopSecrets owns must be reachable by the wipe path.
     *
     * Regression: moving the mesh keys from prefs into the keystore took them
     * out of reach of `DesktopEnv.clear()`, so an account wipe left the Ed25519
     * announce seed behind. The NEXT account then advertised its new npub in a
     * 0x53 discovery packet signed by the OLD key, linking the two accounts for
     * any passive BLE listener. The wipe call site is driven off MANAGED_KEYS,
     * so this asserts the list actually covers the mesh keys.
     */
    @Test
    fun managedKeysCoversEverySecretTheAppStores() {
        val managed = DesktopSecrets.MANAGED_KEYS
        for (k in listOf("nsec", "dbKeyHex", "mesh.noise.priv", "mesh.ed25519.seed")) {
            assertTrue(
                managed.contains(k),
                "$k is stored by the app but missing from MANAGED_KEYS, so a wipe would leave it behind",
            )
        }
    }

    /**
     * A wipe must clear the plaintext copies too, not only the keystore ones.
     * Uses an isolated root so it cannot touch the developer's real store.
     */
    @Test
    fun clearingManagedKeysRemovesThePlaintextCopies() {
        val dir = Files.createTempDirectory("sonar-wipe-test").toFile()
        DesktopEnv.useTestRoot(dir)
        try {
            for (k in DesktopSecrets.MANAGED_KEYS) DesktopEnv.putString(k, "value-for-$k")
            assertEquals(
                DesktopSecrets.MANAGED_KEYS.size,
                DesktopSecrets.storedInPlaintext().size,
                "precondition: all managed keys present in plaintext",
            )

            DesktopSecrets.clear(*DesktopSecrets.MANAGED_KEYS.toTypedArray())

            assertEquals(
                emptyList(),
                DesktopSecrets.storedInPlaintext(),
                "a wipe must leave no managed secret behind",
            )
        } finally {
            DesktopEnv.useTestRoot(null)
            dir.deleteRecursively()
        }
    }

    /**
     * Secrets on disk must always produce a reason to show, even when the
     * keystore itself looks healthy: a failed prefs removal after a successful
     * keystore write leaves plaintext behind with no keystore fault to report,
     * and returning null there hides an unprotected account key.
     */
    @Test
    fun plaintextSecretsAlwaysProduceAWarning() {
        val dir = Files.createTempDirectory("sonar-warn-test").toFile()
        DesktopEnv.useTestRoot(dir)
        try {
            DesktopEnv.putString("nsec", "nsec1exampleplaintextvalue")
            assertTrue(
                DesktopSecrets.plaintextFallbackInUse(),
                "precondition: a secret is sitting in plaintext",
            )
            assertNotNull(
                SecretStorageStatus.degradedReason(),
                "a plaintext account key must always yield a warning, even with a healthy keystore",
            )
        } finally {
            DesktopEnv.useTestRoot(null)
            dir.deleteRecursively()
        }
    }

    /** The prefs file must be owner-only the moment it is written. */
    @Test
    fun writingAPrefLeavesTheFileOwnerOnly() {
        val dir = Files.createTempDirectory("sonar-perm-write").toFile()
        DesktopEnv.useTestRoot(dir)
        try {
            DesktopEnv.putString("nsec", "nsec1example")
            val f = File(dir, "prefs.properties")
            assertTrue(f.exists(), "prefs should have been written")
            assertFalse(isOtherReadable(f), "a freshly written prefs file must not be world-readable")
        } finally {
            DesktopEnv.useTestRoot(null)
            dir.deleteRecursively()
        }
    }
}
