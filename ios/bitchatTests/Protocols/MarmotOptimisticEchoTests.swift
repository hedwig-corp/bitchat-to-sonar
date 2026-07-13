//
// MarmotOptimisticEchoTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import Sonar

@MainActor
struct MarmotOptimisticEchoTests {
    private func message(
        id: String,
        createdAt: Date,
        content: String = "hello"
    ) -> MarmotService.MarmotMessage {
        MarmotService.MarmotMessage(
            id: id,
            senderNpub: "npub",
            content: content,
            createdAt: createdAt,
            isMine: true,
            media: []
        )
    }

    @Test
    func previouslyVisibleSameSecondRowDoesNotFulfillNewEcho() {
        let timestamp = Date(timeIntervalSince1970: 100)
        let echo = message(id: "optimistic-1", createdAt: timestamp)
        let prior = message(id: "canonical-prior", createdAt: timestamp)

        #expect(
            !MarmotChatModel.serverMessage(
                prior,
                matchesOptimistic: echo,
                excludingServerIDs: [prior.id]
            )
        )
    }

    @Test
    func newCanonicalRowStillFulfillsEcho() {
        let echo = message(id: "optimistic-1", createdAt: Date(timeIntervalSince1970: 100))
        let canonical = message(id: "canonical-new", createdAt: Date(timeIntervalSince1970: 101))

        #expect(MarmotChatModel.serverMessage(canonical, matchesOptimistic: echo))
    }

    @Test
    func localEchoDoesNotFulfillItself() {
        let echo = message(id: "optimistic-1", createdAt: Date(timeIntervalSince1970: 100))

        #expect(!MarmotChatModel.serverMessage(echo, matchesOptimistic: echo))
    }
}
