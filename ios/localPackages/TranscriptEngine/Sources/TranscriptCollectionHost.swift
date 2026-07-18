#if canImport(UIKit) && !os(macOS)
import SwiftUI
import UIKit

// MARK: - Public model

/// Row inputs for the generic collection host. Height keys are supplied by the app
/// so media / expansion fingerprints stay app-specific.
public struct TranscriptHostEntry: Hashable {
    public let id: String
    public let date: Date?

    public init(id: String, date: Date?) {
        self.id = id
        self.date = date
    }
}

/// Resolves the unread divider anchor from bounded local rows + capture count.
public typealias TranscriptUnreadAnchorResolver = (
    _ entries: [TranscriptHostEntry],
    _ unreadCount: UInt64
) -> String?

/// Cell + measure hooks supplied by the host app (Sonar bubbles, sample UILabels, …).
public struct TranscriptCollectionHostCallbacks {
    public var configureCell: (UICollectionView, UICollectionViewCell, IndexPath, TranscriptDayRow) -> Void
    /// Sticky day header chrome. When nil, the host falls back to a plain `UILabel`.
    /// Apps with custom pills (Sonar `SNStickyDayHeader`) must supply this so measure
    /// (`headerHeight`) and display stay on the same object graph.
    public var configureHeader: ((UICollectionView, UICollectionViewCell, IndexPath, String) -> Void)?
    public var itemHeight: (TranscriptDayRow, String, CGFloat) -> CGFloat
    public var headerHeight: (String, CGFloat) -> CGFloat
    public var unreadAnchorResolver: TranscriptUnreadAnchorResolver?

    public init(
        configureCell: @escaping (UICollectionView, UICollectionViewCell, IndexPath, TranscriptDayRow) -> Void,
        itemHeight: @escaping (TranscriptDayRow, String, CGFloat) -> CGFloat,
        headerHeight: @escaping (String, CGFloat) -> CGFloat,
        configureHeader: ((UICollectionView, UICollectionViewCell, IndexPath, String) -> Void)? = nil,
        unreadAnchorResolver: TranscriptUnreadAnchorResolver? = nil
    ) {
        self.configureCell = configureCell
        self.configureHeader = configureHeader
        self.itemHeight = itemHeight
        self.headerHeight = headerHeight
        self.unreadAnchorResolver = unreadAnchorResolver
    }
}

// MARK: - SwiftUI entry

/// Generic UIKit transcript host: full-height collection + keyboardLayoutGuide composer.
public struct TranscriptCollectionHostView<Composer: View>: UIViewControllerRepresentable {
    let entries: [TranscriptHostEntry]
    let heightKey: (TranscriptDayRow) -> String
    let callbacks: TranscriptCollectionHostCallbacks
    var unreadCountAtOpen: UInt64?
    var expectedNewestDate: Date?
    var loadOlder: (() async -> Bool)?
    var loadNewest: (() async -> Void)?
    /// Host / collection / composer chrome background. Defaults to system; apps
    /// with branded transcript chrome (Sonar `SonarTheme.bg`) pass their color.
    var transcriptBackgroundColor: UIColor
    @ViewBuilder var composer: () -> Composer

    public init(
        entries: [TranscriptHostEntry],
        heightKey: @escaping (TranscriptDayRow) -> String,
        callbacks: TranscriptCollectionHostCallbacks,
        unreadCountAtOpen: UInt64? = nil,
        expectedNewestDate: Date? = nil,
        loadOlder: (() async -> Bool)? = nil,
        loadNewest: (() async -> Void)? = nil,
        transcriptBackgroundColor: UIColor = .systemBackground,
        @ViewBuilder composer: @escaping () -> Composer
    ) {
        self.entries = entries
        self.heightKey = heightKey
        self.callbacks = callbacks
        self.unreadCountAtOpen = unreadCountAtOpen
        self.expectedNewestDate = expectedNewestDate
        self.loadOlder = loadOlder
        self.loadNewest = loadNewest
        self.transcriptBackgroundColor = transcriptBackgroundColor
        self.composer = composer
    }

