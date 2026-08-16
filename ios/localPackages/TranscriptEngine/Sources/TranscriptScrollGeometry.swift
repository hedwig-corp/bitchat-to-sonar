import CoreGraphics
import Foundation

/// O(1) identity for transcript changes that can affect the live edge.
public struct TranscriptTailRevision: Equatable {
    public let itemCount: Int
    public let tailID: String?

    public init(itemCount: Int, tailID: String?) {
        self.itemCount = itemCount
        self.tailID = tailID
    }
}

/// Signal `scrollToBottomOfLoadWindow`: `contentOffset.y = maxContentOffsetY`.
public func transcriptScrollToBottomOfLoadWindowOffsetY(
    boundsHeight: CGFloat,
    contentHeight: CGFloat,
    topInset: CGFloat,
    bottomInset: CGFloat
) -> CGFloat {
    let minY = -topInset
    return max(minY, contentHeight + bottomInset - boundsHeight)
}

/// Lockstep clamp after inset change — corrects overshoot past max content offset.
public func transcriptRestingOffsetOvershootCorrection(
    offsetY: CGFloat,
    boundsHeight: CGFloat,
    contentHeight: CGFloat,
    topInset: CGFloat,
    bottomInset: CGFloat
) -> CGFloat? {
    let minY = -topInset
    let maxY = max(minY, contentHeight + bottomInset - boundsHeight)
    return offsetY > maxY + 1 ? maxY : nil
}

/// Correction for a resting offset that has ended up outside the valid range in
/// EITHER direction.
///
/// Overshoot past `maxY` leaves a blank band under the last message. Undershoot
/// above `minY` is worse: with the short-feed top inset it parks the whole feed
/// below the viewport, so the transcript reads as empty. `UIScrollView` only
/// rubber-bands back at the end of a real drag, so an offset left out of range
/// by an inset / content change stays there until the reader scrolls.
public func transcriptRestingOffsetCorrection(
    offsetY: CGFloat,
    boundsHeight: CGFloat,
    contentHeight: CGFloat,
    topInset: CGFloat,
    bottomInset: CGFloat
) -> CGFloat? {
    let minY = -topInset
    let maxY = max(minY, contentHeight + bottomInset - boundsHeight)
    if offsetY > maxY + 1 { return maxY }
    if offsetY < minY - 1 { return minY }
    return nil
}
