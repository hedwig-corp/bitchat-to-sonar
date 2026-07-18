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
