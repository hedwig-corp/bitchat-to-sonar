//
// SNTranscriptScrollPolicy.swift
// bitchat
//
// Pure Signal-shaped transcript scroll / open / inset policy (Phase 1).
// Mirrors docs/SIGNAL-TRANSCRIPT-PATTERNS.md and the Compose TranscriptScrollPolicy.
// Latch + coalescer remain thin adapters; SNMsgList keeps production behavior.
//

import CoreGraphics
import Foundation

/// Latch → host action. `.snap` is coalesced (10 ms); `.animate` follows an
/// append at the live edge. Policy maps these to pin | lockstep | ignore.
enum SNTailPinAction: Equatable {
    case none
    case snap
    case animate
}

// MARK: - Open action (Signal CVScrollAction shape)

/// Declarative chat-open scroll target. Signal:
/// `scrollToInitialPosition` → live edge | unread divider | jump(id).
enum SNTranscriptOpenAction: Equatable {
    case liveEdge
    case unreadDivider
    case jump(id: String)
}

// MARK: - Inset / viewport follow (Signal wasScrolledToBottom)

/// Decision after capturing `wasAtTail` before an inset or viewport change.
/// Signal `updateContentInsets`: pin live edge, else lockstep offset by Δ;
/// ignore while dragging or during a deliberate history prepend.
enum SNTranscriptInsetDecision: Equatable {
    case pin
    case lockstep
    case ignore
}

// MARK: - Continuity (Signal ScrollContinuity)

/// Token captured before a load-older / load-newer land so the host can
/// restore position without hope-scroll. Phase 2 hosts consume this; Phase 1
/// only locks the shape + equality.
struct SNTranscriptContinuityToken: Equatable {
    enum Edge: Equatable {
        /// Distance from the live edge (Signal `lastKnownDistanceFromBottom`).
        case edgeDistance(CGFloat)
        /// Absolute content offset sample when edge distance is unavailable.
        case pixelOffset(CGFloat)
    }

    let anchorId: String
    let edge: Edge
}

// MARK: - Policy namespace

/// Named API for transcript open, inset follow, continuity, and fully-read
/// open recovery. Production latch methods call into these helpers so the
/// invariants live in one place.
enum SNTranscriptScrollPolicy {

    /// Signal coalesces rapid safe-area/inset notifications with a 10 ms,
    /// last-event-only debounce (`DebouncedEventLastOnly(0.01)`).
    static let snapCoalesceSeconds: TimeInterval = 0.01

    // MARK: Open

    /// Fully-read opens may use a bottom scroll anchor (iOS 17+). Unread
    /// opens stay top-anchored so the divider owns first paint.
    ///
    /// Unset capture (`nil`) is treated as **provisional live edge**: holding
    /// with no scroll left long agent DMs mid-history (worse than a brief
    /// bottom→divider correction when unread settles).
    static func usesBottomScrollAnchor(
        unreadAnchorId: String?,
        unreadCountAtOpen: UInt64?,
        unreadAnchorAbandoned: Bool
    ) -> Bool {
        if unreadCountAtOpen == nil {
            return unreadAnchorId == nil && !unreadAnchorAbandoned
        }
        return unreadAnchorId == nil && (unreadCountAtOpen == 0 || unreadAnchorAbandoned)
    }

    /// Select the declarative open action. Pending unread without a resolved
    /// divider id returns `.unreadDivider` (host must wait to scroll). Unset
    /// capture returns provisional `.liveEdge` so first paint is not mid-history.
    static func openAction(
        unreadAnchorId: String?,
        unreadCountAtOpen: UInt64?,
        unreadAnchorAbandoned: Bool,
        jumpId: String? = nil
    ) -> SNTranscriptOpenAction {
        if let jumpId {
            return .jump(id: jumpId)
        }
        if usesBottomScrollAnchor(
            unreadAnchorId: unreadAnchorId,
            unreadCountAtOpen: unreadCountAtOpen,
            unreadAnchorAbandoned: unreadAnchorAbandoned
        ) {
            return .liveEdge
        }
        if let unreadCountAtOpen, unreadCountAtOpen > 0, !unreadAnchorAbandoned {
            return .unreadDivider
        }
        return .liveEdge
    }

