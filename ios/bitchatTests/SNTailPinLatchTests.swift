//
// SNTailPinLatchTests.swift
// bitchatTests
//
// Regression coverage for the transcript tail staying pinned through
// keyboard/viewport shrinks (iOS mirror of the Android TranscriptTailPinner).
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
        // keyboardWillShow fires with the reader at the tail.
        let atStart = latch.viewportWillShrink(isNearBottom: true)
        #expect(atStart)
        // The safe-area shrink lands in layout steps; the sentinel is already
        // covered, so isNearBottom is false — the pin must still be demanded.
        let midTransition = latch.viewportWillShrink(isNearBottom: false)
        #expect(midTransition)
        let lateSettle = latch.viewportWillShrink(isNearBottom: false)
        #expect(lateSettle)
    }

    /// Once a pin delivers the sentinel back into view, the latch drops: a
    /// genuine user scroll-away afterwards must not be yanked back by the
    /// next viewport change (composer growth, keyboard re-open).
    @Test
    func userScrollAwayIsRespectedAfterTailReturns() {
        var latch = SNTailPinLatch()
        _ = latch.viewportWillShrink(isNearBottom: true)
        latch.tailVisible()
        // Reader scrolls up into history, then the viewport shrinks again.
        let afterScrollAway = latch.viewportWillShrink(isNearBottom: false)
        #expect(!afterScrollAway)
    }

    /// An unread-anchored open starts in history (never at the tail): opening
    /// the keyboard keeps the reading position, Signal-style — no pin.
    @Test
    func anchoredOpenNeverPins() {
        var latch = SNTailPinLatch()
        let first = latch.viewportWillShrink(isNearBottom: false)
        #expect(!first)
        let second = latch.viewportWillShrink(isNearBottom: false)
        #expect(!second)
    }

    /// Multi-step transitions re-latch: sentinel returns mid-animation, then
    /// the next shrink step with the reader still at the tail pins again.
    @Test
    func relatchesAcrossTransitionSteps() {
        var latch = SNTailPinLatch()
        _ = latch.viewportWillShrink(isNearBottom: true)
        latch.tailVisible()
        let relatched = latch.viewportWillShrink(isNearBottom: true)
        #expect(relatched)
        let carried = latch.viewportWillShrink(isNearBottom: false)
        #expect(carried)
    }
}
