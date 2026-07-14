//
// ConversationTranscriptWindowTests.swift
// bitchatTests
//
// Regression coverage for conversation-wide paging across folded transports.
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import Sonar

struct ConversationTranscriptWindowTests {
    private func message(_ index: Int, source: String) -> SNMessage {
        SNMessage(
            id: "\(source)-\(String(format: "%04d", index))",
            text: "\(source) \(index)",
            time: "",
            sortDate: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }

    private func marmotMessage(
        _ index: Int,
        content: String = "message"
    ) -> MarmotService.MarmotMessage {
        MarmotService.MarmotMessage(
            id: "marmot-\(String(format: "%04d", index))",
            senderNpub: "npub",
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
            isMine: false,
            media: []
        )
    }

    @Test func newestBudgetIsAppliedAfterFoldedSourcesMerge() {
        let olderSource = (0..<30).map { message($0, source: "internet") }
        let newerSource = (30..<60).map { message($0, source: "mesh") }

        let visible = SNConversationTranscriptWindow.newest(
            olderSource + newerSource,
            limit: 30
        )

        #expect(visible.map(\.sortDate) == newerSource.map(\.sortDate))
    }

    @Test func olderFoldedSourceAdvancesFullHistoricalWindow() {
        let olderSource = (0..<500).map { message($0, source: "internet") }
        let visibleNewerSource = (500..<1000).map { message($0, source: "mesh") }

        let page = SNConversationTranscriptWindow.nearestOlderPage(
            in: olderSource + visibleNewerSource,
            before: visibleNewerSource[0],
            pageSize: 30
        )
        let moved = SNConversationTranscriptWindow.prepending(
            page,
            to: visibleNewerSource,
            limit: 500
        )

        #expect(page.first?.id == "internet-0470")
        #expect(page.last?.id == "internet-0499")
        #expect(moved.first?.id == "internet-0470")
        #expect(moved.last?.id == "mesh-0969")
        #expect(moved.count == 500)
    }

    @Test func historicalRefreshDoesNotSnapBackToNewerSource() {
        let historical = (0..<500).map { message($0, source: "internet") }
        var updated = historical[499]
        updated.text = "updated"
        let unseenTail = (500..<530).map { message($0, source: "mesh") }

        let refreshed = SNConversationTranscriptWindow.refreshing(
            historical,
            from: [updated] + unseenTail,
            limit: 500,
            preservingOlderEdge: true
        )

        #expect(refreshed.first?.id == "internet-0000")
        #expect(refreshed.last?.id == "internet-0499")
        #expect(refreshed.last?.text == "updated")
        #expect(refreshed.contains(where: { $0.id == "mesh-0529" }) == false)
    }

    @Test func reachingRetainedBudgetPinsBeforeLiveAppend() {
        let older = (0..<30).map { message($0, source: "internet") }
        let previous = (30..<500).map { message($0, source: "internet") }
        let fullWindow = SNConversationTranscriptWindow.prepending(
            older,
            to: previous,
            limit: 500
        )
        let shouldPreserve = SNConversationTranscriptWindow.shouldPreserveOlderEdge(
            afterGrowingTo: 500,
            retainedLimit: 500,
            previous: previous,
            next: fullWindow
        )
        let refreshed = SNConversationTranscriptWindow.refreshing(
            fullWindow,
            from: fullWindow + [message(500, source: "mesh")],
            limit: 500,
            preservingOlderEdge: shouldPreserve
        )

        #expect(fullWindow.count == 500)
        #expect(shouldPreserve)
        #expect(refreshed.first?.id == "internet-0000")
        #expect(refreshed.last?.id == "internet-0499")
        #expect(refreshed.contains(where: { $0.id == "mesh-0500" }) == false)
    }

    @Test @MainActor func backgroundSourceRefreshKeepsHistoricalCursorWindow() {
        let historical = (0..<500).map { marmotMessage($0) }
        let updated = marmotMessage(499, content: "updated")
        let unseenTail = (500..<530).map { marmotMessage($0) }

        let refreshed = MarmotChatModel.refreshHistoricalMessages(
            existing: historical,
            newest: [updated] + unseenTail
        )

        #expect(refreshed.first?.id == "marmot-0000")
        #expect(refreshed.last?.id == "marmot-0499")
        #expect(refreshed.last?.content == "updated")
        #expect(refreshed.contains(where: { $0.id == "marmot-0529" }) == false)
    }

    @Test @MainActor func backgroundSourceRefreshRetainsPartialPagesAndAdmitsLiveTail() {
        let historical = (0..<60).map { marmotMessage($0) }
        let live = marmotMessage(60)

        let refreshed = MarmotChatModel.refreshLocalMessages(
            existing: historical,
            newest: Array(historical.suffix(30)) + [live],
            retainedLimit: 500,
            preservingOlderEdge: false
        )

        #expect(refreshed.count == 61)
        #expect(refreshed.first?.id == "marmot-0000")
        #expect(refreshed.last?.id == "marmot-0060")
    }
}
