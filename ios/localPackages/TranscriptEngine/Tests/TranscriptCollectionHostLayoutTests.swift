#if canImport(UIKit) && !os(macOS)
import SwiftUI
import Testing
import UIKit
@testable import TranscriptEngine

/// R-009 at the REAL call site: these drive `TranscriptCollectionHostViewController`
/// through a window layout pass and assert where the transcript actually comes to
/// rest, instead of re-deriving `updateOwnedInsetsFromChrome`'s arithmetic in a
/// helper. Both scenarios below shipped broken while every helper-level inset test
/// stayed green.
@MainActor
@Suite(.serialized)
struct TranscriptCollectionHostLayoutTests {

    private static let rowHeight: CGFloat = 44
    private static let headerHeight: CGFloat = 32
    private static let composerHeight: CGFloat = 56

    private func makeHost(
        rows: Int,
        viewportHeight: CGFloat
    ) async -> (window: UIWindow, vc: TranscriptCollectionHostViewController<AnyView>) {
        // One day section: contentHeight == headerHeight + rows * rowHeight.
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = (0..<rows).map {
            TranscriptHostEntry(id: "m-\($0)", date: day.addingTimeInterval(Double($0)))
        }
        let callbacks = TranscriptCollectionHostCallbacks(
            configureCell: { _, cell, _, _ in cell.backgroundConfiguration = .clear() },
            itemHeight: { _, _, _ in Self.rowHeight },
            headerHeight: { _, _ in Self.headerHeight }
        )
        let vc = TranscriptCollectionHostViewController<AnyView>(
            composer: { AnyView(Color.clear.frame(height: Self.composerHeight)) },
            callbacks: callbacks,
            heightKey: { row in
                switch row {
                case .unreadDivider: return "u"
                case .message(let id): return "m|\(id)"
                }
            }
        )
        vc.apply(
            entries: entries,
            unreadCountAtOpen: 0,
            expectedNewestDate: nil,
            loadOlder: nil,
            loadNewest: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: viewportHeight))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        await settle(window)
        return (window, vc)
    }

    /// Lay out, then let the coalesced tail pin run. The pin is deferred through
    /// `asyncAfter(+10ms)` (`TranscriptScrollPolicy.snapCoalesceSeconds`) and a
    /// shrink can schedule a second pass behind a contentSize callback, so a
    /// synchronous assertion would measure the pre-pin offset. Yield the main
    /// actor (a blocking `RunLoop.run` leaves the block queued) and poll until
    /// the resting offset stops moving rather than betting on one fixed sleep —
    /// a loaded CI runner is slower than any constant worth hard-coding.
    private func settle(_ window: UIWindow) async {
        var previous: CGPoint?
        var stableRounds = 0
        for _ in 0..<80 {
            window.layoutIfNeeded()
            window.rootViewController?.view.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 25_000_000)
            let offset = scrollView(in: window)?.contentOffset
            if let offset, offset == previous {
                stableRounds += 1
                if stableRounds >= 3 { return }
            } else {
                stableRounds = 0
            }
            previous = offset
        }
    }

    private func scrollView(in window: UIWindow) -> UIScrollView? {
        (window.rootViewController as? TranscriptCollectionHostViewController<AnyView>)?
            .collectionView
    }

    /// Resting distance between the last row's bottom edge and the top of the
    /// owned composer chrome. Zero means the transcript sits ON the composer.
    private func gapBelowLastRow(_ collection: UICollectionView) -> CGFloat {
        let visibleBottom = collection.bounds.height - collection.adjustedContentInset.bottom
        let lastRowBottomInViewport = collection.contentSize.height - collection.contentOffset.y
        return visibleBottom - lastRowBottomInViewport
    }

    @Test
    func shortFeedRestsOnTheComposerInsteadOfLeavingAnEmptyBand() async {
        let (window, vc) = await makeHost(rows: 2, viewportHeight: 844)
        defer { window.isHidden = true }
        let collection = vc.collectionView

        // Precondition: this feed genuinely does not fill the viewport.
        #expect(
            collection.contentSize.height
                < collection.bounds.height - collection.adjustedContentInset.bottom
        )
        // Without the short-feed top inset the content parks at offset 0 and the
        // gap is most of the screen — the reported "blank space between the
        // composer and the last message".
        #expect(abs(gapBelowLastRow(collection)) < 1)
        #expect(collection.contentInset.top > 0)
        // The inset only bottom-aligns; it must not advertise scrollable history.
        #expect(collection.verticalScrollIndicatorInsets.top == 0)
    }

    @Test
    func tallFeedKeepsNoTopInsetAndStaysOnTheLiveEdge() async {
        let (window, vc) = await makeHost(rows: 60, viewportHeight: 844)
        defer { window.isHidden = true }
        let collection = vc.collectionView

        #expect(
            collection.contentSize.height
                > collection.bounds.height - collection.adjustedContentInset.bottom
        )
        #expect(collection.contentInset.top == 0)
        #expect(abs(gapBelowLastRow(collection)) < 1)
    }

    /// SwiftUI keyboard avoidance can shorten the host while `keyboardLayoutGuide`
    /// moves the composer by the same amount: the owned bottom inset is unchanged,
    /// so a re-pin gated on the inset alone never runs and the newest message ends
    /// up behind the composer — the reported "keyboard hides the recent message".
    @Test
    func viewportShrinkWithUnchangedOwnedInsetStillRePinsTheTail() async {
        // Both heights are inset-free (no home-indicator safe area at either
        // size), so the owned bottom inset is byte-identical before and after —
        // the shrink is the ONLY signal available to trigger the re-pin.
        let (window, vc) = await makeHost(rows: 60, viewportHeight: 700)
        defer { window.isHidden = true }
        let collection = vc.collectionView
        let ownedBefore = collection.contentInset.bottom
        #expect(abs(gapBelowLastRow(collection)) < 1)

        window.frame.size.height = 500
        await settle(window)

        #expect(abs(collection.bounds.height - 500) < 1)
        #expect(abs(collection.contentInset.bottom - ownedBefore) < 0.5)
        #expect(abs(gapBelowLastRow(collection)) < 1)
    }

    /// A scroll that has already ENDED still holds the 200 ms `isUserScrolling`
    /// latch. When a viewport / keyboard inset change lands inside that window,
    /// the short-feed re-alignment must still run: there is no finger left on
    /// the scroll view, so nothing rubber-bands the stale offset back and the
    /// transcript stays parked at the PREVIOUS top inset — outside the visible
    /// band, i.e. the reported "open the keyboard and the chat goes blank until
    /// I scroll".
    @Test
    func shortFeedRealignsWhenAnEndedScrollStillHoldsTheUserScrollLatch() async {
        let (window, vc) = await makeHost(rows: 2, viewportHeight: 844)
        defer { window.isHidden = true }
        let collection = vc.collectionView
        #expect(collection.contentInset.top > 0)

        // Finger already lifted: the latch is hot, but no touch is in flight.
        vc.scrollViewWillBeginDragging(collection)

        window.frame.size.height = 500
        await settle(window)

        // Resting above the top inset means the rows sit below the viewport.
        #expect(collection.contentOffset.y >= -collection.adjustedContentInset.top - 1)
        #expect(abs(gapBelowLastRow(collection)) < 1)
    }

    /// The same shrink on a feed that fit before but no longer does: it must
    /// bottom-align rather than stay parked at the top with its tail clipped.
    @Test
    func shrinkThatOverflowsAShortFeedStillLandsOnTheComposer() async {
        let (window, vc) = await makeHost(rows: 6, viewportHeight: 844)
        defer { window.isHidden = true }
        let collection = vc.collectionView
        #expect(collection.contentInset.top > 0)

        window.frame.size.height = 260
        await settle(window)

        #expect(
            collection.contentSize.height
                > collection.bounds.height - collection.adjustedContentInset.bottom
        )
        #expect(collection.contentInset.top == 0)
        #expect(abs(gapBelowLastRow(collection)) < 1)
    }

    // MARK: - Composer growth

    /// Holds the draft the way SNComposer does: inside the composer, not in a
    /// new Composer value handed to `updateComposer`.
    private final class DraftModel: ObservableObject {
        @Published var text = ""
    }

    private struct GrowingComposer: View {
        @ObservedObject var draft: DraftModel
        var body: some View {
            TextField("", text: $draft.text, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 16))
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .padding(8)
        }
    }

    private func makeComposerHost(
        draft: DraftModel
    ) async -> (window: UIWindow, vc: TranscriptCollectionHostViewController<AnyView>) {
        let callbacks = TranscriptCollectionHostCallbacks(
            configureCell: { _, cell, _, _ in cell.backgroundConfiguration = .clear() },
            itemHeight: { _, _, _ in Self.rowHeight },
            headerHeight: { _, _ in Self.headerHeight }
        )
        let vc = TranscriptCollectionHostViewController<AnyView>(
            composer: { AnyView(GrowingComposer(draft: draft)) },
            callbacks: callbacks,
            heightKey: { _ in "k" }
        )
        vc.apply(
            entries: [TranscriptHostEntry(id: "m-0", date: Date(timeIntervalSince1970: 1_700_000_000))],
            unreadCountAtOpen: 0,
            expectedNewestDate: nil,
            loadOlder: nil,
            loadNewest: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        await settle(window)
        return (window, vc)
    }

    /// A draft that wraps must grow the bar, not scroll inside a one-line
    /// field. The host sized the bar from the SwiftUI *ideal* size, measured at
    /// an unconstrained width where any draft fits on one line, and the draft
    /// changes inside the composer, so no `updateComposer` relayout ran either.
    @Test
    func aWrappingDraftGrowsTheComposerBar() async {
        let draft = DraftModel()
        let (window, vc) = await makeComposerHost(draft: draft)
        defer { window.isHidden = true }
        let oneLine = vc.composerContainer.bounds.height
        #expect(oneLine > 30)

        draft.text = String(repeating: "a wrapping draft ", count: 8)
        await settle(window)

        #expect(
            vc.composerContainer.bounds.height > oneLine + 20,
            "the bar must grow with the draft (was \(oneLine), now \(vc.composerContainer.bounds.height))"
        )

        draft.text = ""
        await settle(window)
        #expect(abs(vc.composerContainer.bounds.height - oneLine) < 1, "and shrink back when cleared")
    }
}
#endif
