package chat.bitchat.sonar

import androidx.compose.ui.unit.sp
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class BubbleMetaTimePlaceholderTest {
    @Test
    fun placeholderIsTallEnoughForAndroidFontPadding() {
        val placeholder = bubbleMetaTimePlaceholder("14:32")
        // Android includeFontPadding can add ~40% above fontSize. The old 12.sp
        // slot clipped 10.5.sp glyphs through the midline.
        assertTrue(placeholder.height.value >= BUBBLE_META_TIME_FONT_SP * 1.4f)
        assertEquals(BUBBLE_META_TIME_PLACEHOLDER_HEIGHT_SP.sp, placeholder.height)
        assertTrue(placeholder.height.isSp)
    }

    @Test
    fun placeholderWidthGrowsWithTheClockLabel() {
        val short = bubbleMetaTimePlaceholder("9:00")
        val long = bubbleMetaTimePlaceholder("14:32")
        assertTrue(long.width.value > short.width.value)
    }
}
