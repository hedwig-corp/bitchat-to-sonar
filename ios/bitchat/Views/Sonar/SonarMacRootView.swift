//
// SonarMacRootView.swift
// bitchat
//
// Native macOS split-view shell for Sonar Desktop, following
// design/handoff/project/Sonar Desktop.html and sonar/desktop*.{jsx,css}.
// It keeps the same live SonarAppStore and feature screens as iOS while giving
// Mac users a persistent sidebar, wide content pane, and detail rail.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let sonarMacOpenSearch = Notification.Name("sonar.mac.openSearch")
    static let sonarMacOpenSettings = Notification.Name("sonar.mac.openSettings")
    static let sonarMacShowRadar = Notification.Name("sonar.mac.showRadar")
    static let sonarMacOpenProfile = Notification.Name("sonar.mac.openProfile")
}

struct SonarMacRootView: View {
    @EnvironmentObject private var store: SonarAppStore
    @State private var selection: SonarMacSelection = .radar
    @State private var detailRailOpen = true
    @State private var searchOpen = false
    @State private var settingsOpen = false
    @State private var connectivityOpen = false

    var body: some View {
        Group {
            if store.onboarded {
                HStack(spacing: 0) {
                    SonarMacSidebar(
                        selection: $selection,
                        onSearch: { searchOpen = true },
                        onCompose: { searchOpen = true },
                        onConnectivity: { connectivityOpen = true },
                        onSettings: { settingsOpen = true }
                    )
                        .frame(width: 300)
                    Rectangle()
                        .fill(SonarTheme.hairline)
                        .frame(width: 1)
                    SonarMacMainPane(
                        selection: $selection,
                        detailRailOpen: $detailRailOpen,
                        onSearch: { searchOpen = true },
                        onSettings: { settingsOpen = true }
                    )
                    if detailRailOpen, selection.hasDetailRail {
                        Rectangle()
                            .fill(SonarTheme.hairline)
                            .frame(width: 1)
                        SonarMacDetailRail(selection: $selection)
                            .frame(width: 286)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if selection.hasDetailRail {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                detailRailOpen.toggle()
                            }
                        } label: {
                            SNIcon(name: .info, size: 18, weight: 2)
                                .foregroundColor(detailRailOpen ? SonarTheme.accentDeep : SonarTheme.text2)
                                .frame(width: 34, height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(detailRailOpen ? SonarTheme.accentSoft : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(detailRailOpen ? "Hide details" : "Show details")
                        .padding(.top, 12)
                        .padding(.trailing, detailRailOpen ? 298 : 12)
                    }
                }
                .overlay {
                    if searchOpen {
                        MacCommandPalette(
                            selection: $selection,
                            openSettings: { settingsOpen = true },
                            isPresented: $searchOpen
                        )
                    }
                }
                .overlay {
                    if settingsOpen {
                        MacSettingsModal(isPresented: $settingsOpen)
                    }
                }
            } else {
                ZStack {
                    SonarTheme.bg.ignoresSafeArea()
                    SonarOnboardingScreen()
                        .frame(width: 420)
                        .background(SonarTheme.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
        }
        .frame(minWidth: 980, idealWidth: 1180, minHeight: 700, idealHeight: 780)
        .background(SonarTheme.bg.ignoresSafeArea())
        .snSheet(isPresented: $connectivityOpen, title: "Connection") {
            SNConnectivitySheetContent(onClose: { connectivityOpen = false })
        }
        .snSheet(
            isPresented: Binding(
                get: { store.unifyPay != nil },
                set: { if !$0 { store.dismissUnifyPay() } }
            ),
            title: "Send money"
        ) {
            if let pay = store.unifyPay {
                UnifyPaySheetView(
                    peerName: store.peerItem(pay.peerId).name,
                    phase: pay.phase,
                    balance: store.balanceSats ?? 0,
                    money: { store.money($0) },
                    fiatText: { store.fiatText($0) },
                    onConfirmAmount: { dest, sats in
                        store.confirmUnifyAmount(pay.peerId, destination: dest, sats: sats)
                    },
                    onClose: { store.dismissUnifyPay() }
                )
            }
        }
        .overlay {
            if let call = store.activeCall {
                SonarCallScreen(peerId: call.convId, video: call.video)
            }
        }
        .onChange(of: selection) { _ in
            store.path.removeAll()
        }
        .onChange(of: store.path) { newPath in
            syncSelection(with: newPath.last)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sonarMacOpenSearch)) { _ in
            searchOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .sonarMacOpenSettings)) { _ in
            settingsOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .sonarMacShowRadar)) { _ in
            selection = .radar
        }
        .onReceive(NotificationCenter.default.publisher(for: .sonarMacOpenProfile)) { _ in
            selection = .profile
        }
    }

    private func syncSelection(with route: SonarRoute?) {
        guard let route else { return }
        switch route {
        case .channel(let id):
            selection = .channel(id)
            store.path.removeAll()
        case .dm(let id):
            selection = .dm(id)
            store.path.removeAll()
        case .nearby:
            selection = .radar
            store.path.removeAll()
        case .settings:
            settingsOpen = true
            store.path.removeAll()
        case .profile:
            selection = .profile
            store.path.removeAll()
        case .call:
            break
        case .contactProfile, .groupInfo, .walletActivity:
            break
        }
    }
}

private enum SonarMacSelection: Hashable {
    case radar
    case channel(String)
    case dm(String)
    case profile

    var hasDetailRail: Bool {
        switch self {
        case .channel, .dm:
            return true
        case .radar, .profile:
            return false
        }
    }
}

private struct SonarMacSidebar: View {
    @EnvironmentObject private var store: SonarAppStore
    @Binding var selection: SonarMacSelection
    let onSearch: () -> Void
    let onCompose: () -> Void
    let onConnectivity: () -> Void
    let onSettings: () -> Void

    private var savedChannels: [SNChannelItem] {
        let around = Set(store.channels.map(\.id))
        return store.savedChannels.filter { !around.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            brandRow
            MacStatusBanner(online: store.online, meshCount: store.meshCount) {
                onConnectivity()
            }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            searchRow

            ScrollView {
                VStack(spacing: 0) {
                    MacSidebarDiscoverRow(
                        selected: selection == .radar,
                        meshCount: store.meshCount
                    ) {
                        selection = .radar
                    }

                    SNSectionLabel("Around you")
                    MacHereCard(
                        channels: store.channels,
                        selectedId: selectedChannelId,
                        onEnter: { selection = .channel($0.id) }
                    )
                    MacMorePlacesRow {
                        selection = .radar
                    }

                    if !savedChannels.isEmpty {
                        SNSectionLabel("Saved channels")
                        ForEach(savedChannels) { channel in
                            MacChannelRow(
                                channel: channel,
                                selected: selection == .channel(channel.id)
                            ) {
                                selection = .channel(channel.id)
                            }
                        }
                    }

                    SNSectionLabel("Messages")
                    if store.dmRows.isEmpty && store.marmot.pendingGroupInvites.isEmpty {
                        MacEmptySidebarHint("No secure chats yet. Use Search or the radar to start one.")
                    } else {
                        ForEach(store.marmot.pendingGroupInvites, id: \.id) { invite in
                            let title = invite.groupName.isEmpty ? "Group chat" : invite.groupName
                            MacPaletteRow(icon: .people, title: title, sub: "\(invite.memberCount) members · invite") {
                                Task {
                                    if let groupId = try? await store.marmot.acceptGroupInvite(invite) {
                                        let id = SonarAppStore.marmotIDPrefix + groupId
                                        store.openedDM(id)
                                        selection = .dm(id)
                                    }
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task { try? await store.marmot.declineGroupInvite(invite) }
                                } label: {
                                    Label("Decline invite", systemImage: "xmark.circle")
                                }
                            }
                        }
                        ForEach(store.dmRows) { row in
                            MacDMRow(
                                row: row,
                                selected: selection == .dm(row.id)
                            ) {
                                store.openedDM(row.id)
                                selection = .dm(row.id)
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }

            profileFooter
        }
        .background(SonarTheme.surface.opacity(0.42))
    }

    private var selectedChannelId: String? {
        if case .channel(let id) = selection { return id }
        return nil
    }

    private var brandRow: some View {
        HStack(spacing: 8) {
            SNIcon(name: .rings, size: 20, weight: 1.8)
                .foregroundColor(SonarTheme.accent)
            Text("sonar")
                .font(SonarTheme.uiFont(size: 19, weight: .heavy))
                .foregroundColor(SonarTheme.text)
            Spacer(minLength: 0)
            MacIconButton(icon: .compose, help: "New chat", action: onCompose)
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 4, trailing: 12))
    }

    private var searchRow: some View {
        Button(action: onSearch) {
            HStack(spacing: 8) {
                SNIcon(name: .search, size: 14, weight: 2.2)
                    .foregroundColor(SonarTheme.text3)
                Text("Search")
                    .font(SonarTheme.uiFont(size: 13.5))
                    .foregroundColor(SonarTheme.text3)
                Spacer(minLength: 0)
                Text("cmd K")
                    .font(SonarTheme.monoFont(size: 10.5, weight: .semibold))
                    .foregroundColor(SonarTheme.text3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(SonarTheme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(SonarTheme.hairline, lineWidth: 1)
                            )
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SonarTheme.surface2))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var profileFooter: some View {
        HStack(spacing: 10) {
            Button {
                selection = .profile
            } label: {
                HStack(spacing: 10) {
                    SonarAvatar(name: store.nick.isEmpty ? "you" : store.nick, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.nick.isEmpty ? "you" : store.nick)
                            .font(SonarTheme.uiFont(size: 14, weight: .bold))
                            .foregroundColor(SonarTheme.text)
                            .lineLimit(1)
                        Text(shortKey)
                            .font(SonarTheme.monoFont(size: 10.5))
                            .foregroundColor(SonarTheme.text3)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SNRowPressStyle(cornerRadius: 12))
            .help("Open profile")
            MacIconButton(icon: .list, help: "Settings") {
                onSettings()
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 12))
        .overlay(alignment: .top) {
            Rectangle().fill(SonarTheme.hairline).frame(height: 1)
        }
    }

    private var shortKey: String {
        let key = store.npub ?? ""
        guard !key.isEmpty else { return "connecting..." }
        return key.count > 18 ? String(key.prefix(14)) + "..." : key
    }
}

private struct SonarMacMainPane: View {
    @EnvironmentObject private var store: SonarAppStore
    @Binding var selection: SonarMacSelection
    @Binding var detailRailOpen: Bool
    let onSearch: () -> Void
    let onSettings: () -> Void

    var body: some View {
        NavigationStack(path: $store.path) {
            rootContent
                .navigationDestination(for: SonarRoute.self) { route in
                    destination(for: route)
                }
        }
        .background(SonarTheme.bg)
    }

    @ViewBuilder
    private var rootContent: some View {
        switch selection {
        case .radar:
            MacRadarPane(selection: $selection)
        case .channel(let id):
            MacConversationPane(
                mode: .channel(id),
                detailRailOpen: $detailRailOpen,
                onSelect: { selection = $0 }
            )
        case .dm(let id):
            MacConversationPane(
                mode: .dm(id),
                detailRailOpen: $detailRailOpen,
                onSelect: { selection = $0 }
            )
        case .profile:
            MacProfilePane()
        }
    }

    @ViewBuilder
    private func destination(for route: SonarRoute) -> some View {
        switch route {
        case .channel(let id):
            MacRouteRedirect(selection: $selection, route: .channel(id))
        case .dm(let id):
            MacRouteRedirect(selection: $selection, route: .dm(id))
        case .nearby:
            MacRouteRedirect(selection: $selection, route: .radar)
        case .settings:
            MacModalRouteRedirect(openModal: onSettings)
        case .profile:
            MacRouteRedirect(selection: $selection, route: .profile)
        case .call(let id, let video):
            SonarCallScreen(peerId: id, video: video)
        case .contactProfile(let id, let name):
            SonarContactProfileScreen(peerId: id, peerName: name)
        case .groupInfo(let id):
            SonarGroupInfoScreen(peerId: id)
        case .walletActivity:
            SonarWalletActivityScreen()
        }
    }
}

private struct MacRouteRedirect: View {
    @EnvironmentObject private var store: SonarAppStore
    @Binding var selection: SonarMacSelection
    let route: SonarMacSelection

    var body: some View {
        Color.clear
            .onAppear {
                selection = route
                store.path.removeAll()
            }
    }
}

private struct MacModalRouteRedirect: View {
    @EnvironmentObject private var store: SonarAppStore
    let openModal: () -> Void

    var body: some View {
        Color.clear
            .onAppear {
                openModal()
                store.path.removeAll()
            }
    }
}

private enum MacConversationMode: Hashable {
    case channel(String)
    case dm(String)
}

private struct MacConversationPane: View {
    @EnvironmentObject private var store: SonarAppStore
    let mode: MacConversationMode
    @Binding var detailRailOpen: Bool
    let onSelect: (SonarMacSelection) -> Void

    private static let maxInternetAttachmentBytes = 25 * 1024 * 1024

    @State private var actionSheet = false
    @State private var verifySheet = false
    @State private var paySheet = false
    @State private var walletSheet = false
    @State private var addPeopleSheet = false
    @State private var removePeopleSheet = false
    @State private var groupAddDraft = ""
    @State private var selectedAddNpubs: Set<String> = []
    @State private var importMedia = false
    @State private var importFile = false
    @State private var authorSheet: SonarAppStore.SNChannelAuthor?
    @State private var toast: String?

    private var walletReady: Bool {
        if case .ready = store.walletState { return true }
        return false
    }

    private var id: String {
        switch mode {
        case .channel(let id), .dm(let id): return id
        }
    }

    private var isChannel: Bool {
        if case .channel = mode { return true }
        return false
    }

    private var channel: SNChannelItem { store.channelItem(id) }
    private var peer: SNPeerItem { store.peerItem(id) }
    private var isMultiMemberMarmot: Bool { !isChannel && store.isMultiMemberMarmotGroupId(id) }
    private var verified: Bool { !isChannel && !isMultiMemberMarmot && store.isVerified(id) }
    private var transport: SNVia { isChannel ? (id == "mesh" ? .mesh : .internet) : store.dmTransport(id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            banner
            transcript
            composer
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .overlay(alignment: .bottom) { toastView }
        .animation(.easeOut(duration: 0.2), value: toast)
        .onAppear(perform: appeared)
        .onDisappear(perform: disappeared)
        .snSheet(isPresented: $actionSheet, title: "Add to your message") {
            actionContent
        }
        .snSheet(isPresented: $verifySheet, title: "Verify \(peer.name)") {
            MacVerifySheetContent(peerId: id)
        }
        .snSheet(isPresented: $paySheet, title: "Send money - \(peer.name)") {
            SNPaySheet(
                peerName: peer.name,
                balance: store.balanceSats ?? 0,
                transport: transport,
                money: { store.money($0) },
                fiatText: { store.fiatText($0) },
                onClose: { paySheet = false },
                onSend: { sats in
                    if let message = store.sendPay(id, sats: sats) {
                        showToast(message)
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
        .snSheet(
            isPresented: Binding(
                get: { authorSheet != nil },
                set: { if !$0 { authorSheet = nil } }
            ),
            title: authorSheet.map { "Message \($0.name)" } ?? ""
        ) {
            if let author = authorSheet {
                VStack(spacing: 0) {
                    SNActionRow(
                        icon: .lock,
                        label: "Open private chat",
                        desc: "End-to-end encrypted, over the internet"
                    ) {
                        authorSheet = nil
                        store.openChannelDM(author)
                    }
                    SNActionRow(
                        icon: .trash,
                        label: "Block \(author.name)",
                        desc: "You won't see their messages anymore"
                    ) {
                        let name = author.name
                        authorSheet = nil
                        store.blockChannelAuthor(author)
                        showToast("\(name) blocked")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $importMedia,
            allowedContentTypes: [.image, .movie, .audio],
            allowsMultipleSelection: true
        ) { result in
            importAttachments(result)
        }
        .fileImporter(
            isPresented: $importFile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            importAttachments(result)
        }
        .onChange(of: addPeopleSheet) { open in
            if !open {
                groupAddDraft = ""
                selectedAddNpubs = []
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if isChannel {
                SNPlaceTile(size: 38, icon: id == "mesh" ? .mesh : .pin)
            } else {
                SonarAvatar(name: peer.name, size: 38, presence: peer.inRange)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(isChannel ? channel.name : peer.name)
                        .font(SonarTheme.uiFont(size: 17, weight: .bold))
                        .foregroundColor(SonarTheme.text)
                        .lineLimit(1)
                    if verified {
                        SNIcon(name: .shieldCheck, size: 15, weight: 2.1)
                            .foregroundColor(SonarTheme.green)
                    }
                }
                HStack(spacing: 5) {
                    if isChannel {
                        SNDot(color: SonarTheme.green, small: true)
                        Text(channel.sub)
                    } else {
                        SNIcon(name: .lock, size: 11, weight: 2.4)
                        Text(dmSubtitle)
                    }
                }
                .font(SonarTheme.uiFont(size: 12))
                .foregroundColor(SonarTheme.text2)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            MacIconButton(icon: .rings, help: "People nearby") {
                onSelect(.radar)
            }
            if !isChannel, store.canCall(id) {
                MacIconButton(icon: .phone, help: "Voice call") {
                    store.placeCall(id, video: false)
                }
                MacIconButton(icon: .videocam, help: "Video call") {
                    store.placeCall(id, video: true)
                }
            }
            MacIconButton(icon: .info, help: detailRailOpen ? "Hide details" : "Show details") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    detailRailOpen.toggle()
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 14))
        .background(SonarTheme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SonarTheme.hairline).frame(height: 1)
        }
    }

    private var dmSubtitle: String {
        let prefix = verified ? "Verified - " : ""
        if peer.inRange {
            return prefix + "Nearby - Bluetooth"
        }
        return prefix + (transport == .internet ? "Via internet" : "Waiting for Bluetooth")
    }

    @ViewBuilder private var banner: some View {
        if isChannel {
            SNBanner(icon: .people, tone: .publicRoom, bold: "Public channel", rest: " - anyone nearby can read")
        } else if verified {
            SNBanner(icon: .shieldCheck, tone: .enc, bold: "Verified", rest: " - you confirmed \(peer.name)'s safety number")
        } else if isMultiMemberMarmot {
            SNBanner(icon: .lock, tone: .enc, bold: "End-to-end encrypted", rest: " - only group members can read this")
        } else if transport == .internet && !peer.inRange {
            SNBanner(icon: .globe, tone: .net, bold: "Out of Bluetooth range", rest: " - encrypted over the internet instead")
        } else {
            SNBanner(icon: .lock, tone: .enc, bold: "End-to-end encrypted", rest: " - only you and \(peer.name) can read this") {
                SNBannerButton(label: "Verify") { verifySheet = true }
            }
        }
    }

    @ViewBuilder private var transcript: some View {
        if isChannel {
            let msgs = store.chMsgs(id)
            if msgs.isEmpty {
                SNEmptyState(
                    icon: .pin,
                    iconSize: 26,
                    amber: true,
                    title: "Quiet in \(channel.name) right now",
                    desc: channel.count > 0
                        ? "\(channel.count) people are in range of this channel. Say hi."
                        : "Nobody has said anything yet. Say hi."
                )
            } else {
                SNMsgList(
                    msgs: msgs,
                    showAuthors: true,
                    onTapAuthor: { message in
                        guard !message.mine else { return }
                        if let author = store.channelAuthor(forMessage: message.id) {
                            authorSheet = author
                        } else {
                            showToast("\(message.author ?? "This person") is no longer in the channel")
                        }
                    }
                )
            }
        } else {
            let msgs = store.dmMsgs(id)
            if msgs.isEmpty {
                SNEmptyState(
                    icon: .lock,
                    iconSize: 24,
                    title: "Say hi to \(peer.name)",
                    desc: isMultiMemberMarmot
                        ? "Messages here are end-to-end encrypted. Only group members can read them."
                        : "Messages here are end-to-end encrypted. Only the two of you can read them."
                )
            } else {
                SNMsgList(
                    msgs: msgs,
                    showAuthors: isMultiMemberMarmot,
                    peerName: peer.name,
                    money: { store.money($0) },
                    fiatText: { store.moneySatsLine($0) },
                    onClaim: { payId in
                        if walletReady {
                            store.claimPay(id, payId: payId)
                        } else {
                            walletSheet = true
                        }
                    },
                    loadMedia: { await store.mediaData($0) }
                )
            }
        }
    }

    private var composer: some View {
        SNComposer(
            placeholder: "Message \(isChannel ? channel.name : peer.name)" + (!isChannel && transport == .internet ? " - via internet" : ""),
            transport: transport,
            onSend: { text in
                if isChannel {
                    store.sendCh(id, text)
                } else {
                    store.sendDm(id, text)
                }
            },
            onPlus: { actionSheet = true },
            onCommand: { command in
                store.onCommand(
                    .init(
                        type: isChannel ? .ch : .dm,
                        id: id,
                        target: isChannel ? slapTarget : peer.name
                    ),
                    command
                )
            },
            voiceEnabled: !isChannel && store.canSendMedia(id),
            onVoice: { store.sendVoiceNote(id, url: $0) }
        )
    }

    @ViewBuilder private var actionContent: some View {
        VStack(spacing: 0) {
            if !isChannel, store.paymentCapable(id) {
                SNActionRow(
                    icon: .coin,
                    gold: true,
                    label: walletReady ? "Send money" : "Wallet not ready",
                    desc: walletReady
                        ? (peer.inRange ? "Privately over Bluetooth" : "Privately over the internet")
                        : "Set up or sync your wallet first"
                ) {
                    actionSheet = false
                    openPaySheetOrWallet()
                }
            }
            if !isChannel, store.canSendMedia(id) {
                SNActionRow(icon: .drive, label: "Send photo, video, or audio", desc: "Encrypted end-to-end") {
                    actionSheet = false
                    importMedia = true
                }
                SNActionRow(icon: .data, label: "Send file", desc: "PDFs, documents, and other files") {
                    actionSheet = false
                    importFile = true
                }
            }
            if !isChannel && isMultiMemberMarmot {
                SNActionRow(icon: .people, label: "Add people", desc: "Invite local contacts or paste npubs") {
                    actionSheet = false
                    addPeopleSheet = true
                }
                SNActionRow(icon: .trash, label: "Remove people", desc: "Manage current group members") {
                    actionSheet = false
                    removePeopleSheet = true
                }
            }
            if !isChannel && !isMultiMemberMarmot {
                SNActionRow(icon: .shield, label: "Verify safety number", desc: "Confirm this chat is secure") {
                    actionSheet = false
                    verifySheet = true
                }
            }
            SNActionRow(icon: .people, label: "People nearby", desc: "Open the radar") {
                actionSheet = false
                onSelect(.radar)
            }
        }
    }

    private var addPeopleContent: some View {
        let existing = Set(store.marmotGroup(forConversationId: id)?.memberNpubs ?? [])
        let pasted = parsedNpubs(from: groupAddDraft).filter { !existing.contains($0) }
        let members = mergedNpubs(pasted: pasted, selected: selectedAddNpubs)
        let contacts = store.groupInviteContacts(excluding: existing)

        return ScrollView {
            VStack(spacing: 8) {
                TextField(
                    "",
                    text: $groupAddDraft,
                    prompt: Text(verbatim: "npub1... npub1...").foregroundColor(SonarTheme.text3)
                )
                .textFieldStyle(.plain)
                .font(SonarTheme.monoFont(size: 13))
                .foregroundColor(SonarTheme.text)
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
                    guard let groupId = store.marmotGroupId(id) else { return }
                    addPeopleSheet = false
                    Task { try? await store.marmot.addGroupMembers(members, to: groupId) }
                }
            }
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 2, trailing: 10))
        }
        .frame(maxHeight: 430)
    }

    private var removePeopleContent: some View {
        let members = store.groupMemberContacts(forConversationId: id)
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
                            guard let groupId = store.marmotGroupId(id) else { return }
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

    private func parsedNpubs(from text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("npub1") }
    }

    private func mergedNpubs(pasted: [String], selected: Set<String>) -> [String] {
        var seen = Set<String>()
        return (pasted + selected.sorted()).filter { seen.insert($0).inserted }
    }

    private var slapTarget: String {
        let msgs = store.chMsgs(id)
        return msgs.last(where: { !$0.mine && !$0.action })?.author ?? "everyone"
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast)
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

    private func appeared() {
        switch mode {
        case .channel(let id):
            store.ensureChannelSelected(id)
        case .dm(let id):
            store.openedDM(id)
            if store.consumePayRequest(id) {
                openPaySheetOrWallet()
            }
        }
    }

    private func disappeared() {
        if case .dm(let id) = mode {
            store.closedDM(id)
        }
    }

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            if toast == text { toast = nil }
        }
    }

    private func openPaySheetOrWallet() {
        guard walletReady else {
            walletSheet = true
            return
        }
        if let message = store.paymentDetailsUnavailableMessage(id) {
            showToast(message)
            return
        }
        paySheet = true
    }

    private func importAttachments(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let imported = urls.reduce(0) { count, url in
                sendAttachment(from: url) ? count + 1 : count
            }
            if imported > 0 {
                showToast(imported == 1 ? "Attachment added" : "\(imported) attachments added")
            }
        case .failure:
            showToast("Couldn't attach that file")
        }
    }

    private func sendAttachment(from url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        let limit = attachmentLimitBytes
        if let size = fileSizeBytes(for: url), size > limit {
            showToast("File is too large")
            return false
        }

        guard let data = try? Data(contentsOf: url) else {
            showToast("Couldn't read \(url.lastPathComponent)")
            return false
        }
        guard data.count <= limit else {
            showToast("File is too large")
            return false
        }
        return store.sendAttachment(
            id,
            data: data,
            filename: url.lastPathComponent,
            mime: mimeType(for: url)
        )
    }

    private var attachmentLimitBytes: Int {
        store.dmTransport(id) == .mesh
            ? FileTransferLimits.maxPayloadBytes
            : Self.maxInternetAttachmentBytes
    }

    private func fileSizeBytes(for url: URL) -> Int? {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            return size
        }
        if let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber {
            return size.intValue
        }
        return nil
    }

    private func mimeType(for url: URL) -> String {
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let mime = values.contentType?.preferredMIMEType {
            return mime
        }
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}

private struct MacVerifySheetContent: View {
    @EnvironmentObject private var store: SonarAppStore
    let peerId: String
    @State private var showKey = false

    private var peer: SNPeerItem { store.peerItem(peerId) }
    private var info: SNVerifyInfo { store.verifyInfo(for: peerId) }
    private var verified: Bool { store.isVerified(peerId) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                verifyHead(name: store.nick.isEmpty ? "you" : store.nick, label: "you")
                verifyHead(name: peer.name, label: peer.name)
            }
            .padding(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

            Text("Speaks \(store.speaks(peerId))")
                .font(SonarTheme.uiFont(size: 12.5))
                .foregroundColor(SonarTheme.text3)
                .padding(.bottom, 12)

            if info.available {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                    ForEach(info.safety, id: \.self) { chunk in
                        Text(chunk)
                            .font(SonarTheme.monoFont(size: 13, weight: .semibold))
                            .foregroundColor(SonarTheme.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SonarTheme.surface2))
                    }
                }
                .padding(.horizontal, 8)

                Text("Compare these numbers with \(peer.name) in person or on a call. If they match, nobody is in the middle.")
                    .font(SonarTheme.uiFont(size: 12.5))
                    .foregroundColor(SonarTheme.text2)
                    .multilineTextAlignment(.center)
                    .padding(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12))

                if verified {
                    MacPill(icon: .shieldCheck, text: "Safety number verified", color: SonarTheme.green, fill: SonarTheme.greenSoft)
                        .padding(.horizontal, 8)
                } else {
                    SNPrimaryButton(label: "They match - mark as verified") {
                        store.markVerified(peerId)
                    }
                    .padding(.horizontal, 8)
                }

                SNGhostButton(label: showKey ? "Hide public key" : "Show public key") {
                    showKey.toggle()
                }
                .padding(.horizontal, 8)
                if showKey {
                    Text(info.publicKey)
                        .font(SonarTheme.monoFont(size: 11.5))
                        .foregroundColor(SonarTheme.text2)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SonarTheme.surface2))
                        .padding(.horizontal, 8)
                }
            } else {
                Text(info.note ?? "Verification is not available yet.")
                    .font(SonarTheme.uiFont(size: 13.5))
                    .foregroundColor(SonarTheme.text2)
                    .multilineTextAlignment(.center)
                    .padding(18)
            }
        }
    }

    private func verifyHead(name: String, label: String) -> some View {
        VStack(spacing: 6) {
            SonarAvatar(name: name, size: 48)
            Text(label)
                .font(SonarTheme.uiFont(size: 12.5, weight: .semibold))
                .foregroundColor(SonarTheme.text2)
        }
        .frame(width: 96)
    }
}

private struct MacRadarPane: View {
    @EnvironmentObject private var store: SonarAppStore
    @Binding var selection: SonarMacSelection
    @State private var selectedPeer: SNPeerItem?

    private var inRange: [SNPeerItem] { store.nearbyPeers.filter(\.inRange) }
    private var far: [SNPeerItem] { store.nearbyPeers.filter { !$0.inRange } }
    private var walletReady: Bool {
        if case .ready = store.walletState { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            radarHeader
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    Spacer(minLength: 0)
                    MacRadarField(
                        nick: store.nick,
                        inRange: inRange,
                        far: far,
                        selectedPeer: selectedPeer,
                        onTapPeer: { selectedPeer = $0 }
                    )
                    Text(selectedPeer == nil ? radarHint : "Choose what to do")
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.text3)
                    radarLegend
                    if let selectedPeer {
                        MacRadarPeerCard(
                            peer: selectedPeer,
                            walletReady: walletReady,
                            canPay: canPay(selectedPeer),
                            onOpen: openPeer,
                            onPay: payPeer
                        )
                            .frame(maxWidth: 360)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Rectangle().fill(SonarTheme.hairline).frame(width: 1)
                radarList
                    .frame(width: 310)
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .onAppear { store.nearbyAppeared() }
        .onDisappear { store.nearbyDisappeared() }
    }

    private var radarHint: String {
        walletReady ? "Click someone to chat or pay" : "Click someone to chat"
    }

    private func canPay(_ peer: SNPeerItem) -> Bool {
        walletReady && (peer.unify || store.paymentCapable(peer.id))
    }

    private var radarHeader: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(SonarTheme.accentSoft)
                .frame(width: 38, height: 38)
                .overlay(SNIcon(name: .rings, size: 20).foregroundColor(SonarTheme.accentDeep))
            VStack(alignment: .leading, spacing: 1) {
                Text("Sonar")
                    .font(SonarTheme.uiFont(size: 17, weight: .bold))
                    .foregroundColor(SonarTheme.text)
                HStack(spacing: 5) {
                    SNDot(color: SonarTheme.green, small: true)
                    Text("\(inRange.count) in range - scanning")
                }
                .font(SonarTheme.uiFont(size: 12))
                .foregroundColor(SonarTheme.text2)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 14))
        .overlay(alignment: .bottom) {
            Rectangle().fill(SonarTheme.hairline).frame(height: 1)
        }
    }

    private var radarLegend: some View {
        HStack(spacing: 18) {
            legendItem(color: SonarTheme.accent, label: "nearby - Bluetooth")
            legendItem(color: SonarTheme.net, label: "far - internet")
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(SonarTheme.uiFont(size: 12))
                .foregroundColor(SonarTheme.text2)
        }
    }

    private var radarList: some View {
        ScrollView {
            VStack(spacing: 0) {
                SNSectionLabel("In range - Bluetooth")
                if inRange.isEmpty {
                    MacEmptySidebarHint("Nobody in Bluetooth range right now.")
                } else {
                    ForEach(inRange) { peer in
                        MacRadarPeerRow(peer: peer, action: { openPeer(peer) })
                    }
                }
                SNSectionLabel("Out of range - internet")
                if far.isEmpty {
                    MacEmptySidebarHint("No internet-reachable favorites yet.")
                } else {
                    ForEach(far) { peer in
                        MacRadarPeerRow(peer: peer, action: { openPeer(peer) })
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .background(SonarTheme.surface.opacity(0.18))
    }

    private func openPeer(_ peer: SNPeerItem) {
        if peer.unify {
            if walletReady {
                store.sendSatsToUnify(peer.id)
            } else {
                selectedPeer = peer
            }
        } else {
            store.openedDM(peer.id)
            selection = .dm(peer.id)
        }
    }

    private func payPeer(_ peer: SNPeerItem) {
        guard walletReady else {
            selectedPeer = peer
            return
        }
        if peer.unify {
            store.sendSatsToUnify(peer.id)
        } else if store.paymentCapable(peer.id) {
            store.quickPay(peer.id)
        }
    }
}

private struct MacRadarField: View {
    let nick: String
    let inRange: [SNPeerItem]
    let far: [SNPeerItem]
    let selectedPeer: SNPeerItem?
    let onTapPeer: (SNPeerItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let center: CGFloat = 174

    private func pos(_ peer: SNPeerItem) -> CGPoint {
        let angle = peer.angle * .pi / 180
        return CGPoint(x: center + peer.r * cos(angle), y: center + peer.r * sin(angle))
    }

    var body: some View {
        ZStack {
            Canvas { ctx, _ in
                for radius in [66.0, 112.0, 158.0] {
                    let rect = CGRect(x: center - radius, y: center - radius, width: radius * 2, height: radius * 2)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(SonarTheme.radarRing), lineWidth: 1)
                }
                for radius in [40.0, 88.0, 134.0, 170.0] {
                    let count = Int((2 * .pi * radius) / 17)
                    for idx in 0..<count {
                        let angle = Double(idx) / Double(count) * 2 * .pi
                        let dot = CGRect(
                            x: center + radius * cos(angle) - 1.2,
                            y: center + radius * sin(angle) - 1.2,
                            width: 2.4,
                            height: 2.4
                        )
                        ctx.fill(Path(ellipseIn: dot), with: .color(SonarTheme.radarDot))
                    }
                }
            }

            if !reduceMotion {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let sweepAngle = t.truncatingRemainder(dividingBy: 4.5) / 4.5 * 360
                    ZStack {
                        Circle()
                            .fill(
                                AngularGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .clear, location: 285.0 / 360.0),
                                        .init(color: SonarTheme.sweepSoft, location: 330.0 / 360.0),
                                        .init(color: SonarTheme.sweep, location: 358.0 / 360.0),
                                        .init(color: .clear, location: 1),
                                    ],
                                    center: .center
                                )
                            )
                            .rotationEffect(.degrees(sweepAngle))
                        pulseRing(phase: t.truncatingRemainder(dividingBy: 2.6) / 2.6)
                        pulseRing(phase: (t + 1.3).truncatingRemainder(dividingBy: 2.6) / 2.6)
                    }
                }
                .allowsHitTesting(false)
            }

            radarNode(name: nick.isEmpty ? "you" : nick, label: "you", avatarSize: 52, you: true)
                .position(x: center, y: center)

            ForEach(inRange) { peer in
                Button { onTapPeer(peer) } label: {
                    radarNodeLabel(label: peer.name, peer: peer, ghost: false)
                }
                .buttonStyle(SNScaleStyle(scale: 0.94))
                .position(pos(peer))
            }

            ForEach(far) { peer in
                Button { onTapPeer(peer) } label: {
                    radarNodeLabel(label: peer.name, peer: peer, ghost: true)
                }
                .buttonStyle(SNScaleStyle(scale: 0.94))
                .position(pos(peer))
            }
        }
        .frame(width: 348, height: 348)
        .background(
            Circle()
                .strokeBorder(selectedPeer == nil ? Color.clear : SonarTheme.accent.opacity(0.22), lineWidth: 1)
                .frame(width: 356, height: 356)
        )
    }

    private func pulseRing(phase: Double) -> some View {
        let eased = 1 - pow(1 - phase, 2)
        return Circle()
            .strokeBorder(SonarTheme.accent, lineWidth: 2)
            .frame(width: 70, height: 70)
            .scaleEffect(0.7 + (2.4 - 0.7) * eased)
            .opacity(0.55 * (1 - eased))
    }

    private func radarNode(name: String, label: String, avatarSize: CGFloat, you: Bool) -> some View {
        VStack(spacing: 4) {
            SonarAvatar(name: name, size: avatarSize)
            Text(label)
                .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
                .foregroundColor(you ? SonarTheme.text3 : SonarTheme.text2)
                .padding(EdgeInsets(top: 1, leading: 7, bottom: 1, trailing: 7))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SonarTheme.bg))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func radarNodeLabel(label: String, peer: SNPeerItem, ghost: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                SonarAvatar(name: peer.name, size: ghost ? 34 : 44, presence: !ghost && peer.inRange, seed: peer.avatarSeed)
                if peer.unify {
                    Circle()
                        .fill(SonarTheme.goldFill)
                        .frame(width: 16, height: 16)
                        .overlay(SNIcon(name: .coin, size: 9, weight: 2.4).foregroundColor(SonarTheme.bg))
                        .overlay(Circle().strokeBorder(SonarTheme.bg, lineWidth: 2))
                        .offset(x: 3, y: 3)
                } else if ghost {
                    Circle()
                        .fill(SonarTheme.net)
                        .frame(width: 16, height: 16)
                        .overlay(SNIcon(name: .globe, size: 9, weight: 2.4).foregroundColor(SonarTheme.onNet))
                        .overlay(Circle().strokeBorder(SonarTheme.bg, lineWidth: 2))
                        .offset(x: 3, y: 3)
                } else if peer.sonar {
                    Circle()
                        .fill(SonarTheme.net)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().strokeBorder(SonarTheme.bg, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            Text(label)
                .font(SonarTheme.uiFont(size: 11.5, weight: .semibold))
                .foregroundColor(SonarTheme.text2)
                .padding(EdgeInsets(top: 1, leading: 7, bottom: 1, trailing: 7))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SonarTheme.bg))
                .lineLimit(1)
                .fixedSize()
        }
        .opacity(ghost ? 0.62 : 1)
    }
}

private struct MacRadarPeerCard: View {
    let peer: SNPeerItem
    let walletReady: Bool
    let canPay: Bool
    let onOpen: (SNPeerItem) -> Void
    let onPay: (SNPeerItem) -> Void

