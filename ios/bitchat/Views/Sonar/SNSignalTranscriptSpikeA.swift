//
// SNSignalTranscriptSpikeA.swift
// bitchat
//
// Spike A — Signal-iOS short-feed transcript host (feature-flagged).
// Full-height collection, composer on keyboard/bottom chrome, owned bottom
// inset = bar height, short feeds TOP-ALIGNED (empty space above composer is
// correct). Preserves SNTailPinLatch / R-009 semantics. Not a full SNMsgList
// cutover: sticky dates / pre-measured cells are stubs.
//
// Enable (DEBUG only):
//   • env SONAR_SPIKE_SIGNAL_TRANSCRIPT_A=1
//   • defaults: sonar.spike.signalTranscriptA = YES
//

import SwiftUI
import TranscriptEngine
#if os(iOS)
import UIKit
#endif

// MARK: - Flag

enum SNSignalTranscriptSpikeA {
    static let environmentKey = "SONAR_SPIKE_SIGNAL_TRANSCRIPT_A"
    static let defaultsKey = "sonar.spike.signalTranscriptA"

    /// Release always false. Debug: env wins, then UserDefaults.
    static var isEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment[environmentKey] == "1" { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey)
        #else
        return false
        #endif
    }
}

// MARK: - Owned inset (Signal updateContentInsets bottom bar)

/// Spike A / Signal-iOS: `newInsets.bottom = barHeight - safeArea.bottom`.
/// Unlike production `snOwnedTranscriptBottomContentInset` (always 0 — composer
/// is a VStack sibling), the spike owns the chrome height inside the scroll view.
func snSpikeAOwnedBottomContentInset(barHeight: CGFloat, safeAreaBottom: CGFloat) -> CGFloat {
    max(0, barHeight - safeAreaBottom)
}

// MARK: - SwiftUI entry (DM / Mac)

/// Replaces the production `SNMsgList` + sibling `SNComposer` pair when the
/// spike flag is on. iOS uses a UIKit collection host; macOS uses a SwiftUI
/// full-height + overlay-composer ownership model with the same policy.
struct SNSignalTranscriptSpikeAHost<Composer: View>: View {
    let msgs: [SNMessage]
    let showAuthors: Bool
    var peerName: String = ""
    var money: (Int64) -> String = { sonarFormatSats($0) }
    var fiatText: (Int64) -> String? = { _ in nil }
    var onTapAuthor: ((SNMessage) -> Void)? = nil
    var mediaPipeline: SNMediaPipeline = .unavailable
    var loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)? = nil
    var onTapPack: ((String) -> Void)? = nil
    var onRetry: ((SNMessage) -> Void)? = nil
    var loadOlder: (() async -> Bool)? = nil
    var loadNewest: (() async -> Void)? = nil
    var unreadCountAtOpen: UInt64 = 0
    var expectedNewestDate: Date? = nil
    @ViewBuilder var composer: () -> Composer

    var body: some View {
        #if os(iOS)
        SNSignalTranscriptSpikeARepresentable(
            msgs: msgs,
            showAuthors: showAuthors,
            peerName: peerName,
            money: money,
            fiatText: fiatText,
            onTapAuthor: onTapAuthor,
            mediaPipeline: mediaPipeline,
            loadSticker: loadSticker,
            onTapPack: onTapPack,
            onRetry: onRetry,
            loadOlder: loadOlder,
            loadNewest: loadNewest,
            unreadCountAtOpen: unreadCountAtOpen,
            expectedNewestDate: expectedNewestDate,
            composer: composer
        )
        #else
        SNSignalTranscriptSpikeASwiftUIHost(
            msgs: msgs,
            showAuthors: showAuthors,
            peerName: peerName,
            money: money,
            fiatText: fiatText,
            onTapAuthor: onTapAuthor,
            mediaPipeline: mediaPipeline,
            loadSticker: loadSticker,
            onTapPack: onTapPack,
            onRetry: onRetry,
            loadOlder: loadOlder,
            loadNewest: loadNewest,
            unreadCountAtOpen: unreadCountAtOpen,
            expectedNewestDate: expectedNewestDate,
            composer: composer
        )
        #endif
    }
}

