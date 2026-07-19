//
// SNComposerDraftPersistTests.swift
// bitchatTests
//
// Regression: leaving a chat and returning must restore the in-progress
// composer draft (session-scoped map; empty text removes the entry).
//

import Testing
@testable import Sonar

struct SNComposerDraftPersistTests {

    @Test
    func updatedDraftsStoresPerChatAndClearsEmpty() {
        let afterA = snUpdatedComposerDrafts(drafts: [:], chatId: "dm:a", text: "hello")
        #expect(afterA == ["dm:a": "hello"])

        let afterB = snUpdatedComposerDrafts(drafts: afterA, chatId: "dm:b", text: "world")
        #expect(afterB == ["dm:a": "hello", "dm:b": "world"])

        let cleared = snUpdatedComposerDrafts(drafts: afterB, chatId: "dm:a", text: "")
        #expect(cleared == ["dm:b": "world"])
    }

    @Test
    func updatedDraftsKeepsWhitespaceWhileTyping() {
        let drafts = snUpdatedComposerDrafts(drafts: [:], chatId: "dm:a", text: "hi ")
        #expect(drafts["dm:a"] == "hi ")
    }
}