    var body: some View {
        HStack(spacing: 12) {
            SonarAvatar(name: peer.name, size: 44, presence: peer.inRange, seed: peer.avatarSeed)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name)
                    .font(SonarTheme.uiFont(size: 15.5, weight: .bold))
                    .foregroundColor(SonarTheme.text)
                    .lineLimit(1)
                Text(peer.inRange ? "\(peer.hint) - over Bluetooth" : "Out of range - over the internet")
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if peer.unify {
                if walletReady {
                    SNSmallButton(label: "Pay", primary: true, expand: false) {
                        onPay(peer)
                    }
                } else {
                    Text("Wallet not ready")
                        .font(SonarTheme.uiFont(size: 12, weight: .bold))
                        .foregroundColor(SonarTheme.text3)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 12)
                        .background(Capsule().fill(SonarTheme.surface2))
                }
            } else {
                SNSmallButton(label: "Message", expand: false) {
                    onOpen(peer)
                }
            }
            if !peer.unify, canPay {
                SNSmallButton(label: "Send money", primary: true, expand: false) {
                    onPay(peer)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SonarTheme.surface)
                .shadow(color: Color.black.opacity(0.18), radius: 15, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(SonarTheme.hairline, lineWidth: 1)
        )
    }
}

private struct MacRadarPeerRow: View {
    let peer: SNPeerItem
    let action: () -> Void