    public func makeUIViewController(context: Context) -> TranscriptCollectionHostViewController<Composer> {
        let vc = TranscriptCollectionHostViewController(
            composer: composer,
            callbacks: callbacks,
            heightKey: heightKey,
            transcriptBackgroundColor: transcriptBackgroundColor
        )
        vc.apply(
            entries: entries,
            unreadCountAtOpen: unreadCountAtOpen,
            expectedNewestDate: expectedNewestDate,
            loadOlder: loadOlder,
            loadNewest: loadNewest,
            callbacks: callbacks,
            heightKey: heightKey,
            transcriptBackgroundColor: transcriptBackgroundColor
        )
        return vc
    }

    public func updateUIViewController(
        _ uiViewController: TranscriptCollectionHostViewController<Composer>,
        context: Context
    ) {
        uiViewController.updateComposer(composer())
        uiViewController.apply(
            entries: entries,
            unreadCountAtOpen: unreadCountAtOpen,
            expectedNewestDate: expectedNewestDate,
            loadOlder: loadOlder,
            loadNewest: loadNewest,
            callbacks: callbacks,
            heightKey: heightKey,
            transcriptBackgroundColor: transcriptBackgroundColor
        )
    }
}

// MARK: - Composer root store (preserve @State across SwiftUI updates)

private final class TranscriptComposerRootStore<Composer: View>: ObservableObject {
    @Published var composer: Composer
    init(_ composer: Composer) { self.composer = composer }
}

private struct TranscriptComposerRootView<Composer: View>: View {
    @ObservedObject var store: TranscriptComposerRootStore<Composer>
    var body: some View {
        store.composer.ignoresSafeArea(.container, edges: .bottom)
    }
}

// MARK: - View controller

