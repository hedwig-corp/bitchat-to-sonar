#if os(iOS)
import SwiftUI
import TranscriptEngine
import UIKit
#if DEBUG
import BitLogger
#endif

// MARK: - Sonar render context (cells + measure pass for library host)

@MainActor
final class SNTranscriptHostRenderContext: ObservableObject {
    var msgs: [SNMessage] = []
    var msgIndexByID: [String: Int] = [:]
    /// Cached host entries for the current upstream revision — rebuilt only
    /// when `upstreamRenderRevision` advances (not on every SwiftUI body).
    private(set) var hostEntries: [TranscriptHostEntry] = []
    /// Last `SNConversationRenderState.revision` applied into msgs/index/entries.
    private(set) var upstreamRenderRevision: UInt64 = 0
    var showAuthors = false
    var peerName = ""
    var money: (Int64) -> String = { sonarFormatSats($0) }
    var fiatText: (Int64) -> String? = { _ in nil }
    var onTapAuthor: ((SNMessage) -> Void)?
    var mediaPipeline: SNMediaPipeline = .unavailable
    var loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)?
    var onTapPack: ((String) -> Void)?
    var onRetry: ((SNMessage) -> Void)?
    var onCancelUpload: ((SNMessage) -> Void)?
    var uploadProgressSource: SNMediaUploadProgressSource?
    var onReply: ((SNMessage) -> Void)?
    var onJumpQuote: ((String) -> Void)?
    /// Environment-injected in SwiftUI; the UIKit cell needs it as a closure.
    var onTapMention: ((String) -> Void)?

    /// Pre-measured UIKit rows: the collection view (for column width and
    /// layout direction), the derived paint models, and the shared actions.
    private weak var collectionView: UICollectionView?
    private var textBubbleModels: [String: SNTextBubbleModel] = [:]
    private var textBubbleModelOrder: [String] = []
    private static let textBubbleModelLimit = 600
    private lazy var textBubbleActions: SNTextBubbleActions = makeTextBubbleActions()

    @Published var expandedMessageIDs: Set<String> = [] {
        didSet { contentRevision &+= 1 }
    }
    /// O(1) transcript content revision: bumped only when rows or row-affecting
    /// inputs change. The collection host skips its O(n) snapshot rebuild while
    /// this is unchanged (composer keystrokes, unrelated store publishes).
    ///
    /// Private on purpose: SwiftUI `body` runs BEFORE `prepareForUpdate`'s
    /// `sync`, so a raw read here ships the revision of the PREVIOUS msgs next
    /// to the NEW entries, and `shouldSkipUnchangedApply` then swallows the
    /// apply that carries a real row change (the send/echo-swap pass). The
    /// stale snapshot keeps a dead row id that renders as a blank band and
    /// collapses on scroll until the next forced apply. Callers must use
    /// `contentVersion(afterSyncing:showAuthors:peerName:)`.
    private var contentRevision: UInt64 = 0

    /// The revision `sync` WILL hold after syncing these inputs — safe to read
    /// from `body` (pure). Must mirror `sync`'s bump condition exactly so the
    /// version shipped with `entries` describes the same snapshot.
    func contentVersion(
        afterSyncing renderState: SNConversationRenderState,
        showAuthors: Bool,
        peerName: String
    ) -> UInt64 {
        let rowsOrChromeChanged =
            renderState.revision != upstreamRenderRevision
            || showAuthors != self.showAuthors
            || peerName != self.peerName
        return rowsOrChromeChanged ? contentRevision &+ 1 : contentRevision
    }

    /// Entries to ship with `body` for this renderState — O(1) when the
    /// upstream revision is unchanged; otherwise builds once and caches.
    func entries(for renderState: SNConversationRenderState) -> [TranscriptHostEntry] {
        if renderState.revision == upstreamRenderRevision, !hostEntries.isEmpty || renderState.messages.isEmpty {
            return hostEntries
        }
        // Body can run before sync on a NEW revision; build a temporary list
        // that matches what sync will install so entries and contentVersion
        // stay paired. Cache lands in sync.
        return renderState.messages.map { TranscriptHostEntry(id: $0.id, date: $0.sortDate) }
    }

    private var sizingHost: UIHostingController<AnyView>?

    func sync(
        renderState: SNConversationRenderState,
        showAuthors: Bool,
        peerName: String,
        money: @escaping (Int64) -> String,
        fiatText: @escaping (Int64) -> String?,
        onTapAuthor: ((SNMessage) -> Void)?,
        mediaPipeline: SNMediaPipeline,
        loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)?,
        onTapPack: ((String) -> Void)?,
        onRetry: ((SNMessage) -> Void)?,
        onCancelUpload: ((SNMessage) -> Void)?,
        uploadProgressSource: SNMediaUploadProgressSource?,
        onReply: ((SNMessage) -> Void)?,
        onJumpQuote: ((String) -> Void)?,
        onTapMention: ((String) -> Void)?
    ) {
        // Bump only on real row-content change: composer keystrokes republish
        // the store with an identical transcript revision and must stay O(1).
        // peerName is row content too: nudge and pay bubbles render it, so a
        // name resolving after open (notification-tap before contact metadata
        // loads) must not be swallowed by the skip path.
        let revisionAdvanced = renderState.revision != upstreamRenderRevision
        if revisionAdvanced || showAuthors != self.showAuthors || peerName != self.peerName {
            contentRevision &+= 1
        }
        if revisionAdvanced || peerName != self.peerName {
            // Models are keyed by height key, which deliberately does NOT cover
            // every painted field (transport icon, resolved author, decoded
            // mentions, quoted peer name). Those can be filled in on a rebuild
            // without moving the key, so derived paint state is dropped whenever
            // the transcript revision or the peer name moves. Cheap: the host's
            // own height cache absorbs measure calls, so only visible cells
            // rebuild a model.
            textBubbleModels.removeAll(keepingCapacity: true)
            textBubbleModelOrder.removeAll(keepingCapacity: true)
        }
        if revisionAdvanced {
            self.msgs = renderState.messages
            self.msgIndexByID = renderState.messageIndexByID
            self.hostEntries = renderState.messages.map {
                TranscriptHostEntry(id: $0.id, date: $0.sortDate)
            }
            self.upstreamRenderRevision = renderState.revision
        }
        self.showAuthors = showAuthors
        self.peerName = peerName
        self.money = money
        self.fiatText = fiatText
        self.onTapAuthor = onTapAuthor
        self.mediaPipeline = mediaPipeline
        self.loadSticker = loadSticker
        self.onTapPack = onTapPack
        self.onRetry = onRetry
        self.onCancelUpload = onCancelUpload
        self.uploadProgressSource = uploadProgressSource
        self.onReply = onReply
        self.onJumpQuote = onJumpQuote
        self.onTapMention = onTapMention
    }

    /// Row identity for measure + reconfigure. Text and quote previews are
    /// hashed rather than embedded: the flow layout derives this key for every
    /// loaded row on each `invalidateLayout`, so the key must stay short and
    /// cheap to hash regardless of message length.
    func heightKey(for item: TranscriptDayRow) -> String {
        switch item {
        case .unreadDivider:
            return "u"
        case .message(let id):
            guard let index = msgIndexByID[id] else { return "m|\(id)" }
            let m = msgs[index]
            let flags = rowFlags(index: index)
            let bits = "\(flags.cont ? 1 : 0)\(flags.showAuthor ? 1 : 0)\(flags.showState ? 1 : 0)"
                + "\(expandedMessageIDs.contains(id) ? 1 : 0)"
            let mediaKey = snCollectionHostMediaHeightFingerprint(m.media)
            // Nudge and pay rows render (and wrap on) the peer's display name;
            // a resolved name must re-measure and reconfigure exactly those.
            let nameKey = (m.trill || m.pay != nil) ? "|\(peerName)" : ""
            let replyKey = m.reply.map { "|r:\($0.parentId):\(snFNV1a(($0.author ?? "") + "\u{1}" + $0.preview))" } ?? ""
            return "m|\(id)|\(snFNV1a(m.text))|\(m.state ?? "")|\(mediaKey)|\(bits)\(nameKey)\(replyKey)"
        }
    }

    // MARK: Pre-measured UIKit text rows (Signal CVCell / CVCellMeasurement)

    private var textBubbleColumnWidth: CGFloat {
        let width = collectionView?.bounds.width ?? UIScreen.main.bounds.width
        return max(1, width - SNTextBubbleCell.horizontalInset * 2)
    }

    private var textBubbleLeftToRight: Bool {
        (collectionView?.effectiveUserInterfaceLayoutDirection ?? .leftToRight) == .leftToRight
    }

    /// Cached per `(id, height key)` so a row's paint state is derived once, not
    /// on every configure or measure.
    private func textBubbleModel(index: Int, id: String, key: String) -> SNTextBubbleModel {
        if let hit = textBubbleModels[key] { return hit }
        let flags = rowFlags(index: index)
        let model = SNTextBubbleModel.make(
            message: msgs[index],
            isContinuation: flags.cont,
            showAuthor: flags.showAuthor,
            showState: flags.showState,
            quotedPeerName: flags.showAuthor ? nil : peerName,
            isExpanded: expandedMessageIDs.contains(id),
            authorTappable: onTapAuthor != nil,
            measurementKey: key
        )
        textBubbleModels[key] = model
        textBubbleModelOrder.append(key)
        if textBubbleModelOrder.count > Self.textBubbleModelLimit {
            textBubbleModels.removeValue(forKey: textBubbleModelOrder.removeFirst())
        }
        return model
    }

    /// Nil for rows the UIKit cell does not own (media, stickers, pay, calls,
    /// nudges, action lines) — those keep the SwiftUI hosting path.
    private func textBubbleModel(for item: TranscriptDayRow, key: String? = nil) -> SNTextBubbleModel? {
        guard snUIKitTextBubblesEnabled() else { return nil }
        guard case .message(let id) = item, let index = msgIndexByID[id] else { return nil }
        guard SNTextBubbleModel.handles(msgs[index]) else { return nil }
        return textBubbleModel(index: index, id: id, key: key ?? heightKey(for: item))
    }

    private func makeTextBubbleActions() -> SNTextBubbleActions {
        SNTextBubbleActions(
            reply: { [weak self] id in
                guard let self, let index = self.msgIndexByID[id] else { return }
                self.onReply?(self.msgs[index])
            },
            jumpQuote: { [weak self] parentId in self?.onJumpQuote?(parentId) },
            tapAuthor: { [weak self] id in
                guard let self, let index = self.msgIndexByID[id] else { return }
                self.onTapAuthor?(self.msgs[index])
            },
            tapMention: { [weak self] npub in self?.onTapMention?(npub) },
            openURL: { url in UIApplication.shared.open(url) },
            retry: { [weak self] id in
                guard let self, let index = self.msgIndexByID[id] else { return }
                self.onRetry?(self.msgs[index])
            },
            toggleExpanded: { [weak self] id in
                guard let self else { return }
                if self.expandedMessageIDs.contains(id) {
                    self.expandedMessageIDs.remove(id)
                } else {
                    self.expandedMessageIDs.insert(id)
                }
            }
        )
    }

    func makeCallbacks() -> TranscriptCollectionHostCallbacks {
        TranscriptCollectionHostCallbacks(
            configureCell: { [weak self] collectionView, cell, _, item in
                guard let self else { return }
                // Same column source as itemHeight / main bubbleColumnWidth —
                // never size against UIScreen while the collection already has
                // a width (Split View / first configure with empty cell bounds).
                let column = collectionView.bounds.width > 0
                    ? collectionView.bounds.width
                    : UIScreen.main.bounds.width
                let width = max(1, column - 28)
                cell.contentConfiguration = UIHostingConfiguration {
                    self.row(for: item, columnWidth: width)
                }
                .margins(.horizontal, 14)
                .margins(.vertical, 0)
                cell.backgroundConfiguration = .clear()
            },
            itemHeight: { [weak self] item, key, width in
                guard let self else { return 44 }
                let column = max(1, width - SNTextBubbleCell.horizontalInset * 2)
                if let model = self.textBubbleModel(for: item, key: key) {
                    return SNTextBubbleMeasurementCache.shared.geometry(
                        model: model,
                        columnWidth: column,
                        leftToRight: self.textBubbleLeftToRight
                    ).totalHeight
                }
                return self.measureHeight(
                    for: AnyView(self.row(for: item, columnWidth: column).padding(.horizontal, 14)),
                    width: width
                )
            },
            headerHeight: { [weak self] label, width in
                guard let self else { return 28 }
                return self.measureHeight(
                    for: AnyView(SNStickyDayHeader(label: label)),
                    width: width
                )
            },
            configureHeader: { _, header, _, label in
                header.contentConfiguration = UIHostingConfiguration {
                    SNStickyDayHeader(label: label)
                }
                .margins(.all, 0)
                header.backgroundConfiguration = .clear()
            },
            registerCells: { [weak self] collectionView in
                self?.collectionView = collectionView
                collectionView.register(
                    SNTextBubbleCell.self,
                    forCellWithReuseIdentifier: SNTextBubbleCell.reuseIdentifier
                )
            },
            provideCell: { [weak self] collectionView, indexPath, item in
                guard let self, let model = self.textBubbleModel(for: item) else { return nil }
                guard let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: SNTextBubbleCell.reuseIdentifier,
                    for: indexPath
                ) as? SNTextBubbleCell else { return nil }
                let geometry = SNTextBubbleMeasurementCache.shared.geometry(
                    model: model,
                    columnWidth: self.textBubbleColumnWidth,
                    leftToRight: self.textBubbleLeftToRight
                )
                cell.configure(model: model, geometry: geometry, actions: self.textBubbleActions)
                return cell
            },
            unreadAnchorResolver: { [weak self] entries, unreadCount in
                guard let self else { return nil }
                var remaining = unreadCount
                var anchor: String?
                for entry in entries.reversed() {
                    guard let index = self.msgIndexByID[entry.id] else { continue }
                    let m = self.msgs[index]
                    guard !m.mine, m.call == nil else { continue }
                    anchor = m.id
                    remaining -= 1
                    if remaining == 0 { break }
                }
                return anchor
            }
        )
    }

    private func rowFlags(index: Int) -> (cont: Bool, showAuthor: Bool, showState: Bool) {
        let m = msgs[index]
        let prev = index > 0 ? msgs[index - 1] : nil
        let cont = prev != nil && !(prev!.action) && prev!.author == m.author && prev!.mine == m.mine
        let showState = m.mine && (index == msgs.count - 1 || m.state == "Couldn't send")
        let showAuthor = showAuthors && !m.mine && !cont
        return (cont, showAuthor, showState)
    }

    @ViewBuilder
    private func row(for item: TranscriptDayRow, columnWidth: CGFloat) -> some View {
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
                    onCancelUpload: onCancelUpload,
                    uploadProgressSource: uploadProgressSource,
                    onReply: onReply,
                    onJumpQuote: onJumpQuote,
                    columnWidth: columnWidth,
                    expandedMessageIDs: expandedMessageIDs,
                    onExpandedChange: { [weak self] newValue in
                        guard let self, newValue != self.expandedMessageIDs else { return }
                        self.expandedMessageIDs = newValue
                    }
                )
            }
        }
    }

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
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return max(1, ceil(size.height))
    }
}

