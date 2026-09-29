import Testing
@testable import Sonar

/// QA-001 on iOS: the first message of a chat moves the composer from the
/// empty state into the transcript host, which rebuilds it and used to drop
/// the keyboard. The screen re-focuses the rebuilt composer only then.
struct SNComposerFirstSendFocusTests {
    @Test
    func theFirstSendWithTheKeyboardUpRefocusesTheRebuiltComposer() {
        #expect(snRefocusComposerAfterSend(transcriptWasEmpty: true, composerFocused: true))
    }

    @Test
    func laterSendsKeepTheSameFieldAndNeedNoRefocus() {
        #expect(!snRefocusComposerAfterSend(transcriptWasEmpty: false, composerFocused: true))
    }

    @Test
    func aSendWithoutFocusNeverRaisesTheKeyboard() {
        #expect(!snRefocusComposerAfterSend(transcriptWasEmpty: true, composerFocused: false))
    }
}
