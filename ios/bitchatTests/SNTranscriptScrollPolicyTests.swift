//
// SNTranscriptScrollPolicyTests.swift
// bitchatTests
//
// Phase 1 policy invariants for Signal-shaped transcript open / inset /
// continuity. These fail if open-action or wasAtTail→pin|lockstep|ignore
// semantics drift from docs/SIGNAL-TRANSCRIPT-PATTERNS.md.
//

import CoreGraphics
import Testing
import TranscriptEngine
@testable import Sonar

struct SNTranscriptScrollPolicyTests {

    // MARK: - OpenAction

    @Test
    func openActionFullyReadIsLiveEdge() {
        #expect(
            SNTranscriptScrollPolicy.openAction(
                unreadAnchorId: nil,
                unreadCountAtOpen: 0,
                unreadAnchorAbandoned: false
            ) == .liveEdge
        )
        #expect(
            SNTranscriptScrollPolicy.usesBottomScrollAnchor(
                unreadAnchorId: nil,
                unreadCountAtOpen: 0,
                unreadAnchorAbandoned: false
            )
        )
    }

    @Test
    func openActionPendingUnreadIsUnreadDividerEvenWithoutResolvedId() {
        #expect(
            SNTranscriptScrollPolicy.openAction(
                unreadAnchorId: nil,
                unreadCountAtOpen: 3,
                unreadAnchorAbandoned: false
            ) == .unreadDivider
        )
        #expect(
            !SNTranscriptScrollPolicy.usesBottomScrollAnchor(
                unreadAnchorId: nil,
                unreadCountAtOpen: 3,
                unreadAnchorAbandoned: false
            )
        )
    }

    @Test
    func openActionResolvedUnreadIsUnreadDivider() {
        #expect(
            SNTranscriptScrollPolicy.openAction(
                unreadAnchorId: "oldest-unread",
                unreadCountAtOpen: 3,
                unreadAnchorAbandoned: false
            ) == .unreadDivider
        )
    }

    @Test
    func openActionAbandonedUnreadFallsBackToLiveEdge() {
        #expect(
            SNTranscriptScrollPolicy.openAction(
                unreadAnchorId: nil,
                unreadCountAtOpen: 3,
                unreadAnchorAbandoned: true
            ) == .liveEdge
        )
    }

    @Test
    func openActionJumpOverridesUnreadAndLiveEdge() {
        #expect(
            SNTranscriptScrollPolicy.openAction(
                unreadAnchorId: "oldest-unread",
                unreadCountAtOpen: 3,
                unreadAnchorAbandoned: false,
                jumpId: "msg-42"
            ) == .jump(id: "msg-42")
        )
    }

    @Test
    func openActionUnsetCaptureIsProvisionalLiveEdge() {
        // Nil capture → provisional live edge so agent DMs are not mid-history.
        // Settled unread (>0) still switches hosts to the divider.
        #expect(
            SNTranscriptScrollPolicy.openAction(
                unreadAnchorId: nil,
                unreadCountAtOpen: nil,
                unreadAnchorAbandoned: false
            ) == .liveEdge
        )
        #expect(
            SNTranscriptScrollPolicy.usesBottomScrollAnchor(
                unreadAnchorId: nil,
                unreadCountAtOpen: nil,
                unreadAnchorAbandoned: false
            )
        )
    }

    @Test
    func openActionSettledZeroIsLiveEdge() {
        #expect(
            SNTranscriptScrollPolicy.openAction(
                unreadAnchorId: nil,
                unreadCountAtOpen: 0,
                unreadAnchorAbandoned: false
            ) == .liveEdge
        )
        #expect(
            SNTranscriptScrollPolicy.usesBottomScrollAnchor(
                unreadAnchorId: nil,
                unreadCountAtOpen: 0,
                unreadAnchorAbandoned: false
            )
        )
    }

    @Test
    func openActionSettledNonZeroIsUnreadDivider() {
        #expect(
            SNTranscriptScrollPolicy.openAction(
                unreadAnchorId: nil,
                unreadCountAtOpen: 2,
                unreadAnchorAbandoned: false
            ) == .unreadDivider
        )
    }

    // MARK: - wasAtTail → pin | lockstep | ignore

    @Test
    func insetFollowPinsWhenWasAtTail() {
        #expect(
            SNTranscriptScrollPolicy.insetFollowDecision(
                wasAtTail: true,
                userScrolling: false,
                isPrepending: false
            ) == .pin
        )
    }

    @Test
    func insetFollowLockstepsWhenAwayFromTail() {
        #expect(
            SNTranscriptScrollPolicy.insetFollowDecision(
                wasAtTail: false,
                userScrolling: false,
                isPrepending: false
            ) == .lockstep
        )
    }

    @Test
    func insetFollowIgnoresWhileDraggingOrPrepending() {
        #expect(
            SNTranscriptScrollPolicy.insetFollowDecision(
                wasAtTail: true,
                userScrolling: true,
                isPrepending: false
            ) == .ignore
        )
        #expect(
            SNTranscriptScrollPolicy.insetFollowDecision(
                wasAtTail: true,
                userScrolling: false,
                isPrepending: true
            ) == .ignore
        )
    }

    @Test
    func captureWasAtTailBeforeInsetChangeMatchesSignal() {
        let atTail = SNTranscriptScrollPolicy.captureWasAtTail(
            currentlyNearBottom: true,
            previouslyPinned: false,
            userScrolling: false,
            isPrepending: false
        )
        #expect(atTail.wasAtTail)
        #expect(atTail.decision == .pin)

        let history = SNTranscriptScrollPolicy.captureWasAtTail(
            currentlyNearBottom: false,
            previouslyPinned: false,
            userScrolling: false,
            isPrepending: false
        )
        #expect(!history.wasAtTail)
        #expect(history.decision == .lockstep)

        let dragging = SNTranscriptScrollPolicy.captureWasAtTail(
            currentlyNearBottom: true,
            previouslyPinned: true,
            userScrolling: true,
            isPrepending: false
        )
        #expect(dragging.wasAtTail)
        #expect(dragging.decision == .ignore)

        let prepend = SNTranscriptScrollPolicy.captureWasAtTail(
            currentlyNearBottom: true,
            previouslyPinned: true,
            userScrolling: false,
            isPrepending: true
        )
        #expect(!prepend.wasAtTail)
        #expect(prepend.decision == .ignore)
    }

    /// Latch remains a thin adapter: viewport shrink while pinned still snaps.
    @Test
    func latchViewportShrinkUsesPolicyPinDecision() {
        var latch = SNTailPinLatch()
        latch.tailVisible(itemCount: 40, tailID: "40")
        let action = latch.viewportShrank(userScrolling: false, isPrepending: false)
        #expect(action == .snap)
        #expect(
            SNTranscriptScrollPolicy.insetDecision(
                from: action,
                wasPinned: latch.wasPinned,
                userScrolling: false,
                isPrepending: false
            ) == .pin
        )
    }

    @Test
    func latchHistoryOpenLockstepsOnViewportShrink() {
        var latch = SNTailPinLatch()
        latch.openInHistory(itemCount: 40, tailID: "40")
        let action = latch.viewportShrank(userScrolling: false, isPrepending: false)
        #expect(action == .none)
        #expect(
            SNTranscriptScrollPolicy.insetDecision(
                from: action,
                wasPinned: latch.wasPinned,
                userScrolling: false,
                isPrepending: false
            ) == .lockstep
        )
    }

    // MARK: - Continuity token

    @Test
    func continuityTokenEqualityTracksAnchorAndEdge() {
        let a = SNTranscriptScrollPolicy.continuityToken(
            anchorId: "msg-1",
            edgeDistance: 120
        )
        let b = SNTranscriptContinuityToken(
            anchorId: "msg-1",
            edge: .edgeDistance(120)
        )
        let c = SNTranscriptScrollPolicy.continuityToken(
            anchorId: "msg-1",
            pixelOffset: 480
        )
        #expect(a == b)
        #expect(a != c)
        #expect(
            c == SNTranscriptContinuityToken(anchorId: "msg-1", edge: .pixelOffset(480))
        )
        #expect(
            a != SNTranscriptScrollPolicy.continuityToken(
                anchorId: "msg-2",
                edgeDistance: 120
            )
        )
    }

    // MARK: - Fully-read open recovery + coalesce window

    @Test
    func fullyReadOpenResnapPolicyMatchesBridge() {
        #expect(
            SNTranscriptScrollPolicy.shouldResnapFullyReadOpen(
                usesBottomScrollAnchor: true,
                needsLiveEdgeOpen: true,
                hasLeftBottom: false,
                userScrolling: false,
                hasTailRow: true
            )
        )
        #expect(
            SNTranscriptScrollPolicy.shouldResnapFullyReadOpen(
                usesBottomScrollAnchor: true,
                needsLiveEdgeOpen: true,
                hasLeftBottom: false,
                userScrolling: false,
                hasTailRow: true
            ) == snShouldResnapFullyReadOpen(
                usesBottomScrollAnchor: true,
                needsLiveEdgeOpen: true,
                hasLeftBottom: false,
                userScrolling: false,
                hasTailRow: true
            )
        )
        #expect(SNTranscriptScrollPolicy.snapCoalesceSeconds == 0.01)
    }
}
