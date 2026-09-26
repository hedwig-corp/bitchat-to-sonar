package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Android scan results arrive on the main looper, and a full pass over one
 * crosses into the Rust mesh engine. With other Sonar devices advertising
 * nearby (every emulator on a Mac shares one virtual radio) a pass per
 * advertisement saturated the UI thread: repeated ANRs and 23-26 % idle CPU.
 * The callback now admits at most one pass per address per interval.
 */
class MeshScanThrottleTest {

    @Test
    fun firstSightingAlwaysGetsAPass() {
        assertTrue(shouldProcessMeshSighting(lastProcessedMs = null, nowMs = 0L))
    }

    @Test
    fun reSightingsWithinTheIntervalAreOnlyRecorded() {
        assertFalse(shouldProcessMeshSighting(lastProcessedMs = 10_000L, nowMs = 10_100L))
        assertFalse(
            shouldProcessMeshSighting(
                lastProcessedMs = 10_000L,
                nowMs = 10_000L + MESH_RESIGHT_MIN_INTERVAL_MS - 1,
            ),
        )
    }

    @Test
    fun aReSightingAfterTheIntervalGetsAPassSoFailedDialsAreRetried() {
        assertTrue(
            shouldProcessMeshSighting(
                lastProcessedMs = 10_000L,
                nowMs = 10_000L + MESH_RESIGHT_MIN_INTERVAL_MS,
            ),
        )
    }

    @Test
    fun aBurstOfAdvertisementsCostsOnePassPerIntervalPerAddress() {
        // One device advertising every 100 ms for 5 s: 50 callbacks.
        var last: Long? = null
        var passes = 0
        for (t in 0L until 5_000L step 100L) {
            if (shouldProcessMeshSighting(last, t)) {
                passes++
                last = t
            }
        }
        assertEquals(5, passes)
    }
}
