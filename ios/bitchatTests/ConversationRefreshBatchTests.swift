//
// ConversationRefreshBatchTests.swift
// bitchatTests
//
// A burst of conversation changes hydrates the chat list once instead of
// reloading a page per chat (alpha.15 plan, item 2).
// This is free and unencumbered software released into the public domain.
//

import Foundation
import Testing
@testable import Sonar

struct ConversationRefreshBatchTests {
    @Test func smallBatchesReloadEveryChangedPage() {
        let plan = snConversationRefreshPlan(
            changed: ["a", "b", "c"],
            viewing: ["b"],
            threshold: 16
        )
        #expect(plan.reloadSummaries == false)
        #expect(plan.pageGroups == ["a", "b", "c"])
    }

    @Test func aBurstHydratesSummariesOnceAndPagesOnlyViewedChats() {
        let changed = Set((0..<40).map { "g\($0)" })
        let plan = snConversationRefreshPlan(
            changed: changed,
            viewing: ["g7", "not-in-the-burst"],
            threshold: 16
        )
        #expect(plan.reloadSummaries == true)
        #expect(plan.pageGroups == ["g7"])
    }

    @Test func theThresholdIsExclusive() {
        let sixteen = Set((0..<16).map { "g\($0)" })
        #expect(
            snConversationRefreshPlan(changed: sixteen, viewing: [], threshold: 16)
                .reloadSummaries == false
        )
        #expect(
            snConversationRefreshPlan(
                changed: sixteen.union(["g16"]),
                viewing: [],
                threshold: 16
            ).reloadSummaries == true
        )
    }
}
