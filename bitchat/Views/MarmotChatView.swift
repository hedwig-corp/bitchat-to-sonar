//
// MarmotChatView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import BitLogger

/// UI state for Marmot (MLS-over-Nostr) secure chats — the White Noise
/// interop path. Owns a `MarmotService` and persists the generated Nostr
/// identity in the keychain (wiped by emergency wipe like everything else).
@MainActor
final class MarmotChatModel: ObservableObject {
    private static let nsecKeychainKey = "marmot-nsec"

    @Published var npub: String?
    @Published var groups: [MarmotService.MarmotGroup] = []
    @Published var messagesByGroup: [String: [MarmotService.MarmotMessage]] = [:]
    @Published var busy = false
    @Published var errorText: String?
    /// Resolved kind-0 profiles, keyed by npub — fills in human names/avatars
    /// for Marmot members instead of raw npubs.
    @Published var profilesByNpub: [String: MarmotService.Profile] = [:]

    private let service: MarmotService
    private let keychain: KeychainManagerProtocol
    private var syncTask: Task<Void, Never>?
    /// npubs whose profile fetch is in flight or done, to fetch each once.
    private var profileFetches: Set<String> = []
    /// Optimistically-echoed outgoing messages per group, kept visible until
    /// the relay round-trip brings the real copy back (then reconciled away).
    private var pendingOptimistic: [String: [MarmotService.MarmotMessage]] = [:]
    private static let optimisticIDPrefix = "optimistic-"

    init(
        service: MarmotService = MarmotService(),
        keychain: KeychainManagerProtocol = KeychainManager()
    ) {
        self.service = service
        self.keychain = keychain
    }