// MARK: - macOS / shared SwiftUI ownership host

/// Full-height scroll + overlay composer; bottom content pad = measured chrome.
/// Short feeds stay top-aligned (no contentSize top spacers). Latch via
/// production SNMsgList helpers reused through a thin scroll surface.
private struct SNSignalTranscriptSpikeASwiftUIHost<Composer: View>: View {
    let msgs: [SNMessage]
    let showAuthors: Bool
    var peerName: String
    var money: (Int64) -> String
    var fiatText: (Int64) -> String?
    var onTapAuthor: ((SNMessage) -> Void)?
    var mediaPipeline: SNMediaPipeline
    var loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)?
    var onTapPack: ((String) -> Void)?
    var onRetry: ((SNMessage) -> Void)?
    var loadOlder: (() async -> Bool)?
    var loadNewest: (() async -> Void)?
    var unreadCountAtOpen: UInt64
    var expectedNewestDate: Date?
    @ViewBuilder var composer: () -> Composer

    @State private var chromeHeight: CGFloat = 56

    var body: some View {
        ZStack(alignment: .bottom) {
            // Production SNMsgList still owns unread/latch; spike proves the
            // chrome ownership shell (full-height under overlay composer).
            // Bottom pad is applied as scroll content inset via preference —
            // not a LazyVStack top spacer.
            SNMsgList(
                msgs: msgs,
                showAuthors: showAuthors,
                peerName: peerName,
                money: money,
                fiatText: fiatText,
                onTapAuthor: onTapAuthor,
                mediaPipeline: mediaPipeline,
                loadSticker: loadSticker,
                onTapPack: onTapPack,
                onRetry: onRetry,
                loadOlder: loadOlder,
                loadNewest: loadNewest,
                unreadCountAtOpen: unreadCountAtOpen,
                expectedNewestDate: expectedNewestDate
            )
            .padding(.bottom, chromeHeight)

            composer()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SNSpikeAChromeHeightKey.self, value: geo.size.height)
                    }
                )
        }
        .onPreferenceChange(SNSpikeAChromeHeightKey.self) { chromeHeight = $0 }
    }
}

private struct SNSpikeAChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 56
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#if os(iOS)

// MARK: - UIKit host (Signal ConversationViewController shape)

private struct SNSignalTranscriptSpikeARepresentable<Composer: View>: UIViewControllerRepresentable {
    let msgs: [SNMessage]
    let showAuthors: Bool
    let peerName: String
    let money: (Int64) -> String
    let fiatText: (Int64) -> String?
    let onTapAuthor: ((SNMessage) -> Void)?
    let mediaPipeline: SNMediaPipeline
    let loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)?
    let onTapPack: ((String) -> Void)?
    let onRetry: ((SNMessage) -> Void)?
    let loadOlder: (() async -> Bool)?
    let loadNewest: (() async -> Void)?
    let unreadCountAtOpen: UInt64
    let expectedNewestDate: Date?
    let composer: () -> Composer

    func makeUIViewController(context: Context) -> SNSignalTranscriptSpikeAViewController<Composer> {
        let vc = SNSignalTranscriptSpikeAViewController(composer: composer)
        vc.apply(
            msgs: msgs,
            showAuthors: showAuthors,
            peerName: peerName,
            money: money,
            fiatText: fiatText,
            onTapAuthor: onTapAuthor,
            mediaPipeline: mediaPipeline,
            loadSticker: loadSticker,
            onTapPack: onTapPack,
            onRetry: onRetry,
            loadOlder: loadOlder,
            loadNewest: loadNewest,
            unreadCountAtOpen: unreadCountAtOpen,
            expectedNewestDate: expectedNewestDate
        )
        return vc
    }

    func updateUIViewController(
        _ uiViewController: SNSignalTranscriptSpikeAViewController<Composer>,
        context: Context
    ) {
        // Do not reassign composerHost.rootView here — that resets SNComposer
        // @State (draft). Closures from make capture the store reference type.
        uiViewController.apply(
            msgs: msgs,
            showAuthors: showAuthors,
            peerName: peerName,
            money: money,
            fiatText: fiatText,
            onTapAuthor: onTapAuthor,
            mediaPipeline: mediaPipeline,
            loadSticker: loadSticker,
            onTapPack: onTapPack,
            onRetry: onRetry,
            loadOlder: loadOlder,
            loadNewest: loadNewest,
            unreadCountAtOpen: unreadCountAtOpen,
            expectedNewestDate: expectedNewestDate
        )
    }
}

