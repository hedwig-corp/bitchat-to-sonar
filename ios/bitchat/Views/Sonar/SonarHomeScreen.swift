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
    @State private var searchSheet = false
    @State private var composeSheet = false
    @State private var pendingInvite: MarmotService.GroupInvite?
    @State private var npubEntry = false
    @State private var groupEntry = false
    @State private var npubDraft = ""
    @State private var groupNameDraft = ""
    @State private var groupMembersDraft = ""
    @State private var selectedGroupNpubs: Set<String> = []
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
        .snSheet(isPresented: $searchSheet, title: "Search") {
            SNSearchSheetContent(onClose: { searchSheet = false })
        }
        .snSheet(isPresented: $composeSheet, title: "Start a chat") {
            composeContent
        }
        .snSheet(
            isPresented: Binding(
                get: { pendingInvite != nil },
                set: { if !$0 { pendingInvite = nil } }
            ),
            title: "Group invite"
        ) {
            if let invite = pendingInvite {
                groupInviteContent(invite)
            }
        }
        .onChange(of: composeSheet) { open in
            if !open {
                npubEntry = false
                groupEntry = false
                npubDraft = ""
                groupNameDraft = ""
                groupMembersDraft = ""
                selectedGroupNpubs = []
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
        let invites = store.marmot.pendingGroupInvites
        return VStack(spacing: 0) {
            if rows.isEmpty && invites.isEmpty {
                SNEmptyState(
                    icon: .lock,
                    iconSize: 24,
                    title: "No messages yet",
                    desc: "Find people nearby with the radar, or start a secure chat with the + button."
                )
                .padding(.vertical, 28)
            } else {
                ForEach(Array(invites.enumerated()), id: \.element.id) { i, invite in
                    let title = invite.groupName.isEmpty ? "Group chat" : invite.groupName
                    SNConvRow(
                        title: title,
                        verified: false,
                        time: "",
                        unread: false,
                        divider: i < invites.count - 1 || !rows.isEmpty,
                        action: { pendingInvite = invite },
                        avatar: { SonarAvatar(name: title, size: 52, presence: false) },
                        sub: {
                            SNLockedPreview(preview: "\(invite.memberCount) members · invite")
                        }
                    )
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, d in
                    SNConvRow(
                        title: d.title,
                        verified: d.verified,
                        time: d.time,
                        unread: d.unread,
                        divider: i < rows.count - 1,
                        action: {
                            store.openedDM(d.id, marmotGroupId: d.marmotGroupId)
                            store.push(.dm(d.id))
                        },
                        avatar: { SonarAvatar(name: d.title, size: 52, presence: d.presence) },
                        sub: { SNLockedPreview(preview: d.preview) }
                    )
                    .contextMenu {
                        if !store.isPendingSecureChat(d.id) {
                            Button(role: .destructive) { pendingDelete = d } label: {
                                Label(store.isMultiMemberMarmotGroupId(d.id) ? "Leave group" : "Delete chat", systemImage: "trash")
                            }
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
            Button(store.isMultiMemberMarmotGroupId(row.id) ? "Leave \(row.title)" : "Delete \(row.title)", role: .destructive) { store.deleteChat(row.id) }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            if store.isMultiMemberMarmotGroupId(row.id) {
                Text("This sends a leave update to the group and removes the conversation from this device.")
            } else {
                Text("This removes the conversation from this device only. The other person isn't notified.")
            }
        }
    }

    // sn-fab: search pill + compose FAB
    private var floatingBar: some View {
        HStack(spacing: 10) {
            Button(action: { searchSheet = true }) {
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
            .accessibilityLabel("Search")

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
        return ScrollView {
            VStack(spacing: 0) {
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
                    groupEntry = false
                }
                SNActionRow(icon: .people, label: "New group", desc: "Invite people by npub") {
                    groupEntry = true
                    npubEntry = false
                }
                if npubEntry {
                    npubField
                }
                if groupEntry {
                    groupField
                }
            }
        }
        .frame(maxHeight: 560)
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

    private var groupField: some View {
        let pasted = parsedNpubs(from: groupMembersDraft)
        let members = mergedNpubs(pasted: pasted, selected: selectedGroupNpubs)
        let contacts = store.groupInviteContacts()
        return ScrollView {
            VStack(spacing: 8) {
                TextField(
                    "",
                    text: $groupNameDraft,
                    prompt: Text("Group name").foregroundColor(SonarTheme.text3)
                )
                .textFieldStyle(.plain)
                .font(SonarTheme.uiFont(size: 15))
                .foregroundColor(SonarTheme.text)
                .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
                TextField(
                    "",
                    text: $groupMembersDraft,
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
                                selected: selectedGroupNpubs.contains(contact.npub),
                                divider: i < contacts.count - 1
                            ) {
                                if selectedGroupNpubs.contains(contact.npub) {
                                    selectedGroupNpubs.remove(contact.npub)
                                } else {
                                    selectedGroupNpubs.insert(contact.npub)
                                }
                            }
                        }
                    }
                }

                SNPrimaryButton(
                    label: "Create group",
                    disabled: groupNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || members.count < 2
                ) {
                    let name = groupNameDraft
                    guard members.count >= 2 else { return }
                    composeSheet = false
                    if let id = store.startGroup(name: name, members: members) {
                        store.push(.dm(id))
                    }
                }
            }
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 2, trailing: 10))
        }
        .frame(maxHeight: 430)
    }

    private func groupInviteContent(_ invite: MarmotService.GroupInvite) -> some View {
        let title = invite.groupName.isEmpty ? "Group chat" : invite.groupName
        return VStack(spacing: 14) {
            SonarAvatar(name: title, size: 64)
            VStack(spacing: 5) {
                Text(verbatim: title)
                    .font(SonarTheme.uiFont(size: 22, weight: .bold))
                    .foregroundColor(SonarTheme.text)
                    .lineLimit(1)
                Text(verbatim: "\(invite.memberCount) members · invited by \(shortNpub(invite.welcomerNpub))")
                    .font(SonarTheme.uiFont(size: 13.5))
                    .foregroundColor(SonarTheme.text2)
                    .lineLimit(1)
            }
            Text("End-to-end encrypted — only group members can read this")
                .font(SonarTheme.uiFont(size: 13))
                .foregroundColor(SonarTheme.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            SNPrimaryButton(label: "Accept") {
                let invite = invite
                pendingInvite = nil
                let id = store.acceptGroupInvite(invite)
                store.push(.dm(id))
            }
            Button {
                let invite = invite
                pendingInvite = nil
                Task { try? await store.marmot.declineGroupInvite(invite) }
            } label: {
                Text("Decline")
                    .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                    .foregroundColor(SonarTheme.text2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(SonarTheme.surface2))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
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

private func shortNpub(_ value: String) -> String {
    value.count > 16 ? "\(value.prefix(10))…\(value.suffix(4))" : value
}

/// Live search for the mobile home search pill. It only renders data from
/// channels, conversations and nearby peers exposed by SonarAppStore.
struct SNSearchSheetContent: View {
    @EnvironmentObject private var store: SonarAppStore
    let onClose: () -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedQuery: String {
        trimmedQuery.lowercased()
    }

    private var canStartSecureChat: Bool {
        trimmedQuery.hasPrefix("npub1")
    }

    private var uniqueChannels: [SNChannelItem] {
        var seen = Set<String>()
        return (store.channels + store.savedChannels).filter { seen.insert($0.id).inserted }
    }

    private var filteredChannels: [SNChannelItem] {
        filter(uniqueChannels) { "\($0.name) \($0.preview) \($0.tier)" }
            .prefix(6)
            .map { $0 }
    }

    private var filteredDMs: [SNDMRow] {
        filter(store.dmRows) { "\($0.title) \($0.preview)" }
            .prefix(6)
            .map { $0 }
    }

    private var filteredPeers: [SNPeerItem] {
        filter(store.nearbyPeers.filter { !$0.unify }) { "\($0.name) \($0.hint) \($0.detail)" }
            .prefix(6)
            .map { $0 }
    }

    private var hasResults: Bool {
        canStartSecureChat || !filteredChannels.isEmpty || !filteredDMs.isEmpty || !filteredPeers.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            ScrollView {
                VStack(spacing: 0) {
                    if canStartSecureChat {
                        npubResult
                    }
                    if !filteredChannels.isEmpty {
                        section("Channels")
                        ForEach(filteredChannels) { channel in
                            SNActionRow(
                                icon: channel.id == "mesh" ? .mesh : .pin,
                                label: channel.name,
                                desc: channel.preview
                            ) {
                                openChannel(channel)
                            }
                        }
                    }
                    if !filteredDMs.isEmpty {
                        section("Messages")
                        ForEach(filteredDMs) { row in
                            SNActionRow(
                                icon: row.presence ? .mesh : .lock,
                                label: row.title,
                                desc: row.preview
                            ) {
                                openDM(row)
                            }
                        }
                    }
                    if !filteredPeers.isEmpty {
                        section("Nearby")
                        ForEach(filteredPeers) { peer in
                            SNActionRow(
                                icon: .people,
                                label: peer.name,
                                desc: "\(peer.hint) · \(peer.detail)"
                            ) {
                                openPeer(peer.id)
                            }
                        }
                    }
                    if normalizedQuery.isEmpty {
                        section("Discover")
                        SNActionRow(icon: .rings, label: "People nearby", desc: "Open the radar to see everyone in range") {
                            onClose()
                            store.push(.nearby)
                        }
                    } else if !hasResults {
                        SNEmptyState(
                            icon: .search,
                            iconSize: 22,
                            title: "No results",
                            desc: "Search people, channels, messages, or paste an npub."
                        )
                        .padding(.vertical, 18)
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 420)
        }
        .onAppear {
            store.resolveSavedChannelNames()
            DispatchQueue.main.async { focused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            SNIcon(name: .search, size: 17, weight: 2.2)
                .foregroundColor(SonarTheme.text3)
            TextField(
                "",
                text: $query,
                prompt: Text("Search people, channels, messages").foregroundColor(SonarTheme.text3)
            )
            .textFieldStyle(.plain)
            .font(SonarTheme.uiFont(size: 16))
            .foregroundColor(SonarTheme.text)
            .focused($focused)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            .onSubmit { chooseFirstResult() }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SonarTheme.surface2))
        .padding(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
    }

    private var npubResult: some View {
        SNActionRow(
            icon: .key,
            label: "Start secure chat",
            desc: "Encrypted chat over the internet"
        ) {
            store.startSecureChat(npub: trimmedQuery)
            onClose()
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(SonarTheme.uiFont(size: 11.5, weight: .bold))
            .foregroundColor(SonarTheme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 3, trailing: 10))
    }

    private func filter<T>(_ values: [T], haystack: (T) -> String) -> [T] {
        let q = normalizedQuery
        guard !q.isEmpty else { return values }
        return values.filter { haystack($0).lowercased().contains(q) }
    }

    private func chooseFirstResult() {
        if canStartSecureChat {
            store.startSecureChat(npub: trimmedQuery)
            onClose()
        } else if let channel = filteredChannels.first {
            openChannel(channel)
        } else if let dm = filteredDMs.first {
            openDM(dm)
        } else if let peer = filteredPeers.first {
            openPeer(peer.id)
        } else if normalizedQuery.isEmpty {
            onClose()
            store.push(.nearby)
        }
    }

    private func openChannel(_ channel: SNChannelItem) {
        onClose()
        store.openChannel(channel)
    }

    private func openDM(_ row: SNDMRow) {
        onClose()
        store.openedDM(row.id, marmotGroupId: row.marmotGroupId)
        store.push(.dm(row.id))
    }

    private func openDM(_ id: String) {
        onClose()
        store.openedDM(id)
        store.push(.dm(id))
    }

    private func openPeer(_ id: String) {
        openDM(id)
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
