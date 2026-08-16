package chat.bitchat.sonar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Mesh photos used to ship at 448 px / ~45 KB, which is unreadable in a phone
 * bubble. The ladder must spend the whole mesh budget before it gives up
 * pixels: full edge first, then quality, and only then a smaller edge.
 */
class MeshImageBudgetTest {

    private class Attempt(val edgePx: Int, val quality: Int)

    /** Fake encoder: bytes scale with pixel count and quality. [bytesPerUnit]
     *  tunes how compressible the fake source is. */
    private fun encoder(
        bytesPerUnit: Double,
        log: MutableList<Attempt>,
    ): (Int, Int) -> ByteArray = { edgePx, quality ->
        log += Attempt(edgePx, quality)
        val size = (edgePx.toDouble() * edgePx * quality * bytesPerUnit).toInt().coerceAtLeast(1)
        ByteArray(size)
    }

    @Test
    fun keeps_full_mesh_edge_when_the_photo_already_fits_the_budget() {
        val log = mutableListOf<Attempt>()
        // ~262 KB at 1600px/q85 — inside MESH_IMAGE_TARGET_BYTES.
        val out = compressToMeshBudget(4032, encode = encoder(0.0012, log))

        assertNotNull(out)
        assertTrue(out.size <= MESH_IMAGE_TARGET_BYTES)
        assertEquals(1, log.size, "a fitting photo must not be re-encoded")
        assertEquals(MESH_IMAGE_MAX_EDGE_PX, log[0].edgePx)
        assertEquals(MESH_IMAGE_MAX_QUALITY, log[0].quality)
    }

    @Test
    fun never_upscales_a_source_smaller_than_the_mesh_edge() {
        val log = mutableListOf<Attempt>()
        compressToMeshBudget(900, encode = encoder(0.0012, log))

        assertEquals(900, log[0].edgePx)
    }

    @Test
    fun drops_quality_before_it_drops_pixels() {
        val log = mutableListOf<Attempt>()
        val out = compressToMeshBudget(4032, encode = encoder(0.0018, log))

        assertNotNull(out)
        assertTrue(out.size <= MESH_IMAGE_TARGET_BYTES)
        assertTrue(log.size > 1, "expected the quality ladder to run")
        assertTrue(
            log.all { it.edgePx == MESH_IMAGE_MAX_EDGE_PX },
            "quality must be exhausted before the edge shrinks",
        )
        assertTrue(log.last().quality >= MESH_IMAGE_MIN_QUALITY)
    }

    @Test
    fun shrinks_the_edge_only_after_min_quality_still_misses_the_hard_limit() {
        val log = mutableListOf<Attempt>()
        // Incompressible enough that even 1600px/q60 blows the 1 MiB packet cap.
        val out = compressToMeshBudget(4032, encode = encoder(0.02, log))

        assertNotNull(out)
        val firstShrink = log.indexOfFirst { it.edgePx < MESH_IMAGE_MAX_EDGE_PX }
        assertTrue(firstShrink > 0, "expected a downscale step")
        assertEquals(MESH_IMAGE_MIN_QUALITY, log[firstShrink - 1].quality)
        assertTrue(
            log.none { it.edgePx < MESH_IMAGE_MIN_EDGE_PX },
            "the ladder must not go below the ${MESH_IMAGE_MIN_EDGE_PX}px floor",
        )
    }

    @Test
    fun returns_the_best_attempt_when_nothing_fits_so_the_caller_can_fall_back() {
        val log = mutableListOf<Attempt>()
        // Incompressible even at the 640px floor, so no rung fits the cap.
        val out = compressToMeshBudget(4032, encode = encoder(0.1, log))

        assertNotNull(out, "an over-budget encode must still be returned for the route fallback")
        assertEquals(MESH_IMAGE_MIN_EDGE_PX, log.last().edgePx)
        assertEquals(MESH_IMAGE_MIN_QUALITY, log.last().quality)
    }

    @Test
    fun gives_up_when_the_platform_encoder_fails() {
        assertEquals(null, compressToMeshBudget(4032) { _, _ -> null })
    }
}
