//
// SNComposerMentionLocalityTests.swift
// bitchatTests
//
// Mentions filter from the bound draft + roster locally (Compose Mentions.matches
// shape). Draft text changes must not require a store-published mention query.
//

import Testing
@testable import Sonar

struct SNComposerMentionLocalityTests {
    @Test
    func mentionSuggestionsDeriveFromDraftWithoutStoreQuery() {
        let roster = [
            SNMentionCandidate(npub: "npub1alice", name: "Alice", suffixHex4: "a11c"),
            SNMentionCandidate(npub: "npub1bob", name: "Bob", suffixHex4: "b0b0"),
        ]
        let matches = SNMentions.matches(draft: "hey @Al", roster: roster)
        #expect(matches.map(\.name) == ["Alice"])

        let none = SNMentions.matches(draft: "hey there", roster: roster)
        #expect(none.isEmpty)
    }

    @Test
    func draftHasTextFlagOnlyFlipsOnEmptyBoundary() {
        let empty: [String: Bool] = [:]
        let typed = snUpdatedComposerDraftHasText(flags: empty, chatId: "dm:a", text: "h")
        #expect(typed["dm:a"] == true)
        let more = snUpdatedComposerDraftHasText(flags: typed, chatId: "dm:a", text: "hi @Al")
        #expect(more == typed)
    }
}