    /// Connect on first appearance: reuse the keychain identity if present,
    /// otherwise generate one and persist it. Publishes our KeyPackage so
    /// White Noise users can start chats with us.
    func connectIfNeeded() {
        guard npub == nil, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            // Read the persisted nsec SAFELY: only a genuine .itemNotFound means
            // "no identity yet" (→ generate). On a transient read failure (e.g.
            // device LOCKED during a background BLE wake) do NOT generate — that
            // would overwrite the existing nsec and orphan its derived wallet +
            // chat DB forever. Defer instead; setup retries once accessible (#13).
            let storedNsec: String?
            switch keychain.getIdentityKeyWithResult(forKey: Self.nsecKeychainKey) {
            case .success(let data):
                storedNsec = String(data: data, encoding: .utf8)
                // Migration: re-save to upgrade a legacy WhenUnlocked item to
                // AfterFirstUnlockThisDeviceOnly (this read just succeeded).
                if let s = storedNsec { _ = keychain.saveIdentityKey(Data(s.utf8), forKey: Self.nsecKeychainKey) }
            case .itemNotFound:
                storedNsec = nil
            case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
                SecureLogger.warning("⚠️ marmot-nsec not readable yet (device locked?) — deferring identity", category: .session)
                return
            }
            // 1) Publish our npub IMMEDIATELY — the identity pubkey is offline-
            //    derivable, so Sonar discovery (0x53) can advertise it without
            //    waiting on (or being blocked by) the relay connect. Persist a
            //    freshly-generated nsec so `connect` below reuses the same identity.
            if let np = try? await service.loadIdentityNpub(nsec: storedNsec) {
                if storedNsec == nil, let fresh = await service.exportNsec() {
                    _ = keychain.saveIdentityKey(Data(fresh.utf8), forKey: Self.nsecKeychainKey)
                }
                self.npub = np
            }
            // 2) Connect (opens the encrypted DB) → load the LOCAL chats right away
            //    (they don't need the relays) → then publish our KeyPackage. A relay
            //    publish failure must NOT hide already-persisted chats — that was
            //    the "chats vanish on restart, reappear on the next launch" bug.
            do {
                _ = try await service.connect(nsec: storedNsec)
                await refresh()
                self.errorText = nil
                try await service.publishKeyPackage()
            } catch {
                let desc = Self.describe(error)
                SecureLogger.warning("⚠️ Marmot connect/publish failed: \(desc)", category: .session)
                self.errorText = desc
            }
        }
    }

    func refresh() async {
        do {
            try await service.syncOnce()
            let groups = try await service.groups()
            var byGroup: [String: [MarmotService.MarmotMessage]] = [:]
            for group in groups {
                byGroup[group.id] = try await service.messages(groupId: group.id)
            }
            self.groups = groups
            self.messagesByGroup = reconcileOptimistic(into: byGroup)
            self.errorText = nil
            // Resolve a human name for every counterpart (once each).
            for group in groups {
                for member in group.memberNpubs where member != npub {
                    ensureProfile(member)
                }
            }
        } catch {
            self.errorText = Self.describe(error)
        }
    }

    /// Publish our own kind-0 profile so peers see our nickname, not our npub.
    func publishProfile(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { try? await service.publishProfile(name: trimmed) }
    }

    /// Fetch + cache a peer's kind-0 profile, so their name/avatar replaces the
    /// raw npub in the chat list, header, and avatar. Retries (via the periodic
    /// `refresh()`) until the peer has published a profile.
    func ensureProfile(_ npubToFetch: String) {
        guard !npubToFetch.isEmpty, npubToFetch != npub else { return }
        guard profilesByNpub[npubToFetch] == nil else { return } // already resolved
        guard profileFetches.insert(npubToFetch).inserted else { return } // in flight
        Task {
            let profile = try? await service.fetchProfile(npub: npubToFetch)
            await MainActor.run {
                if let profile, profile.bestName != nil {
                    self.profilesByNpub[npubToFetch] = profile
                } else {
                    self.profileFetches.remove(npubToFetch) // not published yet — allow retry
                }
            }
        }
    }

    /// Best display name for a member npub, if we've resolved their profile.
    func displayName(forNpub member: String) -> String? {
        profilesByNpub[member]?.bestName
    }

    /// Merge still-pending optimistic echoes into the freshly-synced
    /// transcripts. An optimistic message is dropped once the relay copy of
    /// the same outgoing text (mine, same content) has come back, so the
    /// echoed-back copy never duplicates; otherwise it stays visible until
    /// the round-trip completes.
    private func reconcileOptimistic(
        into byGroup: [String: [MarmotService.MarmotMessage]]
    ) -> [String: [MarmotService.MarmotMessage]] {
        guard !pendingOptimistic.isEmpty else { return byGroup }
        var merged = byGroup
        for (groupId, pending) in pendingOptimistic {
            let server = byGroup[groupId] ?? []
            let survivors = pending.filter { opt in
                !server.contains { $0.isMine && $0.content == opt.content }
            }
            if survivors.isEmpty {
                pendingOptimistic[groupId] = nil
            } else {
                pendingOptimistic[groupId] = survivors
                merged[groupId] = (server + survivors).sorted { $0.createdAt < $1.createdAt }
            }
        }
        return merged
    }

    func startChat(with peer: String) {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await service.startDirectMessage(with: trimmed, name: "")
                await refresh()
            } catch {
                self.errorText = Self.describe(error)
            }
        }
    }

    func send(_ text: String, to groupId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Optimistic echo: show the outgoing message immediately, before the
        // relay round-trip, so the conversation doesn't appear to swallow it.
        // refresh() reconciles it away once the real copy comes back.
        let echo = MarmotService.MarmotMessage(
            id: Self.optimisticIDPrefix + UUID().uuidString,
            senderNpub: npub ?? "",
            content: trimmed,
            createdAt: Date(),
            isMine: true
        )
        pendingOptimistic[groupId, default: []].append(echo)
        messagesByGroup[groupId, default: []].append(echo)
        Task {
            do {
                try await service.sendText(groupId: groupId, text: trimmed)
                await refresh()
            } catch {
                // Sending failed: drop the optimistic echo so it doesn't
                // linger as if it were delivered.
                pendingOptimistic[groupId]?.removeAll { $0.id == echo.id }
                messagesByGroup[groupId]?.removeAll { $0.id == echo.id }
                self.errorText = Self.describe(error)
            }
        }
    }

    /// Poll while a Marmot screen is visible (core has no live subscription yet).
    func startPolling() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.refresh()
            }
        }
    }

    func stopPolling() {
        syncTask?.cancel()
        syncTask = nil
    }

    /// Panic-wipe the encrypted Marmot database + its Keychain key and reset
    /// in-memory state. Called from the emergency-wipe path.
    func wipeDatabase() {
        stopPolling()
        let service = self.service
        Task { await service.wipeDatabase() }
        npub = nil
        groups = []
        messagesByGroup = [:]
        pendingOptimistic = [:]
    }

    /// Short label for a 1:1 group: the other member's npub prefix.
    func title(for group: MarmotService.MarmotGroup) -> String {
        if !group.name.isEmpty { return group.name }
        guard let other = group.memberNpubs.first(where: { $0 != npub }) else { return "Secure chat" }
        // Prefer the counterpart's resolved kind-0 profile name; fetch it if we
        // haven't yet; fall back to a short npub until it lands.
        if let name = displayName(forNpub: other) { return name }
        ensureProfile(other)
        return String(other.prefix(12)) + "…"
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case MarmotService.ServiceError.notConnected:
            return "Not connected yet — try again in a moment."
        case MarmotService.ServiceError.invalidInput(let detail):
            return "Invalid input: \(detail)"
        case MarmotService.ServiceError.core(let detail):
            return detail
        default:
            return error.localizedDescription
        }
    }
}

