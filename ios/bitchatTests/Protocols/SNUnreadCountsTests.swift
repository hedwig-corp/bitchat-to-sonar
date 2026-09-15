//
// SNUnreadCountsTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import Sonar

struct SNUnreadCountsTests {
    @Test
    func unreadByGroupSkipsZeroAndSuppressed() {
        let summaries: [(groupIdHex: String, unreadCount: UInt64)] = [
            ("g-read", 0),
            ("g-open", 3),
            ("g-other", 2),
        ]
        let map = SNUnreadCounts.unreadByGroup(
            from: summaries,
            suppressing: ["g-open"]
        )
        #expect(map == ["g-other": 2])
    }

    @Test
    func failedSummariesProbeDoesNotPublishUnread() {
        let emptyInbox: [String]? = []
        let failed: [String]? = nil
        #expect(SNUnreadCounts.shouldPublish(emptyInbox))
        #expect(!SNUnreadCounts.shouldPublish(failed))
        let unread: [(groupIdHex: String, unreadCount: UInt64)] = [
            ("group-08", 4),
            ("other", 1),
        ]
        #expect(SNUnreadCounts.openCount(from: unread, wanted: ["group-08"]) == 4)
        #expect(SNUnreadCounts.openCount(from: [], wanted: ["group-08"]) == 0)
        #expect(SNUnreadCounts.openCount(from: nil, wanted: ["group-08"]) == nil)
    }

    @Test
    func liveOnlyProbeKeepsHistUnreadWhenLiveBadgeIsZero() {
        let folds = ["group-08": "group-09"]
        let previous: [String: UInt64] = ["group-08": 4]
        let liveOnly = SNUnreadCounts.unreadByGroup(
            from: [("group-09", 0)],
            suppressing: []
        )
        let kept = SNUnreadCounts.remountFoldedUnread(
            next: liveOnly,
            previous: previous,
            historicalFolds: folds
        )
        #expect(kept == ["group-08": 4])
        #expect(
            snUnreadForFoldFamily(
                groupId: "group-09",
                unreadByGroup: kept,
                historicalFolds: folds
            ) == 4
        )
        let afterCopy = SNUnreadCounts.remountFoldedUnread(
            next: SNUnreadCounts.unreadByGroup(
                from: [("group-09", 4)],
                suppressing: []
            ),
            previous: previous,
            historicalFolds: folds
        )
        #expect(afterCopy == ["group-09": 4])
        #expect(
            snUnreadForFoldFamily(
                groupId: "group-09",
                unreadByGroup: afterCopy,
                historicalFolds: folds
            ) == 4
        )
        #expect(
            SNUnreadCounts.remountFoldedUnread(
                next: [:],
                previous: previous,
                historicalFolds: folds
            ) == ["group-08": 4]
        )
        #expect(
            SNUnreadCounts.remountFoldedUnread(
                next: [:],
                previous: previous,
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-08": 4]
        )
        #expect(
            SNUnreadCounts.remountFoldedUnread(
                next: [:],
                previous: previous,
                historicalFolds: [:]
            ).isEmpty
        )
        #expect(
            SNUnreadCounts.remountFoldedUnread(
                next: ["group-09": 4],
                previous: previous,
                historicalFolds: [:],
                openedConversationId: "group-09",
                openedConversationPaneId: "group-08"
            ) == ["group-09": 4]
        )
    }

    @Test
    func recoveredFoldUnreadDoesNotRetireBeforeFamilyHasOlder() {
        let histNewest = Date(timeIntervalSince1970: 50)
        let liveNewest = Date(timeIntervalSince1970: 10)
        #expect(
            !SNUnreadCounts.shouldRetireOpenUnread(
                unreadAtOpen: 4,
                anchorFound: false,
                feedNewest: liveNewest,
                expectedNewest: histNewest,
                familyHasOlder: false
            )
        )
        #expect(
            !SNUnreadCounts.shouldRetireOpenUnread(
                unreadAtOpen: 4,
                anchorFound: false,
                feedNewest: Date(timeIntervalSince1970: 80),
                expectedNewest: histNewest,
                familyHasOlder: true
            )
        )
        #expect(
            SNUnreadCounts.shouldRetireOpenUnread(
                unreadAtOpen: 4,
                anchorFound: false,
                feedNewest: Date(timeIntervalSince1970: 80),
                expectedNewest: histNewest,
                familyHasOlder: false
            )
        )
        #expect(
            !SNUnreadCounts.shouldRetireOpenUnread(
                unreadAtOpen: 4,
                anchorFound: true,
                feedNewest: liveNewest,
                expectedNewest: histNewest,
                familyHasOlder: false
            )
        )
        #expect(
            !SNUnreadCounts.shouldRetireOpenUnread(
                unreadAtOpen: 0,
                anchorFound: false,
                feedNewest: liveNewest,
                expectedNewest: histNewest,
                familyHasOlder: false
            )
        )
    }

    @Test
    func pruneKeepsOnlyGroupsStillUnreadInCore() {
        let suppressed: Set<String> = ["g-inflight", "g-done", "g-missing"]
        let summaries: [(groupIdHex: String, unreadCount: UInt64)] = [
            ("g-inflight", 2),
            ("g-done", 0),
        ]
        #expect(
            SNUnreadCounts.pruneConfirmedSuppressions(suppressed, summaries: summaries)
                == ["g-inflight"]
        )
    }
}
