//
// SonarConversationFoldTests.swift
// bitchatTests
//

import Testing
@testable import Sonar

struct SonarConversationFoldTests {
    @Test
    func uniqueTitleMatchInfersPeerKey() {
        let key = snInferUniquePeerKeyByTitle(
            groupTitle: "  Sara   D ",
            peerTitles: [
                "fp-sara": "Sara D",
                "fp-vince": "Vincenzo"
            ],
            allGroupTitles: ["Sara D", "Alice"]
        )

        #expect(key == "fp-sara")
    }

    @Test
    func duplicatePeerTitlesDoNotInfer() {
        let key = snInferUniquePeerKeyByTitle(
            groupTitle: "Sara D",
            peerTitles: [
                "fp-one": "Sara D",
                "fp-two": "sara d"
            ],
            allGroupTitles: ["Sara D"]
        )

        #expect(key == nil)
    }

    @Test
    func duplicateGroupTitlesDoNotInfer() {
        let key = snInferUniquePeerKeyByTitle(
            groupTitle: "Sara D",
            peerTitles: [
                "fp-sara": "Sara D"
            ],
            allGroupTitles: ["Sara D", " sara   d "]
        )

        #expect(key == nil)
    }
}
