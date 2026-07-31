//
// SNComposerLiveDraftTests.swift
// bitchatTests
//
// Regression: on macOS the composer sent a stale prefix of the draft when the
// user typed fast and hit Return. The SwiftUI binding is served from the view
// graph and the draft store is deliberately unpublished, so nothing re-renders
// the composer while typing and the binding falls behind the field. See R-029.
//

import Testing
@testable import Sonar

struct SNComposerLiveDraftTests {

    /// The bug: the binding held the prefix the view graph last saw while the
    /// field already held the whole word. The field wins.
    @Test
    func fieldEditorWinsOverAStaleBinding() {
        #expect(snLiveComposerDraft(binding: "Y", fieldEditor: "Yoooo") == "Yoooo")
    }

    /// An empty field is not "no field": the user cleared it and there is
    /// nothing to send. Falling back to the binding here would resurrect text
    /// the user deleted.
    @Test
    func anEmptyFieldEditorIsNotAMissingOne() {
        #expect(snLiveComposerDraft(binding: "stale draft", fieldEditor: "") == "")
    }

    /// No field editor (send button pressed with focus elsewhere, or iOS)
    /// leaves the binding as the only thing to go on.
    @Test
    func bindingIsUsedWhenThereIsNoFieldEditor() {
        #expect(snLiveComposerDraft(binding: "typed", fieldEditor: nil) == "typed")
    }

    @Test
    func agreementIsPreserved() {
        #expect(snLiveComposerDraft(binding: "same", fieldEditor: "same") == "same")
    }
}
