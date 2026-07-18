package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MeshMarmotSendEchoTest {
    @Test
    fun meshWhiteNoiseEchoStaysUntilCanonicalRowExists() {
        // First out-of-range send / slow refresh: keep the optimistic bubble.
        assertFalse(shouldClearMeshMarmotSendEcho(hasCanonicalRow = false))
        // Only drop it once the White Noise leg has a matching durable row.
        assertTrue(shouldClearMeshMarmotSendEcho(hasCanonicalRow = true))
    }
}
