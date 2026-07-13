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
        content: String = "hello",
        deliveryState: String? = nil
    ) -> MarmotService.MarmotMessage {
        MarmotService.MarmotMessage(
            id: id,
            senderNpub: "npub",
            content: content,
            createdAt: createdAt,
            isMine: true,
            deliveryState: deliveryState,
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

    @Test
    func refreshKeepsPendingLocalEchoExactlyOnce() {
        let echo = message(id: "optimistic-1", createdAt: Date(timeIntervalSince1970: 100))
        let reconciliation = MarmotChatModel.reconciledOptimisticMessages(
            source: [echo],
            pending: [echo]
        )

        #expect(reconciliation.survivors.map(\.id) == [echo.id])
        #expect(reconciliation.visible.map(\.id) == [echo.id])
    }

    @Test
    func refreshRemovesFulfilledLocalEcho() {
        let echo = message(id: "optimistic-1", createdAt: Date(timeIntervalSince1970: 100))
        let canonical = message(id: "canonical-1", createdAt: Date(timeIntervalSince1970: 101))
        let reconciliation = MarmotChatModel.reconciledOptimisticMessages(
            source: [echo, canonical],
            pending: [echo]
        )

        #expect(reconciliation.survivors.isEmpty)
        #expect(reconciliation.visible.map(\.id) == [canonical.id])
    }

    @Test
    func relayAckReplacesSendingStateWithoutAnotherSync() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let echo = message(id: "optimistic-1", createdAt: createdAt)
        let pending = message(
            id: "canonical-1",
            createdAt: createdAt,
            deliveryState: "pending"
        )
        let local = MarmotChatModel.reconciledOptimisticMessages(
            source: [echo, pending],
            pending: [echo]
        )

        #expect(local.survivors.isEmpty)
        #expect(local.visible.map(\.id) == [pending.id])
        #expect(MarmotChatModel.stateText(for: local.visible[0]) == "Sending")

        let sent = message(
            id: pending.id,
            createdAt: createdAt,
            deliveryState: "sent"
        )
        let refreshed = MarmotChatModel.reconciledOptimisticMessages(
            source: local.visible + [sent],
            pending: []
        ).visible

        #expect(refreshed.map(\.id) == [sent.id])
        #expect(MarmotChatModel.stateText(for: refreshed[0]) == "Sent")
    }
}
