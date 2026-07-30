//
// SonarDMScreen.swift
// bitchat
//
// Encrypted, transport-aware direct message screen (DMScreen in
// design/handoff/project/sonar/screens.jsx), backed by real transcripts:
// ChatViewModel private chats (mesh / NIP-17 via MessageRouter) or Marmot
// (White Noise / MLS) groups. Verify sheet uses the real fingerprints.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import AVFoundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
import ImageIO
#endif

/// Movie payload from the Photos picker delivered as a FILE: the transfer
/// lands on disk and is copied into our own temp dir (the picker deletes its
/// copy when the import closure returns), so a large video never buffers
/// through memory on the pick path.
private struct PickedVideoFile: Transferable {
    let url: URL

    var suggestedFilename: String {
        let ext = url.pathExtension.lowercased()
        return "video." + (ext.isEmpty ? "mp4" : ext)
    }

    var mime: String {
        switch url.pathExtension.lowercased() {
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        default: return "video/mp4"
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sonar-picked")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "mp4" : received.file.pathExtension
            let dest = dir.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}

/// Thin wrapper that resolves the per-conversation render state from the
/// store: `@ObservedObject` needs the object at init, and the environment
/// store is only available in `body`. Navigation keeps constructing
/// `SonarDMScreen(peerId:)` unchanged.
struct SonarDMScreen: View {
    @EnvironmentObject private var store: SonarAppStore
    let peerId: String

    var body: some View {
        SonarDMScreenContent(peerId: peerId, convo: store.conversationViewState(peerId))
    }
}

struct SonarDMScreenContent: View {
    @EnvironmentObject private var store: SonarAppStore
    let peerId: String
    /// Precomputed transcript — the ONLY message source this view renders.
    /// Built off the render path in ConversationViewState; reading it here is
    /// O(1) and re-renders happen only when the transcript actually changed.
    @ObservedObject private var convo: ConversationViewState

    init(peerId: String, convo: ConversationViewState) {
        self.peerId = peerId
        self._convo = ObservedObject(wrappedValue: convo)
    }

    @State private var sheet = false
    @State private var verifySheet = false
    @State private var showKey = false
    @State private var paySheet = false
    @State private var walletSheet = false
    @State private var addPeopleSheet = false
    @State private var removePeopleSheet = false
    @State private var toast: String?
    @State private var groupAddDraft = ""
    @State private var selectedAddNpubs: Set<String> = []
    @State private var pickPhoto = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pickFile = false
    @State private var attachmentImportGeneration = 0
    @State private var previewPackCoordinate: String?

    private static let maxInternetAttachmentBytes = 25 * 1024 * 1024

    private var peer: SNPeerItem { store.peerItem(peerId) }
    private var isMarmot: Bool { store.marmotGroupId(peerId) != nil || store.isPendingSecureChat(peerId) }
    private var isMultiMemberMarmot: Bool { store.isMultiMemberMarmotGroupId(peerId) }
    private var isSonar: Bool { store.sonarProfile(peerId) != nil }
    private var verified: Bool { !isMultiMemberMarmot && store.isVerified(peerId) }
    private var transport: SNVia { store.dmTransport(peerId) }
    private var walletReady: Bool {
        if case .ready = store.walletState { return true }
        return false
    }

    /// Header sub: the network name prefixes the encryption line.
    private var subTransport: String {
        ((isMarmot || isSonar) ? "Sonar" : "bitchat") + " · end-to-end encrypted"
    }

    @ViewBuilder
    private var dmComposer: some View {
        SNComposer(
            text: store.composerDraftBinding(for: peerId),
            placeholder: "Message \(peer.name)" + (transport == .internet ? " · via internet" : ""),
            transport: transport,
            onSend: { text in
                // Delivery must never wait on a historical-window reset or
                // its unrelated metadata reads. Move back to the live edge
                // independently after the send has entered the local-first
                // transport/outbox path.
                store.sendDm(peerId, text)
                // Paint the local echo in this frame instead of waiting on the
                // store invalidation debounce (background bursts keep it).
                convo.rebuildNow()
                Task { @MainActor in
                    await convo.loadNewestIfNeeded()
                }
            },
            onPlus: { sheet = true },
            onCommand: { cmd in
                store.onCommand(.init(type: .dm, id: peerId, target: peer.name), cmd)
            },
            onSticker: { sticker, coord in
                store.sendSticker(peerId, sticker: sticker, packCoordinate: coord)
                convo.rebuildNow()
                Task { @MainActor in
                    await convo.loadNewestIfNeeded()
                }
            },
            loadStickerPack: { author, identifier, relays in
                await store.stickerPack(authorPubkeyHex: author, identifier: identifier, relayUrls: relays)
            },
            loadStickerImage: { await store.stickerImageData(url: $0, expectedSha256: $1) },
            fetchInstalledPacks: { await store.fetchInstalledPacks() },
            cachedStickerPacks: { store.cachedStickerPacks() },
            voiceEnabled: store.canSendMedia(peerId),
            onVoice: { store.sendVoiceNote(peerId, url: $0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SNNavHeader(onBack: { store.pop() }, content: {
                Button {
                    if isMultiMemberMarmot, store.marmotGroupId(peerId) != nil {
                        store.push(.groupInfo(peerId))
                    } else if !isMultiMemberMarmot {
                        store.push(.contactProfile(peerId, peer.name))
                    }
                } label: {
                    SonarAvatar(name: peer.name, size: 36, presence: transport == .mesh)
                    SNHeaderTitle(name: peer.name, verified: verified) {
                        SNIcon(name: .lock, size: 11, weight: 2.4)
                        Text(verbatim: (verified ? "Verified · " : "") + subTransport)
                    }
                }
                .buttonStyle(.plain)
            }, trailing: {
                // Calls are Sonar-only: shown when the peer advertised calls and
                // BLE or White Noise can signal.
                if store.canCall(peerId) {
                    SNIconButton(action: { store.placeCall(peerId, video: false) }) {
                        SNIcon(name: .phone, size: 20)
                    }
                    SNIconButton(action: { store.placeCall(peerId, video: true) }) {
                        SNIcon(name: .videocam, size: 21)
                    }
                }
            })

            banner

            let msgs = convo.messages
            if msgs.isEmpty && store.isLocallyHydratingDM(peerId) {
                ProgressView()
                    .tint(SonarTheme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if msgs.isEmpty {
                SNEmptyState(
                    icon: .lock,
                    iconSize: 24,
                    title: "Say hi to \(peer.name)",
                    desc: isMultiMemberMarmot
                        ? "Messages here are end-to-end encrypted. Only group members can read them."
                        : "Messages here are end-to-end encrypted. Only the two of you can read them."
                )
                dmComposer
            } else if SNTranscriptCollectionHostFlag.isEnabled {
                // Production Signal engine (Phase 3 cutover, default ON):
                // full-height collection + keyboardLayoutGuide composer +
                // owned insets + pre-measured cells + sticky day headers.
                // SNMsgList below is the kill-switch fallback.
                SNTranscriptCollectionHost(
                    msgs: msgs,
                    showAuthors: isMultiMemberMarmot,
                    peerName: peer.name,
                    money: { store.money($0) },
                    fiatText: { store.moneySatsLine($0) },
                    mediaPipeline: SNMediaPipeline(
                        state: { store.mediaTransferState($0) },
                        prepare: { store.prepareMedia($0, autoDownload: $1) },
                        request: { store.requestMediaDownload($0) },
                        cancel: { store.cancelMediaDownload($0) },
                        loadLocal: { await store.mediaData($0) }
                    ),
                    loadSticker: { await store.stickerImageData(for: $0, userInitiated: $1) },
                    onTapPack: { previewPackCoordinate = $0 },
                    onRetry: { store.retryDm(peerId, message: $0) },
                    onCancelUpload: { store.cancelMediaUpload($0) },
                    uploadProgressSource: store.marmot.mediaUploadProgressSource,
                    loadOlder: { await convo.loadOlder() },
                    loadNewest: { await convo.loadNewestIfNeeded() },
                    unreadCountAtOpen: store.unreadCountAtOpenByDM[peerId],
                    expectedNewestDate: store.expectedNewestMessageDate(peerId),
                    jumpMessageId: store.jumpMessageIdAtOpenByDM[peerId],
                    onJumpSettled: { store.clearJumpMessageIdAtOpen(peerId) }
                ) {
                    dmComposer
                }
            } else {
                SNMsgList(
                    msgs: msgs,
                    showAuthors: isMultiMemberMarmot,
                    peerName: peer.name,
                    money: { store.money($0) },
                    fiatText: { store.moneySatsLine($0) },
                    mediaPipeline: SNMediaPipeline(
                        state: { store.mediaTransferState($0) },
                        prepare: { store.prepareMedia($0, autoDownload: $1) },
                        request: { store.requestMediaDownload($0) },
                        cancel: { store.cancelMediaDownload($0) },
                        loadLocal: { await store.mediaData($0) }
                    ),
                    loadSticker: { await store.stickerImageData(for: $0, userInitiated: $1) },
                    onTapPack: { previewPackCoordinate = $0 },
                    onRetry: { store.retryDm(peerId, message: $0) },
                    onCancelUpload: { store.cancelMediaUpload($0) },
                    uploadProgressSource: store.marmot.mediaUploadProgressSource,
                    loadOlder: { await convo.loadOlder() },
                    loadNewest: { await convo.loadNewestIfNeeded() },
                    // Captured by push() at navigation time, before this screen
                    // (and openedDM's read-marking) existed. Nil = unset —
                    // do not coerce to 0 (false live-edge chase).
                    unreadCountAtOpen: store.unreadCountAtOpenByDM[peerId],
                    expectedNewestDate: store.expectedNewestMessageDate(peerId)
                )
                dmComposer
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .overlay {
            if let coord = previewPackCoordinate {
                StickerPackPreviewSheet(
                    coordinate: coord,
                    loadPack: { author, identifier, relays in
                        await store.stickerPack(authorPubkeyHex: author, identifier: identifier, relayUrls: relays)
                    },
                    loadImage: { await store.stickerImageData(url: $0, expectedSha256: $1) },
                    installPack: { await store.installStickerPack(coordinate: $0) },
                    uninstallPack: { await store.uninstallStickerPack(coordinate: $0) },
                    isInstalled: { packCoord in
                        let installed = await store.fetchInstalledPacks()
                        return snStickerPackInstalledState(
                            coordinate: packCoord,
                            refreshedCoordinates: installed,
                            cachedInstalled: store.isStickerPackInstalled(packCoord)
                        )
                    },
                    onClose: { previewPackCoordinate = nil }
                )
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.easeOut(duration: 0.2), value: toast)
        .onAppear {
            store.openedDM(peerId)
            // Radar "Send sats" quick-pay: arrive with the PaySheet open.
            if store.consumePayRequest(peerId) {
                openPaySheetOrWallet()
            }
        }
        .onDisappear {
            if !snPreservesAttachmentImport(
                conversationID: peerId,
                routeReplacement: store.pendingMarmotRouteReplacement
            ) {
                attachmentImportGeneration += 1
            }
            store.closedDM(peerId)
        }
        .snSheet(isPresented: $sheet, title: "Add to your message") {
            VStack(spacing: 0) {
                if store.paymentCapable(peerId) {
                    SNActionRow(
                        icon: .coin, gold: true, label: "Send money",
                        desc: peer.inRange ? "Hand to hand over Bluetooth" : "Instant over the internet"
                    ) {
                        sheet = false
                        openPaySheetOrWallet()
                    }
                }
                if store.canSendMedia(peerId) {
                    SNActionRow(icon: .lock, label: "Send photo or video", desc: "Encrypted end-to-end over White Noise") {
                        sheet = false
                        pickPhoto = true
                    }
                }
                // MSN-style nudge (docs/SONAR-TRILL.md). DMs and Marmot groups
                // only — public geohash channels have no nudge action.
                SNActionRow(
                    icon: .bell,
                    label: "Nudge",
                    desc: store.canSendTrill(peerId)
                        ? (isMultiMemberMarmot
                            ? "Buzz everyone to get their attention"
                            : "Buzz \(peer.name)'s screen to get their attention")
                        : "You just sent a nudge — give it a moment",
                    disabled: !store.canSendTrill(peerId)
                ) {
                    sheet = false
                    store.sendTrill(peerId)
                    Task { @MainActor in
                        await convo.loadNewestIfNeeded()
                    }
                }
                if store.canPrepareMedia(peerId) {
                    SNActionRow(icon: .data, label: "Send file", desc: "PDFs, documents, and other files") {
                        sheet = false
                        pickFile = true
                    }
                }
                if isMultiMemberMarmot && store.marmotGroupId(peerId) != nil {
                    SNActionRow(icon: .people, label: "Add people", desc: "Invite local contacts or paste npubs") {
                        sheet = false
                        addPeopleSheet = true
                    }
                    SNActionRow(icon: .trash, label: "Remove people", desc: "Manage current group members") {
                        sheet = false
                        removePeopleSheet = true
                    }
                }
                if !isMultiMemberMarmot {
                    SNActionRow(icon: .shield, label: "Verify safety number", desc: "Confirm this chat is secure") {
                        sheet = false
                        verifySheet = true
                    }
                }
            }
        }
        .photosPicker(
            isPresented: $pickPhoto,
            selection: $photoItems,
            maxSelectionCount: 10,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        )
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            Task {
                // Load every pick in selection order; 2+ stage as one album.
                // Videos land as picker-owned temp FILES (never buffered
                // through memory here); photos load as Data like before.
                var staged: [(payload: SonarAppStore.PendingMediaPayload, filename: String, mime: String)] = []
                // An iCloud download/export can fail per item — count it so a
                // partially imported album never sends in silence.
                var failedImports = 0
                for item in items {
                    let isVideo = item.supportedContentTypes.contains {
                        $0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent)
                    }
                    if isVideo {
                        guard let picked = try? await item.loadTransferable(type: PickedVideoFile.self) else {
                            failedImports += 1
                            continue
                        }
                        staged.append((
                            payload: .file(picked.url),
                            filename: picked.suggestedFilename,
                            mime: picked.mime
                        ))
                        continue
                    }
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        failedImports += 1
                        continue
                    }
                    if data.snIsGif {
                        staged.append((payload: .data(data), filename: "animation.gif", mime: "image/gif"))
                    } else {
                        staged.append((payload: .data(data), filename: "photo.jpg", mime: "image/jpeg"))
                    }
                }
                let toStage = staged
                let failed = failedImports
                await MainActor.run {
                    if failed > 0 {
                        showToast(failed == 1
                            ? "Couldn't load 1 item from your library."
                            : "Couldn't load \(failed) items from your library.")
                    }
                    if !toStage.isEmpty {
                        store.stageMediaPreviews(peerId, items: toStage)
                    }
                    photoItems = []
                }
            }
        }
        .fileImporter(
            isPresented: $pickFile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            importAttachments(result)
        }
        .snSheet(isPresented: $verifySheet, title: "Verify \(peer.name)") {
            verifyContent
        }
        .snSheet(isPresented: $paySheet, title: "Send money · \(peer.name)") {
            SNPaySheet(
                peerName: peer.name,
                balance: store.balanceSats ?? 0,
                transport: transport,
                money: { store.money($0) },
                fiatText: { store.fiatText($0) },
                onClose: { paySheet = false },
                onSend: { sats in
                    Task {
                        if let message = await store.sendPay(peerId, sats: sats) {
                            showToast(message)
                        }
                    }
                }
            )
        }
        .snSheet(isPresented: $addPeopleSheet, title: "Add people") {
            addPeopleContent
        }
        .snSheet(isPresented: $removePeopleSheet, title: "Remove people") {
            removePeopleContent
        }
        .snSheet(isPresented: $walletSheet, title: "Your wallet") {
            SNWalletSheetContent(onClose: { walletSheet = false })
        }
        // iOS presents the media preview full-screen; macOS has no
        // fullScreenCover, so fall back to a sheet (same content/behavior).
#if os(iOS)
        .fullScreenCover(isPresented: mediaPreviewPresented) {
            mediaPreviewContent
        }
#else
        .sheet(isPresented: mediaPreviewPresented) {
            mediaPreviewContent
        }
#endif
        .onChange(of: verifySheet) { open in
            if !open { showKey = false }
        }
        .onChange(of: addPeopleSheet) { open in
            if !open {
                groupAddDraft = ""
                selectedAddNpubs = []
            }
        }
    }

    private var mediaPreviewPresented: Binding<Bool> {
        Binding(
            get: { store.pendingMediaPreviews.contains { $0.peerId == peerId } },
            set: { if !$0 { store.cancelPreview(peerId: peerId) } }
        )
    }

    @ViewBuilder
    private var mediaPreviewContent: some View {
        let previews = store.pendingMediaPreviews.filter { $0.peerId == peerId }
        if !previews.isEmpty {
            MediaSendPreviewLoaderView(
                previews: previews,
                onSend: { store.confirmSendPreview(peerId: peerId) },
                onCancel: { store.cancelPreview(peerId: peerId) }
            )
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(verbatim: toast)
                .font(SonarTheme.uiFont(size: 13.5, weight: .medium))
                .foregroundColor(SonarTheme.text)
                .multilineTextAlignment(.center)
                .padding(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16))
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(SonarTheme.surface2)
                        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(SonarTheme.hairline, lineWidth: 1)
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 88)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func openPaySheetOrWallet() {
        guard walletReady else {
            walletSheet = true
            return
        }
        Task {
            if let message = await store.paymentDetailsUnavailableMessage(peerId) {
                showToast(message)
                return
            }
            paySheet = true
        }
    }

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            if toast == text { toast = nil }
        }
    }

    private func importAttachments(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard urls.contains(where: \.isFileURL) else {
                showToast("Couldn't attach that file")
                return
            }
            attachmentImportGeneration += 1
            let generation = attachmentImportGeneration
            let conversationID = peerId
            let limit = attachmentLimitBytes
            Task { @MainActor in
                let result = await Task.detached(priority: .userInitiated) {
                    snReadAttachments(urls, maxTotalBytes: limit)
                }.value
                guard attachmentImportGeneration == generation else { return }
                guard !result.attachments.isEmpty else {
                    if result.oversizedCount > 0 {
                        showToast("File is too large")
                    } else {
                        showToast("Couldn't attach that file")
                    }
                    return
                }

                switch await store.prepareMediaRoute(conversationID) {
                case .ready:
                    break
                case .unavailable:
                    guard attachmentImportGeneration == generation else { return }
                    showToast("This contact must be online to receive files")
                    return
                case .failed:
                    guard attachmentImportGeneration == generation else { return }
                    showToast("Couldn't set up a secure file transfer")
                    return
                }
                guard attachmentImportGeneration == generation else { return }

                var imported = 0
                var rejected = result.rejectedCount
                for attachment in result.attachments {
                    if store.sendAttachment(
                        conversationID,
                        data: attachment.data,
                        filename: attachment.filename,
                        mime: attachment.mime
                    ) {
                        imported += 1
                    } else {
                        rejected += 1
                    }
                }

                if imported > 0, rejected > 0 {
                    showToast("\(imported) attached; some files couldn't be attached")
                } else if imported > 0 {
                    showToast(imported == 1 ? "Attachment added" : "\(imported) attachments added")
                } else if result.oversizedCount > 0 {
                    showToast("File is too large")
                } else {
                    showToast("Couldn't attach that file")
                }
            }
        case .failure:
            showToast("Couldn't attach that file")
        }
    }

    private var attachmentLimitBytes: Int {
        store.dmTransport(peerId) == .mesh
            ? FileTransferLimits.maxPayloadBytes
            : Self.maxInternetAttachmentBytes
    }

    @ViewBuilder
    private var banner: some View {
        // Prefer the send-path transport over radar `inRange` so a Sonar peer
        // that is only mesh-relayed (or a stale Noise alias after wipe) shows
        // the White Noise banner instead of claiming Bluetooth delivery.
        if !isMarmot && transport == .internet {
            outOfRangeBanner
        } else if verified {
            SNBanner(
                icon: .shieldCheck, tone: .enc,
                bold: "Verified",
                rest: " — you confirmed \(peer.name)\u{2019}s safety number"
            )
        } else if isMultiMemberMarmot {
            SNBanner(
                icon: .lock, tone: .enc,
                bold: "End-to-end encrypted",
                rest: " — only group members can read this"
            )
        } else if isMarmot {
            SNBanner(
                icon: .lock, tone: .enc,
                bold: "End-to-end encrypted",
                rest: " — secure chat over the internet"
            ) {
                SNBannerButton(label: "Verify") { verifySheet = true }
            }
        } else {
            SNBanner(
                icon: .lock, tone: .enc,
                bold: "End-to-end encrypted",
                rest: " — only you and \(peer.name) can read this"
            ) {
                SNBannerButton(label: "Verify") { verifySheet = true }
            }
        }
    }

    /// The out-of-range routing matrix: Sonar peers continue over White
    /// Noise, mutual favorites deliver over the internet (NIP-17), plain
    /// bitchat peers queue until the next meeting (with a Favorite shortcut).
    @ViewBuilder
    private var outOfRangeBanner: some View {
        if isSonar {
            SNBanner(
                icon: .globe, tone: .net,
                bold: "Out of range",
                rest: " — continuing over White Noise"
            )
        } else if store.isMutualFavorite(peerId) {
            SNBanner(
                icon: .globe, tone: .net,
                bold: "Out of range",
                rest: " — delivering over the internet"
            )
        } else if !store.isFavorite(peerId) {
            SNBanner(
                icon: .mesh, tone: .neutral,
                bold: "Out of range",
                rest: " — messages will wait until you meet again. Favorites deliver over the internet."
            ) {
                SNBannerButton(label: "Favorite") { store.toggleFavorite(peerId) }
            }
        } else {
            SNBanner(
                icon: .mesh, tone: .neutral,
                bold: "Out of range",
                rest: " — messages will wait until you meet again"
            )
        }
    }

    // Verify sheet: avatars, copy, real safety-number grid, real key reveal.
    private var verifyContent: some View {
        let info = store.verifyInfo(for: peerId)
        return VStack(spacing: 0) {
            HStack(spacing: 18) {
                verifyHead(name: store.nick.isEmpty ? "you" : store.nick, label: "you")
                verifyHead(name: peer.name, label: peer.name)
            }
            .padding(EdgeInsets(top: 8, leading: 0, bottom: 2, trailing: 0))

            // The one place protocol names appear.
            Text(verbatim: "Speaks " + store.speaks(peerId))
                .font(SonarTheme.uiFont(size: 12.5))
                .foregroundColor(SonarTheme.text3)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            if info.available {
                Text(verbatim: "Compare these numbers with \(peer.name) in person or on a call. If they match, this chat is end-to-end encrypted and nobody is in the middle.")
                    .font(SonarTheme.uiFont(size: 13.5))
                    .lineSpacing(13.5 * 0.3)
                    .foregroundColor(SonarTheme.text2)
                    .multilineTextAlignment(.center)
                    .padding(EdgeInsets(top: 8, leading: 14, bottom: 2, trailing: 14))

                VStack(spacing: 0) {
                    ForEach([0, 4, 8], id: \.self) { row in
                        Text(verbatim: info.safety[row..<(row + 4)].joined(separator: "\u{2002}"))
                            .font(SonarTheme.monoFont(size: 14))
                            .kerning(14 * 0.06)
                            .foregroundColor(SonarTheme.text)
                            .frame(height: 14 * 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(EdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
                .padding(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))

                if showKey {
                    Text(verbatim: info.publicKey)
                        .font(SonarTheme.monoFont(size: 11))
                        .lineSpacing(11 * 0.6)
                        .foregroundColor(SonarTheme.text3)
                        .multilineTextAlignment(.center)
                        .padding(EdgeInsets(top: 2, leading: 18, bottom: 8, trailing: 18))
                }

                VStack(spacing: 6) {
                    SNPrimaryButton(label: "They match — mark as verified") {
                        store.markVerified(peerId)
                        verifySheet = false
                        showKey = false
                    }
                    SNGhostButton(label: showKey ? "Hide public key" : "Show public key") {
                        showKey.toggle()
                    }
                }
                .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
            } else {
                Text(verbatim: info.note ?? "Safety numbers aren\u{2019}t available yet.")
                    .font(SonarTheme.uiFont(size: 13.5))
                    .lineSpacing(13.5 * 0.3)
                    .foregroundColor(SonarTheme.text2)
                    .multilineTextAlignment(.center)
                    .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                VStack(spacing: 6) {
                    SNGhostButton(label: "Close") {
                        verifySheet = false
                    }
                }
                .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
            }
        }
    }

    private var addPeopleContent: some View {
        let existing = Set(store.marmotGroup(forConversationId: peerId)?.memberNpubs ?? [])
        let pasted = parsedNpubs(from: groupAddDraft).filter { !existing.contains($0) }
        let members = mergedNpubs(pasted: pasted, selected: selectedAddNpubs)
        let contacts = store.groupInviteContacts(excluding: existing)

        return ScrollView {
            VStack(spacing: 8) {
                TextField(
                    "",
                    text: $groupAddDraft,
                    prompt: Text(verbatim: "npub1\u{2026} npub1\u{2026}").foregroundColor(SonarTheme.text3)
                )
                .textFieldStyle(.plain)
                .font(SonarTheme.monoFont(size: 13))
                .foregroundColor(SonarTheme.text)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))

                if !contacts.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(contacts.enumerated()), id: \.element.id) { i, contact in
                            SNGroupContactRow(
                                contact: contact,
                                selected: selectedAddNpubs.contains(contact.npub),
                                divider: i < contacts.count - 1
                            ) {
                                if selectedAddNpubs.contains(contact.npub) {
                                    selectedAddNpubs.remove(contact.npub)
                                } else {
                                    selectedAddNpubs.insert(contact.npub)
                                }
                            }
                        }
                    }
                }

                SNPrimaryButton(label: "Add people", disabled: members.isEmpty) {
                    guard let groupId = store.marmotGroupId(peerId) else { return }
                    addPeopleSheet = false
                    Task { try? await store.marmot.addGroupMembers(members, to: groupId) }
                }
            }
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 2, trailing: 10))
        }
        .frame(maxHeight: 430)
    }

    private var removePeopleContent: some View {
        let members = store.groupMemberContacts(forConversationId: peerId)
        return ScrollView {
            VStack(spacing: 0) {
                if members.isEmpty {
                    Text("No removable members.")
                        .font(SonarTheme.uiFont(size: 13.5))
                        .foregroundColor(SonarTheme.text2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                } else {
                    ForEach(members) { member in
                        Button {
                            guard let groupId = store.marmotGroupId(peerId) else { return }
                            Task { try? await store.marmot.removeGroupMembers([member.npub], from: groupId) }
                        } label: {
                            HStack(spacing: 12) {
                                SonarAvatar(name: member.title, size: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: member.title)
                                        .font(SonarTheme.uiFont(size: 15.5, weight: .semibold))
                                        .foregroundColor(SonarTheme.text)
                                        .lineLimit(1)
                                    Text(verbatim: member.subtitle)
                                        .font(SonarTheme.uiFont(size: 12.5))
                                        .foregroundColor(SonarTheme.text2)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                SNIcon(name: .trash, size: 17, weight: 2)
                                    .foregroundColor(SonarTheme.danger)
                            }
                            .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SNRowPressStyle(cornerRadius: 14))
                    }
                }
            }
        }
        .frame(maxHeight: 430)
    }

    private func verifyHead(name: String, label: String) -> some View {
        VStack(spacing: 5) {
            SonarAvatar(name: name, size: 48)
            Text(verbatim: label)
                .font(SonarTheme.uiFont(size: 12.5, weight: .semibold))
                .foregroundColor(SonarTheme.text2)
        }
    }

    private func parsedNpubs(from text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("npub1") }
    }

    private func mergedNpubs(pasted: [String], selected: Set<String>) -> [String] {
        var seen = Set<String>()
        return (pasted + selected.sorted()).filter { seen.insert($0).inserted }
    }
}

