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
