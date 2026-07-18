//
// SNTranscriptSpikeBTests.swift
// bitchatTests
//
// Spike B reverse-feed / unread / pagination policy tests (Signal-Android model).
//

import Testing
@testable import Sonar

struct SNTranscriptSpikeBTests {

    @Test
    func reverseFeedPutsNewestAtIndexZero() {
        let chrono = [
            SpikeBMessage(id: "a", text: "oldest", mine: false),
            SpikeBMessage(id: "b", text: "mid", mine: true),
            SpikeBMessage(id: "c", text: "newest", mine: false),
        ]
        let reverse = spikeBBuildReverseFeed(chronologicalOldestFirst: chrono, unreadFromNewest: 0)
        #expect(reverse.map(\.id) == ["c", "b", "a"])
    }

    @Test
    func unreadAnchorCountsNonMineFromNewestEdge() {
        let chrono = [
            SpikeBMessage(id: "1", text: "old peer", mine: false),
            SpikeBMessage(id: "2", text: "me", mine: true),
            SpikeBMessage(id: "3", text: "peer", mine: false),
            SpikeBMessage(id: "4", text: "peer-new", mine: false),
            SpikeBMessage(id: "5", text: "me-new", mine: true),
        ]
        let reverse = spikeBBuildReverseFeed(chronologicalOldestFirst: chrono, unreadFromNewest: 2)
        #expect(reverse.first?.id == "5")
        #expect(reverse.first(where: { $0.isUnreadAnchor })?.id == "3")
        #expect(reverse.firstIndex(where: { $0.isUnreadAnchor }) == 2)
    }

    @Test
    func initialScrollPrefersUnreadDividerOverTail() {
        #expect(spikeBInitialScrollIndex(unreadAnchorIndex: 4, itemCount: 10) == 4)
        #expect(spikeBInitialScrollIndex(unreadAnchorIndex: -1, itemCount: 10) == 0)
        #expect(spikeBInitialScrollIndex(unreadAnchorIndex: 99, itemCount: 10) == 0)
    }

    @Test
    func loadOlderTriggersAtVisualTopHighIndices() {
        #expect(spikeBShouldLoadOlder(didInitialScroll: true, totalItems: 40, highestVisibleIndex: 38))
        #expect(!spikeBShouldLoadOlder(didInitialScroll: true, totalItems: 40, highestVisibleIndex: 2))
        #expect(!spikeBShouldLoadOlder(didInitialScroll: false, totalItems: 40, highestVisibleIndex: 39))
    }

    @Test
    func reverseTailLatchSnapsOnViewportShrinkWhilePinned() {
        var latch = SNTailPinLatchSpikeB()
        latch.tailVisible(itemCount: 5)
        #expect(latch.viewportShrank(userScrolling: false, isPrepending: false) == .snap)
        #expect(latch.viewportShrank(userScrolling: false, isPrepending: false) == .snap)
    }

    @Test
    func reverseTailLatchRespectsUserScrollAway() {
        var latch = SNTailPinLatchSpikeB()
        latch.tailVisible(itemCount: 5)
        latch.userScrolled(isNearTail: false)
        #expect(latch.viewportShrank(userScrolling: false, isPrepending: false) == .none)
    }

    @Test
    func reverseTailLatchIgnoresHistoryPrepend() {
        var latch = SNTailPinLatchSpikeB()
        latch.tailVisible(itemCount: 5)
        #expect(
            latch.itemsChanged(
                itemCount: 25,
                appendedAtTail: true,
                userScrolling: false,
                isPrepending: true
            ) == .none
        )
    }
}
