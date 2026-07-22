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
    @State private var muteRow: SNDMRow?
    @State private var connSheet = false
    @State private var searchSheet = false
    @State private var composeSheet = false
    @State private var pendingInvite: MarmotService.GroupInvite?
    @State private var groupEntry = false
    @State private var findUsername = false
    @State private var findDraft = ""
    @State private var findResolving = false
    @State private var findNpub: String?
    @State private var findMiss = false
    /// Bumped on draft edit / Back so in-flight lookups cannot apply stale results.
    @State private var findLookupGeneration = 0
    @State private var findLookupTask: Task<Void, Never>?
    @State private var findStartError: String?
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
                SNStatusChip(online: store.online, meshCount: store.meshCount, syncing: store.catchingUp) {
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
        .snSheet(isPresented: $composeSheet, title: findUsername ? "New discussion" : "Start a chat") {
            if findUsername {
                findUsernameContent
            } else {
                composeContent
            }
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
        .snSheet(
            isPresented: Binding(
                get: { muteRow != nil },
                set: { if !$0 { muteRow = nil } }
            ),
            title: muteRow.map { "Mute \($0.title)" }
        ) {
            if let row = muteRow {
                muteContent(row)
            }
        }
        .onChange(of: composeSheet) { open in
            if !open {
                findLookupTask?.cancel()
                findLookupTask = nil
                groupEntry = false
                findUsername = false
                findDraft = ""
                findResolving = false
                findNpub = nil
                findMiss = false
                findLookupGeneration &+= 1
                findStartError = nil
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
                        muted: d.muted,
                        divider: i < rows.count - 1,
                        action: {
                            store.openDM(d.id, marmotGroupId: d.marmotGroupId)
                        },
                        avatar: { SonarAvatar(name: d.title, size: 52, presence: d.presence) },
                        sub: { SNLockedPreview(preview: d.preview) }
                    )
                    .contextMenu {
                        Button { muteRow = d } label: {
                            Label(d.muted ? "Muted" : "Mute", systemImage: d.muted ? "bell.slash.fill" : "bell.slash")
                        }
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

    // ── Mute sheet (design MuteSheet): durations or the muted state ──
    @ViewBuilder
    private func muteContent(_ row: SNDMRow) -> some View {
        if store.isChatMuted(row.id) {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    SNIcon(name: .bellOff, size: 18, weight: 2)
                        .foregroundColor(SonarTheme.text2)
                    Text("Muted")
                        .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                    Spacer(minLength: 0)
                }
                .padding(EdgeInsets(top: 11, leading: 10, bottom: 3, trailing: 10))
                Text("You won't get notifications for this conversation.")
                    .font(SonarTheme.uiFont(size: 13.5))
                    .foregroundColor(SonarTheme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 0, leading: 10, bottom: 8, trailing: 10))
                SNActionRow(icon: .bell, label: "Unmute", desc: "Turn notifications back on") {
                    store.unmuteChat(row.id)
                    muteRow = nil
                }
            }
        } else {
            VStack(spacing: 0) {
                muteOption(row, label: "1 hour", duration: 3600)
                muteOption(row, label: "8 hours", duration: 8 * 3600)
                muteOption(row, label: "1 day", duration: 24 * 3600)
                muteOption(row, label: "1 week", duration: 7 * 24 * 3600)
                muteOption(row, label: "Until I turn it back on", duration: nil)
            }
        }
    }

    private func muteOption(_ row: SNDMRow, label: String, duration: TimeInterval?) -> some View {
        SNActionRow(icon: .bellOff, label: label) {
            store.muteChat(row.id, for: duration)
            muteRow = nil
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

    // ── Compose sheet: nearby peers + radar + new discussion + group ──
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
                                store.openDM(p.id)
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
                SNActionRow(icon: .key, label: "New discussion", desc: "Username, name@domain, or paste a key — reaches anywhere") {
                    findUsername = true
                    groupEntry = false
                    findDraft = ""
                    findNpub = nil
                    findMiss = false
                }
                SNActionRow(icon: .people, label: "New group", desc: "Invite contacts or paste keys") {
                    groupEntry = true
                    findUsername = false
                }
                if groupEntry {
                    groupField
                }
            }
        }
        .frame(maxHeight: 560)
    }

    /// Nested "Find someone" sheet — username / NIP-05 resolve → start chat.
    private var findUsernameContent: some View {
        let trimmed = findDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let looksValid = MarmotService.handleLooksValid(trimmed) || trimmed.hasPrefix("npub1")
        let showSuffix = !trimmed.isEmpty && !trimmed.contains("@") && !trimmed.hasPrefix("npub1")
        let previewAddress: String = {
            if trimmed.hasPrefix("npub1") { return trimmed }
            if trimmed.contains("@") { return trimmed }
            return "\(trimmed)@\(SonarAppStore.handleDomain)"
        }()
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Type a username — just vincenzo for @\(SonarAppStore.handleDomain), a full name@domain, or paste a key.")
                    .font(SonarTheme.uiFont(size: 13.5))
                    .foregroundColor(SonarTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    SNIcon(name: .key, size: 16, weight: 2)
                        .foregroundColor(SonarTheme.text3)
                    TextField(
                        "",
                        text: $findDraft,
                        prompt: Text(verbatim: "vincenzo").foregroundColor(SonarTheme.text3)
                    )
                    .textFieldStyle(.plain)
                    .font(SonarTheme.monoFont(size: 14))
                    .foregroundColor(SonarTheme.text)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .onChange(of: findDraft) { _ in
                        findLookupTask?.cancel()
                        findLookupTask = nil
                        findNpub = nil
                        findMiss = false
                        findResolving = false
                        findStartError = nil
                        findLookupGeneration &+= 1
                    }
                    .onSubmit { lookupUsername() }
                    if showSuffix {
                        Text(verbatim: "@\(SonarAppStore.handleDomain)")
                            .font(SonarTheme.monoFont(size: 12))
                            .foregroundColor(SonarTheme.text3)
                            .lineLimit(1)
                    }
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))

                if findResolving {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(verbatim: "Looking up \(previewAddress)\u{2026}")
                            .font(SonarTheme.uiFont(size: 13))
                            .foregroundColor(SonarTheme.text2)
                    }
                } else if findMiss {
                    Text("No Sonar user found at that address.")
                        .font(SonarTheme.uiFont(size: 13))
                        .foregroundColor(SonarTheme.danger)
                } else if let err = findStartError {
                    Text(verbatim: err)
                        .font(SonarTheme.uiFont(size: 13))
                        .foregroundColor(SonarTheme.danger)
                } else if let npub = findNpub {
                    Button {
                        startChatFromFind(npub)
                    } label: {
                        HStack(spacing: 12) {
                            SonarAvatar(name: trimmed.contains("@") ? String(trimmed.split(separator: "@").first ?? "user") : (trimmed.isEmpty ? "user" : trimmed), size: 46)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: showSuffix || (!trimmed.contains("@") && !trimmed.hasPrefix("npub1"))
                                    ? trimmed
                                    : (trimmed.contains("@")
                                        ? (trimmed.split(separator: "@").first.map(String.init) ?? trimmed)
                                        : trimmed))
                                    .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                                    .foregroundColor(SonarTheme.text)
                                Text(verbatim: previewAddress)
                                    .font(SonarTheme.monoFont(size: 12))
                                    .foregroundColor(SonarTheme.text2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(verbatim: npub.count > 22 ? String(npub.prefix(22)) + "\u{2026}" : npub)
                                    .font(SonarTheme.monoFont(size: 11.5))
                                    .foregroundColor(SonarTheme.text3)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            SNIcon(name: .chevron, size: 16, weight: 2.4)
                                .foregroundColor(SonarTheme.text3)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SonarTheme.surface2))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SNScaleStyle(scale: 0.99))
                }

                VStack(spacing: 6) {
                    if findNpub != nil {
                        SNPrimaryButton(label: "Start encrypted chat", disabled: false) {
                            if let npub = findNpub {
                                startChatFromFind(npub)
                            }
                        }
                    } else {
                        SNPrimaryButton(
                            label: findResolving ? "Looking up\u{2026}" : "Look up",
                            disabled: !looksValid || findResolving
                        ) {
                            lookupUsername()
                        }
                    }
                    SNGhostButton(label: "Back") {
                        findLookupTask?.cancel()
                        findLookupTask = nil
                        findLookupGeneration &+= 1
                        findUsername = false
                        findDraft = ""
                        findNpub = nil
                        findMiss = false
                        findResolving = false
                        findStartError = nil
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
        .frame(maxHeight: 560)
    }

    private func startChatFromFind(_ npub: String) {
        findStartError = nil
        if store.startSecureChat(npub: npub) != nil {
            composeSheet = false
        } else {
            findStartError = "That key isn't a valid npub — check it and try again."
            findNpub = nil
        }
    }

    private func lookupUsername() {
        let trimmed = findDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !findResolving else { return }
        findStartError = nil
        if trimmed.lowercased().hasPrefix("npub1") {
            if let decoded = try? Bech32.decode(trimmed), decoded.hrp == "npub", decoded.data.count == 32 {
                findNpub = SNMarmotProfileCache.canonicalKey(trimmed)
                findMiss = false
            } else {
                findNpub = nil
                findMiss = false
                findStartError = "That key isn't a valid npub — check it and try again."
            }
            return
        }
        guard MarmotService.handleLooksValid(trimmed) else { return }
        findLookupTask?.cancel()
        findLookupGeneration &+= 1
        let generation = findLookupGeneration
        findResolving = true
        findMiss = false
        findNpub = nil
        findLookupTask = Task { @MainActor in
            let npub = await store.resolveHandleForChat(trimmed)
            guard !Task.isCancelled, generation == findLookupGeneration else { return }
            findResolving = false
            findLookupTask = nil
            if let npub {
                findNpub = npub
            } else {
                findMiss = true
            }
        }
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
                        store.openDM(id)
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
                store.openDM(id)
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
    @State private var resolvingHandle = false
    @State private var handleMissQuery: String?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedQuery: String {
        trimmedQuery.lowercased()
    }

    private var canStartSecureChat: Bool {
        trimmedQuery.hasPrefix("npub1")
    }

    /// Show a "start chat by handle" action for plausible handle input (never
    /// npubs). Purely a string gate — resolution happens only on tap.
    private var canStartHandleChat: Bool {
        // No extra length floor: the registrar accepts one-character handles,
        // so the search gate must match the claim validator.
        !canStartSecureChat
            && !trimmedQuery.isEmpty
            && MarmotService.handleLooksValid(trimmedQuery)
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
        canStartSecureChat || canStartHandleChat || !filteredChannels.isEmpty || !filteredDMs.isEmpty || !filteredPeers.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            ScrollView {
                VStack(spacing: 0) {
                    if canStartSecureChat {
                        npubResult
                    }
                    if canStartHandleChat {
                        handleResult
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
        .onChange(of: query) { _ in
            handleMissQuery = nil
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

    /// Handle action row — mirrors the npub row's layout, with a trailing
    /// spinner while the tapped handle resolves over the internet.
    private var handleResult: some View {
        Button(action: resolveHandleAndStartChat) {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SonarTheme.accentSoft)
                    .frame(width: 38, height: 38)
                    .overlay(
                        SNIcon(name: .key, size: 19)
                            .foregroundColor(SonarTheme.accentDeep)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Start secure chat with \(trimmedQuery)")
                        .font(SonarTheme.uiFont(size: 16, weight: .semibold))
                        .foregroundColor(SonarTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if handleMissQuery == trimmedQuery {
                        Text(verbatim: "No one found for \(trimmedQuery)")
                            .font(SonarTheme.uiFont(size: 12.5))
                            .foregroundColor(SonarTheme.danger)
                    } else {
                        Text(resolvingHandle ? "Looking up this username\u{2026}" : "Encrypted chat over the internet")
                            .font(SonarTheme.uiFont(size: 12.5))
                            .foregroundColor(SonarTheme.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if resolvingHandle {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: SonarTheme.text3))
                        .scaleEffect(0.8)
                } else {
                    SNIcon(name: .chevron, size: 14, weight: 2.2)
                        .foregroundColor(SonarTheme.text3)
                }
            }
            .padding(EdgeInsets(top: 11, leading: 10, bottom: 11, trailing: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(SNRowPressStyle(cornerRadius: 14))
        .disabled(resolvingHandle)
    }

    /// Resolve on tap only — never per keystroke, and local results always
    /// paint regardless of this network lookup.
    private func resolveHandleAndStartChat() {
        guard !resolvingHandle else { return }
        let handle = trimmedQuery
        resolvingHandle = true
        handleMissQuery = nil
        Task { @MainActor in
            let npub = await store.resolveHandleForChat(handle)
            // The user may have edited the query while the lookup was in
            // flight — a stale result must not open the wrong chat.
            guard trimmedQuery == handle else {
                resolvingHandle = false
                return
            }
            resolvingHandle = false
            if let npub {
                store.startSecureChat(npub: npub)
                onClose()
            } else {
                handleMissQuery = handle
            }
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
        } else if canStartHandleChat {
            resolveHandleAndStartChat()
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
        store.openDM(row.id, marmotGroupId: row.marmotGroupId)
    }

    private func openDM(_ id: String) {
        onClose()
        store.openDM(id)
    }

    private func openPeer(_ id: String) {
        openDM(id)
    }
}

/// Connectivity sheet: the real facts behind the status chip.
struct SNConnectivitySheetContent: View {
    @EnvironmentObject private var store: SonarAppStore
    let onClose: () -> Void

    @State private var showRelayStatus = false

    var body: some View {
        VStack(spacing: 0) {
            if showRelayStatus {
                SNRelayStatusSheetContent(onClose: {
                    // Back to the compact connection summary, not all the way out.
                    showRelayStatus = false
                })
            } else {
                SNSettingsRow(
                    icon: .globe,
                    tone: store.online ? .cyan : .neutral,
                    label: "Internet",
                    sub: store.connectedRelaySummary,
                    value: store.online ? "Online" : "Offline",
                    trail: .chevron
                ) {
                    showRelayStatus = true
                }
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
}
