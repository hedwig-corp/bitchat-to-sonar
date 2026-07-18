//
// SNTranscriptCollectionHost.swift
// bitchat
//
// Phase 3 UIKit transcript engine (Signal ConversationViewController shape):
// full-height UICollectionView + keyboardLayoutGuide composer + owned
// contentInset; open / pin / lockstep / continuity via SNTranscriptScrollPolicy.
// Cells are PRE-MEASURED (SNTranscriptRowHeightCache + sizeForItemAt) so
// contentSize is exact from the first layout — no self-sizing settle, no
// under-measured opens. Day markers are pinned section headers.
// Top-aligned short feeds only (no Spike B reverse).
// See docs/brainstorms/2026-07-18-signal-transcript-long-term-plan.md.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Flag

/// Feature flag for the UICollectionView transcript host. Phase 3 cutover:
/// default ON in every build. Kill switches: env `=0`, or (Debug only) the
/// Settings → Developer toggle (UserDefaults).
enum SNTranscriptCollectionHostFlag {
    static let environmentKey = "SONAR_TRANSCRIPT_COLLECTION_HOST"
    static let defaultsKey = "sonar.transcript.collectionHost"

    /// Default ON (Debug + Release). Env `=0` forces the SNMsgList fallback,
    /// env `=1` forces the host. UserDefaults is honored only in DEBUG so a
    /// dogfood toggle cannot stick a Release/TestFlight install on the
    /// fallback with no UI to recover.
    static var isEnabled: Bool {
        switch ProcessInfo.processInfo.environment[environmentKey] {
        case "0": return false
        case "1": return true
        default: break
        }
        #if DEBUG
        if let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Bool {
            return stored
        }
        #endif
        return true
    }

    static var entryVisible: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Settings → Developer toggle (Debug builds). Env still overrides.
    static func setEnabled(_ enabled: Bool) {
        #if DEBUG
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        #endif
    }
}

/// Owned bottom inset from composer occlusion in VIEWPORT coordinates — the
/// host view's space, NOT the scroll view's content space, which is shifted by
/// contentOffset and would collapse the inset to 0 at the tail of a long chat
/// (Signal `updateContentInsets`). Prefer this over barHeight−safeArea — the
/// keyboard layout guide already sits above the home indicator, so subtracting
/// safe-area again under-pads and hides the live edge under the composer.
func snCollectionHostOwnedBottomContentInset(
    collectionBoundsHeight: CGFloat,
    composerMinYInViewport: CGFloat
) -> CGFloat {
    max(0, collectionBoundsHeight - composerMinYInViewport)
}

/// Gap between the composer bottom and the keyboard top when both SwiftUI
/// keyboard avoidance and UIKit `keyboardLayoutGuide` own the same host.
/// Non-zero is the floating-composer band after the Phase 3 cutover: SwiftUI
/// shrinks the representable above the IME, then the guide lifts the composer
/// by roughly another keyboard height inside that already-shrunk frame.
/// Production opts out via `.ignoresSafeArea(.keyboard)` on the representable
/// so only UIKit owns IME geometry (`swiftUIKeyboardAvoidanceActive == false`).
func snCollectionHostFloatingComposerGap(
    keyboardOcclusionHeight: CGFloat,
    swiftUIKeyboardAvoidanceActive: Bool
) -> CGFloat {
    guard keyboardOcclusionHeight > 0, swiftUIKeyboardAvoidanceActive else { return 0 }
    return keyboardOcclusionHeight
}

/// Legacy helper kept for tests that pass chrome metrics without a live frame.
func snCollectionHostOwnedBottomContentInset(barHeight: CGFloat, safeAreaBottom: CGFloat) -> CGFloat {
    max(0, barHeight)
}

/// Fingerprint media geometry for the row-height cache key. Nil dims and
/// later MIP-04 bounds must not share a cache entry (reserved box changes).
func snCollectionHostMediaHeightFingerprint(_ media: [SNMediaItem]) -> String {
    media.map { "\($0.width ?? 0)x\($0.height ?? 0):\($0.mime)" }.joined(separator: ",")
}

// MARK: - Day sections (pure, testable)

/// One transcript row inside a day section.
enum SNTranscriptDayRow: Hashable {
    case unreadDivider
    case message(String)
}

