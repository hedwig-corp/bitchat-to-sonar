import CoreGraphics
import Foundation

/// Owned bottom inset from composer occlusion in VIEWPORT coordinates — the
/// host view's space, NOT the scroll view's content space, which is shifted by
/// contentOffset and would collapse the inset to 0 at the tail of a long chat
/// (Signal `updateContentInsets`).
///
/// Call sites must convert the composer frame with `composer.convert(_:to: hostView)`
/// (or equivalent viewport space). Never convert into the collection/scroll view.
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
