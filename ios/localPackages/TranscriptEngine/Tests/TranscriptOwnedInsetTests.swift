#if canImport(UIKit) && !os(macOS)
import Testing
import UIKit
@testable import TranscriptEngine

@MainActor
struct TranscriptOwnedInsetTests {

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

        let viewportRect = composer.convert(composer.bounds, to: host)
        let owned = transcriptOwnedBottomContentInset(
            collectionBoundsHeight: collection.bounds.height,
            composerMinYInViewport: viewportRect.minY
        )
        #expect(abs(owned - 92) < 0.5)

        let contentRect = composer.convert(composer.bounds, to: collection)
        let broken = transcriptOwnedBottomContentInset(
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
                transcriptOwnedBottomContentInset(
                    collectionBoundsHeight: collection.bounds.height,
                    composerMinYInViewport: rect.minY
                )
            )
        }
        #expect(values == [76])
    }

    @Test
    func ownedInsetGrowsWhenComposerRidesKeyboard() {
        let (host, collection, composer) = makeHarness(
            viewportHeight: 844,
            composerHeight: 76,
            contentHeight: 10_000,
            contentOffsetY: 9_000
        )
        composer.frame.origin.y = 844 - 336 - 76
        let rect = composer.convert(composer.bounds, to: host)
        let owned = transcriptOwnedBottomContentInset(
            collectionBoundsHeight: collection.bounds.height,
            composerMinYInViewport: rect.minY
        )
        #expect(abs(owned - (336 + 76)) < 0.5)
    }

    @Test
    func floatingComposerGapRequiresSingleKeyboardOwner() {
        #expect(
            transcriptFloatingComposerGap(
                keyboardOcclusionHeight: 336,
                swiftUIKeyboardAvoidanceActive: true
            ) == 336
        )
        #expect(
            transcriptFloatingComposerGap(
                keyboardOcclusionHeight: 336,
                swiftUIKeyboardAvoidanceActive: false
            ) == 0
        )
        #expect(
            transcriptFloatingComposerGap(
                keyboardOcclusionHeight: 0,
                swiftUIKeyboardAvoidanceActive: true
            ) == 0
        )
    }
}
#endif