/// A calendar-day section. `dayKey` is the unique diffable identity (epoch of
/// the local day start, suffixed on pathological re-occurrence); `label` is
/// display-only — two "5 Jul"s from different years must not collide.
struct SNTranscriptDaySection: Hashable {
    let dayKey: String
    let label: String
    var rows: [SNTranscriptDayRow]
}

/// Build day sections the way the transcript shows chips today: a section
/// starts on the first dated message of each new local day; undated rows
/// inherit the running section (leading undated rows get a headerless "" day).
/// Duplicate message ids are dropped (diffable traps on duplicates); the
/// unread divider lands immediately before its anchor row.
func snTranscriptDaySections(
    entries: [(id: String, date: Date?)],
    unreadAnchorId: String?,
    calendar: Calendar = .current,
    now: Date = Date()
) -> [SNTranscriptDaySection] {
    var sections: [SNTranscriptDaySection] = []
    var seenIDs = Set<String>()
    var usedDayKeys = Set<String>()
    var previousDay: Date?
    for entry in entries {
        let opensNewSection = sections.isEmpty
            || snTranscriptShowsDayChip(previous: previousDay, current: entry.date, calendar: calendar)
        if opensNewSection {
            var dayKey = ""
            var label = ""
            if let date = entry.date {
                dayKey = String(Int(calendar.startOfDay(for: date).timeIntervalSince1970))
                label = snTranscriptDayLabel(for: date, now: now, calendar: calendar)
            }
            // An unsorted feed could revisit a day; keep identities unique.
            var unique = dayKey
            var bump = 1
            while !usedDayKeys.insert(unique).inserted {
                unique = "\(dayKey)#\(bump)"
                bump += 1
            }
            sections.append(SNTranscriptDaySection(dayKey: unique, label: label, rows: []))
        }
        previousDay = entry.date ?? previousDay
        guard seenIDs.insert(entry.id).inserted else { continue }
        if entry.id == unreadAnchorId {
            sections[sections.count - 1].rows.append(.unreadDivider)
        }
        sections[sections.count - 1].rows.append(.message(entry.id))
    }
    return sections
}

// MARK: - Pre-measured heights (Signal CVC measure pass)

/// Width-scoped cache of exact row heights. Signal never lets the list layout
/// guess: every cell height is known before layout, so contentSize is exact
/// and open/continuity offset math is trustworthy. Keys must encode everything
/// that changes a row's height (text, expanded, footer state, neighbor flags).
final class SNTranscriptRowHeightCache {
    private(set) var width: CGFloat = 0
    private var heights: [String: CGFloat] = [:]

    /// Returns true when the width changed and every height was invalidated.
    @discardableResult
    func updateWidth(_ newWidth: CGFloat) -> Bool {
        guard abs(newWidth - width) > 0.5 else { return false }
        width = newWidth
        heights.removeAll()
        return true
    }

    func height(forKey key: String, measure: () -> CGFloat) -> CGFloat {
        if let cached = heights[key] { return cached }
        let measured = measure()
        heights[key] = measured
        return measured
    }

    var count: Int { heights.count }

    func removeAll() { heights.removeAll() }
}

// MARK: - SwiftUI entry (DM / Mac)

/// Replaces the production `SNMsgList` + sibling `SNComposer` pair when the
/// collection-host flag is on. iOS uses a UIKit collection host; macOS uses a
/// SwiftUI full-height + overlay-composer ownership model with the same policy.
struct SNTranscriptCollectionHost<Composer: View>: View {
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
    var unreadCountAtOpen: UInt64? = nil
    var expectedNewestDate: Date? = nil
    @ViewBuilder var composer: () -> Composer

