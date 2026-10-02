//
// MarmotTranscriptPageSplitTests.swift
// bitchatTests
//

import Foundation
import Testing
@testable import Sonar

/// A folded chat pages its groups as one merged core page; the window is split
/// back so echoes, side effects and unread keep reading per group.
struct MarmotTranscriptPageSplitTests {
    private func row(_ id: String, at secs: TimeInterval, group: String?) -> MarmotService.MarmotMessage {
        MarmotService.MarmotMessage(
            id: id,
            senderNpub: "npub1sara",
            content: id,
            createdAt: Date(timeIntervalSince1970: secs),
            isMine: false,
            media: [],
            groupId: group
        )
    }

    @Test
    func aMergedPageSplitsBackByEachRowsGroup() {
        let canonical = [row("a1", at: 1, group: "aa"), row("b1", at: 2, group: "bb"), row("a2", at: 3, group: "aa")]
        let echo = row("optimistic-1", at: 4, group: nil)
        let split = MarmotChatModel.splitLocalTranscriptPage(
            canonical: canonical,
            echoes: [echo],
            page: canonical,
            groups: ["aa", "bb"],
            origin: ["optimistic-1": "bb"],
            fallback: "aa"
        )
        #expect(split.byGroup["aa"]?.map(\.id) == ["a1", "a2"])
        #expect(split.byGroup["bb"]?.map(\.id) == ["b1", "optimistic-1"], "the echo stays in the window it was sent from")
        #expect(split.fresh["aa"]?.map(\.id) == ["a1", "a2"])
        #expect(split.fresh["bb"]?.map(\.id) == ["b1"])
    }

    /// A quiet group with no row on the newest merged page gets an empty
    /// window, not a stale one, and rows with no group stay where they were.
    @Test
    func aQuietGroupAndUntaggedRowsKeepTheirPlace() {
        let snapshotRow = row("old", at: 1, group: nil)
        let split = MarmotChatModel.splitLocalTranscriptPage(
            canonical: [snapshotRow, row("a1", at: 2, group: "aa")],
            echoes: [],
            page: [],
            groups: ["aa", "bb"],
            origin: ["old": "aa"],
            fallback: "aa"
        )
        #expect(split.byGroup["aa"]?.map(\.id) == ["old", "a1"])
        #expect(split.byGroup["bb"]?.isEmpty == true)
    }

    /// One group: everything stays in it, exactly as the per-group pager did.
    @Test
    func aSingleGroupPagesAsBefore() {
        let rows = [row("x1", at: 1, group: "solo"), row("x2", at: 2, group: nil)]
        let split = MarmotChatModel.splitLocalTranscriptPage(
            canonical: rows, echoes: [], page: rows,
            groups: ["solo"], origin: [:], fallback: "solo"
        )
        #expect(split.byGroup["solo"]?.map(\.id) == ["x1", "x2"])
        #expect(split.fresh["solo"]?.map(\.id) == ["x1", "x2"])
    }
}
