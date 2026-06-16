//
// SonarHomeScreen.swift
// bitchat
//
// Home screen of the Sonar app (HomeScreen in
// design/handoff/project/sonar/screens.jsx), driven by live data:
// real location channels + #mesh, real private chats merged with Marmot
// secure chats, real connectivity in the status chip.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct SonarHomeScreen: View {
    @EnvironmentObject private var store: SonarAppStore
    // NB: do NOT add @ObservedObject GeohashBookmarksStore.shared here — that
    // singleton is LocationStateManager, whose objectWillChange the store already
    // republishes (SonarAppStore.init), so saving/unsaving updates the section
    // live through `store`. Observing it directly is redundant double-observation.

    @State private var wipeAsk = false
    @State private var pendingDelete: SNDMRow?
    @State private var connSheet = false
    @State private var composeSheet = false
    @State private var npubEntry = false
    @State private var npubDraft = ""
    @State private var titleTaps: [Date] = []

    /// Triple-tap on the "sonar" title (taps within 1.2 s) triggers the wipe sheet.
    private func titleTap() {
        let now = Date()
        titleTaps = titleTaps.filter { now.timeIntervalSince($0) < 1.2 }
        titleTaps.append(now)
        if titleTaps.count >= 3 {
            titleTaps = []
            wipeAsk = true
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                SNStatusChip(online: store.online, meshCount: store.meshCount) {
                    connSheet = true
                }
                ScrollView {
                    VStack(spacing: 0) {
                        SNSectionLabel("Around you")
                        channelList
                        let saved = store.savedChannels
                        if !saved.isEmpty {
                            SNSectionLabel("Saved channels")
                            savedList(saved)
                        }
                        SNSectionLabel("Messages")
                        dmList
                    }
                    .padding(.bottom, 120)
                }
                .onAppear { store.resolveSavedChannelNames() }
            }
            floatingBar
        }
        .background(SonarTheme.bg.ignoresSafeArea())
        .snSheet(isPresented: $wipeAsk, title: "Emergency wipe") {
            SNWipeSheetContent(
                onWipe: {
                    wipeAsk = false
                    store.wipe()
                },
                onClose: { wipeAsk = false }
            )
        }
        .snSheet(isPresented: $connSheet, title: "Connection") {
            SNConnectivitySheetContent(onClose: { connSheet = false })
        }
        .snSheet(isPresented: $composeSheet, title: "Start a chat") {
            composeContent
        }
        .onChange(of: composeSheet) { open in
            if !open {
                npubEntry = false
                npubDraft = ""
            }
        }
    }

    // bc-header: settings avatar · "sonar" title · radar button
    private var header: some View {
        HStack(spacing: 6) {
            SNIconButton(action: { store.push(.settings) }) {
                SonarAvatar(name: store.nick.isEmpty ? "you" : store.nick, size: 32)
            }
            .accessibilityLabel("Settings")
            Text("sonar")
                .font(SonarTheme.uiFont(size: 27, weight: .heavy))
                .kerning(-27 * 0.02)
                .foregroundColor(SonarTheme.text)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { titleTap() }
            SNIconButton(action: { store.push(.nearby) }) {
                SNIcon(name: .rings, size: 22)
            }
            .accessibilityLabel("People nearby")
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(SonarTheme.bg)
    }

    private var channelList: some View {
        return VStack(spacing: 0) {
            // "Around you" collapses the geohash precision ladder (+ Mesh) into one
            // card with a tier picker (design: HereCard) instead of a flat list.
            SNHereCard(channels: store.channels) { store.openChannel($0) }
            if !store.locationReady {
                SNConvRow(
                    title: "Channels around you",
                    divider: false,
                    action: { store.enableLocation() },
                    avatar: { SNPlaceTile(size: 52) },
                    sub: {
                        Text(verbatim: store.locationPermissionDenied
                            ? "Location access is off — allow it in iOS Settings"
                            : "Enable location to find channels around you")
                            .font(SonarTheme.uiFont(size: 14))
                            .foregroundColor(SonarTheme.text2)
                    }
                )
            }
        }
    }

    // Design HomeScreen "Saved channels": a flat list of explicitly bookmarked
    // channels (BC_DATA.channels), each a PlaceTile + humanized name row that
    // opens the channel. Live "N here now" count, else "Saved channel".
    private func savedList(_ saved: [SNChannelItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(saved.enumerated()), id: \.element.id) { i, c in
                SNConvRow(
                    title: c.name,
                    divider: i < saved.count - 1,
                    action: { store.openChannel(c) },
                    avatar: { SNPlaceTile(size: 52) },
                    sub: {
                        Text(verbatim: c.preview)
                            .font(SonarTheme.uiFont(size: 14))
                            .foregroundColor(SonarTheme.text2)
                    }
                )
            }
        }
    }

    private var dmList: some View {
        let rows = store.dmRows
        return VStack(spacing: 0) {
            if rows.isEmpty {
                SNEmptyState(
                    icon: .lock,
                    iconSize: 24,
                    title: "No messages yet",
                    desc: "Find people nearby with the radar, or start a secure chat with the + button."
                )
                .padding(.vertical, 28)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, d in
                    SNConvRow(
                        title: d.title,
                        verified: d.verified,
                        time: d.time,
                        unread: d.unread,
                        divider: i < rows.count - 1,
                        action: {
                            store.openedDM(d.id)
                            store.push(.dm(d.id))
                        },
                        avatar: { SonarAvatar(name: d.title, size: 52, presence: d.presence) },
                        sub: { SNLockedPreview(preview: d.preview) }
                    )
                    .contextMenu {
                        Button(role: .destructive) { pendingDelete = d } label: {
                            Label("Delete chat", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { row in
            Button("Delete \(row.title)", role: .destructive) { store.deleteChat(row.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the conversation from this device only. The other person isn't notified.")
        }
    }

    // sn-fab: search pill + compose FAB
    private var floatingBar: some View {
        HStack(spacing: 10) {
            Button(action: {}) {
                HStack(spacing: 9) {
                    SNIcon(name: .search, size: 17, weight: 2)
                    Text("Search")
                        .font(SonarTheme.uiFont(size: 15))
                    Spacer(minLength: 0)
                }
                .foregroundColor(SonarTheme.text3)
                .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
                .background(
                    Capsule()
                        .fill(SonarTheme.surface)
                        .shadow(color: Color.black.opacity(0.16), radius: 9, y: 4)
                )
                .overlay(Capsule().strokeBorder(SonarTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(SNScaleStyle(scale: 0.98))

            Button(action: { composeSheet = true }) {
                Circle()
                    .fill(SonarTheme.accentFill)
                    .frame(width: 48, height: 48)
                    .overlay(
                        SNIcon(name: .rings, size: 23, weight: 1.9)
                            .foregroundColor(SonarTheme.onAccent)
                    )
                    .shadow(color: Color.black.opacity(0.22), radius: 7, y: 4)
            }
            .buttonStyle(SNScaleStyle(scale: 0.93))
            .accessibilityLabel("Start a chat")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // ── Compose sheet: nearby peers + radar + secure chat via npub ──
    private var composeContent: some View {
        let inRange = store.nearbyPeers.filter(\.inRange)
        return VStack(spacing: 0) {
            if inRange.isEmpty {
                Text("Nobody in Bluetooth range right now.")
                    .font(SonarTheme.uiFont(size: 13.5))
                    .foregroundColor(SonarTheme.text2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(inRange.prefix(4).enumerated()), id: \.element.id) { i, p in
                    SNConvRow(
                        title: p.name,
                        verified: store.isVerified(p.id),
                        divider: i < min(inRange.count, 4) - 1,
                        action: {
                            composeSheet = false
                            store.openedDM(p.id)
                            store.push(.dm(p.id))
                        },
                        avatar: { SonarAvatar(name: p.name, size: 44, presence: true) },
                        sub: {
                            HStack(spacing: 6) {
                                SNBars(n: p.bars)
                                Text(verbatim: "\(p.hint) · \(p.detail)")
                                    .font(SonarTheme.uiFont(size: 13.5))
                                    .foregroundColor(SonarTheme.text2)
                            }
                        }
                    )
                }
            }
            SNActionRow(icon: .rings, label: "People nearby", desc: "Open the radar to see everyone in range") {
                composeSheet = false
                store.push(.nearby)
            }
            SNActionRow(icon: .key, label: "Secure chat via npub", desc: "Encrypted chat over the internet — reaches anywhere") {
                npubEntry = true
            }
            if npubEntry {
                npubField
            }
        }
    }

    private var npubField: some View {
        VStack(spacing: 8) {
            TextField(
                "",
                text: $npubDraft,
                prompt: Text(verbatim: "npub1\u{2026}").foregroundColor(SonarTheme.text3)
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
            if let err = store.marmot.errorText {
                Text(verbatim: err)
                    .font(SonarTheme.uiFont(size: 12))
                    .foregroundColor(SonarTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SNPrimaryButton(
                label: "Start secure chat",
                disabled: !npubDraft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("npub1")
            ) {
                store.startSecureChat(npub: npubDraft)
                composeSheet = false
            }
        }
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 2, trailing: 10))
    }
}

/// Connectivity sheet: the real facts behind the status chip.
struct SNConnectivitySheetContent: View {
    @EnvironmentObject private var store: SonarAppStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SNSettingsRow(
                icon: .globe,
                tone: store.online ? .cyan : .neutral,
                label: "Internet",
                sub: store.online
                    ? "Connected · \(store.connectedRelayCount) Nostr relays"
                    : "Offline — messages wait or travel over Bluetooth",
                value: store.online ? "Online" : "Offline",
                trail: .none
            ) {}
            SNSettingsRow(
                icon: .mesh,
                tone: .cyan,
                label: "Bluetooth mesh",
                sub: "\(store.meshCount) people in range",
                trail: .none,
                divider: false
            ) {}
            VStack(spacing: 6) {
                SNGhostButton(label: "Done", action: onClose)
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
        }
    }
}
