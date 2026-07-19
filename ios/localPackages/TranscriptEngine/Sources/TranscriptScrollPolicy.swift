import CoreGraphics
import Foundation

/// Latch → host action. `.snap` is coalesced (10 ms); `.animate` follows an
/// append at the live edge.
public enum TranscriptTailPinAction: Equatable {
    case none
    case snap
    case animate
}

/// Declarative chat-open scroll target (Signal CVScrollAction shape).
public enum TranscriptOpenAction: Equatable {
    case liveEdge
    case unreadDivider
    case jump(id: String)
}

/// Decision after capturing `wasAtTail` before an inset or viewport change.
public enum TranscriptInsetDecision: Equatable {
    case pin
    case lockstep
    case ignore
}

/// Token captured before a load-older / load-newer land.
public struct TranscriptContinuityToken: Equatable {
    public enum Edge: Equatable {
        case edgeDistance(CGFloat)
        case pixelOffset(CGFloat)
    }

    public let anchorId: String
    public let edge: Edge

    public init(anchorId: String, edge: Edge) {
        self.anchorId = anchorId
        self.edge = edge
    }
}

/// Pure transcript open, inset follow, and continuity policy.
public enum TranscriptScrollPolicy {
    public static let snapCoalesceSeconds: TimeInterval = 0.01

    public static func usesBottomScrollAnchor(
        unreadAnchorId: String?,
        unreadCountAtOpen: UInt64?,
        unreadAnchorAbandoned: Bool
    ) -> Bool {
        if unreadCountAtOpen == nil {
            return unreadAnchorId == nil && !unreadAnchorAbandoned
        }
        return unreadAnchorId == nil && (unreadCountAtOpen == 0 || unreadAnchorAbandoned)
    }

    public static func openAction(
        unreadAnchorId: String?,
        unreadCountAtOpen: UInt64?,
        unreadAnchorAbandoned: Bool,
        jumpId: String? = nil
    ) -> TranscriptOpenAction {
        if let jumpId {
            return .jump(id: jumpId)
        }
        // Mirror KMP `resolveOpenAction`: null count is provisional live edge
        // only when no frozen anchor; a retained unreadAnchorId keeps UnreadDivider
        // so hosts can re-anchor when the settled count lands.
        if unreadCountAtOpen == nil {
            if unreadAnchorId == nil && !unreadAnchorAbandoned {
                return .liveEdge
            }
            return .unreadDivider
        }
        let fullyRead =
            unreadAnchorId == nil && (unreadCountAtOpen == 0 || unreadAnchorAbandoned)
        return fullyRead ? .liveEdge : .unreadDivider
    }

    public static func shouldResnapFullyReadOpen(
        usesBottomScrollAnchor: Bool,
        needsLiveEdgeOpen: Bool,
        hasLeftBottom: Bool,
        userScrolling: Bool,
        hasTailRow: Bool
    ) -> Bool {
        usesBottomScrollAnchor
            && needsLiveEdgeOpen
            && !hasLeftBottom
            && !userScrolling
            && hasTailRow
    }

    public static func insetFollowDecision(
        wasAtTail: Bool,
        userScrolling: Bool,
        isPrepending: Bool
    ) -> TranscriptInsetDecision {
        if isPrepending || userScrolling {
            return .ignore
        }
        return wasAtTail ? .pin : .lockstep
    }

    public static func captureWasAtTail(
        currentlyNearBottom: Bool,
        previouslyPinned: Bool,
        userScrolling: Bool,
        isPrepending: Bool
    ) -> (wasAtTail: Bool, decision: TranscriptInsetDecision) {
        if isPrepending {
            return (false, .ignore)
        }
        if userScrolling {
            return (currentlyNearBottom, .ignore)
        }
        let pinned = currentlyNearBottom || previouslyPinned
        let decision = insetFollowDecision(
            wasAtTail: pinned,
            userScrolling: false,
            isPrepending: false
        )
        return (wasAtTail: pinned, decision: decision)
    }

    public static func insetDecision(
        from action: TranscriptTailPinAction,
        wasPinned: Bool,
        userScrolling: Bool,
        isPrepending: Bool
    ) -> TranscriptInsetDecision {
        if userScrolling || isPrepending {
            return .ignore
        }
        switch action {
        case .snap, .animate:
            return .pin
        case .none:
            return wasPinned ? .pin : .lockstep
        }
    }

