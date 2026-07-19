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
