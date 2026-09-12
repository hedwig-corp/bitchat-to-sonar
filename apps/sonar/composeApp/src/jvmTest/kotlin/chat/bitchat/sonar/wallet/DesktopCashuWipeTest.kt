package chat.bitchat.sonar.wallet

import chat.bitchat.sonar.DesktopEnv
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * Pins the desktop Cashu wipe root against a redirected DesktopEnv, the same
 * way iOS `testWalletStorageWipeRemovesSharedAndLegacyState` drives
 * `wipeWalletFilesAndDefaults` on injected paths.
 *
 * A wipe that only deleted `sonar-wallet` would leave `cashu.redb` and the
 * migration journal for the next nsec to resume.
 */
class DesktopCashuWipeTest {

    @BeforeTest
    fun isolate() {
        DesktopEnv.useTestRoot(Files.createTempDirectory("sonar-cashu-wipe").toFile())
    }

    @AfterTest
    fun restore() {
        DesktopEnv.useTestRoot(null)
    }

    @Test
    fun wipeRemovesProofStoreJournalAndRestoreMarker() = runBlocking {
        val accountDir = DesktopEnv.file("sonar-cashu/deadbeef/mainnet").apply { mkdirs() }
        File(accountDir, "cashu.redb").writeText("proofs")
        File(accountDir, "cashu.migration.v1.json").writeText("{}")
        File(accountDir, "cashu.migration.v1.json.tmp").writeText("{}")
        File(accountDir, "cashu.migration.v1.lock").writeText("")
        File(accountDir, "cashu.restored.mint").writeText("1")
        val unrelated = DesktopEnv.file("unrelated.txt").apply { writeText("keep") }
        val root = DesktopEnv.file("sonar-cashu")
        assertTrue(root.exists())

        wipeCashuMigrationStorage()

        assertFalse(root.exists(), "desktop wipe must remove the Cashu store root")
        assertTrue(unrelated.exists(), "wipe must not delete unrelated DesktopEnv files")
    }
}
