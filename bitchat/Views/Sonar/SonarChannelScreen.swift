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
    let chId: String

    @State private var sheet = false

    private var ch: SNChannelItem { store.channelItem(chId) }

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
                SNIconButton(action: { store.push(.nearby) }) {
                    SNIcon(name: .rings, size: 20)
                }
                .accessibilityLabel("People nearby")
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
                SNMsgList(msgs: msgs, showAuthors: true)
            }

            SNComposer(
                placeholder: "Message \(ch.name)",
                transport: transport,
                onSend: { store.sendCh(chId, $0) },
                onPlus: { sheet = true },
                onCommand: { cmd in
                    store.onCommand(.init(type: .ch, id: chId, target: slapTarget), cmd)
                }
            )
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .onAppear { store.ensureChannelSelected(chId) }
        .snSheet(isPresented: $sheet, title: "Add to your message") {
            VStack(spacing: 0) {
                SNActionRow(icon: .people, label: "People nearby", desc: "See who can hear you over Bluetooth") {
                    sheet = false
                    store.push(.nearby)
                }
            }
        }
    }
}
