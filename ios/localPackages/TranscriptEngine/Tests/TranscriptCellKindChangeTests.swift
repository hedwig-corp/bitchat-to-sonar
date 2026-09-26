#if canImport(UIKit) && !os(macOS)
import SwiftUI
import Testing
import UIKit
@testable import TranscriptEngine

private final class AltCell: UICollectionViewCell {}

/// Mutable row state the callbacks read, like Sonar's adapter reading `msgs`.
@MainActor
private final class RowKinds {
    var alt: Set<String> = []
}

/// A visible row whose cell class changes between applies must be reloaded.
/// `reconfigureItems` hands the item back to the cell provider and UIKit
/// raises NSInternalInconsistencyException ("Attempted to dequeue a cell for a
/// different registration or reuse identifier than the existing cell when
/// reconfiguring an item") when the provider returns another class — in Sonar
/// that is a UIKit text row gaining its first reaction chip, which moves it to
/// the hosted SwiftUI cell.
@MainActor
@Suite(.serialized)
struct TranscriptCellKindChangeTests {

    @Test func rowThatChangesCellClassIsReloadedNotReconfigured() {
        let kinds = RowKinds()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = (0..<5).map {
            TranscriptHostEntry(id: "m-\($0)", date: day.addingTimeInterval(Double($0)))
        }
        let callbacks = TranscriptCollectionHostCallbacks(
            configureCell: { _, cell, _, _ in cell.backgroundConfiguration = .clear() },
            itemHeight: { _, _, _ in 44 },
            headerHeight: { _, _ in 32 },
            registerCells: { $0.register(AltCell.self, forCellWithReuseIdentifier: "alt") },
            provideCell: { collectionView, indexPath, item in
                guard case .message(let id) = item, kinds.alt.contains(id) else { return nil }
                return collectionView.dequeueReusableCell(withReuseIdentifier: "alt", for: indexPath)
            },
            cellKind: { item in
                guard case .message(let id) = item, kinds.alt.contains(id) else { return "default" }
                return "alt"
            }
        )
        // The kind is part of the height key, as Sonar's reaction fingerprint is.
        let heightKey: (TranscriptDayRow) -> String = { row in
            switch row {
            case .unreadDivider: return "u"
            case .message(let id): return "m|\(id)|\(kinds.alt.contains(id) ? "alt" : "default")"
            }
        }
        let vc = TranscriptCollectionHostViewController<AnyView>(
            composer: { AnyView(Color.clear.frame(height: 56)) },
            callbacks: callbacks,
            heightKey: heightKey
        )
        func apply(_ version: UInt64) {
            vc.apply(
                entries: entries,
                unreadCountAtOpen: 0,
                expectedNewestDate: nil,
                contentVersion: version,
                loadOlder: nil,
                loadNewest: nil,
                callbacks: callbacks,
                heightKey: heightKey
            )
            vc.view.window?.layoutIfNeeded()
            vc.collectionView.layoutIfNeeded()
        }
        func cell(_ id: String) -> UICollectionViewCell? {
            guard let dataSource = vc.collectionView.dataSource
                    as? UICollectionViewDiffableDataSource<TranscriptDaySection, TranscriptDayRow>,
                  let indexPath = dataSource.indexPath(for: .message(id)) else { return nil }
            return vc.collectionView.cellForItem(at: indexPath)
        }

        apply(1)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        #expect(cell("m-4") != nil, "the row under test must be on screen")
        #expect(!(cell("m-4") is AltCell))

        kinds.alt = ["m-4"]
        apply(2)
        #expect(cell("m-4") is AltCell, "the row moved to the other cell class")

        kinds.alt = []
        apply(3)
        #expect(cell("m-4") != nil)
        #expect(!(cell("m-4") is AltCell), "and back again")
        window.isHidden = true
    }
}
#endif
