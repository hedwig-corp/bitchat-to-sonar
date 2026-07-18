import CoreGraphics
import Foundation

/// Owned bottom inset from composer occlusion in VIEWPORT coordinates — the
/// host view's space, NOT the scroll view's content space, which is shifted by
/// contentOffset and would collapse the inset to 0 at the tail of a long chat
/// (Signal `updateContentInsets`).
public func transcriptOwnedBottomContentInset(
    collectionBoundsHeight: CGFloat,
    composerMinYInViewport: CGFloat
) -> CGFloat {
    max(0, collectionBoundsHeight - composerMinYInViewport)
}

/// Gap between the composer bottom and the keyboard top when both SwiftUI
/// keyboard avoidance and UIKit `keyboardLayoutGuide` own the same host.
public func transcriptFloatingComposerGap(
    keyboardOcclusionHeight: CGFloat,
    swiftUIKeyboardAvoidanceActive: Bool
) -> CGFloat {
    guard keyboardOcclusionHeight > 0, swiftUIKeyboardAvoidanceActive else { return 0 }
    return keyboardOcclusionHeight
}

/// Legacy helper for tests that pass chrome metrics without a live frame.
/// `safeAreaBottom` is intentionally unused — owned inset is viewport occlusion,
/// not "bar + safe area". Prefer `transcriptOwnedBottomContentInset(collectionBoundsHeight:composerMinYInViewport:)`.
@available(*, deprecated, message: "Use viewport-space overload; safeAreaBottom is ignored")
public func transcriptOwnedBottomContentInset(barHeight: CGFloat, safeAreaBottom: CGFloat) -> CGFloat {
    max(0, barHeight)
}
