package chat.bitchat.sonar

import chat.bitchat.sonar.screens.emojiTrayHeightDp
import chat.bitchat.sonar.screens.shouldCloseEmojiTrayOnComposerFocus
import chat.bitchat.sonar.screens.shouldDismissKeyboardWhenOpeningEmojiTray
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class EmojiTrayKeyboardPolicyTest {
    @Test
    fun openingTrayDismissesKeyboardOnlyOnSoftKeyboardPlatforms() {
        assertTrue(
            shouldDismissKeyboardWhenOpeningEmojiTray(
                openingTray = true,
                usesSoftKeyboard = true,
            ),
        )
        assertFalse(
            shouldDismissKeyboardWhenOpeningEmojiTray(
                openingTray = true,
                usesSoftKeyboard = false,
            ),
        )
        assertFalse(
            shouldDismissKeyboardWhenOpeningEmojiTray(
                openingTray = false,
                usesSoftKeyboard = true,
            ),
        )
    }

    @Test
    fun composerFocusClosesOpenTrayOnlyOnSoftKeyboardPlatforms() {
        assertTrue(
            shouldCloseEmojiTrayOnComposerFocus(
                composerFocused = true,
                trayOpen = true,
                usesSoftKeyboard = true,
            ),
        )
        assertFalse(
            shouldCloseEmojiTrayOnComposerFocus(
                composerFocused = true,
                trayOpen = true,
                usesSoftKeyboard = false,
            ),
        )
        assertFalse(
            shouldCloseEmojiTrayOnComposerFocus(
                composerFocused = true,
                trayOpen = false,
                usesSoftKeyboard = true,
            ),
        )
        assertFalse(
            shouldCloseEmojiTrayOnComposerFocus(
                composerFocused = false,
                trayOpen = true,
                usesSoftKeyboard = true,
            ),
        )
    }

    @Test
    fun trayHeightShrinksWhenSearchFocused() {
        assertEquals(320, emojiTrayHeightDp(searchFocused = false))
        assertEquals(200, emojiTrayHeightDp(searchFocused = true))
    }
}
