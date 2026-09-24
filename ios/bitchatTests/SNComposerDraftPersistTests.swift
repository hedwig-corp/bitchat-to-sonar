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
    func draftHasTextPublishesOnlyOnEmptyBoundary() {
        // Regression: the send/mic toggle re-renders off this published mirror.
        // It must flip on the first typed char and on clear, and must stay
        // identical (no publish) for every keystroke in between.
        let empty: [String: Bool] = [:]

        let typed = snUpdatedComposerDraftHasText(flags: empty, chatId: "dm:a", text: "h")
        #expect(typed == ["dm:a": true])

        let moreTyping = snUpdatedComposerDraftHasText(flags: typed, chatId: "dm:a", text: "hi")
        #expect(moreTyping == typed)

        let whitespaceOnly = snUpdatedComposerDraftHasText(flags: empty, chatId: "dm:a", text: "  ")
        #expect(whitespaceOnly == empty)

        let cleared = snUpdatedComposerDraftHasText(flags: typed, chatId: "dm:a", text: "")
        #expect(cleared == ["dm:a": false])

        // Other chats' flags are untouched.
        let two = snUpdatedComposerDraftHasText(flags: typed, chatId: "dm:b", text: "yo")
        #expect(two == ["dm:a": true, "dm:b": true])
    }

    @Test
    func updatedDraftsKeepsWhitespaceWhileTyping() {
        let drafts = snUpdatedComposerDrafts(drafts: [:], chatId: "dm:a", text: "hi ")
        #expect(drafts["dm:a"] == "hi ")
    }

    // QA-A19: typed while the chat was pending, lost when it reconciled.
    @Test
    func pendingChatDraftFollowsTheChatToItsRealId() {
        let drafts = ["pending:x": "hello while pending", "dm:other": "keep"]
        let moved = snMovedComposerEntry(drafts, from: "pending:x", to: "marmot:real")
        #expect(moved == ["dm:other": "keep", "marmot:real": "hello while pending"])
    }

    @Test
    func existingDraftOnTheRealIdWinsAndPendingKeyIsDropped() {
        let drafts = ["pending:x": "older", "marmot:real": "newer"]
        #expect(snMovedComposerEntry(drafts, from: "pending:x", to: "marmot:real") == ["marmot:real": "newer"])
    }

    @Test
    func movingWithoutAPendingEntryIsANoOp() {
        let drafts = ["dm:a": "hi"]
        #expect(snMovedComposerEntry(drafts, from: "pending:x", to: "marmot:real") == drafts)
        #expect(snMovedComposerEntry(drafts, from: "dm:a", to: "dm:a") == drafts)
    }
}