    var body: some View {
        #if os(iOS)
        // UIKit owns IME via keyboardLayoutGuide. If SwiftUI also keyboard-avoids
        // this representable, the composer floats ~one keyboard height above the
        // IME (snCollectionHostFloatingComposerGap). Kill-switch SNMsgList keeps
        // the sibling-composer path and still wants SwiftUI avoidance.
        SNTranscriptCollectionRepresentable(
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
        .ignoresSafeArea(.keyboard, edges: .bottom)
        #else
        SNTranscriptCollectionSwiftUIHost(
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
/// Short feeds stay top-aligned. The Mac list engine stays SNMsgList (AppKit
/// collection parity is a tracked gap — docs/SIGNAL-TRANSCRIPT-PATTERNS.md).
private struct SNTranscriptCollectionSwiftUIHost<Composer: View>: View {
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
    var unreadCountAtOpen: UInt64?
    var expectedNewestDate: Date?
    @ViewBuilder var composer: () -> Composer

    @State private var chromeHeight: CGFloat = 56

    var body: some View {
        ZStack(alignment: .bottom) {
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
                        Color.clear.preference(
                            key: SNCollectionHostChromeHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
        }
        .onPreferenceChange(SNCollectionHostChromeHeightKey.self) { chromeHeight = $0 }
    }
}

private struct SNCollectionHostChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 56
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Floating day pill for pinned section headers (Signal's sticky date header).
struct SNStickyDayHeader: View {
    let label: String

    var body: some View {
        Text(verbatim: label)
            .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
            .foregroundColor(SonarTheme.text2)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(SonarTheme.surface2.opacity(0.94)))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

#if os(iOS)

// MARK: - UIKit host (Signal ConversationViewController shape)

/// Holds the live composer view without replacing `UIHostingController.rootView`.
/// Mutating `@Published composer` lets SwiftUI refresh props (transport /
/// placeholder / voiceEnabled) while preserving `SNComposer` `@State` (draft,
/// emoji tray, voice recorder). Assigning `rootView` on every update resets that
/// state — the bug this box exists to prevent.
private final class SNComposerRootStore<Composer: View>: ObservableObject {
    @Published var composer: Composer
    init(_ composer: Composer) { self.composer = composer }
}

private struct SNComposerRootView<Composer: View>: View {
    @ObservedObject var store: SNComposerRootStore<Composer>
    var body: some View {
        // The UIKit container is already placed by keyboardLayoutGuide above the
        // home indicator / IME. Suppress hosting safe-area bottom padding here
        // so iOS 16.0–16.3 (no `safeAreaRegions`) cannot add a second band.
        store.composer.ignoresSafeArea(.container, edges: .bottom)
    }
}

private struct SNTranscriptCollectionRepresentable<Composer: View>: UIViewControllerRepresentable {
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
    let unreadCountAtOpen: UInt64?
    let expectedNewestDate: Date?
    let composer: () -> Composer

    func makeUIViewController(context: Context) -> SNTranscriptCollectionViewController<Composer> {
        let vc = SNTranscriptCollectionViewController(composer: composer)
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
        _ uiViewController: SNTranscriptCollectionViewController<Composer>,
        context: Context
    ) {
        uiViewController.updateComposer(composer())
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

private enum SNCollectionHostItem: Hashable {
    case unreadDivider
    case message(String)
}

final class SNTranscriptCollectionViewController<Composer: View>: UIViewController,
    UICollectionViewDelegateFlowLayout
{
    private let collectionView: UICollectionView
    private let flowLayout: UICollectionViewFlowLayout
    private let composerContainer = UIView()
    private let composerStore: SNComposerRootStore<Composer>
    private let composerHost: UIHostingController<SNComposerRootView<Composer>>
    private var dataSource:
        UICollectionViewDiffableDataSource<SNTranscriptDaySection, SNCollectionHostItem>?

    private var msgs: [SNMessage] = []
    private var msgIndexByID: [String: Int] = [:]
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
    private var unreadCountAtOpen: UInt64? = nil
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
    private var latch = SNTailPinLatch()
    private var snapCoalescer = SNTailSnapCoalescer()
    private var lastBarHeight: CGFloat = 0
    private var pendingContinuity: SNTranscriptContinuityToken?
    private var composerBottomConstraint: NSLayoutConstraint?
    private var contentSizeObservation: NSKeyValueObservation?
    private var lastContentHeight: CGFloat = 0

    // Phase 3 measure pass: exact heights + one off-screen sizing host.
    private let heightCache = SNTranscriptRowHeightCache()
    private var sizingHost: UIHostingController<AnyView>?
    private var expandedMessageIDs: Set<String> = []
    private var appliedHeightKeys: [SNCollectionHostItem: String] = [:]

    init(composer: () -> Composer) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        // Phase 3: NO self-sizing. Every size comes from the measure pass via
        // sizeForItemAt, so contentSize is exact from the first layout.
        layout.estimatedItemSize = .zero
        layout.sectionHeadersPinToVisibleBounds = true
        flowLayout = layout
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        let store = SNComposerRootStore(composer())
        composerStore = store
        composerHost = UIHostingController(rootView: SNComposerRootView(store: store))
        super.init(nibName: nil, bundle: nil)
    }

    /// Refresh composer props without replacing `composerHost.rootView`.
    func updateComposer(_ composer: Composer) {
        composerStore.composer = composer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(SonarTheme.bg)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = UIColor(SonarTheme.bg)
        collectionView.keyboardDismissMode = .interactive
        // Signal: own insets; never let UIKit add a second keyboard band.
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        view.addSubview(collectionView)

        composerContainer.translatesAutoresizingMaskIntoConstraints = false
        composerContainer.backgroundColor = UIColor(SonarTheme.bg)
        view.addSubview(composerContainer)

        composerHost.view.translatesAutoresizingMaskIntoConstraints = false
        composerHost.view.backgroundColor = .clear
        // keyboardLayoutGuide already places the bar above the home indicator /
        // IME; hosting-controller safe-area padding would add a second band.
        if #available(iOS 16.4, *) {
            composerHost.safeAreaRegions = []
        }
        addChild(composerHost)
        composerContainer.addSubview(composerHost.view)
        composerHost.didMove(toParent: self)

        // Composer rides IME via keyboardLayoutGuide (iOS 15+). Requires the
        // SwiftUI representable to `.ignoresSafeArea(.keyboard)` — see
        // snCollectionHostFloatingComposerGap.
        let bottomToKeyboard = composerContainer.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor
        )
        composerBottomConstraint = bottomToKeyboard

        NSLayoutConstraint.activate([
            // Full-height collection — frame does not shrink for keyboard.
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
        // Media decode/self-layout can still grow contentSize marginally after
        // the first live-edge scroll (e.g. dimension-less media). Keep
        // re-pinning while the latch owns the tail (Signal wasAtBottom).
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
        // makeUIViewController may have called apply() before the view loaded;
        // materialize the stored msgs now (never touch dataSource until here).
        applySnapshot()
        if !didInitialScroll {
            scrollToInitialPosition()
            didInitialScroll = true
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = collectionView.bounds.width
        if width > 0, heightCache.updateWidth(width) {
            // Rotation / split-view width change: re-measure everything.
            flowLayout.invalidateLayout()
        }
        updateOwnedInsetsFromChrome()
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
        unreadCountAtOpen: UInt64?,
        expectedNewestDate: Date?
    ) {
        let previousRevision = SNTailRevision(itemCount: self.msgs.count, tailID: self.msgs.last?.id)
        let previousUnread = self.unreadCountAtOpen
        self.msgs = msgs
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(msgs.count)
        for (i, m) in msgs.enumerated() where indexByID[m.id] == nil {
            indexByID[m.id] = i
        }
        self.msgIndexByID = indexByID
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

        let hadAnchor = unreadAnchorId != nil
        resolveUnreadAnchor()
        // SwiftUI calls apply from makeUIViewController before viewDidLoad;
        // defer snapshot/scroll until the data source exists.
        guard isViewLoaded, dataSource != nil else { return }
        applySnapshot()

        let revision = SNTailRevision(itemCount: msgs.count, tailID: msgs.last?.id)
        if !didInitialScroll {
            scrollToInitialPosition()
            didInitialScroll = true
        } else if !hadAnchor, unreadAnchorId != nil {
            // Late-resolved divider owns open — drive via OpenAction only.
            applyOpenAction(.unreadDivider)
        } else if previousUnread != unreadCountAtOpen {
            // Capture settled (nil → 0/N) or unread changed — OpenAction only.
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
        let cellReg = UICollectionView.CellRegistration<UICollectionViewCell, SNCollectionHostItem> {
            [weak self] cell, _, item in
            guard let self else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                self.row(for: item)
            }
            .margins(.horizontal, 14)
            .margins(.vertical, 0)
            cell.backgroundConfiguration = .clear()
        }
        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard let self,
                  let section = self.dataSource?.sectionIdentifier(for: indexPath.section)
            else { return }
            header.contentConfiguration = UIHostingConfiguration {
                SNStickyDayHeader(label: section.label)
            }
            .margins(.all, 0)
            header.backgroundConfiguration = .clear()
        }
        let ds = UICollectionViewDiffableDataSource<SNTranscriptDaySection, SNCollectionHostItem>(
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

    /// Neighbor-derived render flags. Shared by the row builder and the
    /// height-cache key so a re-measure is forced whenever they change.
    private func rowFlags(index: Int) -> (cont: Bool, showAuthor: Bool, showState: Bool) {
        let m = msgs[index]
        let prev = index > 0 ? msgs[index - 1] : nil
        let cont = prev != nil && !(prev!.action) && prev!.author == m.author && prev!.mine == m.mine
        let showState = m.mine && (index == msgs.count - 1 || m.state == "Couldn't send")
        let showAuthor = showAuthors && !m.mine && !cont
        return (cont, showAuthor, showState)
    }

    private func heightKey(for item: SNCollectionHostItem) -> String {
        switch item {
        case .unreadDivider:
            return "u"
        case .message(let id):
            guard let index = msgIndexByID[id] else { return "m|\(id)" }
            let m = msgs[index]
            let flags = rowFlags(index: index)
            let bits = "\(flags.cont ? 1 : 0)\(flags.showAuthor ? 1 : 0)\(flags.showState ? 1 : 0)"
                + "\(expandedMessageIDs.contains(id) ? 1 : 0)"
            // Media dims must be in the key: nil→real width/height changes the
            // reserved box (snReservedMediaSize) and must invalidate the cache.
            let mediaKey = snCollectionHostMediaHeightFingerprint(m.media)
            return "m|\(id)|\(m.text)|\(m.state ?? "")|\(mediaKey)|\(bits)"
        }
    }

    /// Bubble max width from the collection column (not UIScreen) so measure
    /// and cell agree under Split View / Stage Manager.
    private var bubbleColumnWidth: CGFloat {
        let width = collectionView.bounds.width
        guard width > 0 else { return UIScreen.main.bounds.width }
        return max(1, width - 28) // 14pt horizontal margins each side
    }

    private func headerHeightKey(for section: SNTranscriptDaySection) -> String {
        "h|\(section.label)"
    }

    /// Off-screen SwiftUI measure (Signal's measure pass). The measured tree
    /// mirrors the cell exactly: same row view, same 14pt horizontal margins.
    private func measureHeight(for content: AnyView, width: CGFloat) -> CGFloat {
        let host: UIHostingController<AnyView>
        if let sizingHost {
            host = sizingHost
        } else {
            host = UIHostingController(rootView: AnyView(EmptyView()))
            if #available(iOS 16.4, *) {
                host.safeAreaRegions = []
            }
            sizingHost = host
        }
        host.rootView = content
        let size = host.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return max(1, ceil(size.height))
    }

    private func itemHeight(for item: SNCollectionHostItem, width: CGFloat) -> CGFloat {
        heightCache.height(forKey: heightKey(for: item)) { [weak self] in
            guard let self else { return 44 }
            return self.measureHeight(
                for: AnyView(self.row(for: item).padding(.horizontal, 14)),
                width: width
            )
        }
    }

    // MARK: UICollectionViewDelegateFlowLayout (exact sizes)

    func collectionView(
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

    func collectionView(
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
            return self.measureHeight(
                for: AnyView(SNStickyDayHeader(label: sectionID.label)),
                width: width
            )
        }
        return CGSize(width: width, height: height)
    }

    @ViewBuilder
    private func row(for item: SNCollectionHostItem) -> some View {
        switch item {
        case .unreadDivider:
            SNUnreadDivider()
        case .message(let id):
            if let index = msgIndexByID[id] {
                let flags = rowFlags(index: index)
                SNCollectionHostMessageRow(
                    message: msgs[index],
                    cont: flags.cont,
                    showAuthor: flags.showAuthor,
                    showState: flags.showState,
                    peerName: peerName,
                    money: money,
                    fiatText: fiatText,
                    onTapAuthor: onTapAuthor,
                    mediaPipeline: mediaPipeline,
                    loadSticker: loadSticker,
                    onTapPack: onTapPack,
                    onRetry: onRetry,
                    columnWidth: bubbleColumnWidth,
                    expandedMessageIDs: expandedMessageIDs,
                    onExpandedChange: { [weak self] newValue in
                        self?.expandedMessageIDsChanged(newValue)
                    }
                )
            }
        }
    }

    /// "Read more" expansion changes a row's height: reconfigure the cell and
    /// invalidate layout so the pre-measured size is recomputed (the cache key
    /// includes the expanded bit).
    private func expandedMessageIDsChanged(_ newValue: Set<String>) {
        guard newValue != expandedMessageIDs, let dataSource else {
            expandedMessageIDs = newValue
            return
        }
        let changed = newValue.symmetricDifference(expandedMessageIDs)
        expandedMessageIDs = newValue
        var snapshot = dataSource.snapshot()
        let items = changed.map { SNCollectionHostItem.message($0) }
            .filter { snapshot.indexOfItem($0) != nil }
        guard !items.isEmpty else { return }
        snapshot.reconfigureItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
        flowLayout.invalidateLayout()
    }

    private func applySnapshot() {
        guard let dataSource else { return }
        let sections = snTranscriptDaySections(
            entries: msgs.map { ($0.id, $0.sortDate) },
            unreadAnchorId: unreadAnchorId
        )
        var snapshot = NSDiffableDataSourceSnapshot<SNTranscriptDaySection, SNCollectionHostItem>()
        var newHeightKeys: [SNCollectionHostItem: String] = [:]
        var reconfigure: [SNCollectionHostItem] = []
        for var section in sections {
            let rows = section.rows
            section.rows = []
            snapshot.appendSections([section])
            let items: [SNCollectionHostItem] = rows.map {
                switch $0 {
                case .unreadDivider: return .unreadDivider
                case .message(let id): return .message(id)
                }
            }
            snapshot.appendItems(items, toSection: section)
            for item in items {
                let key = heightKey(for: item)
                newHeightKeys[item] = key
                // Same identity, different height inputs (e.g. delivery footer
                // moved to a newer row): repaint + re-measure that cell.
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

    // MARK: Open / unread (SNTranscriptOpenAction only)

    private var feedCaughtUp: Bool {
        guard let expected = expectedNewestDate else { return true }
        if let newest = msgs.last?.sortDate { return newest >= expected }
        guard let newest = msgs.lazy.compactMap(\.sortDate).max() else { return false }
        return newest >= expected
    }

    private var usesBottomScrollAnchor: Bool {
        SNTranscriptScrollPolicy.usesBottomScrollAnchor(
            unreadAnchorId: unreadAnchorId,
            unreadCountAtOpen: unreadCountAtOpen,
            unreadAnchorAbandoned: unreadAnchorAbandoned
        )
    }

    private var transcriptOpenAction: SNTranscriptOpenAction {
        SNTranscriptScrollPolicy.openAction(
            unreadAnchorId: unreadAnchorId,
            unreadCountAtOpen: unreadCountAtOpen,
            unreadAnchorAbandoned: unreadAnchorAbandoned
        )
    }

    private func resolveUnreadAnchor() {
        guard let unreadCountAtOpen, unreadCountAtOpen > 0 else { return }
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
        applyOpenAction(transcriptOpenAction)
    }

    /// Drive open exclusively from `SNTranscriptOpenAction` — no parallel
    /// unread-count gate that can fight the enum.
    private func applyOpenAction(_ action: SNTranscriptOpenAction) {
        switch action {
        case .unreadDivider:
            needsLiveEdgeOpen = false
            // Pending unread without a resolved divider id: wait (do not scroll).
            guard unreadAnchorId != nil else { return }
            hasLeftBottom = true
            latch.openInHistory(itemCount: msgs.count, tailID: msgs.last?.id)
            DispatchQueue.main.async { [weak self] in
                self?.scrollToUnreadDivider()
            }
        case .liveEdge:
            needsLiveEdgeOpen = true
            latch.tailVisible(itemCount: msgs.count, tailID: msgs.last?.id)
            DispatchQueue.main.async { [weak self] in
                self?.resnapFullyReadOpenIfNeeded()
            }
        case .jump(let id):
            needsLiveEdgeOpen = false
            hasLeftBottom = true
            latch.openInHistory(itemCount: msgs.count, tailID: msgs.last?.id)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let indexPath = self.dataSource?.indexPath(for: .message(id)) {
                    self.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
                }
            }
        }
    }

    private func resnapFullyReadOpenIfNeeded() {
        guard SNTranscriptScrollPolicy.shouldResnapFullyReadOpen(
            usesBottomScrollAnchor: usesBottomScrollAnchor,
            needsLiveEdgeOpen: needsLiveEdgeOpen,
            hasLeftBottom: hasLeftBottom,
            userScrolling: isUserScrolling,
            hasTailRow: msgs.last?.id != nil
        ) else { return }
        latch.tailVisible(itemCount: msgs.count, tailID: msgs.last?.id)
        scrollToBottomOfLoadWindow(animated: false)
    }

    private func handleItemsChanged() {
        // While divider is still pending, do not follow merged rows to the tail.
        if let unreadCountAtOpen, unreadCountAtOpen > 0,
           unreadAnchorId == nil, !unreadAnchorAbandoned
        {
            return
        }
        if SNTranscriptScrollPolicy.shouldResnapFullyReadOpen(
            usesBottomScrollAnchor: usesBottomScrollAnchor,
            needsLiveEdgeOpen: needsLiveEdgeOpen,
            hasLeftBottom: hasLeftBottom,
            userScrolling: isUserScrolling,
            hasTailRow: msgs.last?.id != nil
        ) {
            resnapFullyReadOpenIfNeeded()
            return
        }
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
        guard let indexPath = dataSource?.indexPath(for: .unreadDivider) else { return }
        collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
    }

    /// Settled open: with pre-measured cells contentSize is exact after one
    /// layout pass, so the live-edge offset math lands exactly — no visited-
    /// cell settle loop.
    private func scrollToBottomOfLoadWindow(animated: Bool) {
        collectionView.layoutIfNeeded()
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
        if isScrolledToBottom() {
            needsLiveEdgeOpen = false
        }
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

    // MARK: Owned insets + real Lockstep

    /// Signal `updateContentInsets`: capture wasAtTail via policy, mutate owned
    /// bottom inset, then pin | lockstep (offset += Δ clamped) | ignore.
    private func updateOwnedInsetsFromChrome() {
        let barHeight = composerContainer.bounds.height
        guard barHeight > 0, collectionView.bounds.height > 0 else { return }
        // Measure the composer in the VIEWPORT (host view) space — never via
        // convert(to: collectionView): a scroll view's coordinate space is
        // shifted by contentOffset, so at the tail of a long chat the converted
        // minY is huge and the owned inset collapses to 0, dropping the last
        // message under the composer.
        let composerInViewport = composerContainer.convert(
            composerContainer.bounds,
            to: view
        )
        let owned = snCollectionHostOwnedBottomContentInset(
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

        // Capture wasAtTail BEFORE mutating contentInset (Signal).
        let captured = SNTranscriptScrollPolicy.captureWasAtTail(
            currentlyNearBottom: near,
            previouslyPinned: latch.wasPinned,
            userScrolling: userScrolling,
            isPrepending: isLoadingOlder
        )
        if captured.wasAtTail {
            latch.tailVisible(itemCount: msgs.count, tailID: msgs.last?.id)
        } else if userScrolling {
            latch.userScrolled(isNearBottom: near)
        } else if isLoadingOlder {
            latch.openInHistory(itemCount: msgs.count, tailID: msgs.last?.id)
        } else {
            // Lockstep path: keep latch unpinned without treating as deliberate history open.
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

    /// Signal non-pinned branch: `offset += Δ`, clamped to content bounds so
    /// keyboard dismiss never leaves a blank band under the last message.
    private func applyLockstep(offsetY: CGFloat, delta: CGFloat, bottomInset: CGFloat) {
        let target = offsetY + delta
        let corrected = snRestingOffsetOvershootCorrection(
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

    private func followTail(_ action: SNTailPinAction, animateAppends: Bool) {
        guard action != .none else { return }
        if action == .snap {
            guard snapCoalescer.request() else { return }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + SNTranscriptScrollPolicy.snapCoalesceSeconds
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

    // MARK: ContinuityToken (loadOlder / loadNewer)

    private func captureContinuityToken(anchorId: String) -> SNTranscriptContinuityToken {
        let maxY = snScrollToBottomOfLoadWindowOffsetY(
            boundsHeight: collectionView.bounds.height,
            contentHeight: collectionView.contentSize.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom
        )
        let edgeDistance = maxY - collectionView.contentOffset.y
        return SNTranscriptScrollPolicy.continuityToken(
            anchorId: anchorId,
            edgeDistance: edgeDistance
        )
    }

    /// Restore after prepend/append. With pre-measured cells the edge-distance
    /// restore (Signal `lastKnownDistanceFromBottom`) is exact.
    private func restoreContinuity(_ token: SNTranscriptContinuityToken) {
        collectionView.layoutIfNeeded()
        switch token.edge {
        case .edgeDistance(let distance):
            let contentHeight = collectionView.contentSize.height
            if contentHeight < 1, let indexPath = dataSource?.indexPath(for: .message(token.anchorId)) {
                collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
                return
            }
            let maxY = snScrollToBottomOfLoadWindowOffsetY(
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

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        needsLiveEdgeOpen = false
        recordUserScroll(isNearBottom: isScrolledToBottom())
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let near = isScrolledToBottom()
        if near {
            isUserScrolling = false
            userScrollGeneration &+= 1
            needsLiveEdgeOpen = false
            latch.tailVisible(itemCount: msgs.count, tailID: msgs.last?.id)
            // loadNewest only after the reader has left the live edge once
            // (matches SNMsgList sn-bottom onAppear gate).
            if hasLeftBottom, let loadNewest, !isLoadingNewest, !isLoadingOlder {
                let anchorId = msgs.last?.id ?? "sn-bottom"
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

        // loadOlder near top — ContinuityToken, not preserveID hope-scroll.
        let mayLoadOlder = hasLeftBottom || unreadAnchorId != nil
        if mayLoadOlder, scrollView.contentOffset.y < 40,
           let loadOlder, !isLoadingOlder, !msgs.isEmpty {
            let anchorId = msgs[0].id
            let token = captureContinuityToken(anchorId: anchorId)
            isLoadingOlder = true
            latch.openInHistory(itemCount: msgs.count, tailID: msgs.last?.id)
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

/// Cell bubble bridge. Render flags (`cont` / `showAuthor` / `showState`) are
/// computed by the controller so the measure pass and the cell agree; the
/// expanded set lives on the controller so "read more" survives cell reuse and
/// re-measures the row.
private struct SNCollectionHostMessageRow: View {
    let message: SNMessage
    let cont: Bool
    let showAuthor: Bool
    let showState: Bool
    let peerName: String
    let money: (Int64) -> String
    let fiatText: (Int64) -> String?
    let onTapAuthor: ((SNMessage) -> Void)?
    let mediaPipeline: SNMediaPipeline
    let loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)?
    let onTapPack: ((String) -> Void)?
    let onRetry: ((SNMessage) -> Void)?
    /// Collection column width (margins already subtracted). Never UIScreen —
    /// measure and cell must agree under Split View.
    let columnWidth: CGFloat
    let expandedMessageIDs: Set<String>
    let onExpandedChange: (Set<String>) -> Void

    var body: some View {
        let m = message
        let textMax = columnWidth * 0.78
        let mediaMax = columnWidth * 0.72
        Group {
            if let call = m.call {
                SNCallLogRow(call: call, mine: m.mine, time: m.time)
            } else if m.pay != nil {
                SNPayBubble(
                    m: m,
                    peerName: peerName,
                    money: money,
                    fiatText: fiatText,
                    maxBubbleWidth: textMax
                )
            } else if !m.media.isEmpty {
                SNMediaBubble(
                    m: m,
                    maxBubbleWidth: mediaMax,
                    showState: showState,
                    onRetry: snCanRetryFailedMessage(m) ? { onRetry?(m) } : nil,
                    pipeline: mediaPipeline
                )
            } else if m.stickerRef != nil {
                SNStickerBubble(
                    m: m,
                    showAuthor: showAuthor,
                    showState: showState,
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
                SNMsgBubble(
                    m: m,
                    preview: SonarTranscriptDisplayPolicy.preview(m.text),
                    expandedMessageIDs: Binding(
                        get: { expandedMessageIDs },
                        set: { onExpandedChange($0) }
                    ),
                    showAuthor: showAuthor,
                    cont: cont,
                    showState: showState,
                    onRetry: snCanRetryFailedMessage(m) ? { onRetry?(m) } : nil,
                    maxBubbleWidth: textMax,
                    onTapAuthor: onTapAuthor
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
}

#endif
