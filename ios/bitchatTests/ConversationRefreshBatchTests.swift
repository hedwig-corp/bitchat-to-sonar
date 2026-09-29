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

    @Test func aFailedHydrationFallsBackToEveryChangedPage() {
        // #629 review: the burst path removed every changed id before one
        // summaries hydrate; a transient failure there dropped them all.
        let changed = Set((0..<40).map { "g\($0)" })
        let plan = snConversationRefreshPlan(changed: changed, viewing: ["g7"], threshold: 16)
        #expect(
            snConversationRefreshPageGroups(plan: plan, changed: changed, summariesHydrated: true)
                == ["g7"]
        )
        #expect(
            snConversationRefreshPageGroups(plan: plan, changed: changed, summariesHydrated: false)
                == changed.sorted()
        )
        let small = snConversationRefreshPlan(changed: ["a", "b"], viewing: [], threshold: 16)
        #expect(
            snConversationRefreshPageGroups(plan: small, changed: ["a", "b"], summariesHydrated: false)
                == ["a", "b"],
            "no burst, no hydrate: the plan's pages stand"
        )
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