    var body: some View {
        MacSidebarButton(selected: false, action: action) {
            HStack(spacing: 11) {
                SonarAvatar(name: peer.name, size: 40, presence: peer.inRange, seed: peer.avatarSeed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.name)
                        .font(SonarTheme.uiFont(size: 14.5, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if peer.inRange {
                            SNBars(n: peer.bars)
                        } else {
                            SNIcon(name: .globe, size: 12, weight: 2.2)
                                .foregroundColor(SonarTheme.net)
                        }
                        Text(peer.inRange ? "\(peer.hint) - \(peer.detail)" : peer.detail)
                            .font(SonarTheme.uiFont(size: 12.5))
                            .foregroundColor(SonarTheme.text2)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private enum MacPaletteCommand: String, CaseIterable, Identifiable {
    case profile
    case secureChat
    case newGroup
    case settings
    case nearby

    var id: String { rawValue }

    var icon: SNIconName {
        switch self {
        case .profile: return .key
        case .secureChat: return .key
        case .newGroup: return .people
        case .settings: return .list
        case .nearby: return .rings
        }
    }

    var title: String {
        switch self {
        case .profile: return "Profile"
        case .secureChat: return "Secure chat via npub"
        case .newGroup: return "New group"
        case .settings: return "Settings"
        case .nearby: return "People Nearby"
        }
    }

    var sub: String {
        switch self {
        case .profile: return "Identity, key sharing, safety, and payment address"
        case .secureChat: return "Encrypted chat over the internet - reaches anywhere"
        case .newGroup: return "Invite people by npub"
        case .settings: return "Appearance, network, wallet, and privacy"
        case .nearby: return "Open Sonar discovery"
        }
    }
}

private struct MacCommandPalette: View {
    @EnvironmentObject private var store: SonarAppStore
    @Binding var selection: SonarMacSelection
    let openSettings: () -> Void
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var npubDraft = ""
    @State private var npubEntry = false
    @State private var groupNameDraft = ""
    @State private var groupMembersDraft = ""
    @State private var selectedGroupNpubs: Set<String> = []
    @State private var groupEntry = false
    @State private var walletSheet = false
    @FocusState private var focused: Bool

    private var walletReady: Bool {
        if case .ready = store.walletState { return true }
        return false
    }

    private var uniqueChannels: [SNChannelItem] {
        var seen = Set<String>()
        return (store.channels + store.savedChannels).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        ZStack {
            SonarTheme.scrim
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SNIcon(name: .search, size: 17, weight: 2.2)
                        .foregroundColor(SonarTheme.text3)
                    TextField("", text: $query, prompt: Text("Search people, channels, commands").foregroundColor(SonarTheme.text3))
                        .textFieldStyle(.plain)
                        .font(SonarTheme.uiFont(size: 17))
                        .foregroundColor(SonarTheme.text)
                        .focused($focused)
                        .onSubmit { chooseFirstResult() }
                    Text("esc")
                        .font(SonarTheme.monoFont(size: 10.5, weight: .semibold))
                        .foregroundColor(SonarTheme.text3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(SonarTheme.surface2))
                }
                .padding(14)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SonarTheme.hairline).frame(height: 1)
                }

                ScrollView {
                    VStack(spacing: 0) {
                        MacPaletteRow(icon: .rings, title: "Sonar", sub: "\(store.meshCount) people in range") {
                            choose(.radar)
                        }
                        section("Commands")
                        ForEach(filteredCommands) { command in
                            MacPaletteRow(icon: command.icon, title: command.title, sub: command.sub) {
                                choose(command)
                            }
                        }
                        if npubEntry || canStartSecureChatFromQuery {
                            MacNpubComposeCard(
                                npub: secureChatBinding,
                                errorText: store.marmot.errorText,
                                onStart: { startSecureChatFromDraft() }
                            )
                        }
                        if groupEntry {
                            MacGroupComposeCard(
                                name: $groupNameDraft,
                                members: $groupMembersDraft,
                                selected: $selectedGroupNpubs,
                                contacts: store.groupInviteContacts(),
                                onStart: { startGroupFromDraft() }
                            )
                        }
                        section("Channels")
                        ForEach(filteredChannels) { channel in
                            MacPaletteRow(icon: channel.id == "mesh" ? .mesh : .pin, title: channel.name, sub: channel.preview) {
                                choose(.channel(channel.id))
                            }
                        }
                        section("Messages")
                        ForEach(filteredDMs) { row in
                            MacPaletteRow(icon: row.presence ? .mesh : .lock, title: row.title, sub: row.preview) {
                                store.openedDM(row.id)
                                choose(.dm(row.id))
                            }
                        }
                        section("Nearby")
                        ForEach(filteredPeers) { peer in
                            MacPaletteRow(icon: peer.unify ? .coin : .people, title: peer.name, sub: paletteSubtitle(for: peer)) {
                                choosePeer(peer)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 440)
            }
            .frame(width: 560)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(SonarTheme.surface)
                    .shadow(color: Color.black.opacity(0.30), radius: 28, y: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(SonarTheme.hairline, lineWidth: 1)
            )
            Button("Close") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: isPresented) { open in
            if !open {
                npubEntry = false
                groupEntry = false
                npubDraft = ""
                groupNameDraft = ""
                groupMembersDraft = ""
                selectedGroupNpubs = []
            }
        }
        .snSheet(isPresented: $walletSheet, title: "Your wallet") {
            SNWalletSheetContent(onClose: { walletSheet = false })
        }
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStartSecureChatFromQuery: Bool {
        trimmedQuery.hasPrefix("npub1")
    }

    private var secureChatBinding: Binding<String> {
        if canStartSecureChatFromQuery {
            return Binding(
                get: { query },
                set: { query = $0 }
            )
        }
        return $npubDraft
    }

    private var filteredChannels: [SNChannelItem] {
        filter(uniqueChannels) { "\($0.name) \($0.preview) \($0.tier)" }
            .prefix(8)
            .map { $0 }
    }

    private var filteredDMs: [SNDMRow] {
        filter(store.dmRows) { "\($0.title) \($0.preview)" }
            .prefix(8)
            .map { $0 }
    }

    private var filteredPeers: [SNPeerItem] {
        filter(store.nearbyPeers) { "\($0.name) \($0.hint) \($0.detail)" }
            .prefix(8)
            .map { $0 }
    }

    private var filteredCommands: [MacPaletteCommand] {
        filter(MacPaletteCommand.allCases) { "\($0.title) \($0.sub)" }
            .prefix(6)
            .map { $0 }
    }

    private func filter<T>(_ values: [T], haystack: (T) -> String) -> [T] {
        let q = normalizedQuery
        guard !q.isEmpty else { return values }
        return values.filter { haystack($0).lowercased().contains(q) }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(SonarTheme.uiFont(size: 11.5, weight: .bold))
            .foregroundColor(SonarTheme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 5, trailing: 16))
    }

    private func choose(_ next: SonarMacSelection) {
        selection = next
        isPresented = false
    }

    private func choose(_ command: MacPaletteCommand) {
        switch command {
        case .profile:
            choose(SonarMacSelection.profile)
        case .secureChat:
            if canStartSecureChatFromQuery {
                startSecureChat(with: trimmedQuery)
            } else {
                if npubDraft.isEmpty, trimmedQuery.hasPrefix("npub") {
                    npubDraft = trimmedQuery
                }
                npubEntry = true
                groupEntry = false
            }
        case .newGroup:
            if groupNameDraft.isEmpty, !trimmedQuery.hasPrefix("npub") {
                groupNameDraft = trimmedQuery
            } else if groupMembersDraft.isEmpty, trimmedQuery.hasPrefix("npub") {
                groupMembersDraft = trimmedQuery
            }
            npubEntry = false
            groupEntry = true
        case .settings:
            openSettings()
            isPresented = false
        case .nearby:
            choose(SonarMacSelection.radar)
        }
    }

    private func chooseFirstResult() {
        if canStartSecureChatFromQuery {
            startSecureChat(with: trimmedQuery)
        } else if normalizedQuery.isEmpty {
            choose(.radar)
        } else if let command = filteredCommands.first {
            choose(command)
        } else if let channel = filteredChannels.first {
            choose(.channel(channel.id))
        } else if let row = filteredDMs.first {
            store.openedDM(row.id)
            choose(.dm(row.id))
        } else if let peer = filteredPeers.first {
            choosePeer(peer)
        }
    }

    private func paletteSubtitle(for peer: SNPeerItem) -> String {
        if peer.unify && !walletReady {
            return "Wallet not ready"
        }
        return peer.detail
    }

    private func choosePeer(_ peer: SNPeerItem) {
        if peer.unify {
            guard walletReady else {
                walletSheet = true
                return
            }
            store.sendSatsToUnify(peer.id)
            isPresented = false
        } else {
            store.openedDM(peer.id)
            choose(.dm(peer.id))
        }
    }

    private func startSecureChatFromDraft() {
        let npub = secureChatBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        startSecureChat(with: npub)
    }

    private func startSecureChat(with npub: String) {
        guard npub.hasPrefix("npub1") else { return }
        store.startSecureChat(npub: npub)
        isPresented = false
    }

    private func startGroupFromDraft() {
        let name = groupNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let members = mergedNpubs(pasted: parsedNpubs(from: groupMembersDraft), selected: selectedGroupNpubs)
        guard !name.isEmpty, members.count >= 2 else { return }
        Task {
            if let groupId = try? await store.marmot.startGroup(name: name, members: members) {
                let id = SonarAppStore.marmotIDPrefix + groupId
                store.openedDM(id)
                selection = .dm(id)
                isPresented = false
            }
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

private struct MacPaletteRow: View {
    let icon: SNIconName
    let title: String
    let sub: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SonarTheme.accentSoft)
                    .frame(width: 34, height: 34)
                    .overlay(SNIcon(name: icon, size: 17).foregroundColor(SonarTheme.accentDeep))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SonarTheme.uiFont(size: 14.5, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                        .lineLimit(1)
                    Text(sub)
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.text2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                SNIcon(name: .chevron, size: 14, weight: 2.2)
                    .foregroundColor(SonarTheme.text3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(SNRowPressStyle(cornerRadius: 0))
    }
}

private struct MacNpubComposeCard: View {
    @Binding var npub: String
    let errorText: String?
    let onStart: () -> Void

    private var canStart: Bool {
        npub.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("npub1")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField(
                "",
                text: $npub,
                prompt: Text(verbatim: "npub1...").foregroundColor(SonarTheme.text3)
            )
            .textFieldStyle(.plain)
            .font(SonarTheme.monoFont(size: 13))
            .foregroundColor(SonarTheme.text)
            .onSubmit {
                if canStart {
                    onStart()
                }
            }
            .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))

            if let errorText {
                Text(verbatim: errorText)
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SNPrimaryButton(label: "Start secure chat", disabled: !canStart) {
                onStart()
            }
        }
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 7, trailing: 14))
    }
}

private struct MacGroupComposeCard: View {
    @Binding var name: String
    @Binding var members: String
    @Binding var selected: Set<String>
    let contacts: [SNGroupContact]
    let onStart: () -> Void

    private var pastedNpubs: [String] {
        members.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("npub1") }
    }

    private var memberNpubs: [String] {
        var seen = Set<String>()
        return (pastedNpubs + selected.sorted()).filter { seen.insert($0).inserted }
    }

    private var canStart: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && memberNpubs.count >= 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField(
                "",
                text: $name,
                prompt: Text("Group name").foregroundColor(SonarTheme.text3)
            )
            .textFieldStyle(.plain)
            .font(SonarTheme.uiFont(size: 14))
            .foregroundColor(SonarTheme.text)
            .onSubmit {
                if canStart {
                    onStart()
                }
            }
            .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))

            TextField(
                "",
                text: $members,
                prompt: Text(verbatim: "npub1... npub1...").foregroundColor(SonarTheme.text3)
            )
            .textFieldStyle(.plain)
            .font(SonarTheme.monoFont(size: 13))
            .foregroundColor(SonarTheme.text)
            .onSubmit {
                if canStart {
                    onStart()
                }
            }
            .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))

