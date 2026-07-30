//
// SNComposerReturnMarkedTextTests.swift
// bitchatTests
//
// Regression: on macOS the composer claims Return to send. Claiming it while an
// IME composition is open stops the text system from committing the marked
// text, so the pending character is dropped from the field AND from the message
// that goes out — the macOS "sent text is cut" report. See R-027.
//

import Testing
@testable import Sonar

struct SNComposerReturnMarkedTextTests {

    @Test
    func bareReturnSendsWhenNothingIsComposing() {
        #expect(snReturnSendsComposerDraft(
            hasMarkedText: false, isShiftPressed: false, isOptionPressed: false
        ))
    }

    /// The bug: a Return during composition must reach the text system so the
    /// marked character is committed. The next Return sends.
    @Test
    func returnDuringCompositionDoesNotSend() {
        #expect(!snReturnSendsComposerDraft(
            hasMarkedText: true, isShiftPressed: false, isOptionPressed: false
        ))
    }

    /// Shift/Option stay reserved for newline (#334) regardless of composition.
    @Test
    func modifiedReturnNeverSends() {
        #expect(!snReturnSendsComposerDraft(
            hasMarkedText: false, isShiftPressed: true, isOptionPressed: false
        ))
        #expect(!snReturnSendsComposerDraft(
            hasMarkedText: false, isShiftPressed: false, isOptionPressed: true
        ))
        #expect(!snReturnSendsComposerDraft(
            hasMarkedText: true, isShiftPressed: true, isOptionPressed: false
        ))
    }
}
