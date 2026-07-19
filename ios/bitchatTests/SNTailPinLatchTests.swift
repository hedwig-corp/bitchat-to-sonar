//
// SNTailPinLatchTests.swift
// bitchatTests
//
// Regression coverage for the transcript tail staying pinned through content
// and viewport changes (iOS mirror of the Android TranscriptTailPinner).
// This is free and unencumbered software released into the public domain.
//

import Testing
import TranscriptEngine
@testable import Sonar

struct SNTailPinLatchTests {

    @Test
    func tailRevisionTracksOnlyCountAndLiveEdge() {
        let original = SNTailRevision(itemCount: 100, tailID: "old-tail")
        #expect(original == SNTailRevision(itemCount: 100, tailID: "old-tail"))
        #expect(original != SNTailRevision(itemCount: 100, tailID: "new-tail"))
        #expect(original != SNTailRevision(itemCount: 99, tailID: "old-tail"))
    }

    /// Signal's 10 ms last-event-only limiter means a burst of safe-area
    /// updates owns one pending correction instead of one main-queue job each.
    @Test
    func tailSnapBurstCoalescesUntilDelivery() {
        var coalescer = SNTailSnapCoalescer()
        let firstRequest = coalescer.request()
        #expect(firstRequest)
        for _ in 0..<30 {
            let duplicateRequest = coalescer.request()
            #expect(!duplicateRequest)
        }
        let firstDelivery = coalescer.consume()
        let duplicateDelivery = coalescer.consume()
        let nextRequest = coalescer.request()
        #expect(firstDelivery)
        #expect(!duplicateDelivery)
        #expect(nextRequest)
    }

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

    /// A chat that first paints under a keyboard-sized safe area, then expands
    /// when that inset clears (keyboard never shown / already dismissed), must
    /// keep the tail — otherwise the transcript stays top-stranded with a
    /// phantom empty band above the composer until close/re-open.
    @Test
    func expandKeepsPinningAfterPhantomKeyboardInsetClears() {
        var latch = SNTailPinLatch()
        latch.tailVisible(itemCount: 6, tailID: "6")
        #expect(latch.viewportExpanded(userScrolling: false, isPrepending: false) == .snap)
        latch.userScrolled(isNearBottom: false)
        #expect(latch.viewportExpanded(userScrolling: false, isPrepending: false) == .none)
    }

    /// Signal's `updateContentInsets` clamps a resting reader to
    /// `maxContentOffsetY` after the keyboard inset shrinks. Without the
    /// clamp, dismissing the keyboard away from the tail leaves a
    /// keyboard-sized blank band under the last message.
    @Test
    func keyboardDismissOvershootIsClampedToContentBounds() {
        // Reader mid-history; keyboard dismissed grew bounds 400 -> 700,
        // offset now rests past the new maximum.
        let corrected = snRestingOffsetOvershootCorrection(
            offsetY: 900,
            boundsHeight: 700,
            contentHeight: 1500,
            topInset: 0,
            bottomInset: 60
        )
        #expect(corrected == 860)

        // At rest within bounds: no programmatic move.
        let atRest = snRestingOffsetOvershootCorrection(
            offsetY: 500,
            boundsHeight: 700,
            contentHeight: 1500,
            topInset: 0,
            bottomInset: 60
        )
        #expect(atRest == nil)

        // Short chat (content shorter than viewport): Signal's max() floor —
        // rest is top-aligned at -topInset, never a negative scroll band.
        let shortChat = snRestingOffsetOvershootCorrection(
            offsetY: 200,
            boundsHeight: 700,
            contentHeight: 300,
            topInset: 50,
            bottomInset: 60
        )
        #expect(shortChat == -50)
    }

    /// Spike A owns bottom inset as barHeight − safeArea (Signal
    /// `updateContentInsets`); production sibling-composer path stays 0.
    @Test
    func spikeAOwnedBottomInsetTracksBarMinusSafeArea() {
        #expect(snSpikeAOwnedBottomContentInset(barHeight: 336, safeAreaBottom: 34) == 302)
        #expect(snSpikeAOwnedBottomContentInset(barHeight: 20, safeAreaBottom: 34) == 0)
        #expect(snOwnedTranscriptBottomContentInset(automaticBottomInset: 336) == 0)
    }