            if !contacts.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(contacts.enumerated()), id: \.element.id) { i, contact in
                        SNGroupContactRow(
                            contact: contact,
                            selected: selected.contains(contact.npub),
                            divider: i < contacts.count - 1
                        ) {
                            if selected.contains(contact.npub) {
                                selected.remove(contact.npub)
                            } else {
                                selected.insert(contact.npub)
                            }
                        }
                    }
                }
            }

            SNPrimaryButton(label: "Create group", disabled: !canStart) {
                onStart()
            }
        }
        .padding(EdgeInsets(top: 4, leading: 14, bottom: 7, trailing: 14))
    }
}

private struct MacProfilePane: View {
    @EnvironmentObject private var store: SonarAppStore
    @State private var editingName = false
    @State private var draftName = ""
    @State private var bip353Draft = ""
    @State private var walletSheet = false
    @State private var currencySheet = false
    @State private var exportKeySheet = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 14) {
                        identityCard
                        keyCard
                    }
                    .frame(minWidth: 360, maxWidth: 430)

                    VStack(spacing: 14) {
                        safetyCard
                        paymentCard
                        walletCard
                    }
                    .frame(minWidth: 340, maxWidth: 430)
                }
                .frame(maxWidth: 900)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .onAppear {
            draftName = store.nick
            bip353Draft = store.bip353
        }
        .snSheet(isPresented: $walletSheet, title: "Your wallet") {
            SNWalletSheetContent(onClose: { walletSheet = false })
        }
        .snSheet(isPresented: $currencySheet, title: "Currency") {
            SNCurrencyPickerContent(
                currencies: store.supportedCurrencies(),
                selected: store.displayCurrency,
                onPick: { code in
                    store.setDisplayCurrency(code)
                    currencySheet = false
                },
                onClose: { currencySheet = false }
            )
        }
        .snSheet(isPresented: $exportKeySheet, title: "Export private key") {
            SNExportKeySheetContent()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Profile")
                    .font(SonarTheme.uiFont(size: 22, weight: .heavy))
                    .foregroundColor(SonarTheme.text)
                Text("Identity, key sharing, payments, and safety")
                    .font(SonarTheme.uiFont(size: 12.5))
                    .foregroundColor(SonarTheme.text2)
            }
            Spacer(minLength: 0)
            MacPill(icon: .shieldCheck, text: "\(store.verifiedCount) verified", color: SonarTheme.green, fill: SonarTheme.greenSoft)
        }
        .padding(EdgeInsets(top: 18, leading: 22, bottom: 16, trailing: 22))
        .background(SonarTheme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SonarTheme.hairline).frame(height: 1)
        }
    }

    private var identityCard: some View {
        SNSettingsCard {
            VStack(spacing: 14) {
                SonarAvatar(name: displayName, size: 96)
                if editingName {
                    HStack(spacing: 8) {
                        TextField("", text: $draftName, prompt: Text("nickname").foregroundColor(SonarTheme.text3))
                            .textFieldStyle(.plain)
                            .font(SonarTheme.uiFont(size: 18, weight: .bold))
                            .foregroundColor(SonarTheme.text)
                            .focused($nameFocused)
                            .onSubmit(saveName)
                            .onChange(of: draftName) { value in
                                if value.count > 20 { draftName = String(value.prefix(20)) }
                            }
                            .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
                        SNSmallButton(label: "Save", primary: true, expand: false, action: saveName)
                    }
                } else {
                    HStack(spacing: 7) {
                        Text(displayName)
                            .font(SonarTheme.uiFont(size: 24, weight: .heavy))
                            .foregroundColor(SonarTheme.text)
                        MacIconButton(icon: .pencil, help: "Edit nickname") {
                            draftName = store.nick
                            editingName = true
                            nameFocused = true
                        }
                    }
                }

                Text(store.shortKey)
                    .font(SonarTheme.monoFont(size: 12))
                    .foregroundColor(SonarTheme.text3)
                    .lineLimit(1)
                    .padding(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                    .background(Capsule().fill(SonarTheme.surface2))

                Text("Your nickname is what people see. Your key stays on this device unless you explicitly export it.")
                    .font(SonarTheme.uiFont(size: 12.5))
                    .foregroundColor(SonarTheme.text2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    private var keyCard: some View {
        VStack(spacing: 0) {
            SNSectionLabel("Your key")
            SNSettingsCard {
                if let npub = store.npub {
                    SNKeyShareCard(key: npub)
                        .padding(.vertical, 10)
                } else {
                    Text("Your key is not ready yet - connecting to the secure chat service.")
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.text2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
            }
        }
    }

    private var safetyCard: some View {
        VStack(spacing: 0) {
            SNSectionLabel("Safety")
            SNSettingsCard {
                SNSettingsRow(
                    icon: .key,
                    tone: .cyan,
                    label: "Fingerprint",
                    sub: "Read this aloud to verify in person",
                    value: store.myFingerprintDisplay,
                    valueMono: true,
                    trail: .none
                ) {}
                SNSettingsRow(
                    icon: .shieldCheck,
                    tone: .cyan,
                    label: "Verified people",
                    sub: "People whose safety number you checked",
                    value: String(store.verifiedCount)
                ) {
                    store.push(.nearby)
                }
                SNSettingsRow(
                    icon: .importKey,
                    tone: .cyan,
                    label: "Export private key",
                    sub: "Move your account to another wallet",
                    divider: false
                ) {
                    exportKeySheet = true
                }
            }
        }
    }

    private var paymentCard: some View {
        VStack(spacing: 0) {
            SNSectionLabel("Payments")
            SNSettingsCard {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Payment address (BIP-353)")
                            .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                            .foregroundColor(SonarTheme.text)
                        Spacer(minLength: 0)
                        SNIcon(name: .coin, size: 18, weight: 2)
                            .foregroundColor(SonarTheme.goldDeep)
                    }
                    TextField("", text: $bip353Draft, prompt: Text("user@domain").foregroundColor(SonarTheme.text3))
                        .textFieldStyle(.plain)
                        .font(SonarTheme.monoFont(size: 13))
                        .foregroundColor(SonarTheme.text)
                        .onSubmit { store.setBip353(bip353Draft) }
                        .onChange(of: bip353Draft) { store.setBip353($0) }
                        .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
                    Text("Leave this empty if you do not want to announce a payment address to nearby Sonar peers.")
                        .font(SonarTheme.uiFont(size: 12))
                        .foregroundColor(SonarTheme.text3)
                        .lineSpacing(3)
                }
                .padding(16)
            }
        }
    }

    private var walletCard: some View {
        VStack(spacing: 0) {
            SNSectionLabel("Wallet")
            SNSettingsCard {
                SNSettingsRow(
                    icon: .coin,
                    tone: .gold,
                    label: "Balance",
                    sub: walletSubtitle,
                    value: walletValue,
                    divider: store.balanceSats != nil
                ) {
                    walletSheet = true
                }
                if store.balanceSats != nil {
                    SNSettingsRow(
                        icon: .coin,
                        tone: .gold,
                        label: "Display mode",
                        value: store.displayMode == "fiat" ? "Money" : "Bitcoin"
                    ) {
                        store.setDisplayMode(store.displayMode == "fiat" ? "bitcoin" : "fiat")
                    }
                    SNSettingsRow(
                        icon: .coin,
                        tone: .gold,
                        label: "Currency",
                        value: store.displayCurrency,
                        divider: false
                    ) {
                        currencySheet = true
                    }
                }
            }
        }
    }

    private var displayName: String {
        let candidate = editingName ? draftName.trimmingCharacters(in: .whitespaces) : store.nick
        return candidate.isEmpty ? "you" : candidate
    }

    private var walletValue: String {
        switch store.walletState {
        case .ready(let balance): return store.money(balance)
        case .settingUp: return "Setting up..."
        case .notConfigured: return "Set up"
        }
    }

    private var walletSubtitle: String {
        store.balanceSats == nil
            ? "Needs Breez API key and Sonar identity"
            : "Pays like you message - Bluetooth or Lightning"
    }

    private func saveName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2 {
            store.rename(trimmed)
        }
        editingName = false
    }
}

private struct MacSettingsModal: View {
    @EnvironmentObject private var store: SonarAppStore
    @Binding var isPresented: Bool

    @State private var editingName = false
    @State private var draftName = ""
    @State private var bip353Draft = ""
    @State private var connSheet = false
    @State private var wipeAsk = false
    @State private var eraseAsk = false
    @State private var walletSheet = false
    @State private var currencySheet = false
    @State private var exportKeySheet = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            SonarTheme.scrim
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }
            VStack(spacing: 0) {
                modalHeader
                ScrollView {
                    VStack(spacing: 0) {
                        profileHead
                        keySection
                        appSection
                        networkSection
                        walletSection
                        safetySection
                        aboutSection
                        Color.clear.frame(height: 16)
                    }
                    .padding(.bottom, 18)
                }
            }
            .frame(width: 500, height: 690)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(SonarTheme.bg)
                    .shadow(color: Color.black.opacity(0.30), radius: 30, y: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(SonarTheme.hairline, lineWidth: 1)
            )
        }
        .onAppear {
            draftName = store.nick
            bip353Draft = store.bip353
        }
        .snSheet(isPresented: $connSheet, title: "Connection") {
            SNConnectivitySheetContent(onClose: { connSheet = false })
        }
        .snSheet(isPresented: $eraseAsk, title: "Erase all chats") {
            SNEraseChatsSheetContent(
                onErase: {
                    eraseAsk = false
                    store.eraseAllChats()
                },
                onClose: { eraseAsk = false }
            )
        }
        .snSheet(isPresented: $wipeAsk, title: "Emergency wipe") {
            SNWipeSheetContent(
                onWipe: {
                    wipeAsk = false
                    store.wipe()
                },
                onClose: { wipeAsk = false }
            )
        }
        .snSheet(isPresented: $walletSheet, title: "Your wallet") {
            SNWalletSheetContent(onClose: { walletSheet = false })
        }
        .snSheet(isPresented: $currencySheet, title: "Currency") {
            SNCurrencyPickerContent(
                currencies: store.supportedCurrencies(),
                selected: store.displayCurrency,
                onPick: { code in
                    store.setDisplayCurrency(code)
                    currencySheet = false
                },
                onClose: { currencySheet = false }
            )
        }
        .snSheet(isPresented: $exportKeySheet, title: "Export private key") {
            SNExportKeySheetContent()
        }
    }

    private var modalHeader: some View {
        HStack {
            Text("Settings")
                .font(SonarTheme.uiFont(size: 18, weight: .heavy))
                .foregroundColor(SonarTheme.text)
            Spacer(minLength: 0)
            MacIconButton(icon: .x, help: "Close") {
                isPresented = false
            }
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 12, trailing: 14))
        .overlay(alignment: .bottom) {
            Rectangle().fill(SonarTheme.hairline).frame(height: 1)
        }
    }

    private var profileHead: some View {
        VStack(spacing: 8) {
            SonarAvatar(name: displayName, size: 72)
            if editingName {
                HStack(spacing: 8) {
                    TextField("", text: $draftName, prompt: Text("nickname").foregroundColor(SonarTheme.text3))
                        .textFieldStyle(.plain)
                        .font(SonarTheme.uiFont(size: 17, weight: .bold))
                        .foregroundColor(SonarTheme.text)
                        .focused($nameFocused)
                        .onSubmit(saveName)
                        .onChange(of: draftName) { value in
                            if value.count > 20 { draftName = String(value.prefix(20)) }
                        }
                        .padding(EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 13))
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
                    SNSmallButton(label: "Save", primary: true, expand: false, action: saveName)
                }
                .padding(.horizontal, 24)
            } else {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(SonarTheme.uiFont(size: 21, weight: .heavy))
                        .foregroundColor(SonarTheme.text)
                    MacIconButton(icon: .pencil, help: "Edit nickname") {
                        draftName = store.nick
                        editingName = true
                        nameFocused = true
                    }
                }
            }
            Text(store.shortKey)
                .font(SonarTheme.monoFont(size: 12))
                .foregroundColor(SonarTheme.text3)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 4, trailing: 20))
    }

    private var keySection: some View {
        VStack(spacing: 0) {
            SNSectionLabel("Your key")
            SNSettingsCard {
                if let npub = store.npub {
                    SNKeyShareCard(key: npub, compact: true)
                        .padding(.vertical, 12)
                } else {
                    Text("Your key is not ready yet - connecting to the secure chat service.")
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.text2)
                        .multilineTextAlignment(.center)
                        .padding(22)
                }
            }
        }
    }

    private var appSection: some View {
        VStack(spacing: 0) {
            SNSectionLabel("App")
            SNSettingsCard {
                SNSettingsRow(
                    icon: .moon,
                    label: "Appearance",
                    value: store.isDarkMode ? "Dark" : "Light",
                    divider: false
                ) {
                    store.toggleMode()
                }
            }
        }
    }

    private var networkSection: some View {
        VStack(spacing: 0) {
            SNSectionLabel("Network")
            SNSettingsCard {
                SNSettingsRow(
                    icon: .mesh,
                    tone: .cyan,
                    label: "Connection",
                    sub: store.online ? "Bluetooth + internet" : "Nearby only, no internet",
                    value: store.online ? "Online" : "Bluetooth only",
                    divider: false
                ) {
                    connSheet = true
                }
            }
        }
    }

    private var walletSection: some View {
        VStack(spacing: 0) {
            SNSectionLabel("Wallet")
            SNSettingsCard {
                SNSettingsRow(
                    icon: .coin,
                    tone: .gold,
                    label: "Balance",
                    sub: walletSubtitle,
                    value: walletValue,
                    divider: store.balanceSats != nil
                ) {
                    walletSheet = true
                }
                if store.balanceSats != nil {
                    SNSettingsRow(
                        icon: .coin,
                        tone: .gold,
                        label: "Show balance in",
                        value: store.displayMode == "fiat" ? "Money" : "Bitcoin",
                        divider: true
                    ) {
                        store.setDisplayMode(store.displayMode == "fiat" ? "bitcoin" : "fiat")
                    }
                    SNSettingsRow(
                        icon: .coin,
                        tone: .gold,
                        label: "Currency",
                        value: store.displayCurrency,
                        divider: false
                    ) {
                        currencySheet = true
                    }
                }
            }
        }
    }

    private var safetySection: some View {
        VStack(spacing: 0) {
            SNSectionLabel("Privacy & safety")
            SNSettingsCard {
                SNSettingsRow(icon: .shieldCheck, tone: .cyan, label: "Verified people", value: String(store.verifiedCount)) {
                    store.push(.nearby)
                    isPresented = false
                }
                SNSettingsRow(
                    icon: .key,
                    tone: .cyan,
                    label: "Fingerprint",
                    sub: "Read this aloud to verify in person",
                    value: store.myFingerprintDisplay,
                    valueMono: true,
                    trail: .none
                ) {}
                SNSettingsRow(
                    icon: .importKey,
                    tone: .cyan,
                    label: "Export private key",
                    sub: "Move your account to another wallet"
                ) {
                    exportKeySheet = true
                }
                SNSettingsRow(
                    icon: .trash,
                    tone: .cyan,
                    label: "Erase all chats",
                    sub: "Clears conversations - keeps your identity"
                ) {
                    eraseAsk = true
                }
                SNSettingsRow(
                    icon: .trash,
                    tone: .red,
                    label: "Emergency wipe",
                    sub: "Deletes your key, chats and nickname",
                    danger: true,
                    divider: false
                ) {
                    wipeAsk = true
                }
            }
            SNSettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Payment address (BIP-353)")
                        .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                    TextField("", text: $bip353Draft, prompt: Text("user@domain").foregroundColor(SonarTheme.text3))
                        .textFieldStyle(.plain)
                        .font(SonarTheme.monoFont(size: 13))
                        .foregroundColor(SonarTheme.text)
                        .onSubmit { store.setBip353(bip353Draft) }
                        .onChange(of: bip353Draft) { store.setBip353($0) }
                        .padding(EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 13))
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SonarTheme.surface2))
                }
                .padding(14)
            }
        }
    }

    private var aboutSection: some View {
        VStack(spacing: 0) {
            SNSectionLabel("About")
            SNSettingsCard {
                SNSettingsRow(
                    icon: .info,
                    label: "About Sonar",
                    sub: "Open protocols - Bluetooth mesh + Nostr",
                    trail: .none,
                    divider: false
                ) {}
            }
        }
    }

    private var displayName: String {
        let candidate = editingName ? draftName.trimmingCharacters(in: .whitespaces) : store.nick
        return candidate.isEmpty ? "you" : candidate
    }

    private var walletValue: String {
        switch store.walletState {
        case .ready(let balance): return store.money(balance)
        case .settingUp: return "Setting up..."
        case .notConfigured: return "Set up"
        }
    }

    private var walletSubtitle: String {
        store.balanceSats == nil
            ? "Needs Breez API key and Sonar identity"
            : "Pays like you message - Bluetooth or Lightning"
    }

    private func saveName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2 {
            store.rename(trimmed)
        }
        editingName = false
    }
}

