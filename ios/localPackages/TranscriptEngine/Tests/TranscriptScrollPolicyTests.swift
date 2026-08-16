import CoreGraphics
import Testing
@testable import TranscriptEngine

struct TranscriptScrollPolicyTests {

    @Test
    func openActionFullyReadIsLiveEdge() {
        #expect(
            TranscriptScrollPolicy.openAction(
                unreadAnchorId: nil,
                unreadCountAtOpen: 0,
                unreadAnchorAbandoned: false
            ) == .liveEdge
        )
    }

    @Test
    func openActionPendingUnreadIsUnreadDividerEvenWithoutResolvedId() {
        #expect(
            TranscriptScrollPolicy.openAction(
                unreadAnchorId: nil,
                unreadCountAtOpen: 3,
                unreadAnchorAbandoned: false
            ) == .unreadDivider
        )
    }

    @Test
    func openActionJumpOverridesUnreadAndLiveEdge() {
        #expect(
            TranscriptScrollPolicy.openAction(
                unreadAnchorId: "oldest-unread",
                unreadCountAtOpen: 3,
                unreadAnchorAbandoned: false,
                jumpId: "msg-42"
            ) == .jump(id: "msg-42")
        )
    }

    @Test
    func openActionUnsetCaptureIsProvisionalLiveEdge() {
        #expect(
            TranscriptScrollPolicy.openAction(
                unreadAnchorId: nil,
                unreadCountAtOpen: nil,
                unreadAnchorAbandoned: false
            ) == .liveEdge
        )
    }

    @Test
    func openActionFrozenUnreadAnchorIsUnreadDivider() {
        #expect(
            TranscriptScrollPolicy.openAction(
                unreadAnchorId: "m:abc",
                unreadCountAtOpen: 0,
                unreadAnchorAbandoned: false
            ) == .unreadDivider
        )
        #expect(
            TranscriptScrollPolicy.openAction(
                unreadAnchorId: "m:abc",
                unreadCountAtOpen: nil,
                unreadAnchorAbandoned: false
            ) == .unreadDivider
        )
    }

    @Test
    func insetFollowPinsWhenWasAtTail() {
        #expect(
            TranscriptScrollPolicy.insetFollowDecision(
                wasAtTail: true,
                userScrolling: false,
                isPrepending: false
            ) == .pin
        )
    }

    @Test
    func insetFollowLockstepsWhenAwayFromTail() {
        #expect(
            TranscriptScrollPolicy.insetFollowDecision(
                wasAtTail: false,
                userScrolling: false,
                isPrepending: false
            ) == .lockstep
        )
    }

    @Test
    func insetFollowIgnoresWhileDraggingOrPrepending() {
        #expect(
            TranscriptScrollPolicy.insetFollowDecision(
                wasAtTail: true,
                userScrolling: true,
                isPrepending: false
            ) == .ignore
        )
    }

    @Test
    func latchViewportShrinkUsesPolicyPinDecision() {
        var latch = TranscriptTailPinLatch()
        latch.tailVisible(itemCount: 40, tailID: "40")
        let action = latch.viewportShrank(userScrolling: false, isPrepending: false)
        #expect(action == .snap)
    }

    @Test
    func continuityTokenEqualityTracksAnchorAndEdge() {
        let a = TranscriptScrollPolicy.continuityToken(anchorId: "msg-1", edgeDistance: 120)
        let b = TranscriptContinuityToken(anchorId: "msg-1", edge: .edgeDistance(120))
        #expect(a == b)
    }

    @Test
    func coalesceSecondsMatchesSignalTenMs() {
        #expect(TranscriptScrollPolicy.snapCoalesceSeconds == 0.01)
        #expect(
            TranscriptScrollPolicy.usesBottomScrollAnchor(
                unreadAnchorId: nil,
                unreadCountAtOpen: 0,
                unreadAnchorAbandoned: false
            )
        )
    }

    /// Collection-host open recovery must keep `needsLiveEdgeOpen` until owned
    /// chrome has been applied — "near" against a pre-chrome maxY is not the
    /// live edge (MsgList waits for the `sn-bottom` sentinel).
    @Test
    func clearLiveEdgeOpenRequiresOwnedChrome() {
        #expect(
            !TranscriptScrollPolicy.shouldClearLiveEdgeOpen(
                isNearBottom: true,
                ownedChromeApplied: false
            )
        )
        #expect(
            TranscriptScrollPolicy.shouldClearLiveEdgeOpen(
                isNearBottom: true,
                ownedChromeApplied: true
            )
        )
        #expect(
            !TranscriptScrollPolicy.shouldClearLiveEdgeOpen(
                isNearBottom: false,
                ownedChromeApplied: true
            )
        )
    }

    /// Snapshot layout can fire `scrollViewDidScroll` before the live-edge
    /// latch is armed; that must not set `hasLeftBottom` and kill resnap.
    @Test
    func markLeftBottomIgnoresProgrammaticLiveEdgeOpen() {
        #expect(
            !TranscriptScrollPolicy.shouldMarkLeftBottom(
                needsLiveEdgeOpen: true,
                wasPinned: false,
                userDragging: false
            )
        )
        #expect(
            TranscriptScrollPolicy.shouldMarkLeftBottom(
                needsLiveEdgeOpen: false,
                wasPinned: false,
                userDragging: false
            )
        )
        #expect(
            !TranscriptScrollPolicy.shouldMarkLeftBottom(
                needsLiveEdgeOpen: false,
                wasPinned: true,
                userDragging: false
            )
        )
        #expect(
            TranscriptScrollPolicy.shouldMarkLeftBottom(
                needsLiveEdgeOpen: false,
                wasPinned: true,
                userDragging: true
            )
        )
    }

    @Test
    func unchangedApplySkipsOnlyWhenVersionAndOpenInputsMatch() {
        // Nil version (generic hosts) must always apply.
        #expect(
            !TranscriptScrollPolicy.shouldSkipUnchangedApply(
                contentVersion: nil, lastContentVersion: nil,
                unreadCountAtOpen: nil, lastUnreadCountAtOpen: nil,
                jumpMessageId: nil, lastJumpMessageId: nil,
                expectedNewestDate: nil, lastExpectedNewestDate: nil
            )
        )
        // Same version + same open inputs: composer keystroke / unrelated
        // store publish — skip the snapshot rebuild.
        #expect(
            TranscriptScrollPolicy.shouldSkipUnchangedApply(
                contentVersion: 7, lastContentVersion: 7,
                unreadCountAtOpen: 0, lastUnreadCountAtOpen: 0,
                jumpMessageId: nil, lastJumpMessageId: nil,
                expectedNewestDate: nil, lastExpectedNewestDate: nil
            )
        )
        // Content bump must apply.
        #expect(
            !TranscriptScrollPolicy.shouldSkipUnchangedApply(
                contentVersion: 8, lastContentVersion: 7,
                unreadCountAtOpen: 0, lastUnreadCountAtOpen: 0,
                jumpMessageId: nil, lastJumpMessageId: nil,
                expectedNewestDate: nil, lastExpectedNewestDate: nil
            )
        )
        // Late unread-count settle or a new jump target must apply even when
        // the transcript itself is unchanged.
        #expect(
            !TranscriptScrollPolicy.shouldSkipUnchangedApply(
                contentVersion: 7, lastContentVersion: 7,
                unreadCountAtOpen: 3, lastUnreadCountAtOpen: 0,
                jumpMessageId: nil, lastJumpMessageId: nil,
                expectedNewestDate: nil, lastExpectedNewestDate: nil
            )
        )
        #expect(
            !TranscriptScrollPolicy.shouldSkipUnchangedApply(
                contentVersion: 7, lastContentVersion: 7,
                unreadCountAtOpen: 0, lastUnreadCountAtOpen: 0,
                jumpMessageId: "m1", lastJumpMessageId: nil,
                expectedNewestDate: nil, lastExpectedNewestDate: nil
            )
        )
    }

    /// A resting offset above `minY` is the blank-chat shape: with a short-feed
    /// top inset the rows sit entirely below the viewport, and the overshoot-only
    /// correction returned nil for it.
    @Test
    func restingOffsetCorrectionPullsBackFromBothEnds() {
        // Short feed: content 120, viewport 500, composer 56 ⇒ topInset 324,
        // and -324 is the single valid resting offset.
        #expect(
            transcriptRestingOffsetCorrection(
                offsetY: -664, boundsHeight: 500, contentHeight: 120,
                topInset: 324, bottomInset: 56
            ) == -324
        )
        #expect(
            transcriptRestingOffsetCorrection(
                offsetY: -324, boundsHeight: 500, contentHeight: 120,
                topInset: 324, bottomInset: 56
            ) == nil
        )
        // Overshoot past the live edge still clamps down (tall feed).
        #expect(
            transcriptRestingOffsetCorrection(
                offsetY: 2400, boundsHeight: 500, contentHeight: 2672,
                topInset: 0, bottomInset: 56
            ) == 2228
        )
        // In-range reading position is left alone.
        #expect(
            transcriptRestingOffsetCorrection(
                offsetY: 1200, boundsHeight: 500, contentHeight: 2672,
                topInset: 0, bottomInset: 56
            ) == nil
        )
        // Sub-pixel drift is not a correction (avoids offset ping-pong).
        #expect(
            transcriptRestingOffsetCorrection(
                offsetY: -324.4, boundsHeight: 500, contentHeight: 120,
                topInset: 324, bottomInset: 56
            ) == nil
        )
    }
}
