//
// SNTailPinLatchTests.swift
// bitchatTests
//
// Regression coverage for the transcript tail staying pinned through content
// and viewport changes (iOS mirror of the Android TranscriptTailPinner).
// This is free and unencumbered software released into the public domain.
//

import Testing
@testable import Sonar

struct SNTailPinLatchTests {

    /// The regression: the keyboard's own shrink covers the bottom sentinel,
    /// flipping live "near bottom" state false mid-transition. A guard on the
    /// live state alone stops re-pinning exactly when the pin is needed and
    /// strands the transcript behind the keyboard for the rest of the open.
    @Test
    func shrinkKeepsPinningWhileSentinelIsCovered() {
        var latch = SNTailPinLatch()
        latch.tailVisible(itemCount: 40, tailID: "40")
        #expect(latch.viewportShrank(userScrolling: false, isPrepending: false) == .snap)
        // The sentinel is covered now, but the prior pinned frame still owns
        // every later keyboard-animation step.
        #expect(latch.viewportShrank(userScrolling: false, isPrepending: false) == .snap)
    }

    /// Once a pin delivers the sentinel back into view, a genuine user
    /// scroll-away afterwards must not be yanked back by the next viewport
    /// change (composer growth, keyboard re-open).
    @Test
    func userScrollAwayIsRespectedAfterTailReturns() {
        var latch = SNTailPinLatch()
        latch.tailVisible(itemCount: 40, tailID: "40")
        latch.userScrolled(isNearBottom: false)
        #expect(latch.viewportShrank(userScrolling: false, isPrepending: false) == .none)
    }

    /// Reaching the tail again consumes the UI's transient user-scroll marker
    /// before re-arming this state, so an immediate keyboard shrink still pins.
    @Test
    func returningToTailRearmsAfterUserScroll() {
        var latch = SNTailPinLatch()
        latch.tailVisible(itemCount: 40, tailID: "40")
        latch.userScrolled(isNearBottom: false)
        latch.tailVisible(itemCount: 40, tailID: "40")
        #expect(latch.viewportShrank(userScrolling: false, isPrepending: false) == .snap)
    }

    /// An unread-anchored open starts in history (never at the tail): opening
    /// the keyboard keeps the reading position, Signal-style — no pin.
    @Test
    func anchoredOpenNeverPins() {
        var latch = SNTailPinLatch()
        latch.openInHistory(itemCount: 40, tailID: "40")
        #expect(latch.viewportShrank(userScrolling: false, isPrepending: false) == .none)
    }

    /// A keyboard notification without a real safe-area shrink (floating iPad
    /// keyboard) creates no sticky latch that can yank a later history reader.
    @Test
    func keyboardShowWithoutShrinkDoesNotLeaveStickyPin() {
        var latch = SNTailPinLatch()
        latch.tailVisible(itemCount: 40, tailID: "40")
        // No viewport event occurs. The next real event is the user's scroll.
        latch.userScrolled(isNearBottom: false)
        #expect(latch.viewportShrank(userScrolling: false, isPrepending: false) == .none)
    }

