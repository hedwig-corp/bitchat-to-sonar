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
}
