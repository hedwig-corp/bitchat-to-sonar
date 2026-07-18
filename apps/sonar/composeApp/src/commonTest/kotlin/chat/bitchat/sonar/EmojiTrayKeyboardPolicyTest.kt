package chat.bitchat.sonar

import chat.bitchat.sonar.screens.shouldCloseEmojiTrayOnComposerFocus
import chat.bitchat.sonar.screens.shouldDismissKeyboardWhenOpeningEmojiTray
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class EmojiTrayKeyboardPolicyTest {
    @Test
    fun openingTrayDismissesKeyboard() {
        assertTrue(shouldDismissKeyboardWhenOpeningEmojiTray(openingTray = true))
        assertFalse(shouldDismissKeyboardWhenOpeningEmojiTray(openingTray = false))
    }

    @Test
    fun composerFocusClosesOpenTray() {
        assertTrue(shouldCloseEmojiTrayOnComposerFocus(composerFocused = true, trayOpen = true))
        assertFalse(shouldCloseEmojiTrayOnComposerFocus(composerFocused = true, trayOpen = false))
        assertFalse(shouldCloseEmojiTrayOnComposerFocus(composerFocused = false, trayOpen = true))
    }
}