private struct SonarMacDetailRail: View {
    @EnvironmentObject private var store: SonarAppStore
    @Binding var selection: SonarMacSelection

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                switch selection {
                case .dm(let id):
                    MacDMDetailRail(peerId: id)
                case .channel(let id):
                    MacChannelDetailRail(chId: id) { channel in
                        selection = .channel(channel.id)
                    }
                case .radar, .profile:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 26)
        }
        .background(SonarTheme.bg)
    }
}

private struct MacDMDetailRail: View {
    @EnvironmentObject private var store: SonarAppStore
    let peerId: String
    @State private var showPublicKey = false

    private var peer: SNPeerItem { store.peerItem(peerId) }
    private var verifyInfo: SNVerifyInfo { store.verifyInfo(for: peerId) }
    private var verified: Bool { store.isVerified(peerId) }

    var body: some View {
        VStack(spacing: 12) {
            SonarAvatar(name: peer.name, size: 76, presence: peer.inRange)
            HStack(spacing: 6) {
                Text(peer.name)
                    .font(SonarTheme.uiFont(size: 19, weight: .heavy))
                    .foregroundColor(SonarTheme.text)
                    .lineLimit(1)
                if verified {
                    SNIcon(name: .shieldCheck, size: 16, weight: 2.1)
                        .foregroundColor(SonarTheme.green)
                }
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(peer.inRange ? SonarTheme.accent : SonarTheme.net)
                    .frame(width: 8, height: 8)
                Text(deliverySubtitle)
            }
            .font(SonarTheme.uiFont(size: 12.5))
            .foregroundColor(SonarTheme.text2)

            if verified {
                MacPill(icon: .shieldCheck, text: "Safety number verified", color: SonarTheme.green, fill: SonarTheme.greenSoft)
            } else if verifyInfo.available {
                safetyGrid
                Text("Compare these numbers with \(peer.name) in person or on a call. If they match, nobody is in the middle.")
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.text3)
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)

                MacPrimaryRailButton(title: "They match - mark verified", icon: .shieldCheck) {
                    store.markVerified(peerId)
                }
            } else if let note = verifyInfo.note {
                Text(note)
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.text3)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            if verifyInfo.available {
                publicKeyDisclosure
            }

