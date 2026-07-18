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
}