/// List of Marmot secure chats + entry point to start one by npub.
struct MarmotChatsView: View {
    @StateObject private var model = MarmotChatModel()
    @State private var newPeer = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                banner
                if let error = model.errorText {
                    Text(error)
                        .font(SonarTheme.uiFont(size: 12.5))
                        .foregroundColor(SonarTheme.danger)
                        .padding(.horizontal, 18)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                newChatRow
                chatList
            }
            .background(SonarTheme.bg)
            .navigationTitle("Secure chats")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.npub == nil)
                }
            }
        }
        .onAppear {
            model.connectIfNeeded()
            model.startPolling()
        }
        .onDisappear { model.stopPolling() }
    }

    private var banner: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text("End-to-end encrypted groups over the internet")
                    .font(SonarTheme.uiFont(size: 12.5, weight: .semibold))
                if let npub = model.npub {
                    Text(npub)
                        .font(SonarTheme.monoFont(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(model.busy ? "Connecting…" : "Setting up your identity…")
                        .font(SonarTheme.uiFont(size: 12))
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(SonarTheme.netDeep)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(SonarTheme.netSoft)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var newChatRow: some View {
        HStack(spacing: 8) {
            TextField("npub of a Sonar or White Noise user", text: $newPeer)
                .font(SonarTheme.monoFont(size: 13))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(SonarTheme.surface2)
                .clipShape(Capsule())
            Button {
                model.startChat(with: newPeer)
                newPeer = ""
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(SonarTheme.onNet)
                    .frame(width: 34, height: 34)
                    .background(SonarTheme.netFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(newPeer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var chatList: some View {
        Group {
            if model.groups.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 26))
                        .foregroundColor(SonarTheme.netDeep)
                        .frame(width: 56, height: 56)
                        .background(SonarTheme.netSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.bottom, 8)
                    Text("No secure chats yet")
                        .font(SonarTheme.uiFont(size: 17, weight: .bold))
                        .foregroundColor(SonarTheme.text)
                    Text("Paste a friend's npub above — or have them message yours from White Noise.")
                        .font(SonarTheme.uiFont(size: 13.5))
                        .foregroundColor(SonarTheme.text2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 44)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.groups, id: \.id) { group in
                    NavigationLink {
                        MarmotConversationView(group: group, model: model)
                    } label: {
                        HStack(spacing: 12) {
                            SonarAvatar(name: model.title(for: group), size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.title(for: group))
                                    .font(SonarTheme.uiFont(size: 16.5, weight: .semibold))
                                    .foregroundColor(SonarTheme.text)
                                Text(model.messagesByGroup[group.id]?.last?.content ?? "Say hi 👋")
                                    .font(SonarTheme.uiFont(size: 14))
                                    .foregroundColor(SonarTheme.text2)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .listRowBackground(SonarTheme.bg)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

/// One Marmot conversation: history + composer. Own bubbles are indigo —
/// these messages always travel over the internet (Nostr relays).
struct MarmotConversationView: View {
    let group: MarmotService.MarmotGroup
    @ObservedObject var model: MarmotChatModel
    @State private var draft = ""

    private var messages: [MarmotService.MarmotMessage] {
        model.messagesByGroup[group.id] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(messages, id: \.id) { message in
                            bubble(for: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            composer
        }
        .background(SonarTheme.bg)
        .navigationTitle(model.title(for: group))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func bubble(for message: MarmotService.MarmotMessage) -> some View {
        HStack {
            if message.isMine { Spacer(minLength: 60) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(SonarTheme.uiFont(size: 16))
                    .foregroundColor(message.isMine ? SonarTheme.onNet : SonarTheme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isMine ? SonarTheme.netFill : SonarTheme.bubbleOther)
                    .clipShape(RoundedRectangle(cornerRadius: SonarTheme.bubbleRadius, style: .continuous))
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(SonarTheme.uiFont(size: 10.5))
                    .foregroundColor(SonarTheme.text3)
            }
            if !message.isMine { Spacer(minLength: 60) }
        }
        .padding(.top, 7)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .font(SonarTheme.uiFont(size: 16))
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(SonarTheme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            Button {
                model.send(draft, to: group.id)
                draft = ""
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(SonarTheme.onNet)
                    .frame(width: 34, height: 34)
                    .background(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? AnyShapeStyle(SonarTheme.surface2)
                            : AnyShapeStyle(SonarTheme.netFill)
                    )
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SonarTheme.bg)
    }
}