/// One staged attachment in the pre-send preview pager. Images/GIFs carry
/// their bytes; videos carry only a poster frame (never the full payload).
private struct SendPreviewItem {
    let data: Data?
    let isGif: Bool
    let isVideo: Bool
    let poster: CGImage?
    let filename: String
}

private struct MediaSendPreviewView: View {
    let items: [SendPreviewItem]
    let onSend: () -> Void
    let onCancel: () -> Void

    @State private var page = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if os(iOS)
            if items.count > 1 {
                TabView(selection: $page) {
                    ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                        singleImage(item)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .padding(.bottom, 80)
            } else if let only = items.first {
                singleImage(only)
            }
            #else
            Text("Preview")
                .foregroundColor(.white.opacity(0.6))
            #endif

            VStack {
                HStack {
                    Button { onCancel() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(12)
                    }
                    Spacer()
                    if items.count > 1 {
                        Text(verbatim: "\(page + 1) of \(items.count)")
                            .font(SonarTheme.uiFont(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.trailing, 16)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 12)

                Spacer()

                HStack {
                    Spacer()
                    Button { onSend() } label: {
                        HStack(spacing: 6) {
                            if items.count > 1 {
                                Text(verbatim: "\(items.count)")
                                    .font(SonarTheme.uiFont(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            Image(systemName: "arrow.up")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .frame(minWidth: 52)
                        .frame(height: 52)
                        .padding(.horizontal, items.count > 1 ? 14 : 0)
                        .background(SonarTheme.accent)
                        .clipShape(Capsule())
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func singleImage(_ item: SendPreviewItem) -> some View {
        #if os(iOS)
        if item.isVideo {
            ZStack {
                if let poster = item.poster {
                    Image(decorative: poster, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea()
                        .padding(.bottom, 80)
                }
                VStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white)
                    if item.poster == nil {
                        Text(item.filename)
                            .font(SonarTheme.uiFont(size: 14))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
            }
        } else if item.isGif, let data = item.data {
            GifImageView(data: data)
                .ignoresSafeArea()
                .padding(.bottom, 80)
        } else if let data = item.data, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .ignoresSafeArea()
                .padding(.bottom, 80)
        } else {
            Text("Couldn't decode image")
                .foregroundColor(.white.opacity(0.6))
        }
        #else
        EmptyView()
        #endif
    }
}

private struct MediaSendPreviewLoaderView: View {
    let previews: [SonarAppStore.PendingMediaPreview]
    let onSend: () -> Void
    let onCancel: () -> Void

    @State private var items: [SendPreviewItem]?

    private var loadKey: String {
        previews.map(\.tempURL.absoluteString).joined(separator: "|")
    }

    var body: some View {
        Group {
            if let items, !items.isEmpty {
                MediaSendPreviewView(
                    items: items,
                    onSend: onSend,
                    onCancel: onCancel
                )
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .task(id: loadKey) {
            let toLoad = previews
            items = await Task.detached(priority: .userInitiated) {
                var loaded: [SendPreviewItem] = []
                for preview in toLoad {
                    if preview.mime.hasPrefix("video/") {
                        // Poster frame only — never buffer the full video.
                        let poster = await Self.videoPoster(preview.tempURL)
                        loaded.append(SendPreviewItem(
                            data: nil,
                            isGif: false,
                            isVideo: true,
                            poster: poster,
                            filename: preview.filename
                        ))
                        continue
                    }
                    guard let data = try? Data(contentsOf: preview.tempURL) else { continue }
                    loaded.append(SendPreviewItem(
                        data: data,
                        isGif: preview.mime == "image/gif",
                        isVideo: false,
                        poster: nil,
                        filename: preview.filename
                    ))
                }
                return loaded
            }.value
        }
    }

    private static func videoPoster(_ url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.03, preferredTimescale: 600)
        if #available(iOS 16.0, macOS 13.0, *) {
            return try? await generator.image(at: time).image
        } else {
            return try? generator.copyCGImage(at: time, actualTime: nil)
        }
    }
}

#if os(iOS)
private struct GifImageView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        guard uiView.image == nil && uiView.animationImages == nil else { return }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 1 {
            var images: [UIImage] = []
            var duration: Double = 0
            let count = CGImageSourceGetCount(source)
            for i in 0..<count {
                if let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) {
                    images.append(UIImage(cgImage: cgImage))
                    if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
                       let gifProps = props[kCGImagePropertyGIFDictionary as String] as? [String: Any],
                       let delay = gifProps[kCGImagePropertyGIFDelayTime as String] as? Double {
                        duration += delay
                    } else {
                        duration += 0.1
                    }
                }
            }
            uiView.animationImages = images
            uiView.animationDuration = duration
            uiView.startAnimating()
        } else {
            uiView.image = UIImage(data: data)
        }
    }
}
#endif

private extension Data {
    var snIsGif: Bool {
        count >= 6 &&
        self[startIndex] == 0x47 &&
        self[index(startIndex, offsetBy: 1)] == 0x49 &&
        self[index(startIndex, offsetBy: 2)] == 0x46 &&
        self[index(startIndex, offsetBy: 3)] == 0x38 &&
        (self[index(startIndex, offsetBy: 4)] == 0x37 || self[index(startIndex, offsetBy: 4)] == 0x39) &&
        self[index(startIndex, offsetBy: 5)] == 0x61
    }
}
