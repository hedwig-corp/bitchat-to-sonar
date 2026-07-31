import Foundation
import TranscriptEngine

// Sonar app shims — keep existing SN* call sites compiling. Not part of the
// public TranscriptEngine library API (lives in the Sonar target only).

public typealias SNTranscriptOpenAction = TranscriptOpenAction
public typealias SNTranscriptInsetDecision = TranscriptInsetDecision
public typealias SNTranscriptContinuityToken = TranscriptContinuityToken
public typealias SNTranscriptScrollPolicy = TranscriptScrollPolicy
public typealias SNTailPinAction = TranscriptTailPinAction
public typealias SNTailSnapCoalescer = TranscriptTailSnapCoalescer
public typealias SNTailPinLatch = TranscriptTailPinLatch
public typealias SNTranscriptDayRow = TranscriptDayRow
public typealias SNTranscriptDaySection = TranscriptDaySection
public typealias SNTranscriptRowHeightCache = TranscriptRowHeightCache

public func snUsesBottomScrollAnchor(
    unreadAnchorId: String?,
    unreadCountAtOpen: UInt64?,
    unreadAnchorAbandoned: Bool
) -> Bool {
    TranscriptScrollPolicy.usesBottomScrollAnchor(
        unreadAnchorId: unreadAnchorId,
        unreadCountAtOpen: unreadCountAtOpen,
        unreadAnchorAbandoned: unreadAnchorAbandoned
    )
}

public func snShouldResnapFullyReadOpen(
    usesBottomScrollAnchor: Bool,
    needsLiveEdgeOpen: Bool,
    hasLeftBottom: Bool,
    userScrolling: Bool,
    hasTailRow: Bool
) -> Bool {
    TranscriptScrollPolicy.shouldResnapFullyReadOpen(
        usesBottomScrollAnchor: usesBottomScrollAnchor,
        needsLiveEdgeOpen: needsLiveEdgeOpen,
        hasLeftBottom: hasLeftBottom,
        userScrolling: userScrolling,
        hasTailRow: hasTailRow
    )
}

public func snShouldClearLiveEdgeOpen(
    isNearBottom: Bool,
    ownedChromeApplied: Bool
) -> Bool {
    TranscriptScrollPolicy.shouldClearLiveEdgeOpen(
        isNearBottom: isNearBottom,
        ownedChromeApplied: ownedChromeApplied
    )
}

public func snShouldMarkLeftBottom(
    needsLiveEdgeOpen: Bool,
    wasPinned: Bool,
    userDragging: Bool
) -> Bool {
    TranscriptScrollPolicy.shouldMarkLeftBottom(
        needsLiveEdgeOpen: needsLiveEdgeOpen,
        wasPinned: wasPinned,
        userDragging: userDragging
    )
}

public func snTranscriptShowsDayChip(previous: Date?, current: Date?, calendar: Calendar = .current) -> Bool {
    transcriptShowsDayChip(previous: previous, current: current, calendar: calendar)
}

public func snTranscriptDayLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    transcriptDayLabel(for: date, now: now, calendar: calendar)
}

public func snTranscriptDaySections(
    entries: [(id: String, date: Date?)],
    unreadAnchorId: String?,
    calendar: Calendar = .current,
    now: Date = Date()
) -> [SNTranscriptDaySection] {
    transcriptDaySections(
        entries: entries,
        unreadAnchorId: unreadAnchorId,
        calendar: calendar,
        now: now
    )
}

// MARK: - Owned inset (R-009 viewport-space math lives in TranscriptEngine)

public func snCollectionHostOwnedBottomContentInset(
    collectionBoundsHeight: CGFloat,
    composerMinYInViewport: CGFloat
) -> CGFloat {
    transcriptOwnedBottomContentInset(
        collectionBoundsHeight: collectionBoundsHeight,
        composerMinYInViewport: composerMinYInViewport
    )
}

public func snCollectionHostOwnedBottomContentInset(
    collectionBoundsHeight: CGFloat,
    composerBottomYInViewport: CGFloat,
    composerHeight: CGFloat
) -> CGFloat {
    transcriptOwnedBottomContentInset(
        collectionBoundsHeight: collectionBoundsHeight,
        composerBottomYInViewport: composerBottomYInViewport,
        composerHeight: composerHeight
    )
}

public func snCollectionHostShortFeedTopContentInset(
    collectionBoundsHeight: CGFloat,
    contentHeight: CGFloat,
    bottomInset: CGFloat
) -> CGFloat {
    transcriptShortFeedTopContentInset(
        collectionBoundsHeight: collectionBoundsHeight,
        contentHeight: contentHeight,
        bottomInset: bottomInset
    )
}

public func snCollectionHostFloatingComposerGap(
    keyboardOcclusionHeight: CGFloat,
    swiftUIKeyboardAvoidanceActive: Bool
) -> CGFloat {
    transcriptFloatingComposerGap(
        keyboardOcclusionHeight: keyboardOcclusionHeight,
        swiftUIKeyboardAvoidanceActive: swiftUIKeyboardAvoidanceActive
    )
}

public func snScrollToBottomOfLoadWindowOffsetY(
    boundsHeight: CGFloat,
    contentHeight: CGFloat,
    topInset: CGFloat,
    bottomInset: CGFloat
) -> CGFloat {
    transcriptScrollToBottomOfLoadWindowOffsetY(
        boundsHeight: boundsHeight,
        contentHeight: contentHeight,
        topInset: topInset,
        bottomInset: bottomInset
    )
}

public func snRestingOffsetOvershootCorrection(
    offsetY: CGFloat,
    boundsHeight: CGFloat,
    contentHeight: CGFloat,
    topInset: CGFloat,
    bottomInset: CGFloat
) -> CGFloat? {
    transcriptRestingOffsetOvershootCorrection(
        offsetY: offsetY,
        boundsHeight: boundsHeight,
        contentHeight: contentHeight,
        topInset: topInset,
        bottomInset: bottomInset
    )
}

public typealias SNTailRevision = TranscriptTailRevision