    /// Composer is a sibling ⇒ owned bottom inset is always 0. Fully-read
    /// opens use a bottom scroll anchor; unread opens must not.
    @Test
    func transcriptOpenUsesBottomAnchorOnlyWhenFullyRead() {
        #expect(snOwnedTranscriptBottomContentInset(automaticBottomInset: 336) == 0)
        #expect(
            snUsesBottomScrollAnchor(
                unreadAnchorId: nil,
                unreadCountAtOpen: 0,
                unreadAnchorAbandoned: false
            )
        )
        #expect(
            !snUsesBottomScrollAnchor(
                unreadAnchorId: nil,
                unreadCountAtOpen: 3,
                unreadAnchorAbandoned: false
            )
        )
        #expect(
            !snUsesBottomScrollAnchor(
                unreadAnchorId: "oldest-unread",
                unreadCountAtOpen: 3,
                unreadAnchorAbandoned: false
            )
        )
        #expect(
            snScrollToBottomOfLoadWindowOffsetY(
                boundsHeight: 700,
                contentHeight: 2000,
                topInset: 0,
                bottomInset: 0
            ) == 1300
        )
    }

    /// Alpha.11 still opened fully-read DMs mid-history: one async `scrollTo`
    /// lost to LazyVStack under-measure and the latch never re-snapped.
    /// Keep recovering until the live-edge sentinel lands (or the user scrolls).
    @Test
    func fullyReadOpenResnapsUntilLiveEdgeLands() {
        #expect(
            snShouldResnapFullyReadOpen(
                usesBottomScrollAnchor: true,
                needsLiveEdgeOpen: true,
                hasLeftBottom: false,
                userScrolling: false,
                hasTailRow: true
            )
        )
        #expect(
            !snShouldResnapFullyReadOpen(
                usesBottomScrollAnchor: true,
                needsLiveEdgeOpen: false,
                hasLeftBottom: false,
                userScrolling: false,
                hasTailRow: true
            )
        )
        #expect(
            !snShouldResnapFullyReadOpen(
                usesBottomScrollAnchor: true,
                needsLiveEdgeOpen: true,
                hasLeftBottom: true,
                userScrolling: false,
                hasTailRow: true
            )
        )
        #expect(
            !snShouldResnapFullyReadOpen(
                usesBottomScrollAnchor: true,
                needsLiveEdgeOpen: true,
                hasLeftBottom: false,
                userScrolling: true,
                hasTailRow: true
            )
        )
        #expect(
            !snShouldResnapFullyReadOpen(
                usesBottomScrollAnchor: false,
                needsLiveEdgeOpen: true,
                hasLeftBottom: false,
                userScrolling: false,
                hasTailRow: true
            )
        )
        #expect(
            !snShouldResnapFullyReadOpen(
                usesBottomScrollAnchor: true,
                needsLiveEdgeOpen: true,
                hasLeftBottom: false,
                userScrolling: false,
                hasTailRow: false
            )
        )
    }

    /// Collection host must not end live-edge open recovery on "near bottom"
    /// measured before owned composer chrome lands — that maxY is short of the
    /// true live edge and leaves the last message a flick below the fold.
    @Test
    func clearLiveEdgeOpenRequiresOwnedChrome() {
        #expect(
            !snShouldClearLiveEdgeOpen(isNearBottom: true, ownedChromeApplied: false)
        )
        #expect(
            snShouldClearLiveEdgeOpen(isNearBottom: true, ownedChromeApplied: true)
        )
        #expect(
            !snShouldClearLiveEdgeOpen(isNearBottom: false, ownedChromeApplied: true)
        )
    }

    /// Pre-latch `scrollViewDidScroll` during snapshot layout must not set
    /// `hasLeftBottom` and abort `shouldResnapFullyReadOpen`.
    @Test
    func markLeftBottomIgnoresProgrammaticLiveEdgeOpen() {
        #expect(
            !snShouldMarkLeftBottom(
                needsLiveEdgeOpen: true,
                wasPinned: false,
                userDragging: false
            )
        )
        #expect(
            snShouldMarkLeftBottom(
                needsLiveEdgeOpen: false,
                wasPinned: false,
                userDragging: false
            )
        )
        #expect(
            !snShouldMarkLeftBottom(
                needsLiveEdgeOpen: false,
                wasPinned: true,
                userDragging: false
            )
        )
        #expect(
            snShouldMarkLeftBottom(
                needsLiveEdgeOpen: false,
                wasPinned: true,
                userDragging: true
            )
        )
    }

    /// Signal captures this state before changing its collection-view inset.
    /// The keyboard notification must do the same before SwiftUI publishes
    /// the safe-area shrink or its offset clamp.
    @Test
    func keyboardFrameChangeCapturesVisibleTailBeforeShrink() {
        var latch = SNTailPinLatch()
        #expect(
            latch.viewportWillChange(
                isNearBottom: true,
                userScrolling: false,
                isPrepending: false
            ) == .snap
        )
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

    /// UIKit may report the offset clamp before the keyboard safe-area change,
    /// so the instantaneous bounds/inset sample still looks unchanged. The
    /// frame-transition bracket must prevent that ordering gap from unpinning.
    @Test
    func preLayoutKeyboardClampIsNotUserScroll() {
        var classifier = SNUserScrollOffsetClassifier()
        classifier.reset(y: 900, viewportHeight: 700, bottomInset: 0)
        let activity = classifier.observe(
            y: 600,
            viewportHeight: 700,
            bottomInset: 0,
            isAtBottom: false,
            isTouchScrolling: false,
            isViewportTransitioning: true
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