// MARK: - Thin wrapper around TranscriptEngine generic host

struct SNTranscriptCollectionRepresentable<Composer: View>: View {
    let renderState: SNConversationRenderState
    let showAuthors: Bool
    let peerName: String
    let money: (Int64) -> String
    let fiatText: (Int64) -> String?
    let onTapAuthor: ((SNMessage) -> Void)?
    let mediaPipeline: SNMediaPipeline
    let loadSticker: ((MarmotService.MarmotStickerRef, Bool) async -> Data?)?
    let onTapPack: ((String) -> Void)?
    let onRetry: ((SNMessage) -> Void)?
    let onCancelUpload: ((SNMessage) -> Void)?
    let uploadProgressSource: SNMediaUploadProgressSource?
    var onReply: ((SNMessage) -> Void)? = nil
    var onJumpQuote: ((String) -> Void)? = nil
    let loadOlder: (() async -> Bool)?
    let loadNewest: (() async -> Void)?
    let unreadCountAtOpen: UInt64?
    let expectedNewestDate: Date?
    /// Search / deep-link jump target; wins over unread/live-edge open (#372).
    var jumpMessageId: String? = nil
    var onJumpSettled: (() -> Void)? = nil
    var composerVersion: UInt64? = nil
    @ViewBuilder var composer: () -> Composer

