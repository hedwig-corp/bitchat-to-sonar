//
// SNCollectionHostInsetTests.swift
// bitchatTests
//
// Regression: the owned bottom inset must be derived from the composer's
// frame in VIEWPORT (host view) coordinates. Converting into the collection
// view's coordinate space adds contentOffset, so at the tail of a long chat
// the converted minY exceeds the bounds height and the inset collapses to 0 —
// the last message renders under the composer.
//

#if os(iOS)
import Testing
import UIKit

@testable import Sonar

@MainActor
struct SNCollectionHostInsetTests {

    /// Mimics the host hierarchy: full-bleed collection view + composer
    /// container pinned near the bottom of the same host view.
    private func makeHarness(
        viewportHeight: CGFloat,
        composerHeight: CGFloat,
        contentHeight: CGFloat,
        contentOffsetY: CGFloat
    ) -> (host: UIView, collection: UICollectionView, composer: UIView) {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: viewportHeight))
        let collection = UICollectionView(
            frame: host.bounds,
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        collection.contentSize = CGSize(width: 390, height: contentHeight)
        collection.contentOffset = CGPoint(x: 0, y: contentOffsetY)
        host.addSubview(collection)
        let composer = UIView(
            frame: CGRect(
                x: 0,
                y: viewportHeight - composerHeight,
                width: 390,
                height: composerHeight
            )
        )
        host.addSubview(composer)
        return (host, collection, composer)
    }

    @Test
    func ownedInsetUsesViewportSpaceNotContentSpace() {
        let (host, collection, composer) = makeHarness(
            viewportHeight: 844,
            composerHeight: 92,
            contentHeight: 20_000,
            contentOffsetY: 19_000
        )

        // Call-site shape: convert the composer frame into the HOST view.
        let viewportRect = composer.convert(composer.bounds, to: host)
        let owned = snCollectionHostOwnedBottomContentInset(
            collectionBoundsHeight: collection.bounds.height,
            composerMinYInViewport: viewportRect.minY
        )
        #expect(abs(owned - 92) < 0.5)

        // The rejected shape: converting into the scroll view picks up
        // contentOffset and collapses the inset to 0 deep in a long chat. If
        // this stops holding, the harness no longer pins the regression.
        let contentRect = composer.convert(composer.bounds, to: collection)
        let broken = snCollectionHostOwnedBottomContentInset(
            collectionBoundsHeight: collection.bounds.height,
            composerMinYInViewport: contentRect.minY
        )
        #expect(broken == 0)
    }

    @Test
    func ownedInsetStableAcrossScrollPositions() {
        let (host, collection, composer) = makeHarness(
            viewportHeight: 844,
            composerHeight: 76,
            contentHeight: 50_000,
            contentOffsetY: 0
        )
        var values: Set<CGFloat> = []
        for offset in [0.0, 123.0, 25_000.0, 49_156.0] {
            collection.contentOffset = CGPoint(x: 0, y: offset)
            let rect = composer.convert(composer.bounds, to: host)
            values.insert(
                snCollectionHostOwnedBottomContentInset(
                    collectionBoundsHeight: collection.bounds.height,
                    composerMinYInViewport: rect.minY
                )
            )
        }
        #expect(values == [76])
    }

    @Test
    func mediaHeightFingerprintChangesWhenDimsArrive() {
        let pending = SNMediaItem(
            url: "https://example/a",
            mime: "image/jpeg",
            filename: "a.jpg",
            groupId: "g",
            width: nil,
            height: nil
        )
        var settled = pending
        settled.width = 1200
        settled.height = 900
        #expect(
            snCollectionHostMediaHeightFingerprint([pending])
                != snCollectionHostMediaHeightFingerprint([settled])
        )
    }

    @Test
    func ownedInsetGrowsWhenComposerRidesKeyboard() {
        let (host, collection, composer) = makeHarness(
            viewportHeight: 844,
            composerHeight: 76,
            contentHeight: 10_000,
            contentOffsetY: 9_000
        )
        // Keyboard up: keyboardLayoutGuide pulls the composer container up.
        composer.frame.origin.y = 844 - 336 - 76
        let rect = composer.convert(composer.bounds, to: host)
        let owned = snCollectionHostOwnedBottomContentInset(
            collectionBoundsHeight: collection.bounds.height,
            composerMinYInViewport: rect.minY
        )
        #expect(abs(owned - (336 + 76)) < 0.5)
    }

    /// A transcript shorter than the viewport must rest ON the composer. The
    /// SwiftUI fallback gets this from `.defaultScrollAnchor(.bottom)`; the
    /// collection host has to inset for it, or a two-message chat opens with a
    /// screen-tall empty band between the last bubble and the composer.
    @Test
    func shortFeedTopInsetBottomAlignsOnlyWhileContentUnderfillsTheViewport() {
        // 844pt viewport, 76pt composer, 300pt of rows ⇒ 468pt to give back.
        #expect(
            snCollectionHostShortFeedTopContentInset(
                collectionBoundsHeight: 844,
                contentHeight: 300,
                bottomInset: 76
            ) == 468
        )
        // Exactly filling the visible area needs no inset…
        #expect(
            snCollectionHostShortFeedTopContentInset(
                collectionBoundsHeight: 844,
                contentHeight: 768,
                bottomInset: 76
            ) == 0
        )
        // …and a real conversation must never be pushed off its live edge.
        #expect(
            snCollectionHostShortFeedTopContentInset(
                collectionBoundsHeight: 844,
                contentHeight: 20_000,
                bottomInset: 76
            ) == 0
        )
        // Keyboard up: the same short feed now overflows, so the inset clears.
        #expect(
            snCollectionHostShortFeedTopContentInset(
                collectionBoundsHeight: 844,
                contentHeight: 600,
                bottomInset: 76 + 336
            ) == 0
        )
    }

    /// Pins the Phase 3 floating-composer contract: UIKit `keyboardLayoutGuide`
    /// alone owns IME geometry. If SwiftUI also keyboard-avoids the representable,
    /// the composer sits roughly one keyboard height above the IME.
    @Test
    func floatingComposerGapRequiresSingleKeyboardOwner() {
        #expect(
            snCollectionHostFloatingComposerGap(
                keyboardOcclusionHeight: 336,
                swiftUIKeyboardAvoidanceActive: true
            ) == 336
        )
        #expect(
            snCollectionHostFloatingComposerGap(
                keyboardOcclusionHeight: 336,
                swiftUIKeyboardAvoidanceActive: false
            ) == 0
        )
        #expect(
            snCollectionHostFloatingComposerGap(
                keyboardOcclusionHeight: 0,
                swiftUIKeyboardAvoidanceActive: true
            ) == 0
        )
    }
}
#endif
