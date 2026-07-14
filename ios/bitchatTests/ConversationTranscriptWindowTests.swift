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
    private func message(
        _ index: Int,
        source: String,
        paymentID: String? = nil
    ) -> SNMessage {
        SNMessage(
            id: "\(source)-\(String(format: "%04d", index))",
            text: "\(source) \(index)",
            time: "",
            sortDate: Date(timeIntervalSince1970: TimeInterval(index)),
            transcriptSourceID: source,
            pay: paymentID.map {
                SNPayInfo(id: $0, sats: 1, state: .sealed)
            }
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

    @Test func foldedSourcesAdvanceOnlyTheIncompleteGlobalFrontier() {
        let farOlder = (970..<1000).map { message($0, source: "internet") }
        let visibleNewer = (1970..<2000).map { message($0, source: "mesh") }
        let oldestVisible = visibleNewer[0]
        let initialSources = [
            SNConversationTranscriptSource(id: "internet", rows: farOlder, hasMore: true),
            SNConversationTranscriptSource(id: SNConversationTranscriptSource.meshID, rows: visibleNewer, hasMore: true),
        ]

        let initialNeeds = SNConversationTranscriptWindow.sourceIDsNeedingExpansion(
            initialSources,
            before: oldestVisible,
            pageSize: 30
        )
        #expect(initialNeeds == [SNConversationTranscriptSource.meshID])

        let expandedNewer = (1940..<2000).map { message($0, source: "mesh") }
        let readySources = [
            SNConversationTranscriptSource(id: "internet", rows: farOlder, hasMore: true),
            SNConversationTranscriptSource(id: SNConversationTranscriptSource.meshID, rows: expandedNewer, hasMore: true),
        ]
        let readyNeeds = SNConversationTranscriptWindow.sourceIDsNeedingExpansion(
            readySources,
            before: oldestVisible,
            pageSize: 30
        )
        let page = SNConversationTranscriptWindow.nearestOlderPage(
            in: farOlder + expandedNewer,
            before: oldestVisible,
            pageSize: 30
        )

        #expect(readyNeeds.isEmpty)
        #expect(page.first?.id == "mesh-1940")
        #expect(page.last?.id == "mesh-1969")
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

    @Test func batchedLiveRowsCannotEvictAnchorWhileCrossingRetainedBudget() {
        let historical = (0..<499).map { message($0, source: "internet") }
        let firstLive = message(499, source: "mesh")
        let excessLive = message(500, source: "mesh")

        let filled = SNConversationTranscriptWindow.refreshing(
            historical,
            from: historical + [firstLive, excessLive],
            limit: 500,
            preservingOlderEdge: false,
            pinningOlderEdgeAtCapacity: true
        )

        #expect(filled.count == 500)
        #expect(filled.first?.id == "internet-0000")
        #expect(filled.last?.id == firstLive.id)
        #expect(filled.contains(where: { $0.id == excessLive.id }) == false)
    }

    @Test func liveRefreshTreatsCoveredCandidateRangeAsAuthoritative() {
        let existing = [
            message(0, source: "internet"),
            message(
                1,
                source: SNConversationTranscriptSource.paymentActivityID,
                paymentID: "replaced"
            ),
            message(
                3,
                source: SNConversationTranscriptSource.paymentActivityID,
                paymentID: "retained"
            ),
        ]
        let candidates = [
            message(0, source: "internet"),
            message(1, source: "internet", paymentID: "replaced"),
            message(
                3,
                source: SNConversationTranscriptSource.paymentActivityID,
                paymentID: "retained"
            ),
        ]

        let refreshed = SNConversationTranscriptWindow.refreshing(
            existing,
            from: candidates,
            limit: 30,
            preservingOlderEdge: false
        )

        #expect(refreshed.map(\.id) == candidates.map(\.id))
        #expect(refreshed.contains(where: { $0.id == "$payment-activity-0001" }) == false)
    }

    @Test func partialFinalPageLeavesRoomForLiveRows() {
        let older = (0..<15).map { message($0, source: "internet") }
        let previous = (15..<485).map { message($0, source: "internet") }
        let partialWindow = SNConversationTranscriptWindow.prepending(
            older,
            to: previous,
            limit: 500
        )
        let shouldPreserve = SNConversationTranscriptWindow.shouldPreserveOlderEdge(
            afterGrowingTo: 500,
            retainedLimit: 500,
            previous: previous,
            next: partialWindow
        )
        let live = message(485, source: "mesh")
        let refreshed = SNConversationTranscriptWindow.refreshing(
            partialWindow,
            from: partialWindow + [live],
            limit: 500,
            preservingOlderEdge: shouldPreserve
        )

        #expect(partialWindow.count == 485)
        #expect(shouldPreserve == false)
        #expect(refreshed.last?.id == live.id)
        #expect(refreshed.count == 486)

        // The coordinator formats only sourceLimit + 1 candidates. Reproduce
        // successive live invalidations with that fixed 486-row lookahead; the
        // render window must still accumulate to 500 without losing its anchor.
        var canonical = partialWindow + [live]
        var filled = refreshed
        for index in 486..<500 {
            canonical.append(message(index, source: "mesh"))
            filled = SNConversationTranscriptWindow.refreshing(
                filled,
                from: Array(canonical.suffix(486)),
                limit: 500,
                preservingOlderEdge: false
            )
        }
        #expect(filled.count == 500)
        #expect(filled.first?.id == "internet-0000")
        #expect(SNConversationTranscriptWindow.shouldPreserveOlderEdge(
            afterGrowingTo: 500,
            retainedLimit: 500,
            previous: refreshed,
            next: filled
        ))
    }

    @Test func foldedPartialSourceWindowsGrowIndependently() {
        let oldInternet = message(0, source: "internet")
        var meshCanonical = (100..<585).map { message($0, source: "mesh") }
        var visible = [oldInternet] + meshCanonical

        for index in 585..<599 {
            meshCanonical.append(message(index, source: "mesh"))
            let independentlyBoundedCandidates = [oldInternet] + Array(meshCanonical.suffix(486))
            visible = SNConversationTranscriptWindow.refreshing(
                visible,
                from: independentlyBoundedCandidates,
                limit: 500,
                preservingOlderEdge: false
            )
        }

        #expect(visible.count == 500)
        #expect(visible.first?.id == oldInternet.id)
        #expect(visible[1].id == "mesh-0100")
        #expect(visible.last?.id == "mesh-0598")
    }

    @Test func renderOnlyLocalSourceContinuesPastLookahead() {
        let calls = (0..<100).map {
            message($0, source: SNConversationTranscriptSource.callLogID)
        }
        let visible = Array(calls.suffix(30))
        let initialCandidates = Array(calls.suffix(31))
        let initialNeeds = SNConversationTranscriptWindow.sourceIDsNeedingExpansion(
            [
                SNConversationTranscriptSource(
                    id: SNConversationTranscriptSource.callLogID,
                    rows: initialCandidates,
                    hasMore: true
                )
            ],
            before: visible[0],
            pageSize: 30
        )

        #expect(initialNeeds == [SNConversationTranscriptSource.callLogID])
        #expect(SNConversationTranscriptWindow.localPageGrowth(
            totalRows: 100,
            sourceLimit: 30,
            newestOffset: 0,
            pageSize: 30
        ) == 30)

        let expandedCandidates = Array(calls.suffix(61))
        let expandedNeeds = SNConversationTranscriptWindow.sourceIDsNeedingExpansion(
            [
                SNConversationTranscriptSource(
                    id: SNConversationTranscriptSource.callLogID,
                    rows: expandedCandidates,
                    hasMore: true
                )
            ],
            before: visible[0],
            pageSize: 30
        )
        let page = SNConversationTranscriptWindow.nearestOlderPage(
            in: expandedCandidates,
            before: visible[0],
            pageSize: 30
        )

        #expect(expandedNeeds.isEmpty)
        #expect(page.first?.id == "$call-log-0040")
        #expect(page.last?.id == "$call-log-0069")
    }

    @Test func partialSourceLoadReportsActualGrowthWithoutEviction() {
        let before = Set((0..<480).map { "message-\($0)" })
        let after = Set((0..<485).map { "message-\($0)" })
        var result = SNConversationTranscriptLoadResult.none

        result.record(before: before, after: after)

        #expect(result.added)
        #expect(result.maxSourceGrowth == 5)
        #expect(result.movedRetainedWindow == false)
    }

    @Test func fullSourceLoadReportsActualRetainedWindowMovement() {
        let before = Set((30..<530).map { "message-\($0)" })
        let after = Set((0..<500).map { "message-\($0)" })
        var result = SNConversationTranscriptLoadResult.none

        result.record(before: before, after: after)

        #expect(result.maxSourceGrowth == 30)
        #expect(result.movedRetainedWindow)
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

    /// Regression: a message sent at the live edge, followed by scrolling deep
    /// into history before the relay ack lands, pins the render window while it
    /// still contains the optimistic echo. Once the Marmot model reconciles the
    /// echo with its canonical database row, the echo vanishes from candidates;
    /// the pinned window must drop the stale "Sending" copy and admit the
    /// sender's own canonical row in its place.
    @Test func pinnedWindowSwapsReconciledEchoForOwnCanonicalRow() {
        let history = (0..<30).map { message($0, source: "internet") }
        var echo = message(31, source: "internet")
        echo.id = "optimistic-abc"
        echo.mine = true
        echo.state = "Sending"
        echo.transcriptSourceID = nil
        var canonical = message(30, source: "internet")
        canonical.mine = true
        canonical.state = "Sent"

        let refreshed = SNConversationTranscriptWindow.refreshing(
            history + [echo],
            from: history + [canonical],
            limit: 500,
            preservingOlderEdge: true
        )

        #expect(refreshed.contains(where: { $0.id == echo.id }) == false)
        #expect(refreshed.last?.id == canonical.id)
        #expect(refreshed.last?.state == "Sent")
        #expect(refreshed.count == history.count + 1)
    }

    /// An echo still present in candidates is still pending: the pinned window
    /// must keep it (updated in place), not drop it.
    @Test func pinnedWindowKeepsStillPendingEcho() {
        let history = (0..<30).map { message($0, source: "internet") }
        var echo = message(31, source: "internet")
        echo.id = "optimistic-abc"
        echo.mine = true
        echo.state = "Sending"
        echo.transcriptSourceID = nil

        let refreshed = SNConversationTranscriptWindow.refreshing(
            history + [echo],
            from: history + [echo],
            limit: 500,
            preservingOlderEdge: true
        )

        #expect(refreshed.last?.id == echo.id)
        #expect(refreshed.count == history.count + 1)
    }

    /// Foreign live rows must keep waiting at the unseen newer edge of a
    /// pinned window: only the sender's own rows are admitted.
    @Test func pinnedWindowStillExcludesForeignLiveRows() {
        let history = (0..<30).map { message($0, source: "internet") }
        let foreignLive = message(40, source: "internet")

        let refreshed = SNConversationTranscriptWindow.refreshing(
            history,
            from: history + [foreignLive],
            limit: 500,
            preservingOlderEdge: true
        )

        #expect(refreshed.contains(where: { $0.id == foreignLive.id }) == false)
        #expect(refreshed.map(\.id) == history.map(\.id))
    }

    /// Own candidate rows older than the pinned window's newest kept row are
    /// history, not replacements — they must not be injected into the window.
    @Test func pinnedWindowDoesNotAdmitOwnOlderHistoryRows() {
        let history = (10..<40).map { message($0, source: "internet") }
        var ownOlder = message(5, source: "internet")
        ownOlder.mine = true

        let refreshed = SNConversationTranscriptWindow.refreshing(
            history,
            from: history + [ownOlder],
            limit: 500,
            preservingOlderEdge: true
        )

        #expect(refreshed.contains(where: { $0.id == ownOlder.id }) == false)
        #expect(refreshed.map(\.id) == history.map(\.id))
    }
}
