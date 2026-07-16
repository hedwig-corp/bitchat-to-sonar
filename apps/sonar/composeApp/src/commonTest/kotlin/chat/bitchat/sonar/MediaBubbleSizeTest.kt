package chat.bitchat.sonar

import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The reserved box must equal what MediaImage (ContentScale.Fit under the
 * width/height maxes) actually renders — otherwise the bubble either reflows
 * when the bytes decode or shows background bars around the image.
 */
class MediaBubbleSizeTest {

    private fun fit(w: Int, h: Int) = mediaBubbleFittedSize(
        intrinsic = DpSize(w.dp, h.dp),
        maxWidth = MAX_MEDIA_BUBBLE_WIDTH,
        maxHeight = MAX_MEDIA_BUBBLE_HEIGHT,
    )

    private fun assertAspectPreserved(intrinsic: DpSize, fitted: DpSize) {
        val want = intrinsic.width / intrinsic.height
        val got = fitted.width / fitted.height
        assertTrue(
            kotlin.math.abs(want - got) < 0.01f,
            "aspect ratio drifted: intrinsic $want vs fitted $got ($intrinsic -> $fitted)",
        )
    }

    @Test
    fun portrait_screenshot_fits_by_height_not_stretched_to_max_width() {
        // 1080x2410 px at density 3 = 360x803dp. Height binds: 300/803 = 0.3736.
        val fitted = fit(360, 803)
        assertEquals(MAX_MEDIA_BUBBLE_HEIGHT, fitted.height)
        assertTrue(
            fitted.width < 140.dp,
            "portrait must not claim the full 240dp width (was ${fitted.width})",
        )
        assertAspectPreserved(DpSize(360.dp, 803.dp), fitted)
    }

    @Test
    fun landscape_fits_by_width_not_stretched_to_max_height() {
        // 3000x2000 px at density 3 = 1000x666dp. Width binds: 240/1000 = 0.24.
        val fitted = fit(1000, 666)
        assertEquals(MAX_MEDIA_BUBBLE_WIDTH, fitted.width)
        assertTrue(
            fitted.height < 165.dp,
            "landscape must not claim the full 300dp height (was ${fitted.height})",
        )
        assertAspectPreserved(DpSize(1000.dp, 666.dp), fitted)
    }

    @Test
    fun small_image_is_never_upscaled() {
        // Intrinsic already inside the maxes: MediaImage renders it 1:1.
        assertEquals(DpSize(33.dp, 33.dp), fit(33, 33))
    }

    @Test
    fun exact_bounds_image_is_unchanged() {
        assertEquals(DpSize(240.dp, 300.dp), fit(240, 300))
    }

    @Test
    fun fitted_box_never_exceeds_either_bound() {
        for ((w, h) in listOf(1 to 4000, 4000 to 1, 800 to 800, 241 to 301, 5 to 900)) {
            val fitted = fit(w, h)
            assertTrue(fitted.width <= MAX_MEDIA_BUBBLE_WIDTH, "width overflow for ${w}x$h: $fitted")
            assertTrue(fitted.height <= MAX_MEDIA_BUBBLE_HEIGHT, "height overflow for ${w}x$h: $fitted")
        }
    }

    @Test
    fun narrower_bubble_max_constrains_width() {
        // Group/desktop layouts pass a smaller maxBubbleWidth than 240dp.
        val fitted = mediaBubbleFittedSize(
            intrinsic = DpSize(1000.dp, 666.dp),
            maxWidth = 120.dp,
            maxHeight = MAX_MEDIA_BUBBLE_HEIGHT,
        )
        assertEquals(120.dp, fitted.width)
        assertAspectPreserved(DpSize(1000.dp, 666.dp), fitted)
    }

    @Test
    fun degenerate_dimensions_collapse_to_zero_rather_than_dividing_by_zero() {
        assertEquals(DpSize(0.dp, 0.dp), fit(0, 100))
        assertEquals(DpSize(0.dp, 0.dp), fit(100, 0))
    }
}