    /// Fully-read opens must keep re-snapping to the live edge until the
    /// sentinel lands (or the user scrolls). Alpha.11 raced one async
    /// `scrollTo` against under-measured LazyVStack content.
    static func shouldResnapFullyReadOpen(
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

    // MARK: Inset / wasAtTail

    /// Pure mapping of Signal `wasScrolledToBottom` after capture:
    /// dragging or prepend → ignore; at tail → pin; else lockstep.
    static func insetFollowDecision(
        wasAtTail: Bool,
        userScrolling: Bool,
        isPrepending: Bool
    ) -> SNTranscriptInsetDecision {
        if isPrepending || userScrolling {
            return .ignore
        }
        return wasAtTail ? .pin : .lockstep
    }

    /// Capture `wasAtTail` the way Signal does before mutating insets:
    /// if the sentinel is currently visible, treat as at tail; while the user
    /// is scrolling, adopt live near-bottom and ignore programmatic follow;
    /// prepend always clears pin.
    ///
    /// Returns the new latch pin flag and the follow decision for this change.
    static func captureWasAtTail(
        currentlyNearBottom: Bool,
        previouslyPinned: Bool,
        userScrolling: Bool,
        isPrepending: Bool
    ) -> (wasAtTail: Bool, decision: SNTranscriptInsetDecision) {
        if isPrepending {
            return (false, .ignore)
        }
        if userScrolling {
            return (currentlyNearBottom, .ignore)
        }
        // Match latch: if currently near bottom, force pin true; then decide.
        let pinned = currentlyNearBottom || previouslyPinned
        let decision = insetFollowDecision(
            wasAtTail: pinned,
            userScrolling: false,
            isPrepending: false
        )
        return (wasAtTail: pinned, decision: decision)
    }

    /// Map a latch UI action into the shared inset decision vocabulary.
    /// `.none` while unpinned is lockstep (host/UIKit shifts offset by Δ);
    /// `.none` while ignore conditions apply is ignore.
    static func insetDecision(
        from action: SNTailPinAction,
        wasPinned: Bool,
        userScrolling: Bool,
        isPrepending: Bool
    ) -> SNTranscriptInsetDecision {
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

    // MARK: Continuity

    static func continuityToken(
        anchorId: String,
        edgeDistance: CGFloat
    ) -> SNTranscriptContinuityToken {
        SNTranscriptContinuityToken(anchorId: anchorId, edge: .edgeDistance(edgeDistance))
    }

    static func continuityToken(
        anchorId: String,
        pixelOffset: CGFloat
    ) -> SNTranscriptContinuityToken {
        SNTranscriptContinuityToken(anchorId: anchorId, edge: .pixelOffset(pixelOffset))
    }
}

// MARK: - Free-function shims (existing call sites / tests)

/// Fully-read opens may use `defaultScrollAnchor(.bottom)` (iOS 17+). Unread
/// / pending-unread opens stay top-anchored so the divider owns first paint.
func snUsesBottomScrollAnchor(
    unreadAnchorId: String?,
    unreadCountAtOpen: UInt64?,
    unreadAnchorAbandoned: Bool
) -> Bool {
    SNTranscriptScrollPolicy.usesBottomScrollAnchor(
        unreadAnchorId: unreadAnchorId,
        unreadCountAtOpen: unreadCountAtOpen,
        unreadAnchorAbandoned: unreadAnchorAbandoned
    )
}

/// Fully-read opens must keep re-snapping to the live edge until LazyVStack
/// has a real tail (and folded legs have caught up).
func snShouldResnapFullyReadOpen(
    usesBottomScrollAnchor: Bool,
    needsLiveEdgeOpen: Bool,
    hasLeftBottom: Bool,
    userScrolling: Bool,
    hasTailRow: Bool
) -> Bool {
    SNTranscriptScrollPolicy.shouldResnapFullyReadOpen(
        usesBottomScrollAnchor: usesBottomScrollAnchor,
        needsLiveEdgeOpen: needsLiveEdgeOpen,
        hasLeftBottom: hasLeftBottom,
        userScrolling: userScrolling,
        hasTailRow: hasTailRow
    )
}

// MARK: - Coalescer + latch (implementation adapters)

/// Signal coalesces rapid safe-area/inset notifications with a 10 ms,
/// last-event-only debounce. Keyboard layout steps all request the same snap,
/// so keep at most one pending main-queue correction per debounce window.
struct SNTailSnapCoalescer {
    private(set) var isScheduled = false

    mutating func request() -> Bool {
        guard !isScheduled else { return false }
        isScheduled = true
        return true
    }

    mutating func consume() -> Bool {
        guard isScheduled else { return false }
        isScheduled = false
        return true
    }
}

/// Previous-frame tail state, mirroring Signal-iOS `updateContentInsets`:
/// capture `wasScrolledToBottom` before the inset/viewport change, then
/// `scrollToBottomOfLoadWindow(animated: false)` when pinned.
/// Sentinel disappearance alone is ambiguous — keyboard shrink, append, and
/// user scroll all hide it — so keep prior pin until user scroll or history
/// open. Decision vocabulary lives in `SNTranscriptScrollPolicy`.
struct SNTailPinLatch {
    private(set) var wasPinned = false
    private(set) var lastItemCount = 0
    private(set) var lastTailID: String?

    mutating func tailVisible(itemCount: Int, tailID: String?) {
        wasPinned = true
        updateSnapshot(itemCount: itemCount, tailID: tailID)
    }

    mutating func openInHistory(itemCount: Int, tailID: String?) {
        wasPinned = false
        updateSnapshot(itemCount: itemCount, tailID: tailID)
    }

    mutating func userScrolled(isNearBottom: Bool) {
        if !isNearBottom { wasPinned = false }
    }

    mutating func itemsChanged(
        itemCount: Int,
        tailID: String?,
        isNearBottom: Bool,
        userScrolling: Bool,
        isPrepending: Bool
    ) -> SNTailPinAction {
        // A full bounded window can replace its oldest row when a new message
        // arrives, leaving the item count unchanged. The tail identity is the
        // authoritative live-edge signal in that case.
        let appendedAtTail = tailID != lastTailID
        updateSnapshot(itemCount: itemCount, tailID: tailID)
        if isPrepending {
            // A deliberate history-page insert owns the scroll position even
            // when the old short transcript still fits and reports its tail
            // visible during the first update frame.
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

    mutating func tailHidden(
        itemCount: Int,
        tailID: String?,
        userScrolling: Bool,
        isPrepending: Bool
    ) -> SNTailPinAction {
        let appendedAtTail = tailID != lastTailID
        updateSnapshot(itemCount: itemCount, tailID: tailID)
        if userScrolling || isPrepending {
            wasPinned = false
            return .none
        }
        guard wasPinned, itemCount > 0 else { return .none }
        return appendedAtTail ? .animate : .snap
    }

    mutating func viewportShrank(userScrolling: Bool, isPrepending: Bool) -> SNTailPinAction {
        viewportResized(userScrolling: userScrolling, isPrepending: isPrepending)
    }

    /// Signal `updateContentInsets` re-pins whenever insets change while
    /// `wasScrolledToBottom` — grow or shrink (keyboard dismiss / phantom
    /// safe-area clear). Only user scroll unpins.
    mutating func viewportExpanded(userScrolling: Bool, isPrepending: Bool) -> SNTailPinAction {
        viewportResized(userScrolling: userScrolling, isPrepending: isPrepending)
    }

    private mutating func viewportResized(userScrolling: Bool, isPrepending: Bool) -> SNTailPinAction {
        let decision = SNTranscriptScrollPolicy.insetFollowDecision(
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

    /// Signal: `let wasScrolledToBottom = self.isScrolledToBottom` before
    /// mutating `contentInset`. Keyboard frame notification is the SwiftUI
    /// equivalent — capture before the safe-area shrink/offset clamp.
    mutating func viewportWillChange(
        isNearBottom: Bool,
        userScrolling: Bool,
        isPrepending: Bool
    ) -> SNTailPinAction {
        let captured = SNTranscriptScrollPolicy.captureWasAtTail(
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
