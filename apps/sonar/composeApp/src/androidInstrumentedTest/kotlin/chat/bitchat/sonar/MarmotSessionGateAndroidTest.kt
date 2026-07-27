package chat.bitchat.sonar

import androidx.test.ext.junit.runners.AndroidJUnit4
import chat.bitchat.sonar.backup.MarmotSessionGate
import chat.bitchat.sonar.backup.withMarmotSessionClaim
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The auto-backup seal closes the Marmot node, so every path that owns the node
 * must hold the gate. A push-woken process has no UI session: without a headless
 * claim the OS worker would close the node in the middle of a push drain.
 */
@RunWith(AndroidJUnit4::class)
class MarmotSessionGateAndroidTest {

    @Before
    fun resetGate() {
        MarmotSessionGate.setLiveUiSession(false)
        repeat(8) { MarmotSessionGate.releaseHeadlessSession() }
    }

    @After
    fun clearGate() = resetGate()

    @Test
    fun headlessWakeBlocksBackgroundSeal() = runBlocking {
        assertFalse(MarmotSessionGate.isLiveUiSession())
        withMarmotSessionClaim {
            assertTrue(
                "a headless wake owning the node must block the seal",
                MarmotSessionGate.isLiveUiSession(),
            )
        }
        assertFalse("claim must be released", MarmotSessionGate.isLiveUiSession())
    }

    @Test
    fun claimIsReleasedWhenTheWakeThrows() = runBlocking {
        runCatching {
            withMarmotSessionClaim { throw IllegalStateException("drain failed") }
        }
        assertFalse(
            "a failed wake must not leave the gate raised forever",
            MarmotSessionGate.isLiveUiSession(),
        )
    }

    @Test
    fun overlappingWakesEachHoldTheGate() {
        MarmotSessionGate.acquireHeadlessSession()
        MarmotSessionGate.acquireHeadlessSession()
        MarmotSessionGate.releaseHeadlessSession()
        assertTrue(
            "releasing one wake must not clear the other wake's hold",
            MarmotSessionGate.isLiveUiSession(),
        )
        MarmotSessionGate.releaseHeadlessSession()
        assertFalse(MarmotSessionGate.isLiveUiSession())
    }

    @Test
    fun headlessReleaseDoesNotClearTheUiHold() {
        MarmotSessionGate.setLiveUiSession(true)
        MarmotSessionGate.acquireHeadlessSession()
        MarmotSessionGate.releaseHeadlessSession()
        assertTrue(
            "a wake finishing must not hand the node to the seal while the UI owns it",
            MarmotSessionGate.isLiveUiSession(),
        )
    }
}