    @Test
    func nonKeyboardLayoutTheftSnapsBack() {
        var latch = SNTailPinLatch()
        latch.tailVisible(itemCount: 40, tailID: "40")
        #expect(
            latch.tailHidden(
                itemCount: 40,
                tailID: "40",
                userScrolling: false,
                isPrepending: false
            ) == .snap
        )
    }

    @Test
    func appendedOutgoingRowAtTailFollows() {
        var latch = SNTailPinLatch()
        latch.tailVisible(itemCount: 40, tailID: "40")
        #expect(
            latch.itemsChanged(
                itemCount: 41,
                tailID: "outgoing-41",
                isNearBottom: false,
                userScrolling: false,
                isPrepending: false
        ) == .animate
        )
    }

    /// A full retained window replaces its oldest row when a send arrives,
    /// so the count stays constant while the live-edge ID changes.
    @Test
    func replacedTailAtCapacityStillFollows() {
        var latch = SNTailPinLatch()
        latch.tailVisible(itemCount: 100, tailID: "old-tail")
        #expect(
            latch.itemsChanged(
                itemCount: 100,
                tailID: "new-tail",
                isNearBottom: true,
                userScrolling: false,
                isPrepending: false
            ) == .animate
        )
    }

    @Test
    func historyPrependNeverYanksToTail() {
        var latch = SNTailPinLatch()
        latch.tailVisible(itemCount: 40, tailID: "40")
        #expect(
            latch.itemsChanged(
                itemCount: 80,
                tailID: "40",
                // Event ordering can leave the old short transcript's
                // sentinel visible during the count update. Prepending still
                // owns the position and must unpin unconditionally.
                isNearBottom: true,
                userScrolling: false,
                isPrepending: true
            ) == .none
        )
        #expect(!latch.wasPinned)
    }

    @Test
    func userScrollThatHidesTailNeverRepins() {
        var latch = SNTailPinLatch()
        latch.tailVisible(itemCount: 40, tailID: "40")
        #expect(
            latch.tailHidden(
                itemCount: 40,
                tailID: "40",
                userScrolling: true,
                isPrepending: false
            ) == .none
        )
        #expect(latch.viewportShrank(userScrolling: false, isPrepending: false) == .none)
    }

    /// UIKit leaves its touch flags false for status-bar scroll-to-top and
    /// accessibility paging, so an offset moving toward history must still
    /// count as the user's scroll-away.
    @Test
    func nonTouchScrollTowardTopCountsAsUserScroll() {
        var classifier = SNUserScrollOffsetClassifier()
        classifier.reset(y: 900, viewportHeight: 600, bottomInset: 0)
        let activity = classifier.observe(
            y: 500,
            viewportHeight: 600,
            bottomInset: 0,
            isAtBottom: false,
            isTouchScrolling: false
        )
        #expect(activity == .towardHistory)
        #expect(snShouldRecordUserScroll(activity, isNearBottom: false))
    }

    /// Tail-following and keyboard adjustments move the offset toward the
    /// bottom. They must not be mistaken for non-touch user scrolling.
    @Test
    func programmaticTailFollowIsNotUserScroll() {
        var classifier = SNUserScrollOffsetClassifier()
        classifier.reset(y: 500, viewportHeight: 600, bottomInset: 0)
        let activity = classifier.observe(
            y: 900,
            viewportHeight: 600,
            bottomInset: 0,
            isAtBottom: true,
            isTouchScrolling: false
        )
        #expect(activity == .none)
    }

    /// The tail sentinel can appear before UIKit's downward deceleration ends.
    /// Remaining frames must not recreate the debounce the sentinel consumed.
    @Test
    func downwardDecelerationAtVisibleTailIsIgnored() {
        var classifier = SNUserScrollOffsetClassifier()
        classifier.reset(y: 500, viewportHeight: 600, bottomInset: 0)
        let activity = classifier.observe(
            y: 600,
            viewportHeight: 600,
            bottomInset: 0,
            isAtBottom: true,
            isTouchScrolling: true
        )
        #expect(activity == .towardTail)
        #expect(!snShouldRecordUserScroll(activity, isNearBottom: true))
    }

    /// Keyboard dismissal expands the native viewport and clamps its bottom
    /// offset upward. That is layout bookkeeping, not status-bar scrolling.
    @Test
    func layoutDrivenUpwardOffsetIsNotUserScroll() {
        var classifier = SNUserScrollOffsetClassifier()
        classifier.reset(y: 900, viewportHeight: 400, bottomInset: 300)
        let activity = classifier.observe(
            y: 600,
            viewportHeight: 700,
            bottomInset: 0,
            isAtBottom: true,
            isTouchScrolling: false
        )
        #expect(activity == .none)
    }

    /// If a prior resize did not move the offset, a later accessibility or
    /// status-bar scroll still leaves the tail and must not be hidden merely
    /// because the classifier's last viewport sample is stale.
    @Test
    func nonTouchHistoryScrollAfterResizeStillCounts() {
        var classifier = SNUserScrollOffsetClassifier()
        classifier.reset(y: 900, viewportHeight: 400, bottomInset: 300)
        let activity = classifier.observe(
            y: 500,
            viewportHeight: 700,
            bottomInset: 0,
            isAtBottom: false,
            isTouchScrolling: false
        )
        #expect(activity == .towardHistory)
    }
}