    @StateObject private var renderContext = SNTranscriptHostRenderContext()
    /// The pre-measured UIKit cell cannot read SwiftUI environment, so the
    /// mention-tap handler is threaded into the render context instead.
    @Environment(\.snMentionTap) private var onTapMention

    var body: some View {
        let version = renderContext.contentVersion(
            afterSyncing: renderState,
            showAuthors: showAuthors,
            peerName: peerName
        )
        #if DEBUG
        let _ = SNTranscriptApplyMeter.record(
            skipped: renderState.revision == renderContext.upstreamRenderRevision
                && showAuthors == renderContext.showAuthors
                && peerName == renderContext.peerName,
            revision: renderState.revision
        )
        #endif
        // Keep sync off the SwiftUI body path — `prepareForUpdate` runs inside
        // `make`/`updateUIViewController` before `apply`.
        TranscriptCollectionHostView(
            entries: renderContext.entries(for: renderState),
            heightKey: { renderContext.heightKey(for: $0) },
            callbacks: renderContext.makeCallbacks(),
            unreadCountAtOpen: unreadCountAtOpen,
            expectedNewestDate: expectedNewestDate,
            jumpMessageId: jumpMessageId,
            loadOlder: loadOlder,
            loadNewest: loadNewest,
            transcriptBackgroundColor: UIColor(SonarTheme.bg),
            prepareForUpdate: {
                renderContext.sync(
                    renderState: renderState,
                    showAuthors: showAuthors,
                    peerName: peerName,
                    money: money,
                    fiatText: fiatText,
                    onTapAuthor: onTapAuthor,
                    mediaPipeline: mediaPipeline,
                    loadSticker: loadSticker,
                    onTapPack: onTapPack,
                    onRetry: onRetry,
                    onCancelUpload: onCancelUpload,
                    uploadProgressSource: uploadProgressSource,
                    onReply: onReply,
                    onJumpQuote: onJumpQuote,
                    onTapMention: onTapMention
                )
            },
            onJumpSettled: onJumpSettled,
            // Post-sync revision, predicted from the same renderState as
            // `entries` above — a raw pre-sync read is one bump stale and lets
            // the host skip the apply that carries this pass's row change.
            contentVersion: version,
            composerVersion: composerVersion,
            composer: composer
        )
    }
}

#endif
