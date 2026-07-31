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

/// Owned bottom inset when chrome height is known independently of the
/// composer container's bounds.
///
/// `UIHostingController` can report a full-bleed frame while the visible bar
/// is only `composerHeight` tall at the bottom. Using `container.bounds.minY`
/// then inflates `contentInset.bottom` to nearly the full viewport — the
/// empty band under the last message when rubber-banding at the live edge.
/// Prefer the container's **bottom** edge (pinned to the keyboard guide) minus
/// the fitting chrome height.
public func transcriptOwnedBottomContentInset(
    collectionBoundsHeight: CGFloat,
    composerBottomYInViewport: CGFloat,
    composerHeight: CGFloat
) -> CGFloat {
    let height = max(0, composerHeight)
    let composerTopY = composerBottomYInViewport - height
    return max(0, collectionBoundsHeight - composerTopY)
}

/// Top content inset that bottom-aligns a feed shorter than the viewport, so a
/// two-message conversation opens with its last row resting on the composer
/// instead of pinned to the top of an otherwise empty screen.
///
/// A `UICollectionView` cannot scroll content it does not have: with no top
/// inset, `maxContentOffsetY` clamps to `-topInset` (0) and the transcript
/// stays top-aligned with a viewport-sized empty band above the composer. The
/// SwiftUI fallback (`SNMsgList`) gets this from `.defaultScrollAnchor(.bottom)`;
/// the collection host has to inset for it.
///
/// Zero once the content is tall enough to fill the viewport, so it never
/// perturbs the live edge of a real conversation.
public func transcriptShortFeedTopContentInset(
    collectionBoundsHeight: CGFloat,
    contentHeight: CGFloat,
    bottomInset: CGFloat
) -> CGFloat {
    max(0, collectionBoundsHeight - max(0, bottomInset) - max(0, contentHeight))
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
