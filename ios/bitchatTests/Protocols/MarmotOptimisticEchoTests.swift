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

    /// Regression: a group pinned to its older historical edge admits no new
    /// rows into the visible window, so the relay copy of an outgoing send
    /// only exists in the freshly-read database page. The echo must reconcile
    /// against that page — otherwise the message stays "Sending" forever.
    @Test
    func freshDatabaseRowOutsidePinnedWindowFulfillsEcho() {
        let old = message(
            id: "canonical-old",
            createdAt: Date(timeIntervalSince1970: 10),
            content: "history"
        )
        let echo = message(id: "optimistic-1", createdAt: Date(timeIntervalSince1970: 100))
        let canonical = message(
            id: "canonical-new",
            createdAt: Date(timeIntervalSince1970: 101),
            deliveryState: "sent"
        )

        // Pinned window: only the historical row + the echo; the new canonical
        // row was read from the database but not admitted to the window.
        let reconciliation = MarmotChatModel.reconciledOptimisticMessages(
            source: [old, echo],
            pending: [echo],
            freshCanonical: [old, canonical]
        )

        #expect(reconciliation.survivors.isEmpty)
        #expect(reconciliation.visible.map(\.id) == [old.id, canonical.id])
        #expect(MarmotChatModel.stateText(for: reconciliation.visible[1]) == "Sent")
    }

    /// The out-of-window match must respect the same freshness slack as the
    /// windowed match: an older identical row from history must not consume a
    /// still-pending echo.
    @Test
    func olderIdenticalFreshRowDoesNotFulfillEcho() {
        let echo = message(id: "optimistic-1", createdAt: Date(timeIntervalSince1970: 100))
        let older = message(id: "canonical-old", createdAt: Date(timeIntervalSince1970: 50))

        let reconciliation = MarmotChatModel.reconciledOptimisticMessages(
            source: [echo],
            pending: [echo],
            freshCanonical: [older]
        )

        #expect(reconciliation.survivors.map(\.id) == [echo.id])
        #expect(reconciliation.visible.map(\.id) == [echo.id])
    }

    /// A fresh row that is already part of the visible window must not be
    /// admitted twice, and reconciliation must behave exactly as before.
    @Test
    func freshRowAlreadyInWindowReconcilesOnce() {
        let echo = message(id: "optimistic-1", createdAt: Date(timeIntervalSince1970: 100))
        let canonical = message(id: "canonical-1", createdAt: Date(timeIntervalSince1970: 101))

        let reconciliation = MarmotChatModel.reconciledOptimisticMessages(
            source: [echo, canonical],
            pending: [echo],
            freshCanonical: [canonical]
        )

        #expect(reconciliation.survivors.isEmpty)
        #expect(reconciliation.visible.map(\.id) == [canonical.id])
    }

    /// Exclusions (canonical rows that predate the echo) apply to fresh
    /// database rows too: a pre-existing identical row must not fulfill a new
    /// echo just because it arrived through the fresh page.
    @Test
    func excludedFreshRowDoesNotFulfillEcho() {
        let timestamp = Date(timeIntervalSince1970: 100)
        let echo = message(id: "optimistic-1", createdAt: timestamp)
        let prior = message(id: "canonical-prior", createdAt: timestamp)

        let reconciliation = MarmotChatModel.reconciledOptimisticMessages(
            source: [echo],
            pending: [echo],
            exclusionsByOptimisticID: [echo.id: [prior.id]],
            freshCanonical: [prior]
        )

        #expect(reconciliation.survivors.map(\.id) == [echo.id])
        // The excluded row is not admitted: it did not fulfill anything.
        #expect(reconciliation.visible.map(\.id) == [echo.id])
    }
}
