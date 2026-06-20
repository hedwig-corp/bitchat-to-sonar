//
// SonarChannelScreen.swift
// bitchat
//
// Public location-channel screen (ChannelScreen in
// design/handoff/project/sonar/screens.jsx), backed by the real timeline:
// ChatViewModel messages for the selected #mesh / geohash channel, sent
// through the existing send path (mesh broadcast or kind-20000 over Nostr).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarChannelScreen: View {
    @EnvironmentObject private var store: SonarAppStore
    // NB: GeohashBookmarksStore.shared is LocationStateManager, whose
    // objectWillChange the store already republishes — so toggling the bookmark
    // re-renders this view through `store`. No direct @ObservedObject needed.
    let chId: String

    @State private var sheet = false
    @State private var authorSheet: SonarAppStore.SNChannelAuthor?
    @State private var toast: String?
    @State private var previewPackCoordinate: String?

    private var ch: SNChannelItem { store.channelItem(chId) }

    /// Raw geohash for a location channel ("geo:<gh>"), nil for the Mesh channel
    /// (Mesh is always present and never bookmarkable).
    private var geohash: String? {
        chId.hasPrefix("geo:") ? String(chId.dropFirst(4)) : nil
    }

    /// Channel routing is real: geohash channels go over Nostr (kind 20000),
    /// the #mesh channel broadcasts over Bluetooth.
    private var transport: SNVia {
        chId == "mesh" ? .mesh : .internet
    }

    /// Target for /slap: most recent other participant, else the whole channel.
    private var slapTarget: String {
        let msgs = store.chMsgs(chId)
        return msgs.last(where: { !$0.mine && !$0.action })?.author ?? "everyone"
    }

    var body: some View {
        VStack(spacing: 0) {
            SNNavHeader(onBack: { store.pop() }) {
                SNPlaceTile(size: 36, icon: chId == "mesh" ? .mesh : .pin)
                SNHeaderTitle(name: ch.name) {
                    SNDot(color: SonarTheme.green, small: true)
                    Text(verbatim: ch.sub)
                }
            } trailing: {
                HStack(spacing: 2) {
                    // Save/unsave this channel to the home "Saved channels" list
                    // (geohash channels only — Mesh is always present).
                    if let gh = geohash {
                        let saved = GeohashBookmarksStore.shared.isBookmarked(gh)
                        SNIconButton(action: {
                            GeohashBookmarksStore.shared.toggle(gh)
                            showToast(GeohashBookmarksStore.shared.isBookmarked(gh) ? "Channel saved" : "Removed from saved channels")
                        }) {
                            Image(systemName: saved ? "bookmark.fill" : "bookmark")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(saved ? SonarTheme.accent : SonarTheme.text2)
                        }
                        .accessibilityLabel(saved ? "Unsave channel" : "Save channel")
                    }
                    SNIconButton(action: { store.push(.nearby) }) {
                        SNIcon(name: .rings, size: 20)
                    }
                    .accessibilityLabel("People nearby")
                }
            }

            SNBanner(icon: .people, tone: .publicRoom, bold: "Public channel", rest: " — anyone nearby can read")

            let msgs = store.chMsgs(chId)
            if msgs.isEmpty {
                SNEmptyState(
                    icon: .pin,
                    iconSize: 26,
                    amber: true,
                    title: "Quiet in \(ch.name) right now",
                    desc: ch.count > 0
                        ? "\(ch.count) people are in range of this channel. Say hi."
                        : "Nobody has said anything yet. Say hi."
                )
            } else {
                SNMsgList(msgs: msgs, showAuthors: true, onTapAuthor: { m in
                    guard !m.mine else { return }
                    if let author = store.channelAuthor(forMessage: m.id) {
                        authorSheet = author
                    } else {
                        // Their per-location identity has left the channel, so
                        // we can't open a DM right now (honest "offline" signal).
                        showToast("\(m.author ?? "Questa persona") non \u{00E8} pi\u{00F9} nel canale")
                    }
                }, loadSticker: { await store.stickerImageData(for: $0) },
                    onTapPack: { previewPackCoordinate = $0 })
            }

            SNComposer(
                placeholder: "Message \(ch.name)",
                transport: transport,
                onSend: { store.sendCh(chId, $0) },
                onPlus: { sheet = true },
                onCommand: { cmd in
                    store.onCommand(.init(type: .ch, id: chId, target: slapTarget), cmd)
                },
                onSticker: { sticker, coord in
                    if !store.sendStickerToChannel(chId, sticker: sticker, packCoordinate: coord) {
                        showToast("Stickers aren't supported in public channels yet")
                    }
                },
                loadStickerPack: { author, identifier, relays in
                    await store.stickerPack(authorPubkeyHex: author, identifier: identifier, relayUrls: relays)
                },
                loadStickerImage: { await store.stickerImageData(url: $0, expectedSha256: $1) },
                voiceEnabled: false
            )
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
                    isInstalled: { coord in
                        let installed = await store.fetchInstalledPacks()
                        return installed.contains(where: { $0.lowercased() == coord.lowercased() })
                    },
                    onClose: { previewPackCoordinate = nil }
                )
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.easeOut(duration: 0.2), value: toast)
        .onAppear { store.ensureChannelSelected(chId) }
        .snSheet(isPresented: $sheet, title: "Add to your message") {
            VStack(spacing: 0) {
                SNActionRow(icon: .people, label: "People nearby", desc: "See who can hear you over Bluetooth") {
                    sheet = false
                    store.push(.nearby)
                }
            }
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
                        icon: .lock, label: "Open private chat",
                        desc: "End-to-end encrypted, over the internet"
                    ) {
                        authorSheet = nil
                        store.openChannelDM(author)
                    }
                    SNActionRow(
                        icon: .trash, label: "Block \(author.name)",
                        desc: "You won\u{2019}t see their messages anymore"
                    ) {
                        let name = author.name
                        authorSheet = nil
                        store.blockChannelAuthor(author)
                        showToast("\(name) blocked")
                    }
                }
            }
        }
    }

    // sn-toast: transient bottom snackbar in the app style (auto-dismisses).
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

    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            if toast == text { toast = nil }
        }
    }
}
