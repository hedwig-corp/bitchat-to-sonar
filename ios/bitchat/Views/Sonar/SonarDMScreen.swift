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

import SwiftUI
import PhotosUI

struct SonarDMScreen: View {
    @EnvironmentObject private var store: SonarAppStore
    let peerId: String

    @State private var sheet = false
    @State private var verifySheet = false
    @State private var showKey = false
    @State private var paySheet = false
    @State private var walletSheet = false
    @State private var pickPhoto = false
    @State private var photoItem: PhotosPickerItem?

    private var peer: SNPeerItem { store.peerItem(peerId) }
    private var isMarmot: Bool { store.marmotGroupId(peerId) != nil }
    private var isSonar: Bool { store.sonarProfile(peerId) != nil }
    private var verified: Bool { store.isVerified(peerId) }
    private var transport: SNVia { store.dmTransport(peerId) }
    private var walletReady: Bool {
        if case .ready = store.walletState { return true }
        return false
    }

    /// Header sub: the network name prefixes the encryption line.
    private var subTransport: String {
        ((isMarmot || isSonar) ? "Sonar" : "bitchat") + " · end-to-end encrypted"
    }

    var body: some View {
        VStack(spacing: 0) {
            SNNavHeader(onBack: { store.pop() }, content: {
                SonarAvatar(name: peer.name, size: 36, presence: peer.inRange)
                SNHeaderTitle(name: peer.name, verified: verified) {
                    SNIcon(name: .lock, size: 11, weight: 2.4)
                    Text(verbatim: (verified ? "Verified · " : "") + subTransport)
                }
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

            let msgs = store.dmMsgs(peerId)
            if msgs.isEmpty {
                SNEmptyState(
                    icon: .lock,
                    iconSize: 24,
                    title: "Say hi to \(peer.name)",
                    desc: "Messages here are end-to-end encrypted. Only the two of you can read them."
                )
            } else {
                SNMsgList(
                    msgs: msgs,
                    showAuthors: false,
                    peerName: peer.name,
                    money: { store.money($0) },
                    fiatText: { store.moneySatsLine($0) },
                    onClaim: { payId in
                        if walletReady {
                            store.claimPay(peerId, payId: payId)
                        } else {
                            walletSheet = true
                        }
                    },
                    loadMedia: { await store.mediaData($0) }
                )
            }

            SNComposer(
                placeholder: "Message \(peer.name)" + (transport == .internet ? " · via internet" : ""),
                transport: transport,
                onSend: { store.sendDm(peerId, $0) },
                onPlus: { sheet = true },
                onCommand: { cmd in
                    store.onCommand(.init(type: .dm, id: peerId, target: peer.name), cmd)
                },
                voiceEnabled: store.canSendMedia(peerId),
                onVoice: { store.sendVoiceNote(peerId, url: $0) }
            )
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .onAppear {
            store.openedDM(peerId)
            // Radar "Send sats" quick-pay: arrive with the PaySheet open.
            if store.consumePayRequest(peerId) {
                if walletReady {
                    paySheet = true
                } else {
                    walletSheet = true
                }
            }
        }
        .onDisappear { store.closedDM(peerId) }
        .snSheet(isPresented: $sheet, title: "Add to your message") {
            VStack(spacing: 0) {
                if store.paymentCapable(peerId) {
                    SNActionRow(
                        icon: .coin, gold: true, label: "Send money",
                        desc: peer.inRange ? "Hand to hand over Bluetooth" : "Instant over the internet"
                    ) {
                        sheet = false
                        if walletReady {
                            paySheet = true
                        } else {
                            walletSheet = true
                        }
                    }
                }
                if store.canSendMedia(peerId) {
                    SNActionRow(icon: .lock, label: "Send photo or GIF", desc: "Encrypted end-to-end over White Noise") {
                        sheet = false
                        pickPhoto = true
                    }
                }
                SNActionRow(icon: .shield, label: "Verify safety number", desc: "Confirm this chat is secure") {
                    sheet = false
                    verifySheet = true
                }
            }
        }
        .photosPicker(
            isPresented: $pickPhoto,
            selection: $photoItem,
            matching: .images,
            preferredItemEncoding: .current
        )
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let isGif = data.snIsGif
                if isGif {
                    await MainActor.run {
                        _ = store.sendAttachment(peerId, data: data, filename: "animation.gif", mime: "image/gif")
                        photoItem = nil
                    }
                    return
                }
                // Normalize to JPEG: guarantees a format the core's image encoder
                // handles (HEIC/etc. aren't) and keeps the upload small.
                #if os(iOS)
                let bytes = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
                #else
                let bytes = data
                #endif
                await MainActor.run {
                    store.sendImage(peerId, data: bytes, filename: "photo.jpg", mime: "image/jpeg")
                    photoItem = nil
                }
            }
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
                onSend: { sats in store.sendPay(peerId, sats: sats) }
            )
        }
        .snSheet(isPresented: $walletSheet, title: "Your wallet") {
            SNWalletSheetContent(onClose: { walletSheet = false })
        }
        .onChange(of: verifySheet) { open in
            if !open { showKey = false }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if !isMarmot && !peer.inRange {
            outOfRangeBanner
        } else if verified {
            SNBanner(
                icon: .shieldCheck, tone: .enc,
                bold: "Verified",
                rest: " — you confirmed \(peer.name)\u{2019}s safety number"
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

    private func verifyHead(name: String, label: String) -> some View {
        VStack(spacing: 5) {
            SonarAvatar(name: name, size: 48)
            Text(verbatim: label)
                .font(SonarTheme.uiFont(size: 12.5, weight: .semibold))
                .foregroundColor(SonarTheme.text2)
        }
    }
}

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
