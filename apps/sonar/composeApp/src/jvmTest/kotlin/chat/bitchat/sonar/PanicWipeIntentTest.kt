package chat.bitchat.sonar

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PanicWipeIntentTest {
    @Test
    fun markerSurvivesReopenAndClearsIdempotently() {
        val root = Files.createTempDirectory("panic-wipe-test").toFile()
        val marker = root.resolve(".panic-wipe.intent")

        assertTrue(DurablePanicWipeIntent(marker).begin())
        assertTrue(DurablePanicWipeIntent(marker).isPending())
        assertTrue(DurablePanicWipeIntent(marker).begin())
        assertTrue(DurablePanicWipeIntent(marker).clear())
        assertFalse(DurablePanicWipeIntent(marker).isPending())
        assertTrue(DurablePanicWipeIntent(marker).clear())
        root.deleteRecursively()
    }

    @Test
    fun freshWipeCommitsMarkerBeforeRedaction() {
        val events = mutableListOf<String>()

        assertTrue(beginPanicWipeBeforeRedaction(
            alreadyPending = false,
            commitIntent = { events += "commit"; true },
            redact = { events += "redact" },
        ))

        assertEquals(listOf("commit", "redact"), events)
    }

    @Test
    fun failedMarkerCommitLeavesLiveStateUntouched() {
        val events = mutableListOf<String>()

        assertFalse(beginPanicWipeBeforeRedaction(
            alreadyPending = false,
            commitIntent = { events += "commit"; false },
            redact = { events += "redact" },
        ))

        assertEquals(listOf("commit"), events)
    }

    @Test
    fun pendingRecoveryCanRedactWithoutRecommittingMarker() {
        val events = mutableListOf<String>()

        assertTrue(beginPanicWipeBeforeRedaction(
            alreadyPending = true,
            commitIntent = { events += "commit"; false },
            redact = { events += "redact" },
        ))

        assertEquals(listOf("redact"), events)
    }
}