private enum SNSpikeAItem: Hashable {
    case dateChip(String)
    case unreadDivider
    case message(String)
}

final class SNSignalTranscriptSpikeAViewController<Composer: View>: UIViewController,
    UICollectionViewDelegate
{
    private let collectionView: UICollectionView
    private let composerContainer = UIView()
    private let composerHost: UIHostingController<Composer>
    private var dataSource: UICollectionViewDiffableDataSource<Int, SNSpikeAItem>!

    private var msgs: [SNMessage] = []
    private var showAuthors = false
    private var peerName = ""
    private var money: (Int64) -> String = { sonarFormatSats($0) }
    private var fiatText: (Int64) -> String? = { _ in nil }
    private var onTapAuthor: ((SNMessage) -> Void)?
    private var mediaPipeline: SNMediaPipeline = .unavailable
    private var loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)?
    private var onTapPack: ((String) -> Void)?
    private var onRetry: ((SNMessage) -> Void)?
    private var loadOlder: (() async -> Bool)?
    private var loadNewest: (() async -> Void)?
    private var unreadCountAtOpen: UInt64 = 0
    private var expectedNewestDate: Date?

    private var unreadAnchorId: String?
    private var unreadAnchorAbandoned = false
    private var didInitialScroll = false
    private var isLoadingOlder = false
    private var isUserScrolling = false
    private var userScrollGeneration: UInt = 0
    private var latch = SNTailPinLatch()
    private var snapCoalescer = SNTailSnapCoalescer()
    private var lastBarHeight: CGFloat = 0
    private var composerBottomConstraint: NSLayoutConstraint?

    init(composer: () -> Composer) {
        let layout = UICollectionViewCompositionalLayout { _, env in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = false
            config.backgroundColor = UIColor(SonarTheme.bg)
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: env)
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        composerHost = UIHostingController(rootView: composer())
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(SonarTheme.bg)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = UIColor(SonarTheme.bg)
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        view.addSubview(collectionView)

        composerContainer.translatesAutoresizingMaskIntoConstraints = false
        composerContainer.backgroundColor = UIColor(SonarTheme.bg)
        view.addSubview(composerContainer)

        composerHost.view.translatesAutoresizingMaskIntoConstraints = false
        composerHost.view.backgroundColor = .clear
        addChild(composerHost)
        composerContainer.addSubview(composerHost.view)
        composerHost.didMove(toParent: self)

        let bottomToKeyboard = composerContainer.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor
        )
        composerBottomConstraint = bottomToKeyboard

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
        // TODO(Spike A→depth C): sticky date headers via section supplementary;
        // pre-measured CV-style cells (UIHostingConfiguration is a temporary bridge).
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateOwnedInsetsFromChrome(reason: .layout)
    }

    func apply(
        msgs: [SNMessage],
        showAuthors: Bool,
        peerName: String,
        money: @escaping (Int64) -> String,
        fiatText: @escaping (Int64) -> String?,
        onTapAuthor: ((SNMessage) -> Void)?,
        mediaPipeline: SNMediaPipeline,
        loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)?,
        onTapPack: ((String) -> Void)?,
        onRetry: ((SNMessage) -> Void)?,
        loadOlder: (() async -> Bool)?,
        loadNewest: (() async -> Void)?,
        unreadCountAtOpen: UInt64,
        expectedNewestDate: Date?
    ) {
        let previousRevision = SNTailRevision(itemCount: self.msgs.count, tailID: self.msgs.last?.id)
        self.msgs = msgs
        self.showAuthors = showAuthors
        self.peerName = peerName
        self.money = money
        self.fiatText = fiatText
        self.onTapAuthor = onTapAuthor
        self.mediaPipeline = mediaPipeline
        self.loadSticker = loadSticker
        self.onTapPack = onTapPack
        self.onRetry = onRetry
        self.loadOlder = loadOlder
        self.loadNewest = loadNewest
        self.unreadCountAtOpen = unreadCountAtOpen
        self.expectedNewestDate = expectedNewestDate
        // loadNewest wired for depth-C live-edge restore; unused in Spike A host.
        _ = self.loadNewest

        resolveUnreadAnchor()
        applySnapshot()

        let revision = SNTailRevision(itemCount: msgs.count, tailID: msgs.last?.id)
        if !didInitialScroll {
            scrollToInitialPosition()
            didInitialScroll = true
        } else if revision != previousRevision {
            handleItemsChanged()
        }
    }

    // MARK: Data source

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, SNSpikeAItem> {
            [weak self] cell, _, item in
            guard let self else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                self.row(for: item)
            }
            .margins(.horizontal, 14)
            .margins(.vertical, 0)
            cell.backgroundConfiguration = .clear()
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }
    }

    @ViewBuilder
    private func row(for item: SNSpikeAItem) -> some View {
        switch item {
        case .dateChip(let label):
            SNDateChip(label: label)
        case .unreadDivider:
            SNUnreadDivider()
        case .message(let id):
            if let m = msgs.first(where: { $0.id == id }),
               let index = msgs.firstIndex(where: { $0.id == id }) {
                SNSpikeAMessageRow(
                    message: m,
                    index: index,
                    msgs: msgs,
                    showAuthors: showAuthors,
                    peerName: peerName,
                    money: money,
                    fiatText: fiatText,
                    onTapAuthor: onTapAuthor,
                    mediaPipeline: mediaPipeline,
                    loadSticker: loadSticker,
                    onTapPack: onTapPack,
                    onRetry: onRetry
                )
            }
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, SNSpikeAItem>()
        snapshot.appendSections([0])
        var items: [SNSpikeAItem] = []
        var previousDay: Date?
        for m in msgs {
            if snTranscriptShowsDayChip(previous: previousDay, current: m.sortDate),
               let day = m.sortDate {
                items.append(.dateChip(snTranscriptDayLabel(for: day)))
            }
            previousDay = m.sortDate ?? previousDay
            if m.id == unreadAnchorId {
                items.append(.unreadDivider)
            }
            items.append(.message(m.id))
        }
        snapshot.appendItems(items, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: Open / unread / latch

    private var feedCaughtUp: Bool {
        guard let expected = expectedNewestDate else { return true }
        if let newest = msgs.last?.sortDate { return newest >= expected }
        guard let newest = msgs.lazy.compactMap(\.sortDate).max() else { return false }
        return newest >= expected
    }

    private func resolveUnreadAnchor() {
        guard unreadCountAtOpen > 0 else { return }
        if let current = unreadAnchorId, msgs.contains(where: { $0.id == current }) { return }
        if let expected = expectedNewestDate,
           let newest = msgs.compactMap(\.sortDate).max(),
           newest < expected {
            return
        }
        var remaining = unreadCountAtOpen
        var anchor: String?
        for m in msgs.reversed() where !m.mine && m.call == nil {
            anchor = m.id
            remaining -= 1
            if remaining == 0 { break }
        }
        unreadAnchorId = anchor
        if anchor == nil { unreadAnchorAbandoned = true }
    }

    private func scrollToInitialPosition() {
        // Match SNMsgList / SNTranscriptScrollPolicy: pending unread must NOT
        // yank to the live edge while the divider id is unresolved.
        let action = SNTranscriptScrollPolicy.openAction(
            unreadAnchorId: unreadAnchorId,
            unreadCountAtOpen: unreadCountAtOpen,
            unreadAnchorAbandoned: unreadAnchorAbandoned
        )
        switch action {
        case .unreadDivider:
            latch.openInHistory(itemCount: msgs.count, tailID: msgs.last?.id)
            guard unreadAnchorId != nil else { return }
            DispatchQueue.main.async { [weak self] in
                self?.scrollToUnreadDivider()
            }
        case .liveEdge, .jump:
            latch.tailVisible(itemCount: msgs.count, tailID: msgs.last?.id)
            DispatchQueue.main.async { [weak self] in
                self?.scrollToBottomOfLoadWindow(animated: false)
            }
        }
    }

    private func handleItemsChanged() {
        if unreadCountAtOpen > 0, unreadAnchorId == nil, !unreadAnchorAbandoned { return }
        let near = isScrolledToBottom()
        let action = latch.itemsChanged(
            itemCount: msgs.count,
            tailID: msgs.last?.id,
            isNearBottom: near,
            userScrolling: isUserScrolling,
            isPrepending: isLoadingOlder
        )
        followTail(action, animateAppends: feedCaughtUp)
    }

    private func scrollToUnreadDivider() {
        guard let indexPath = dataSource.indexPath(for: .unreadDivider) else { return }
        collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
    }

    private func scrollToBottomOfLoadWindow(animated: Bool) {
        let y = snScrollToBottomOfLoadWindowOffsetY(
            boundsHeight: collectionView.bounds.height,
            contentHeight: collectionView.contentSize.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom
        )
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: y),
            animated: animated
        )
        latch.tailVisible(itemCount: msgs.count, tailID: msgs.last?.id)
    }

    private func isScrolledToBottom() -> Bool {
        let maxY = snScrollToBottomOfLoadWindowOffsetY(
            boundsHeight: collectionView.bounds.height,
            contentHeight: collectionView.contentSize.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom
        )
        return collectionView.contentOffset.y >= maxY - 5
    }

    private enum InsetReason { case layout, keyboard }

    private func updateOwnedInsetsFromChrome(reason: InsetReason) {
        let barHeight = composerContainer.bounds.height
        guard barHeight > 0 else { return }
        let owned = snSpikeAOwnedBottomContentInset(
            barHeight: barHeight,
            safeAreaBottom: view.safeAreaInsets.bottom
        )
        let insetChanged = abs(collectionView.contentInset.bottom - owned) > 0.5
            || abs(lastBarHeight - barHeight) > 0.5
        guard insetChanged else { return }

        // Signal: capture wasScrolledToBottom BEFORE mutating contentInset.
        let near = isScrolledToBottom()
        let action = latch.viewportWillChange(
            isNearBottom: near,
            userScrolling: isUserScrolling || collectionView.isTracking
                || collectionView.isDragging || collectionView.isDecelerating,
            isPrepending: isLoadingOlder
        )

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

        if action == .snap || action == .animate {
            followTail(action, animateAppends: false)
        } else if !near {
            // History lockstep: shift offset with inset delta, clamp (Signal).
            let delta = owned - oldBottom
            let target = oldOffset.y + delta
            if let corrected = snRestingOffsetOvershootCorrection(
                offsetY: target,
                boundsHeight: collectionView.bounds.height,
                contentHeight: collectionView.contentSize.height,
                topInset: collectionView.adjustedContentInset.top,
                bottomInset: owned
            ) {
                collectionView.setContentOffset(
                    CGPoint(x: oldOffset.x, y: corrected),
                    animated: false
                )
            } else {
                collectionView.setContentOffset(
                    CGPoint(x: oldOffset.x, y: target),
                    animated: false
                )
            }
        }
        _ = reason
    }

    private func followTail(_ action: SNTailPinAction, animateAppends: Bool) {
        guard action != .none else { return }
        if action == .snap {
            guard snapCoalescer.request() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
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

    // MARK: Scroll delegate (user scroll + pagination stubs)

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        recordUserScroll(isNearBottom: isScrolledToBottom())
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let near = isScrolledToBottom()
        if near {
            isUserScrolling = false
            userScrollGeneration &+= 1
            latch.tailVisible(itemCount: msgs.count, tailID: msgs.last?.id)
        } else if scrollView.isDragging || scrollView.isTracking {
            latch.userScrolled(isNearBottom: false)
        }

        // loadOlder when approaching top (stub continuity — Spike depth C later).
        if scrollView.contentOffset.y < 40, let loadOlder, !isLoadingOlder, !msgs.isEmpty {
            let preserveID = msgs[0].id
            isLoadingOlder = true
            Task { @MainActor in
                let added = await loadOlder()
                self.isLoadingOlder = false
                guard added else { return }
                self.applySnapshot()
                if let indexPath = self.dataSource.indexPath(for: .message(preserveID)) {
                    self.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
                }
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

/// Thin bubble bridge for spike cells. Full media/pre-measure is depth C.
private struct SNSpikeAMessageRow: View {
    let message: SNMessage
    let index: Int
    let msgs: [SNMessage]
    let showAuthors: Bool
    let peerName: String
    let money: (Int64) -> String
    let fiatText: (Int64) -> String?
    let onTapAuthor: ((SNMessage) -> Void)?
    let mediaPipeline: SNMediaPipeline
    let loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)?
    let onTapPack: ((String) -> Void)?
    let onRetry: ((SNMessage) -> Void)?

    @State private var expandedMessageIDs: Set<String> = []

    var body: some View {
        let m = message
        Group {
            if let call = m.call {
                SNCallLogRow(call: call, mine: m.mine, time: m.time)
            } else if m.pay != nil {
                SNPayBubble(
                    m: m,
                    peerName: peerName,
                    money: money,
                    fiatText: fiatText,
                    maxBubbleWidth: UIScreen.main.bounds.width * 0.78
                )
            } else if !m.media.isEmpty {
                let showDeliveryState = m.mine && (index == msgs.count - 1 || m.state == "Couldn't send")
                SNMediaBubble(
                    m: m,
                    maxBubbleWidth: UIScreen.main.bounds.width * 0.72,
                    showState: showDeliveryState,
                    onRetry: snCanRetryFailedMessage(m) ? { onRetry?(m) } : nil,
                    pipeline: mediaPipeline
                )
            } else if m.stickerRef != nil {
                let showDeliveryState = m.mine && (index == msgs.count - 1 || m.state == "Couldn't send")
                SNStickerBubble(
                    m: m,
                    showAuthor: showAuthors && !m.mine,
                    showState: showDeliveryState,
                    onRetry: snCanRetryFailedMessage(m) ? { onRetry?(m) } : nil,
                    load: loadSticker,
                    onTapPack: onTapPack
                )
            } else if m.action {
                Text(verbatim: m.text)
                    .font(SonarTheme.uiFont(size: 13).italic())
                    .foregroundColor(SonarTheme.text3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 9)
                    .padding(.horizontal, 20)
            } else {
                let prev = index > 0 ? msgs[index - 1] : nil
                let cont = prev != nil && !(prev!.action) && prev!.author == m.author && prev!.mine == m.mine
                SNMsgBubble(
                    m: m,
                    preview: SonarTranscriptDisplayPolicy.preview(m.text),
                    expandedMessageIDs: $expandedMessageIDs,
                    showAuthor: showAuthors && !m.mine && !cont,
                    cont: cont,
                    showState: m.mine && (index == msgs.count - 1 || m.state == "Couldn't send"),
                    onRetry: snCanRetryFailedMessage(m) ? { onRetry?(m) } : nil,
                    maxBubbleWidth: UIScreen.main.bounds.width * 0.78,
                    onTapAuthor: onTapAuthor,
                    mentions: m.mentions
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
}

#endif