            MacRailSection(title: "Delivery") {
                VStack(alignment: .leading, spacing: 8) {
                    MacInfoLine(icon: peer.inRange ? .mesh : .globe,
                                title: peer.inRange ? "Nearby" : "Out of range",
                                value: peer.inRange ? "Bluetooth mesh" : peer.detail)
                    MacInfoLine(icon: .lock,
                                title: "Encryption",
                                value: "End-to-end encrypted")
                }
            }

            if store.canCall(peerId) {
                MacPrimaryRailButton(title: "Start call", icon: .phone) {
                    store.placeCall(peerId, video: false)
                }
                MacPrimaryRailButton(title: "Start video", icon: .videocam) {
                    store.placeCall(peerId, video: true)
                }
            }
        }
    }

    private var deliverySubtitle: String {
        if peer.inRange {
            return "\(peer.hint) - over Bluetooth"
        }
        return "Out of range - over the internet"
    }

    private var publicKeyDisclosure: some View {
        VStack(spacing: 7) {
            SNGhostButton(label: showPublicKey ? "Hide public key" : "Show public key") {
                showPublicKey.toggle()
            }
            if showPublicKey {
                Text(verifyInfo.publicKey)
                    .font(SonarTheme.monoFont(size: 11))
                    .foregroundColor(SonarTheme.text2)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SonarTheme.surface2))
            }
        }
        .padding(.top, verified ? 2 : 0)
    }

    private var safetyGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Safety number")
                .font(SonarTheme.uiFont(size: 12, weight: .bold))
                .foregroundColor(SonarTheme.text3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                ForEach(verifyInfo.safety, id: \.self) { chunk in
                    Text(chunk)
                        .font(SonarTheme.monoFont(size: 11.5, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SonarTheme.surface2))
                }
            }
        }
        .padding(.top, 8)
    }
}