public final class TranscriptCollectionHostViewController<Composer: View>: UIViewController,
    UICollectionViewDelegateFlowLayout
{
    private let collectionView: UICollectionView
    private let flowLayout: UICollectionViewFlowLayout
    private let composerContainer = UIView()
    private let composerStore: TranscriptComposerRootStore<Composer>
    private let composerHost: UIHostingController<TranscriptComposerRootView<Composer>>
    private var dataSource:
        UICollectionViewDiffableDataSource<TranscriptDaySection, TranscriptDayRow>?

    private var callbacks: TranscriptCollectionHostCallbacks
    private var heightKeyForItem: (TranscriptDayRow) -> String
    private var transcriptBackgroundColor: UIColor

    private var entries: [TranscriptHostEntry] = []
    private var loadOlder: (() async -> Bool)?
    private var loadNewest: (() async -> Void)?
    private var unreadCountAtOpen: UInt64?
    private var expectedNewestDate: Date?

    private var unreadAnchorId: String?
    private var unreadAnchorAbandoned = false
    private var didInitialScroll = false
    private var needsLiveEdgeOpen = false
    private var hasLeftBottom = false
    private var isLoadingOlder = false
    private var isLoadingNewest = false
    private var isUserScrolling = false
    private var userScrollGeneration: UInt = 0
    private var latch = TranscriptTailPinLatch()
    private var snapCoalescer = TranscriptTailSnapCoalescer()
    private var lastBarHeight: CGFloat = 0
    private var pendingContinuity: TranscriptContinuityToken?
    private var contentSizeObservation: NSKeyValueObservation?
    private var lastContentHeight: CGFloat = 0

    private let heightCache = TranscriptRowHeightCache()
    private var appliedHeightKeys: [TranscriptDayRow: String] = [:]

    public init(
        composer: () -> Composer,
        callbacks: TranscriptCollectionHostCallbacks,
        heightKey: @escaping (TranscriptDayRow) -> String,
        transcriptBackgroundColor: UIColor = .systemBackground
    ) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        layout.estimatedItemSize = .zero
        layout.sectionHeadersPinToVisibleBounds = true
        flowLayout = layout
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        let store = TranscriptComposerRootStore(composer())
        composerStore = store
        composerHost = UIHostingController(rootView: TranscriptComposerRootView(store: store))
        self.callbacks = callbacks
        heightKeyForItem = heightKey
        self.transcriptBackgroundColor = transcriptBackgroundColor
        super.init(nibName: nil, bundle: nil)
    }

    public func updateComposer(_ composer: Composer) {
        composerStore.composer = composer
    }

    private func applyTranscriptBackground() {
        view.backgroundColor = transcriptBackgroundColor
        collectionView.backgroundColor = transcriptBackgroundColor
        composerContainer.backgroundColor = transcriptBackgroundColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        applyTranscriptBackground()

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        view.addSubview(collectionView)

        composerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerContainer)

        composerHost.view.translatesAutoresizingMaskIntoConstraints = false
        composerHost.view.backgroundColor = .clear
        if #available(iOS 16.4, *) {
            composerHost.safeAreaRegions = []
        }
        addChild(composerHost)
        composerContainer.addSubview(composerHost.view)
        composerHost.didMove(toParent: self)

        let bottomToKeyboard = composerContainer.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor
        )

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            composerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomToKeyboard,

            composerHost.view.topAnchor.constraint(equalTo: composerContainer.topAnchor),
            composerHost.view.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor),
            composerHost.view.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor),
            composerHost.view.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor),
        ])

        configureDataSource()
        contentSizeObservation = collectionView.observe(\.contentSize, options: [.new]) {
            [weak self] scrollView, _ in
            guard let self else { return }
            let height = scrollView.contentSize.height
            guard height > self.lastContentHeight + 0.5 else {
                self.lastContentHeight = height
                return
            }
            self.lastContentHeight = height
            guard !self.isUserScrolling, !self.isLoadingOlder else { return }
            guard self.needsLiveEdgeOpen || self.latch.wasPinned || self.isScrolledToBottom() else {
                return
            }
            self.scrollToBottomOfLoadWindow(animated: false)
        }
        applySnapshot()
        if !didInitialScroll {
            scrollToInitialPosition()
            didInitialScroll = true
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = collectionView.bounds.width
        if width > 0, heightCache.updateWidth(width) {
            flowLayout.invalidateLayout()
        }
        updateOwnedInsetsFromChrome()
    }

    public func apply(
        entries: [TranscriptHostEntry],
        unreadCountAtOpen: UInt64?,
        expectedNewestDate: Date?,
        loadOlder: (() async -> Bool)?,
        loadNewest: (() async -> Void)?,
        callbacks: TranscriptCollectionHostCallbacks? = nil,
        heightKey: ((TranscriptDayRow) -> String)? = nil,
        transcriptBackgroundColor: UIColor? = nil
    ) {
        if let callbacks { self.callbacks = callbacks }
        if let heightKey { heightKeyForItem = heightKey }
        if let transcriptBackgroundColor {
            self.transcriptBackgroundColor = transcriptBackgroundColor
            if isViewLoaded { applyTranscriptBackground() }
        }
        let previousRevision = TranscriptTailRevision(
            itemCount: self.entries.count,
            tailID: self.entries.last?.id
        )
        let previousUnread = self.unreadCountAtOpen
        self.entries = entries
        self.unreadCountAtOpen = unreadCountAtOpen
        self.expectedNewestDate = expectedNewestDate
        self.loadOlder = loadOlder
        self.loadNewest = loadNewest

        let hadAnchor = unreadAnchorId != nil
        resolveUnreadAnchor()
        guard isViewLoaded, dataSource != nil else { return }
        applySnapshot()

        let revision = TranscriptTailRevision(itemCount: entries.count, tailID: entries.last?.id)
        if !didInitialScroll {
            scrollToInitialPosition()
            didInitialScroll = true
        } else if !hadAnchor, unreadAnchorId != nil {
            applyOpenAction(.unreadDivider)
        } else if previousUnread != unreadCountAtOpen {
            applyOpenAction(transcriptOpenAction)
        } else if revision != previousRevision {
            handleItemsChanged()
        } else if needsLiveEdgeOpen {
            resnapFullyReadOpenIfNeeded()
        }

        if let token = pendingContinuity {
            pendingContinuity = nil
            restoreContinuity(token)
        }
    }

    // MARK: Data source

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewCell, TranscriptDayRow> {
            [weak self] cell, indexPath, item in
            guard let self else { return }
            self.callbacks.configureCell(self.collectionView, cell, indexPath, item)
        }
        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard let self,
                  let section = self.dataSource?.sectionIdentifier(for: indexPath.section),
                  !section.label.isEmpty
            else { return }
            if let configureHeader = self.callbacks.configureHeader {
                configureHeader(self.collectionView, header, indexPath, section.label)
                return
            }
            // Default sample chrome — production apps should pass configureHeader.
            header.contentConfiguration = nil
            header.contentView.subviews.forEach { $0.removeFromSuperview() }
            let label = UILabel()
            label.text = section.label
            label.font = .systemFont(ofSize: 11.5, weight: .semibold)
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            header.contentView.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: header.contentView.topAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: header.contentView.bottomAnchor, constant: -4),
                label.centerXAnchor.constraint(equalTo: header.contentView.centerXAnchor),
            ])
            header.backgroundConfiguration = .clear()
        }
        let ds = UICollectionViewDiffableDataSource<TranscriptDaySection, TranscriptDayRow>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }
        ds.supplementaryViewProvider = { collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader else { return nil }
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: headerReg,
                for: indexPath
            )
        }
        dataSource = ds
    }

    private func headerHeightKey(for section: TranscriptDaySection) -> String {
        "h|\(section.label)"
    }

    private func itemHeight(for item: TranscriptDayRow, width: CGFloat) -> CGFloat {
        let key = heightKeyForItem(item)
        return heightCache.height(forKey: key) { [weak self] in
            guard let self else { return 44 }
            return self.callbacks.itemHeight(item, key, width)
        }
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = collectionView.bounds.width
        guard width > 0, let item = dataSource?.itemIdentifier(for: indexPath) else {
            return CGSize(width: max(width, 1), height: 44)
        }
        heightCache.updateWidth(width)
        return CGSize(width: width, height: itemHeight(for: item, width: width))
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        let width = collectionView.bounds.width
        guard width > 0,
              let sectionID = dataSource?.sectionIdentifier(for: section),
              !sectionID.label.isEmpty
        else { return .zero }
        heightCache.updateWidth(width)
        let height = heightCache.height(forKey: headerHeightKey(for: sectionID)) { [weak self] in
            guard let self else { return 28 }
            return self.callbacks.headerHeight(sectionID.label, width)
        }
        return CGSize(width: width, height: height)
    }

    private func applySnapshot() {
        guard let dataSource else { return }
        let sections = transcriptDaySections(
            entries: entries.map { ($0.id, $0.date) },
            unreadAnchorId: unreadAnchorId
        )
        var snapshot = NSDiffableDataSourceSnapshot<TranscriptDaySection, TranscriptDayRow>()
        var newHeightKeys: [TranscriptDayRow: String] = [:]
        var reconfigure: [TranscriptDayRow] = []
        for var section in sections {
            let rows = section.rows
            section.rows = []
            snapshot.appendSections([section])
            snapshot.appendItems(rows, toSection: section)
            for item in rows {
                let key = heightKeyForItem(item)
                newHeightKeys[item] = key
                if let old = appliedHeightKeys[item], old != key {
                    reconfigure.append(item)
                }
            }
        }
        if !reconfigure.isEmpty {
            snapshot.reconfigureItems(reconfigure)
        }
        let layoutChanged = newHeightKeys != appliedHeightKeys
        appliedHeightKeys = newHeightKeys
        dataSource.apply(snapshot, animatingDifferences: false)
        if layoutChanged {
            flowLayout.invalidateLayout()
        }
    }

    // MARK: Open / unread

    private var feedCaughtUp: Bool {
        guard let expected = expectedNewestDate else { return true }
        if let newest = entries.last?.date { return newest >= expected }
        guard let newest = entries.lazy.compactMap(\.date).max() else { return false }
        return newest >= expected
    }

    private var usesBottomScrollAnchor: Bool {
        TranscriptScrollPolicy.usesBottomScrollAnchor(
            unreadAnchorId: unreadAnchorId,
            unreadCountAtOpen: unreadCountAtOpen,
            unreadAnchorAbandoned: unreadAnchorAbandoned
        )
    }

    private var transcriptOpenAction: TranscriptOpenAction {
        TranscriptScrollPolicy.openAction(
            unreadAnchorId: unreadAnchorId,
            unreadCountAtOpen: unreadCountAtOpen,
            unreadAnchorAbandoned: unreadAnchorAbandoned
        )
    }

    private func resolveUnreadAnchor() {
        guard let unreadCountAtOpen, unreadCountAtOpen > 0 else { return }
        if let current = unreadAnchorId, entries.contains(where: { $0.id == current }) { return }
        if let expected = expectedNewestDate,
           let newest = entries.compactMap(\.date).max(),
           newest < expected {
            return
        }
        if let resolver = callbacks.unreadAnchorResolver {
            unreadAnchorId = resolver(entries, unreadCountAtOpen)
            if unreadAnchorId == nil { unreadAnchorAbandoned = true }
            return
        }
        // Generic default: Nth-from-end entry id. Apps that filter mine/calls
        // (Sonar) must supply unreadAnchorResolver — omitting it must not
        // silently abandon UnreadDivider opens to LiveEdge.
        let offset = max(0, entries.count - Int(unreadCountAtOpen))
        if offset < entries.count {
            unreadAnchorId = entries[offset].id
        } else {
            unreadAnchorAbandoned = true
        }
    }

    private func scrollToInitialPosition() {
        applyOpenAction(transcriptOpenAction)
    }

    private func applyOpenAction(_ action: TranscriptOpenAction) {
        switch action {
        case .unreadDivider:
            needsLiveEdgeOpen = false
            guard unreadAnchorId != nil else { return }
            hasLeftBottom = true
            latch.openInHistory(itemCount: entries.count, tailID: entries.last?.id)
            DispatchQueue.main.async { [weak self] in
                self?.scrollToUnreadDivider()
            }
        case .liveEdge:
            needsLiveEdgeOpen = true
            latch.tailVisible(itemCount: entries.count, tailID: entries.last?.id)
            DispatchQueue.main.async { [weak self] in
                self?.resnapFullyReadOpenIfNeeded()
            }
        case .jump(let id):
            needsLiveEdgeOpen = false
            hasLeftBottom = true
            latch.openInHistory(itemCount: entries.count, tailID: entries.last?.id)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let indexPath = self.dataSource?.indexPath(for: .message(id)) {
                    self.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
                }
            }
        }
    }

    private func resnapFullyReadOpenIfNeeded() {
        guard TranscriptScrollPolicy.shouldResnapFullyReadOpen(
            usesBottomScrollAnchor: usesBottomScrollAnchor,
            needsLiveEdgeOpen: needsLiveEdgeOpen,
            hasLeftBottom: hasLeftBottom,
            userScrolling: isUserScrolling,
            hasTailRow: entries.last?.id != nil
        ) else { return }
        latch.tailVisible(itemCount: entries.count, tailID: entries.last?.id)
        scrollToBottomOfLoadWindow(animated: false)
    }

    private func handleItemsChanged() {
        if let unreadCountAtOpen, unreadCountAtOpen > 0,
           unreadAnchorId == nil, !unreadAnchorAbandoned
        {
            return
        }
        if TranscriptScrollPolicy.shouldResnapFullyReadOpen(
            usesBottomScrollAnchor: usesBottomScrollAnchor,
            needsLiveEdgeOpen: needsLiveEdgeOpen,
            hasLeftBottom: hasLeftBottom,
            userScrolling: isUserScrolling,
            hasTailRow: entries.last?.id != nil
        ) {
            resnapFullyReadOpenIfNeeded()
            return
        }
        let near = isScrolledToBottom()
        let action = latch.itemsChanged(
            itemCount: entries.count,
            tailID: entries.last?.id,
            isNearBottom: near,
            userScrolling: isUserScrolling,
            isPrepending: isLoadingOlder
        )
        followTail(action, animateAppends: feedCaughtUp)
    }

    private func scrollToUnreadDivider() {
        guard let indexPath = dataSource?.indexPath(for: .unreadDivider) else { return }
        collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
    }

    private func scrollToBottomOfLoadWindow(animated: Bool) {
        collectionView.layoutIfNeeded()
        let y = transcriptScrollToBottomOfLoadWindowOffsetY(
            boundsHeight: collectionView.bounds.height,
            contentHeight: collectionView.contentSize.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom
        )
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: y),
            animated: animated
        )
        latch.tailVisible(itemCount: entries.count, tailID: entries.last?.id)
        if isScrolledToBottom() {
            needsLiveEdgeOpen = false
        }
    }

    private func isScrolledToBottom() -> Bool {
        let maxY = transcriptScrollToBottomOfLoadWindowOffsetY(
            boundsHeight: collectionView.bounds.height,
            contentHeight: collectionView.contentSize.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom
        )
        return collectionView.contentOffset.y >= maxY - 5
    }

    // MARK: Owned insets

    private func updateOwnedInsetsFromChrome() {
        let barHeight = composerContainer.bounds.height
        guard barHeight > 0, collectionView.bounds.height > 0 else { return }
        let composerInViewport = composerContainer.convert(composerContainer.bounds, to: view)
        let owned = transcriptOwnedBottomContentInset(
            collectionBoundsHeight: collectionView.bounds.height,
            composerMinYInViewport: composerInViewport.minY
        )
        let insetChanged = abs(collectionView.contentInset.bottom - owned) > 0.5
            || abs(lastBarHeight - barHeight) > 0.5
        guard insetChanged else { return }

        let near = isScrolledToBottom()
        let userScrolling = isUserScrolling
            || collectionView.isTracking
            || collectionView.isDragging
            || collectionView.isDecelerating

        let captured = TranscriptScrollPolicy.captureWasAtTail(
            currentlyNearBottom: near,
            previouslyPinned: latch.wasPinned,
            userScrolling: userScrolling,
            isPrepending: isLoadingOlder
        )
        if captured.wasAtTail {
            latch.tailVisible(itemCount: entries.count, tailID: entries.last?.id)
        } else if userScrolling {
            latch.userScrolled(isNearBottom: near)
        } else if isLoadingOlder {
            latch.openInHistory(itemCount: entries.count, tailID: entries.last?.id)
        } else {
            latch.userScrolled(isNearBottom: false)
        }

        lastBarHeight = barHeight
        var inset = collectionView.contentInset
        inset.top = 0
        inset.bottom = owned
        let oldOffset = collectionView.contentOffset
        let oldBottom = collectionView.adjustedContentInset.bottom
        UIView.performWithoutAnimation {
            collectionView.contentInset = inset
            collectionView.scrollIndicatorInsets = inset
            collectionView.contentOffset = oldOffset
        }

        let delta = owned - oldBottom
        switch captured.decision {
        case .pin:
            followTail(.snap, animateAppends: false)
        case .lockstep:
            applyLockstep(offsetY: oldOffset.y, delta: delta, bottomInset: owned)
        case .ignore:
            break
        }
        if needsLiveEdgeOpen {
            resnapFullyReadOpenIfNeeded()
        }
    }

    private func applyLockstep(offsetY: CGFloat, delta: CGFloat, bottomInset: CGFloat) {
        let target = offsetY + delta
        let corrected = transcriptRestingOffsetOvershootCorrection(
            offsetY: target,
            boundsHeight: collectionView.bounds.height,
            contentHeight: collectionView.contentSize.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: bottomInset
        ) ?? target
        let minY = -collectionView.adjustedContentInset.top
        let clamped = max(minY, corrected)
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: clamped),
            animated: false
        )
    }

    private func followTail(_ action: TranscriptTailPinAction, animateAppends: Bool) {
        guard action != .none else { return }
        if action == .snap {
            guard snapCoalescer.request() else { return }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + TranscriptScrollPolicy.snapCoalesceSeconds
            ) { [weak self] in
                guard let self, self.snapCoalescer.consume() else { return }
                self.scrollToBottomOfLoadWindow(animated: false)
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollToBottomOfLoadWindow(animated: animateAppends)
        }
    }

    // MARK: Continuity

    private func captureContinuityToken(anchorId: String) -> TranscriptContinuityToken {
        let maxY = transcriptScrollToBottomOfLoadWindowOffsetY(
            boundsHeight: collectionView.bounds.height,
            contentHeight: collectionView.contentSize.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom
        )
        let edgeDistance = maxY - collectionView.contentOffset.y
        return TranscriptScrollPolicy.continuityToken(anchorId: anchorId, edgeDistance: edgeDistance)
    }

    private func restoreContinuity(_ token: TranscriptContinuityToken) {
        collectionView.layoutIfNeeded()
        switch token.edge {
        case .edgeDistance(let distance):
            let contentHeight = collectionView.contentSize.height
            if contentHeight < 1, let indexPath = dataSource?.indexPath(for: .message(token.anchorId)) {
                collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
                return
            }
            let maxY = transcriptScrollToBottomOfLoadWindowOffsetY(
                boundsHeight: collectionView.bounds.height,
                contentHeight: contentHeight,
                topInset: collectionView.adjustedContentInset.top,
                bottomInset: collectionView.adjustedContentInset.bottom
            )
            let minY = -collectionView.adjustedContentInset.top
            let y = max(minY, maxY - distance)
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: y),
                animated: false
            )
        case .pixelOffset(let y):
            if let indexPath = dataSource?.indexPath(for: .message(token.anchorId)) {
                collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
            } else {
                let minY = -collectionView.adjustedContentInset.top
                collectionView.setContentOffset(
                    CGPoint(x: collectionView.contentOffset.x, y: max(minY, y)),
                    animated: false
                )
            }
        }
    }

    // MARK: Scroll delegate

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        needsLiveEdgeOpen = false
        recordUserScroll(isNearBottom: isScrolledToBottom())
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let near = isScrolledToBottom()
        if near {
            isUserScrolling = false
            userScrollGeneration &+= 1
            needsLiveEdgeOpen = false
            latch.tailVisible(itemCount: entries.count, tailID: entries.last?.id)
            if hasLeftBottom, let loadNewest, !isLoadingNewest, !isLoadingOlder {
                let anchorId = entries.last?.id ?? "transcript-bottom"
                let token = captureContinuityToken(anchorId: anchorId)
                isLoadingNewest = true
                Task { @MainActor in
                    await loadNewest()
                    self.isLoadingNewest = false
                    self.applySnapshot()
                    self.restoreContinuity(token)
                }
            }
        } else {
            if !latch.wasPinned || scrollView.isDragging || scrollView.isTracking {
                hasLeftBottom = true
            }
            if scrollView.isDragging || scrollView.isTracking {
                latch.userScrolled(isNearBottom: false)
            }
        }

        let mayLoadOlder = hasLeftBottom || unreadAnchorId != nil
        if mayLoadOlder, scrollView.contentOffset.y < 40,
           let loadOlder, !isLoadingOlder, !entries.isEmpty {
            let anchorId = entries[0].id
            let token = captureContinuityToken(anchorId: anchorId)
            isLoadingOlder = true
            latch.openInHistory(itemCount: entries.count, tailID: entries.last?.id)
            Task { @MainActor in
                let added = await loadOlder()
                self.isLoadingOlder = false
                guard added else { return }
                self.pendingContinuity = token
                self.applySnapshot()
                self.restoreContinuity(token)
                self.pendingContinuity = nil
            }
        }
    }

    private func recordUserScroll(isNearBottom: Bool) {
        isUserScrolling = true
        latch.userScrolled(isNearBottom: isNearBottom)
        userScrollGeneration &+= 1
        let generation = userScrollGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.userScrollGeneration == generation else { return }
            self.isUserScrolling = false
        }
    }
}
#endif
