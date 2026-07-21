#if os(iOS)
import SwiftUI
import TranscriptEngine
import UIKit

// MARK: - Sonar render context (cells + measure pass for library host)

@MainActor
final class SNTranscriptHostRenderContext: ObservableObject {
    var msgs: [SNMessage] = []
    var msgIndexByID: [String: Int] = [:]
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

    @Published var expandedMessageIDs: Set<String> = [] {
        didSet { contentRevision &+= 1 }
    }
    /// O(1) transcript content revision: bumped only when rows or row-affecting
    /// inputs change. The collection host skips its O(n) snapshot rebuild while
    /// this is unchanged (composer keystrokes, unrelated store publishes).
    private(set) var contentRevision: UInt64 = 0
    private var sizingHost: UIHostingController<AnyView>?

    func sync(
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
        onCancelUpload: ((SNMessage) -> Void)?,
        uploadProgressSource: SNMediaUploadProgressSource?
    ) {
        // Bump only on real row-content change: composer keystrokes republish
        // the store with an identical transcript and must stay O(1) here.
        if msgs != self.msgs || showAuthors != self.showAuthors {
            contentRevision &+= 1
        }
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
        self.onCancelUpload = onCancelUpload
        self.uploadProgressSource = uploadProgressSource
    }

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
            return "m|\(id)|\(m.text)|\(m.state ?? "")|\(mediaKey)|\(bits)"
        }
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
            itemHeight: { [weak self] item, _, width in
                guard let self else { return 44 }
                return self.measureHeight(
                    for: AnyView(self.row(for: item, columnWidth: max(1, width - 28)).padding(.horizontal, 14)),
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
    let onCancelUpload: ((SNMessage) -> Void)?
    let uploadProgressSource: SNMediaUploadProgressSource?
    let loadOlder: (() async -> Bool)?
    let loadNewest: (() async -> Void)?
    let unreadCountAtOpen: UInt64?
    let expectedNewestDate: Date?
    /// Search / deep-link jump target; wins over unread/live-edge open (#372).
    var jumpMessageId: String? = nil
    var onJumpSettled: (() -> Void)? = nil
    @ViewBuilder var composer: () -> Composer

    @StateObject private var renderContext = SNTranscriptHostRenderContext()

    var body: some View {
        // Keep sync off the SwiftUI body path — `prepareForUpdate` runs inside
        // `make`/`updateUIViewController` before `apply`.
        TranscriptCollectionHostView(
            entries: msgs.map { TranscriptHostEntry(id: $0.id, date: $0.sortDate) },
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
                    onCancelUpload: onCancelUpload,
                    uploadProgressSource: uploadProgressSource
                )
            },
            onJumpSettled: onJumpSettled,
            contentVersion: renderContext.contentRevision,
            composer: composer
        )
    }
}

#endif