private struct MacChannelDetailRail: View {
    @EnvironmentObject private var store: SonarAppStore
    let chId: String
    let onSelectChannel: (SNChannelItem) -> Void
    @State private var bookmarkRefresh = false

    private var channel: SNChannelItem { store.channelItem(chId) }
    private var precisionChannels: [SNChannelItem] {
        var seen = Set<String>()
        return (store.channels + [channel]).filter { seen.insert($0.id).inserted }
    }
    private var geohash: String? {
        chId.hasPrefix("geo:") ? String(chId.dropFirst(4)) : nil
    }

    var body: some View {
        VStack(spacing: 12) {
            SNPlaceTile(size: 76, icon: chId == "mesh" ? .mesh : .pin)
            Text(channel.name)
                .font(SonarTheme.uiFont(size: 19, weight: .heavy))
                .foregroundColor(SonarTheme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(channel.sub)
                .font(SonarTheme.uiFont(size: 12.5))
                .foregroundColor(SonarTheme.text2)
                .multilineTextAlignment(.center)

            MacPill(
                icon: chId == "mesh" ? .mesh : .people,
                text: chId == "mesh" ? "Bluetooth public room" : "Public location room",
                color: chId == "mesh" ? SonarTheme.accentDeep : SonarTheme.green,
                fill: chId == "mesh" ? SonarTheme.accentSoft : SonarTheme.greenSoft
            )

            MacRailSection(title: "Precision") {
                VStack(alignment: .leading, spacing: 8) {
                    if precisionChannels.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(precisionChannels) { item in
                                    MacPrecisionChip(
                                        channel: item,
                                        selected: item.id == chId
                                    ) {
                                        onSelectChannel(item)
                                    }
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    MacInfoLine(icon: .pin, title: "Tier", value: channel.tier.isEmpty ? channel.name : channel.tier)
                    MacInfoLine(icon: .people, title: "Presence", value: "\(channel.count) here now")
                    MacInfoLine(icon: chId == "mesh" ? .mesh : .globe,
                                title: "Transport",
                                value: chId == "mesh" ? "Bluetooth mesh" : "Internet relay")
                }
            }

            if let geohash {
                let bookmarked = isBookmarked(geohash)
                MacPrimaryRailButton(
                    title: bookmarked ? "Remove saved channel" : "Save channel",
                    icon: bookmarked ? .trash : .pin
                ) {
                    GeohashBookmarksStore.shared.toggle(geohash)
                    bookmarkRefresh.toggle()
                }
            }
        }
    }

    private func isBookmarked(_ geohash: String) -> Bool {
        _ = bookmarkRefresh
        return GeohashBookmarksStore.shared.isBookmarked(geohash)
    }
}

private struct MacPrecisionChip: View {
    let channel: SNChannelItem
    let selected: Bool
    let action: () -> Void

    private var title: String {
        if !channel.tier.isEmpty { return channel.tier }
        return channel.id == "mesh" ? "Mesh" : channel.name
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(SonarTheme.uiFont(size: 11.5, weight: selected ? .bold : .semibold))
                    .lineLimit(1)
                if channel.count > 0 {
                    Circle()
                        .fill(SonarTheme.green)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundColor(selected ? SonarTheme.text : SonarTheme.text2)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(selected ? SonarTheme.surface2 : SonarTheme.surface.opacity(0.55))
            )
            .overlay(
                Capsule()
                    .strokeBorder(selected ? SonarTheme.accent : SonarTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Switch to \(channel.name)")
    }
}

private struct MacStatusBanner: View {
    let online: Bool
    let meshCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(online ? SonarTheme.green : SonarTheme.accent)
                    .frame(width: 9, height: 9)
                (
                    Text(online ? "Online" : "Offline")
                        .fontWeight(.bold)
                        .foregroundColor(SonarTheme.text)
                    + Text(online ? " - reaches anyone" : " - \(meshCount) nearby on Bluetooth")
                        .foregroundColor(SonarTheme.text2)
                )
                .font(SonarTheme.uiFont(size: 12.5))
                .lineLimit(1)
                Spacer(minLength: 0)
                SNIcon(name: .chevron, size: 13, weight: 2.2)
                    .foregroundColor(SonarTheme.text3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(online ? SonarTheme.greenSoft : SonarTheme.surface2)
            )
        }
        .buttonStyle(SNScaleStyle(scale: 0.98))
        .help("Show connection details")
    }
}

private struct MacHereCard: View {
    let channels: [SNChannelItem]
    let selectedId: String?
    let onEnter: (SNChannelItem) -> Void
    @State private var idx = 0

    private var defaultIdx: Int {
        channels.firstIndex(where: { $0.count > 0 }) ?? max(0, channels.count - 1)
    }

    var body: some View {
        if channels.isEmpty {
            MacEmptySidebarHint("Enable location to see nearby channels.")
        } else {
            let selected = channels[min(idx, channels.count - 1)]
            VStack(spacing: 0) {
                Button {
                    onEnter(selected)
                } label: {
                    HStack(spacing: 11) {
                        SNPlaceTile(size: 40, icon: selected.id == "mesh" ? .mesh : .pin)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.name)
                                .font(SonarTheme.uiFont(size: 14.5, weight: .semibold))
                                .foregroundColor(SonarTheme.text)
                                .lineLimit(1)
                            Text("\(selected.tier) · \(selected.count) here now")
                                .font(SonarTheme.uiFont(size: 12))
                                .foregroundColor(SonarTheme.text2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        SNIcon(name: .chevron, size: 14, weight: 2.2)
                            .foregroundColor(SonarTheme.text3)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(channels.enumerated()), id: \.element.id) { i, channel in
                            Button {
                                idx = i
                            } label: {
                                HStack(spacing: 4) {
                                    Text(channel.tier.isEmpty ? channel.name : channel.tier)
                                        .font(SonarTheme.uiFont(size: 11.5, weight: i == idx ? .semibold : .regular))
                                    if channel.count > 0 {
                                        Circle().fill(SonarTheme.green).frame(width: 5, height: 5)
                                    }
                                }
                                .foregroundColor(i == idx ? SonarTheme.text : SonarTheme.text3)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(i == idx ? SonarTheme.surface2 : Color.clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.bottom, 9)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(SonarTheme.surface.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(selectedId == selected.id ? SonarTheme.accent : Color.clear, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .onAppear { idx = preferredIdx }
            .onChange(of: selectedId) { _ in
                idx = preferredIdx
            }
            .onChange(of: channels.map(\.id)) { _ in
                idx = min(preferredIdx, max(0, channels.count - 1))
            }
        }
    }

    private var preferredIdx: Int {
        if let selectedId,
           let selectedIdx = channels.firstIndex(where: { $0.id == selectedId }) {
            return selectedIdx
        }
        return defaultIdx
    }
}

private struct MacSidebarDiscoverRow: View {
    let selected: Bool
    let meshCount: Int
    let action: () -> Void

    var body: some View {
        MacSidebarButton(selected: selected, action: action) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SonarTheme.accentSoft)
                    .frame(width: 34, height: 34)
                    .overlay(SNIcon(name: .rings, size: 18).foregroundColor(SonarTheme.accentDeep))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sonar")
                        .font(SonarTheme.uiFont(size: 14.5, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                    Text("\(meshCount) people in range")
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.text2)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct MacMorePlacesRow: View {
    let action: () -> Void

    var body: some View {
        MacSidebarButton(selected: false, action: action) {
            HStack(spacing: 8) {
                SNIcon(name: .pin, size: 15, weight: 2)
                    .foregroundColor(SonarTheme.text2)
                Text("More places nearby")
                    .font(SonarTheme.uiFont(size: 13, weight: .semibold))
                    .foregroundColor(SonarTheme.text2)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct MacChannelRow: View {
    let channel: SNChannelItem
    let selected: Bool
    let action: () -> Void

    var body: some View {
        MacSidebarButton(selected: selected, action: action) {
            HStack(spacing: 11) {
                SNPlaceTile(size: 40, icon: channel.id == "mesh" ? .mesh : .pin)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(SonarTheme.uiFont(size: 14.5, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                        .lineLimit(1)
                    Text(channel.preview)
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.text2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct MacDMRow: View {
    let row: SNDMRow
    let selected: Bool
    let action: () -> Void

    var body: some View {
        MacSidebarButton(selected: selected, action: action) {
            HStack(spacing: 11) {
                SonarAvatar(name: row.title, size: 40, presence: row.presence)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(row.title)
                            .font(SonarTheme.uiFont(size: 14.5, weight: .semibold))
                            .foregroundColor(SonarTheme.text)
                            .lineLimit(1)
                        if row.verified {
                            SNIcon(name: .shieldCheck, size: 13, weight: 2.1)
                                .foregroundColor(SonarTheme.green)
                        }
                    }
                    HStack(spacing: 4) {
                        SNIcon(name: row.presence ? .mesh : .lock, size: 11, weight: 2.2)
                            .foregroundColor(SonarTheme.text3)
                        Text(row.preview)
                            .font(SonarTheme.uiFont(size: 12.5))
                            .foregroundColor(SonarTheme.text2)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    if !row.time.isEmpty {
                        Text(row.time)
                            .font(SonarTheme.uiFont(size: 11))
                            .foregroundColor(SonarTheme.text3)
                    }
                    if row.unread {
                        Circle()
                            .fill(SonarTheme.accent)
                            .frame(width: 10, height: 10)
                    }
                }
            }
        }
    }
}

private struct MacSidebarButton<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    let content: Content

    init(selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? SonarTheme.accentSoft : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }
}

private struct MacEmptySidebarHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(SonarTheme.uiFont(size: 12.5))
            .foregroundColor(SonarTheme.text3)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
    }
}

private struct MacIconButton: View {
    let icon: SNIconName
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SNIcon(name: icon, size: 17, weight: 2)
                .foregroundColor(SonarTheme.text2)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.clear))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct MacRailSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(SonarTheme.uiFont(size: 11.5, weight: .bold))
                .foregroundColor(SonarTheme.text3)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

private struct MacInfoLine: View {
    let icon: SNIconName
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SNIcon(name: icon, size: 14, weight: 2)
                .foregroundColor(SonarTheme.text3)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SonarTheme.uiFont(size: 12.5, weight: .semibold))
                    .foregroundColor(SonarTheme.text)
                Text(value)
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.text2)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MacPill: View {
    let icon: SNIconName
    let text: String
    let color: Color
    let fill: Color

    var body: some View {
        HStack(spacing: 7) {
            SNIcon(name: icon, size: 14, weight: 2)
            Text(text)
                .font(SonarTheme.uiFont(size: 13, weight: .bold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(fill))
    }
}

private struct MacPrimaryRailButton: View {
    let title: String
    let icon: SNIconName
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SNIcon(name: icon, size: 16, weight: 2)
                Text(title)
                    .font(SonarTheme.uiFont(size: 14.5, weight: .bold))
            }
            .foregroundColor(SonarTheme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(SonarTheme.accentFill))
        }
        .buttonStyle(SNScaleStyle(scale: 0.98))
        .padding(.top, 4)
    }
}
#endif
