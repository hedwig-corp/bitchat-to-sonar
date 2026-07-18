//
// SNEmojiTrayKeyboardPolicyTests.swift
// bitchatTests
//
// Regression: opening the emoji/sticker tray while the IME stays up stacks
// tray height on keyboardLayoutGuide (Phase 3) and freezes the chat UI.
//

import Testing
@testable import Sonar

struct SNEmojiTrayKeyboardPolicyTests {

    @Test
    func openingTrayDismissesKeyboard() {
        #expect(snShouldDismissKeyboardWhenOpeningEmojiTray(openingTray: true))
        #expect(!snShouldDismissKeyboardWhenOpeningEmojiTray(openingTray: false))
    }

    @Test
    func composerFocusClosesOpenTray() {
        #expect(
            snShouldCloseEmojiTrayOnComposerFocus(composerFocused: true, trayOpen: true)
        )
        #expect(
            !snShouldCloseEmojiTrayOnComposerFocus(composerFocused: true, trayOpen: false)
        )
        #expect(
            !snShouldCloseEmojiTrayOnComposerFocus(composerFocused: false, trayOpen: true)
        )
    }
}