    public static func continuityToken(
        anchorId: String,
        edgeDistance: CGFloat
    ) -> TranscriptContinuityToken {
        TranscriptContinuityToken(anchorId: anchorId, edge: .edgeDistance(edgeDistance))
    }

    public static func continuityToken(
        anchorId: String,
        pixelOffset: CGFloat
    ) -> TranscriptContinuityToken {
        TranscriptContinuityToken(anchorId: anchorId, edge: .pixelOffset(pixelOffset))
    }
}

public struct TranscriptTailSnapCoalescer {
    public private(set) var isScheduled = false

    public init() {}

    public mutating func request() -> Bool {
        guard !isScheduled else { return false }
        isScheduled = true
        return true
    }

    public mutating func consume() -> Bool {
        guard isScheduled else { return false }
        isScheduled = false
        return true
    }
}

public struct TranscriptTailPinLatch {
    public private(set) var wasPinned = false
    public private(set) var lastItemCount = 0
    public private(set) var lastTailID: String?

    public init() {}

    public mutating func tailVisible(itemCount: Int, tailID: String?) {
        wasPinned = true
        updateSnapshot(itemCount: itemCount, tailID: tailID)
    }

    public mutating func openInHistory(itemCount: Int, tailID: String?) {
        wasPinned = false
        updateSnapshot(itemCount: itemCount, tailID: tailID)
    }

    public mutating func userScrolled(isNearBottom: Bool) {
        if !isNearBottom { wasPinned = false }
    }

    public mutating func itemsChanged(
        itemCount: Int,
        tailID: String?,
        isNearBottom: Bool,
        userScrolling: Bool,
        isPrepending: Bool
    ) -> TranscriptTailPinAction {
        let appendedAtTail = tailID != lastTailID
        updateSnapshot(itemCount: itemCount, tailID: tailID)
        if isPrepending {
            wasPinned = false
            return .none
        }
        if userScrolling {
            wasPinned = isNearBottom
            return .none
        }
        guard wasPinned, appendedAtTail else { return .none }
        return .animate
    }

    public mutating func tailHidden(
        itemCount: Int,
        tailID: String?,
        userScrolling: Bool,
        isPrepending: Bool
    ) -> TranscriptTailPinAction {
        let appendedAtTail = tailID != lastTailID
        updateSnapshot(itemCount: itemCount, tailID: tailID)
        if userScrolling || isPrepending {
            wasPinned = false
            return .none
        }
        guard wasPinned, itemCount > 0 else { return .none }
        return appendedAtTail ? .animate : .snap
    }

    public mutating func viewportShrank(userScrolling: Bool, isPrepending: Bool) -> TranscriptTailPinAction {
        viewportResized(userScrolling: userScrolling, isPrepending: isPrepending)
    }

    public mutating func viewportExpanded(userScrolling: Bool, isPrepending: Bool) -> TranscriptTailPinAction {
        viewportResized(userScrolling: userScrolling, isPrepending: isPrepending)
    }

    private mutating func viewportResized(userScrolling: Bool, isPrepending: Bool) -> TranscriptTailPinAction {
        let decision = TranscriptScrollPolicy.insetFollowDecision(
            wasAtTail: wasPinned,
            userScrolling: userScrolling,
            isPrepending: isPrepending
        )
        switch decision {
        case .ignore:
            wasPinned = false
            return .none
        case .pin:
            return .snap
        case .lockstep:
            return .none
        }
    }

    public mutating func viewportWillChange(
        isNearBottom: Bool,
        userScrolling: Bool,
        isPrepending: Bool
    ) -> TranscriptTailPinAction {
        let captured = TranscriptScrollPolicy.captureWasAtTail(
            currentlyNearBottom: isNearBottom,
            previouslyPinned: wasPinned,
            userScrolling: userScrolling,
            isPrepending: isPrepending
        )
        wasPinned = captured.wasAtTail
        switch captured.decision {
        case .pin:
            return .snap
        case .lockstep, .ignore:
            return .none
        }
    }

    private mutating func updateSnapshot(itemCount: Int, tailID: String?) {
        lastItemCount = itemCount
        lastTailID = tailID
    }
}
