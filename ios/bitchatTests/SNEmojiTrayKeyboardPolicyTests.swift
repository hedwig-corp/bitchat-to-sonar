//
// SNEmojiTrayKeyboardPolicyTests.swift
// bitchatTests
//
// Regression: opening the emoji/sticker tray while the IME stays up stacks
// tray height on keyboardLayoutGuide (Phase 3) and freezes the chat UI.
// Soft-keyboard gating must not steal focus on macOS / hardware keyboards.
//

import Testing
@testable import Sonar

struct SNEmojiTrayKeyboardPolicyTests {

    @Test
    func openingTrayDismissesKeyboardOnlyOnSoftKeyboardPlatforms() {
        #expect(
            snShouldDismissKeyboardWhenOpeningEmojiTray(
                openingTray: true,
                usesSoftKeyboard: true
            )
        )
        #expect(
            !snShouldDismissKeyboardWhenOpeningEmojiTray(
                openingTray: true,
                usesSoftKeyboard: false
            )
        )
        #expect(
            !snShouldDismissKeyboardWhenOpeningEmojiTray(
                openingTray: false,
                usesSoftKeyboard: true
            )
        )
    }

    @Test
    func composerFocusClosesOpenTrayOnlyOnSoftKeyboardPlatforms() {
        #expect(
            snShouldCloseEmojiTrayOnComposerFocus(
                composerFocused: true,
                trayOpen: true,
                usesSoftKeyboard: true
            )
        )
        #expect(
            !snShouldCloseEmojiTrayOnComposerFocus(
                composerFocused: true,
                trayOpen: true,
                usesSoftKeyboard: false
            )
        )
        #expect(
            !snShouldCloseEmojiTrayOnComposerFocus(
                composerFocused: true,
                trayOpen: false,
                usesSoftKeyboard: true
            )
        )
        #expect(
            !snShouldCloseEmojiTrayOnComposerFocus(
                composerFocused: false,
                trayOpen: true,
                usesSoftKeyboard: true
            )
        )
    }

    @Test
    func trayHeightShrinksWhenSearchFocused() {
        #expect(snEmojiTrayHeight(searchFocused: false) == 320)
        #expect(snEmojiTrayHeight(searchFocused: true) == 200)
    }
}
