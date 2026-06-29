//
// MarmotChatView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import Combine
import BitLogger
import CryptoKit
import SonarCore

enum SNMarmotProfileCache {
    static let defaultsKey = "marmot.profilesByNpub.v1"
    private static let cacheLimit = 4_096
    private static let canonicalLock = NSLock()
    private static var canonicalCache: [String: String] = [:]

    static func canonicalKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        canonicalLock.lock()
        if let cached = canonicalCache[trimmed] {
            canonicalLock.unlock()
            return cached
        }
        canonicalLock.unlock()

        let canonical = computeCanonicalKey(trimmed)

        canonicalLock.lock()
        if canonicalCache.count >= cacheLimit {
            canonicalCache.removeAll(keepingCapacity: true)
        }
        canonicalCache[trimmed] = canonical
        canonicalLock.unlock()

        return canonical
    }

    private static func computeCanonicalKey(_ trimmed: String) -> String {
        if trimmed.hasPrefix("npub1"),
           let decoded = try? Bech32.decode(trimmed),
           decoded.hrp == "npub",
           decoded.data.count == 32,
           let encoded = try? Bech32.encode(hrp: "npub", data: decoded.data) {
            return encoded
        }
        if let data = Data(hexString: trimmed), data.count == 32,
           let encoded = try? Bech32.encode(hrp: "npub", data: data) {
            return encoded
        }
        return trimmed
    }

    static func load(from defaults: UserDefaults) -> [String: MarmotService.Profile] {
        guard let data = defaults.data(forKey: defaultsKey),
              let profiles = try? JSONDecoder().decode([String: MarmotService.Profile].self, from: data)
        else { return [:] }
        return normalized(profiles)
    }

    static func save(_ profiles: [String: MarmotService.Profile], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(normalized(profiles)) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }

    private static func normalized(_ profiles: [String: MarmotService.Profile]) -> [String: MarmotService.Profile] {
        profiles.reduce(into: [:]) { result, entry in
            let key = canonicalKey(entry.key)
            if result[key]?.bestName == nil || entry.value.bestName != nil {
                result[key] = entry.value
            }
        }
    }
}

func snShortNpubLabel(_ value: String) -> String {
    value.count > 16 ? "\(value.prefix(10))…\(value.suffix(4))" : value
}

func snResolvedMarmotAuthorName(
    _ message: MarmotService.MarmotMessage,
    profilesByNpub: [String: MarmotService.Profile],
    fetchMissingProfile: (String) -> Void,
    shortNpub: (String) -> String
) -> String? {
    guard !message.isMine, !message.senderNpub.isEmpty else { return nil }
    let canonical = SNMarmotProfileCache.canonicalKey(message.senderNpub)
    if let name = profilesByNpub[canonical]?.bestName ?? profilesByNpub[message.senderNpub]?.bestName {
        return name
    }
    fetchMissingProfile(message.senderNpub)
    return shortNpub(message.senderNpub)
}

enum SNMarmotChatSnapshotCache {
    private static let defaultsKey = "marmot.chatSnapshot.v1"

    private struct Snapshot: Codable {
        let groups: [MarmotService.MarmotGroup]
    }

    static func load(from defaults: UserDefaults) -> ([MarmotService.MarmotGroup], [String: [MarmotService.MarmotMessage]]) {
        guard let data = defaults.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return ([], [:]) }
        // Rewrite older snapshots that included message bodies/media outside the
        // encrypted chat database. The startup cache is row metadata only.
        save(groups: snapshot.groups, messagesByGroup: [:], to: defaults)
        return (snapshot.groups, [:])
    }

    static func save(
        groups: [MarmotService.MarmotGroup],
        messagesByGroup: [String: [MarmotService.MarmotMessage]],
        to defaults: UserDefaults
    ) {
        _ = messagesByGroup
        let snapshot = Snapshot(groups: groups)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// UI state for Marmot (MLS-over-Nostr) secure chats — the White Noise
/// interop path. Owns a `MarmotService` and persists the generated Nostr
/// identity in the keychain (wiped by emergency wipe like everything else).
@MainActor
final class MarmotChatModel: ObservableObject {
    private static let nsecKeychainKey = "marmot-nsec"
    private static let sonarDescriptorRefreshInterval: TimeInterval = 15 * 60
    private static let sonarDescriptorMissRetryInterval: TimeInterval = 60
    private static let localTranscriptPageLimit: UInt32 = 100
    private static let localSummaryPageLimit: UInt32 = 20
    private static let localSummaryGroupLimit: UInt32 = 50

    @Published var npub: String?
    /// Supplies the local user's current nickname so the kind-0 profile can be
    /// (re)published on every relay connect, alongside the KeyPackage. Set by
    /// SonarAppStore. Without this the profile only published opportunistically
    /// (on the npub signal / explicit rename) and could be lost to relay or
    /// onboarding timing — leaving peers to see a raw npub instead of the name.
    var profileNameProvider: (() -> String)?
    @Published var groups: [MarmotService.MarmotGroup] = []
    @Published var pendingGroupInvites: [MarmotService.GroupInvite] = []
    @Published var messagesByGroup: [String: [MarmotService.MarmotMessage]] = [:]
    @Published var busy = false
    @Published var errorText: String?
    /// Resolved kind-0 profiles, keyed by npub — fills in human names/avatars
    /// for Marmot members instead of raw npubs.
    @Published var profilesByNpub: [String: MarmotService.Profile] = [:]
    /// Resolved public Sonar descriptors, keyed by npub. Presence here confirms
    /// the npub is Sonar-capable; absence is only "unknown / not fetched".
    @Published var sonarDescriptorsByNpub: [String: MarmotService.SonarDescriptor] = [:]
    /// Recent relay misses, keyed by npub. A miss is NOT proof the user is White
    /// Noise-only; it only lets call-offer handling stop deferring forever.
    @Published private(set) var sonarDescriptorMissesByNpub: [String: Date] = [:]
    /// True when the current node is relay-backed, not just the local DB node.
    @Published private(set) var relayConnected = false
    /// Unread message counts per Marmot group, keyed by group ID hex.
    @Published var unreadByGroup: [String: UInt64] = [:]

    private let service: MarmotService
    private let keychain: KeychainManagerProtocol
    private let defaults: UserDefaults
    private var syncTask: Task<Void, Never>?
    private var startupLocalSummaryTask: Task<Void, Never>?
    private var relayConnectTask: Task<Void, Never>?
    private var relayBusy = false
    #if DEBUG
    /// SONAR_BENCH: one-shot guards for the post-connect "first wake" (T3b) and
    /// "first drain" (T4) markers. DEBUG-only (benchmark harness).
    private var benchFirstWakeLogged = false
    private var benchFirstDrainLogged = false
    #endif
    private var installedPackCoordinates: Set<String> = []
    /// npubs whose profile fetch is in flight or done, to fetch each once per session.
    private var profileFetches: Set<String> = []
    /// npubs whose Sonar descriptor fetch is currently in flight.
    private var descriptorFetches: Set<String> = []
    /// Last successful relay lookup time per npub. A successful nil response is
    /// tracked via `sonarDescriptorMissesByNpub`.
    private var sonarDescriptorFetchedAtByNpub: [String: Date] = [:]
    /// Optimistically-echoed outgoing messages per group, kept visible until
    /// the relay round-trip brings the real copy back (then reconciled away).
    private var pendingOptimistic: [String: [MarmotService.MarmotMessage]] = [:]
    private var stickerPacksByCoordinate: [String: StickerPackInfo] = [:]
    private var stickerImagesByURL: [String: Data] = [:]
    /// Last desired payment offer metadata for our public descriptor. Reused
    /// when other descriptor refreshes publish capabilities without changing
    /// payment state.
    private var descriptorBolt12Offer: String?
    private var conversationChangeSub: AnyCancellable?
    /// Serializes outgoing sends so rapid-fire messages arrive in order.
    private var sendChain: Task<Void, Never>?
    private static let optimisticIDPrefix = "optimistic-"
    private static let failedOptimisticIDPrefix = "failed-"

    static func stateText(for message: MarmotService.MarmotMessage) -> String? {
        guard message.isMine else { return nil }
        if message.id.hasPrefix(failedOptimisticIDPrefix) { return "Couldn't send" }
        if message.id.hasPrefix(optimisticIDPrefix) {
            return message.media.isEmpty ? "Sending" : "Uploading"
        }
        if message.deliveryState == "failed" { return "Couldn't send" }
        return "Sent"
    }

    init(
        service: MarmotService = MarmotService(),
        keychain: KeychainManagerProtocol = KeychainManager(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.keychain = keychain
        self.defaults = defaults
        self.profilesByNpub = SNMarmotProfileCache.load(from: defaults)
        let cached = SNMarmotChatSnapshotCache.load(from: defaults)
        self.groups = cached.0
        self.messagesByGroup = cached.1
        self.conversationChangeSub = service.conversationChanged
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.loadLocalSummaries(resolveMembers: false) }
            }
    }

    /// Connect on first appearance: reuse the keychain identity if present.
    /// A fresh identity may be created only by explicit onboarding completion.
    /// Publishes our KeyPackage so White Noise users can start chats with us.
    /// Lazy + idempotent: no-op once connected (npub set) or while a connect is
    /// already in flight (busy).
    func connectIfNeeded(allowCreateIdentity: Bool = false) {
        guard npub == nil, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            _ = await performConnect(allowCreateIdentity: allowCreateIdentity)
        }
    }

    func prepareIdentityForOnboarding() async -> Bool {
        if npub != nil || service.isConnected() { return true }
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        return await performConnect(allowCreateIdentity: true)
    }

    /// The actual connect sequence (awaitable, NOT guarded). Reuse the keychain
    /// identity, open the encrypted DB, load local group metadata, then schedule
    /// relay setup behind first-paint local reads. Used by the lazy
    /// `connectIfNeeded()` and the erase-and-reconnect path —
    /// the latter must NOT be blocked by the `busy`/`npub` guard, which would
    /// silently leave the node disconnected ("not connected yet" until restart).
    private func performConnect(allowCreateIdentity: Bool = false) async -> Bool {
        // Read the persisted nsec SAFELY: transient read failures (e.g. device
        // LOCKED during a background BLE wake) must never generate a replacement
        // key. Even a genuine miss only creates a key during explicit onboarding.
        // Otherwise setup retries once the existing key is accessible (#13).
        var storedNsec: String?
        #if DEBUG
        let benchNsec = ProcessInfo.processInfo.environment["SONAR_BENCH_NSEC"]
        #else
        let benchNsec: String? = nil
        #endif
        if let benchNsec, !benchNsec.isEmpty {
            // SONAR_BENCH: deterministic provisioning for the cold-start benchmark.
            // Adopt the env identity WITHOUT depending on Keychain — unsigned
            // simulator builds get errSecMissingEntitlement (-34018), which would
            // otherwise early-return below and the relay-sync path would never run.
            // Simulator only / throwaway data — never set this env in production.
            storedNsec = benchNsec
            _ = keychain.saveIdentityKey(Data(benchNsec.utf8), forKey: Self.nsecKeychainKey)
            SecureLogger.info("SONAR_BENCH identity from env (keychain-independent)", category: .session)
        } else {
            switch keychain.getIdentityKeyWithResult(forKey: Self.nsecKeychainKey) {
            case .success(let data):
                storedNsec = String(data: data, encoding: .utf8)
                // Migration: re-save to upgrade a legacy WhenUnlocked item to
                // AfterFirstUnlockThisDeviceOnly (this read just succeeded).
                if let s = storedNsec { _ = keychain.saveIdentityKey(Data(s.utf8), forKey: Self.nsecKeychainKey) }
            case .itemNotFound:
                guard allowCreateIdentity else {
                    SecureLogger.warning("⚠️ marmot-nsec missing after onboarding — refusing to create a replacement identity", category: .session)
                    self.errorText = "Account key missing. Restore from your backup key."
                    return false
                }
                storedNsec = nil
            case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
                SecureLogger.warning("⚠️ marmot-nsec not readable yet (device locked?) — deferring identity", category: .session)
                return false
            }
        }
        // 1) Publish our npub IMMEDIATELY — the identity pubkey is offline-
        //    derivable, so Sonar discovery (0x53) can advertise it without
        //    waiting on (or being blocked by) the relay connect. Persist a
        //    freshly-generated nsec so `connect` below reuses the same identity.
        do {
            let np = try await service.loadIdentityNpub(nsec: storedNsec)
            if storedNsec == nil {
                guard let fresh = await service.exportNsec() else {
                    self.errorText = "Couldn't create account key. Try again."
                    SecureLogger.error("Generated identity could not export marmot-nsec", category: .keychain)
                    self.npub = nil
                    return false
                }
                guard keychain.saveIdentityKey(Data(fresh.utf8), forKey: Self.nsecKeychainKey) else {
                    self.errorText = "Couldn't save account key. Try again."
                    SecureLogger.error("Failed to persist newly generated marmot-nsec", category: .keychain)
                    self.npub = nil
                    return false
                }
                storedNsec = fresh
            }
            self.npub = np
        } catch {
            let desc = Self.describe(error)
            SecureLogger.warning("⚠️ Marmot identity load failed: \(desc)", category: .session)
            self.errorText = desc
            return false
        }
        // 2) Open the encrypted DB with no relays first → load LOCAL chats right
        //    away → then attach real relays in the background. A relay publish
        //    failure must NOT hide already-persisted chats.
        do {
            _ = try await service.connectLocal(nsec: storedNsec)
            relayConnected = false
            await loadLocalGroupMetadata()
            #if DEBUG
            // SONAR_BENCH: local-first paint ready — groups hydrated from the
            // encrypted DB before any relay attach (T1).
            SecureLogger.info("SONAR_BENCH t1_local_paint groups=\(groups.count)", category: .session)
            #endif
            self.errorText = nil
            scheduleStartupLocalSummariesThenRelay()
            return true
        } catch {
            let desc = Self.describe(error)
            SecureLogger.warning("⚠️ Marmot local open failed: \(desc)", category: .session)
            self.errorText = desc
            return false
        }
    }

    /// `nsec1…` backup of the connected identity, for the "Export private key"
    /// self-custody escape hatch. Nil until the identity has loaded.
    func exportNsec() async -> String? {
        await service.exportNsec()
    }

    /// Restore an existing identity from a pasted `nsec1…` backup (onboarding
    /// "I already have a key"): validate it, persist it as THE identity, then
    /// connect as it. Throws on an invalid key so the caller can surface it.
    func restoreIdentity(nsec raw: String) async throws {
        let nsec = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate by importing — throws on a malformed/!nsec key, so we never
        // persist garbage over a (possibly existing) identity.
        _ = try await service.loadIdentityNpub(nsec: nsec)
        guard keychain.saveIdentityKey(Data(nsec.utf8), forKey: Self.nsecKeychainKey) else {
            throw MarmotService.ServiceError.core("failed to persist restored identity")
        }
        // Drive the full connect sequence directly (performConnect reads the
        // nsec we just persisted); guard concurrent connectIfNeeded with busy.
        busy = true
        defer { busy = false }
        npub = nil
        guard await performConnect() else {
            throw MarmotService.ServiceError.core(errorText ?? "failed to connect restored identity")
        }
    }

    /// Await until the Marmot node is connected (or a short timeout), kicking
    /// off a connect if none is in flight. Lets start/send wait through the
    /// reconnect window (e.g. right after "erase all chats" or a cold launch)
    /// instead of immediately surfacing "not connected yet".
    func ensureConnected(timeoutSeconds: Double = 10) async -> Bool {
        if service.isConnected() { return true }
        if !busy { connectIfNeeded() }
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if service.isConnected() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return service.isConnected()
    }

    private func scheduleRelayConnect(delaySeconds: Double = 2) {
        guard relayConnectTask == nil else { return }
        relayConnectTask = Task { [weak self] in
            let nanos = UInt64(max(0, delaySeconds) * 1_000_000_000)
            if nanos > 0 {
                try? await Task.sleep(nanoseconds: nanos)
            }
            guard !Task.isCancelled else { return }
            self?.connectRelaysIfNeeded()
            self?.relayConnectTask = nil
        }
    }

    private func scheduleStartupLocalSummariesThenRelay(delaySeconds: Double = 0.25) {
        guard startupLocalSummaryTask == nil else { return }
        startupLocalSummaryTask = Task { [weak self] in
            let nanos = UInt64(max(0, delaySeconds) * 1_000_000_000)
            if nanos > 0 {
                try? await Task.sleep(nanoseconds: nanos)
            }
            guard let self, !Task.isCancelled else { return }
            await self.loadLocalSummaries(resolveMembers: false)
            guard !Task.isCancelled else { return }
            self.startupLocalSummaryTask = nil
            self.scheduleRelayConnect(delaySeconds: 0.25)
        }
    }

    private func connectRelaysIfNeeded() {
        guard !relayBusy else { return }
        relayConnectTask?.cancel()
        relayConnectTask = nil
        relayBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.relayBusy = false }
            do {
                self.relayConnected = false
                #if DEBUG
                // SONAR_BENCH: relay attach begins (T2). connect() returns once
                // relays are quorum-connected (not after sync).
                SecureLogger.info("SONAR_BENCH t2_relay_connect_begin", category: .session)
                #endif
                _ = try await self.service.connect(nsec: nil)
                #if DEBUG
                // SONAR_BENCH: relays quorum-connected (T3). Marmot events now
                // flow into the background buffer and are applied by the drain loop.
                SecureLogger.info("SONAR_BENCH t3_relay_connected", category: .session)
                #endif
                self.errorText = nil
                self.relayConnected = true
                try? await self.service.publishKeyPackage()
                // Republish our kind-0 profile here too (not just on the npub
                // signal / rename): the KeyPackage lands reliably on every relay
                // connect, but the profile previously did not, so peers saw our
                // raw npub when the opportunistic publish lost the relay /
                // onboarding race. Keep them in lockstep.
                if let name = self.profileNameProvider?()
                    .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    try? await self.service.publishProfile(name: name)
                }
                #if DEBUG
                // SONAR_BENCH: KeyPackage + profile published (T3a). Splits the
                // publish cost out of the post-connect window.
                SecureLogger.info("SONAR_BENCH t3a_published", category: .session)
                #endif
                self.startPolling()
            } catch MarmotService.ServiceError.cancelled {
                self.relayConnected = false
                return
            } catch {
                self.relayConnected = false
                let desc = Self.describe(error)
                SecureLogger.warning("⚠️ Marmot relay connect failed: \(desc)", category: .session)
                self.errorText = desc
            }
        }
    }

    func ensureRelayConnected(timeoutSeconds: Double = 10) async -> Bool {
        if service.isRelayConnected() { return true }
        connectRelaysIfNeeded()
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if service.isRelayConnected() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return service.isRelayConnected()
    }

    /// Re-establish relay subscriptions and catch up on missed events after the
    /// app returns to foreground. iOS tears down TCP connections in background;
    /// nostr-sdk may auto-reconnect the sockets, but the Marmot subscription
    /// filters can be stale. This forces a resubscribe + a one-shot sync to
    /// bridge the gap.
    func refreshAfterForeground() {
        guard service.isRelayConnected() else { return }
        Task {
            try? await service.ensureSubscriptions()
            try? await service.syncForce()
            let notifications = (try? await service.drainPending()) ?? []
            if !notifications.isEmpty { await loadLocalSummaries() }
        }
    }

    /// Best-effort local hydration for screen open paths. This never waits for
    /// relay connect/sync; if the encrypted DB is not open yet, connectIfNeeded()
    /// continues opening it in the background.
    func loadLocalIfConnected(groupId: String? = nil) async {
        guard service.isConnected() else {
            connectIfNeeded()
            return
        }
        await loadLocalWindow(groupId: groupId)
    }

    /// Wait only for the local Marmot node/DB to open, then hydrate local state.
    /// This deliberately performs no relay sync.
    @discardableResult
    func loadLocalWhenConnected(groupId: String? = nil, timeoutSeconds: Double = 10) async -> Bool {
        guard await ensureConnected(timeoutSeconds: timeoutSeconds) else { return false }
        await loadLocalWindow(groupId: groupId)
        return true
    }

    /// Background reconciliation for open chats. Kept separate from local
    /// hydration so relay sync cannot gate first paint.
    func refreshWhenConnected(groupId: String? = nil, hydrateBeforeSync: Bool = true) async {
        guard await ensureConnected() else { return }
        if hydrateBeforeSync {
            await loadLocalWindow(groupId: groupId)
        }
        if await ensureRelayConnected() {
            do {
                try await service.syncOnce()
                self.errorText = nil
            } catch {
                self.errorText = Self.describe(error)
            }
            let notifications = (try? await service.drainPending()) ?? []
            if !notifications.isEmpty { await loadLocalWindow(groupId: groupId) ; return }
        }
        await loadLocalWindow(groupId: groupId)
    }

    private func loadLocalWindow(groupId: String?) async {
        if let groupId {
            await loadLocalPage(groupId: groupId)
        } else {
            await loadLocalSummaries()
        }
    }

    /// Load groups + messages from the LOCAL encrypted DB only (no relay I/O),
    /// so the chat list paints instantly on launch regardless of relay health.
    func loadLocal() async {
        await loadLocalSummaries()
    }

    /// Startup local read: load only row metadata, not even one message per
    /// group. The selected chat's `messagesPage` must stay ahead of background
    /// summaries/sync on the serialized engine queue.
    private func loadLocalGroupMetadata() async {
        do {
            let groups = try await service.groups()
            let invites = try await service.pendingGroupInvites()
            self.groups = groups
            self.pendingGroupInvites = invites
            SNMarmotChatSnapshotCache.save(
                groups: groups,
                messagesByGroup: messagesByGroup,
                to: defaults
            )
        } catch {
            self.errorText = Self.describe(error)
        }
    }

    /// Load the latest local transcript window for one group. Used by chat open
    /// so existing conversations paint from the encrypted DB without scanning
    /// all groups or all messages.
    func loadLocalPage(groupId: String) async {
        do {
            let groups = try await service.groups()
            let invites = try await service.pendingGroupInvites()
            let page = try await service.messagesPage(
                groupId: groupId,
                limit: Self.localTranscriptPageLimit
            )
            var byGroup = messagesByGroup
            byGroup[groupId] = page
            self.groups = groups
            self.pendingGroupInvites = invites
            self.messagesByGroup = reconcileOptimistic(into: byGroup)
            SNMarmotChatSnapshotCache.save(
                groups: groups,
                messagesByGroup: self.messagesByGroup,
                to: defaults
            )
            if let group = groups.first(where: { $0.id == groupId }) {
                let relayReady = service.isRelayConnected()
                for member in group.memberNpubs where member != npub {
                    ensureProfile(member)
                    if relayReady {
                        ensureSonarDescriptor(member)
                    }
                }
            }
        } catch {
            self.errorText = Self.describe(error)
        }
    }

    /// Load row metadata plus the newest local message per group. This keeps the
    /// chat list fresh without scanning full transcripts on cold start, polling,
    /// or idle reconciliation. Already-loaded active transcripts are preserved
    /// and merged with the newest row.
    func loadLocalSummaries(resolveMembers: Bool = true) async {
        do {
            let groups = try await service.groups()
            let invites = try await service.pendingGroupInvites()
            var byGroup = messagesByGroup
            let pages = try await service.recentMessagePages(
                groupLimit: Self.localSummaryGroupLimit,
                pageLimit: Self.localSummaryPageLimit
            )
            for page in pages {
                byGroup[page.groupId] = Self.mergeMessages(
                    existing: messagesByGroup[page.groupId] ?? [],
                    incoming: page.messages
                )
            }
            let summaries = await service.conversationSummaries()
            var unread: [String: UInt64] = [:]
            for s in summaries where s.unreadCount > 0 {
                unread[s.groupIdHex] = s.unreadCount
            }
            self.unreadByGroup = unread
            self.groups = groups
            self.pendingGroupInvites = invites
            self.messagesByGroup = reconcileOptimistic(into: byGroup)
            SNMarmotChatSnapshotCache.save(
                groups: groups,
                messagesByGroup: self.messagesByGroup,
                to: defaults
            )
            if resolveMembers {
                let relayReady = service.isRelayConnected()
                for group in groups {
                    for member in group.memberNpubs where member != npub {
                        ensureProfile(member)
                        if relayReady {
                            ensureSonarDescriptor(member)
                        }
                    }
                }
            }
        } catch {
            self.errorText = Self.describe(error)
        }
    }

    private static func mergeMessages(
        existing: [MarmotService.MarmotMessage],
        incoming: [MarmotService.MarmotMessage]
    ) -> [MarmotService.MarmotMessage] {
        var byID: [String: MarmotService.MarmotMessage] = [:]
        for message in existing { byID[message.id] = message }
        for message in incoming { byID[message.id] = message }
        return byID.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Poll the relays once, then reflect the (possibly updated) local state.
    /// Local chats are loaded even when the relay sync fails, so a relay outage
    /// never hides already-persisted conversations. Returns notifications for
    /// incoming messages (empty if nothing new or relay offline).
    @discardableResult
    func refresh() async -> [DrainNotificationInfo] {
        if service.isRelayConnected() {
            do {
                try await service.syncOnce()
                self.errorText = nil
            } catch {
                self.errorText = Self.describe(error)
            }
            let notifications = (try? await service.drainPending()) ?? []
            if !notifications.isEmpty { await loadLocalSummaries() ; return notifications }
        } else {
            connectRelaysIfNeeded()
        }
        await loadLocalSummaries()
        return []
    }

    func markConversationRead(groupId: String) {
        unreadByGroup[groupId] = nil
        Task { await service.markConversationRead(groupId: groupId) }
    }

    /// Publish our own kind-0 profile so peers see our nickname, not our npub.
    func publishProfile(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { try? await service.publishProfile(name: trimmed) }
    }

    /// Publish the app-level Sonar descriptor. This is separate from kind-0
    /// profile metadata so protocol capability discovery can evolve safely.
    func publishSonarDescriptor(callsEnabled: Bool = true) {
        let bolt12Offer = descriptorBolt12Offer
        Task { try? await service.publishSonarDescriptor(callsEnabled: callsEnabled, bolt12Offer: bolt12Offer) }
    }

    /// Publish the descriptor with explicit payment metadata. The desired offer
    /// is retained immediately so concurrent capability refreshes do not drop
    /// it, while callers can still await the relay publish result.
    func publishSonarDescriptor(callsEnabled: Bool = true, bolt12Offer: String?) async throws {
        descriptorBolt12Offer = bolt12Offer
        try await service.publishSonarDescriptor(callsEnabled: callsEnabled, bolt12Offer: bolt12Offer)
    }

    /// Fetch + cache a peer's kind-0 profile, so their name/avatar replaces the
    /// raw npub in the chat list, header, and avatar. Retries (via the periodic
    /// `refresh()`) until the peer has published a profile.
    func ensureProfile(_ npubToFetch: String) {
        let key = SNMarmotProfileCache.canonicalKey(npubToFetch)
        let ownKey = npub.map(SNMarmotProfileCache.canonicalKey)
        guard !key.isEmpty, key != ownKey else { return }
        let hadCachedProfile = profilesByNpub[key] != nil || profilesByNpub[npubToFetch] != nil
        guard profileFetches.insert(key).inserted else { return } // in flight
        Task {
            let profile = try? await service.fetchProfile(npub: key)
            await MainActor.run {
                if let profile, profile.bestName != nil {
                    self.profilesByNpub[key] = profile
                    if key != npubToFetch {
                        self.profilesByNpub.removeValue(forKey: npubToFetch)
                    }
                    SNMarmotProfileCache.save(self.profilesByNpub, to: self.defaults)
                } else {
                    if !hadCachedProfile {
                        self.profileFetches.remove(key) // not published yet — allow retry
                    }
                }
            }
        }
    }

    /// Fetch + cache a peer's public Sonar descriptor. Not finding one keeps the
    /// npub usable for White Noise/Marmot chat, but it does not unlock calls.
    /// Positive results are periodically refreshed so protocol upgrades or
    /// capability changes are noticed during long-running sessions.
    func ensureSonarDescriptor(_ npubToFetch: String) {
        guard !npubToFetch.isEmpty, npubToFetch != npub else { return }
        if sonarDescriptorsByNpub[npubToFetch] != nil,
           let fetchedAt = sonarDescriptorFetchedAtByNpub[npubToFetch],
           Date().timeIntervalSince(fetchedAt) < Self.sonarDescriptorRefreshInterval {
            return
        }
        if let miss = sonarDescriptorMissesByNpub[npubToFetch],
           Date().timeIntervalSince(miss) < Self.sonarDescriptorMissRetryInterval {
            return
        }
        guard descriptorFetches.insert(npubToFetch).inserted else { return }
        Task {
            await performDescriptorFetch(npubToFetch)
        }
    }

    /// Synchronous variant: awaits the relay fetch and returns the descriptor.
    /// Use when the descriptor is missing and the caller needs it before
    /// proceeding (e.g. opening a pay sheet). When the descriptor is already
    /// cached and just stale, prefer the fire-and-forget `ensureSonarDescriptor`.
    func fetchSonarDescriptorSync(
        _ npubToFetch: String,
        bypassRecentMiss: Bool = true
    ) async -> MarmotService.SonarDescriptor? {
        guard !npubToFetch.isEmpty, npubToFetch != npub else { return nil }
        let cached = sonarDescriptorsByNpub[npubToFetch]
        let hasBolt12 = cached?.bolt12Offer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if hasBolt12,
           let fetchedAt = sonarDescriptorFetchedAtByNpub[npubToFetch],
           Date().timeIntervalSince(fetchedAt) < Self.sonarDescriptorRefreshInterval {
            return cached
        }
        if !bypassRecentMiss,
           let miss = sonarDescriptorMissesByNpub[npubToFetch],
           Date().timeIntervalSince(miss) < Self.sonarDescriptorMissRetryInterval {
            return sonarDescriptorsByNpub[npubToFetch]
        }
        descriptorFetches.insert(npubToFetch)
        await performDescriptorFetch(npubToFetch)
        return sonarDescriptorsByNpub[npubToFetch]
    }

    private func performDescriptorFetch(_ npubToFetch: String) async {
        do {
            let descriptor = try await service.fetchSonarDescriptor(npub: npubToFetch)
            await MainActor.run {
                self.descriptorFetches.remove(npubToFetch)
                self.sonarDescriptorFetchedAtByNpub[npubToFetch] = Date()
                if let descriptor {
                    self.sonarDescriptorsByNpub[npubToFetch] = descriptor
                    self.sonarDescriptorMissesByNpub[npubToFetch] = nil
                } else {
                    self.sonarDescriptorsByNpub.removeValue(forKey: npubToFetch)
                    self.sonarDescriptorMissesByNpub[npubToFetch] = Date()
                }
            }
        } catch {
            await MainActor.run {
                _ = self.descriptorFetches.remove(npubToFetch)
            }
        }
    }

    /// Proactively refresh Sonar descriptors for a set of known npubs (e.g. all
    /// persisted fingerprint↔npub links). Only the relay-ready startup pass clears
    /// miss timestamps; foreground refreshes preserve the miss retry cooldown.
    func refreshDescriptors(forKnownNpubs npubs: [String], clearMisses: Bool = false) {
        for npub in npubs {
            if clearMisses {
                sonarDescriptorMissesByNpub[npub] = nil
            }
            ensureSonarDescriptor(npub)
        }
    }

    /// Best display name for a member npub, if we've resolved their profile.
    func displayName(forNpub member: String) -> String? {
        profilesByNpub[SNMarmotProfileCache.canonicalKey(member)]?.bestName
            ?? profilesByNpub[member]?.bestName
    }

    /// Resolve sender name for push notifications: cached profile → fetch → short npub.
    func resolveSenderName(npub: String) async -> String {
        if let cached = displayName(forNpub: npub) { return cached }
        if let profile = try? await service.fetchProfile(npub: npub),
           let name = profile.bestName { return name }
        return String(npub.prefix(12)) + "…"
    }

    /// Resolved author label for a Marmot group message: cached profile name,
    /// or short npub with an async fetch kicked off so it resolves on the next
    /// SwiftUI invalidation cycle.
    func marmotAuthorName(_ m: MarmotService.MarmotMessage) -> String? {
        snResolvedMarmotAuthorName(
            m,
            profilesByNpub: profilesByNpub,
            fetchMissingProfile: ensureProfile,
            shortNpub: snShortNpubLabel
        )
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
            var unmatchedServer = server
            var survivors: [MarmotService.MarmotMessage] = []
            for optimistic in pending {
                if let match = unmatchedServer.firstIndex(where: {
                    Self.serverMessage($0, matchesOptimistic: optimistic)
                }) {
                    unmatchedServer.remove(at: match)
                } else {
                    survivors.append(optimistic)
                }
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

    private static func serverMessage(
        _ server: MarmotService.MarmotMessage,
        matchesOptimistic optimistic: MarmotService.MarmotMessage
    ) -> Bool {
        guard !optimistic.id.hasPrefix(failedOptimisticIDPrefix) else { return false }
        guard server.isMine, server.content == optimistic.content else { return false }
        guard !optimistic.media.isEmpty else { return server.media.isEmpty }
        return optimistic.media.allSatisfy { pending in
            server.media.contains {
                $0.filename == pending.filename && $0.mimeType == pending.mimeType
            }
        }
    }

    func startChat(with peer: String) {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ensureSonarDescriptor(trimmed)
        Task {
            _ = await startChatReturningId(with: trimmed)
        }
    }

    func startChatReturningId(with peer: String) async -> String? {
        let trimmed = peer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard await ensureRelayConnected() else {
            self.errorText = "Not connected yet — try again in a moment."
            return nil
        }
        do {
            let groupId = try await service.startDirectMessage(with: trimmed, name: "")
            await loadLocalPage(groupId: groupId)
            Task { [weak self] in
                await self?.refreshWhenConnected(groupId: groupId, hydrateBeforeSync: false)
            }
            return groupId
        } catch {
            self.errorText = Self.describe(error)
            return nil
        }
    }

    func send(_ text: String, to groupId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let echo = MarmotService.MarmotMessage(
            id: Self.optimisticIDPrefix + UUID().uuidString,
            senderNpub: npub ?? "",
            content: trimmed,
            createdAt: Date(),
            isMine: true,
            media: []
        )
        pendingOptimistic[groupId, default: []].append(echo)
        messagesByGroup[groupId, default: []].append(echo)
        let prev = sendChain
        sendChain = Task { [weak self] in
            _ = await prev?.result
            guard let self else { return }
            do {
                guard await self.ensureConnected(timeoutSeconds: 2) else {
                    throw MarmotService.ServiceError.notConnected
                }
                try await self.service.sendText(groupId: groupId, text: trimmed)
            } catch {
                self.pendingOptimistic[groupId]?.removeAll { $0.id == echo.id }
                self.messagesByGroup[groupId, default: []].removeAll { $0.id == echo.id }
                self.errorText = Self.describe(error)
                return
            }
            // UI refresh + subscriptions run outside the send chain so the
            // next queued message doesn't wait for them.
            Task { [weak self] in
                await self?.loadLocalPage(groupId: groupId)
                try? await self?.service.ensureSubscriptions()
            }
        }
    }

    func send(_ texts: [String], to groupId: String) async -> Bool {
        let trimmed = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return true }
        for text in trimmed {
            send(text, to: groupId)
        }
        // Wait for the chain to finish so the caller knows success/failure.
        if let chain = sendChain {
            _ = await chain.result
        }
        return errorText == nil
    }

    /// Send a media attachment (encrypt with the group key, upload the ciphertext
    /// to Blossom, publish the kind-445 with the imeta tag). Refreshes on success.
    func sendMedia(
        groupId: String,
        data: Data,
        filename: String,
        mime: String,
        caption: String = "",
        localPreviewURL: String? = nil,
        onComplete: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        let echo = MarmotService.MarmotMessage(
            id: Self.optimisticIDPrefix + UUID().uuidString,
            senderNpub: npub ?? "",
            content: caption,
            createdAt: Date(),
            isMine: true,
            media: [
                MarmotService.MarmotMedia(
                    url: localPreviewURL ?? "pending-media-\(UUID().uuidString)",
                    mimeType: mime,
                    filename: filename,
                    width: nil,
                    height: nil,
                    durationMs: nil
                )
            ]
        )
        Task {
            var echoVisible = false
            do {
                guard await ensureConnected() else {
                    throw MarmotService.ServiceError.notConnected
                }
                await loadLocalPage(groupId: groupId)
                pendingOptimistic[groupId, default: []].append(echo)
                messagesByGroup[groupId, default: []].append(echo)
                echoVisible = true
                guard await ensureRelayConnected() else {
                    throw MarmotService.ServiceError.notConnected
                }
                try await service.sendMedia(
                    groupId: groupId, data: data, filename: filename, mime: mime, caption: caption
                )
                onComplete?()
                await refreshWhenConnected(groupId: groupId, hydrateBeforeSync: false)
            } catch {
                pendingOptimistic[groupId]?.removeAll { $0.id == echo.id }
                if echoVisible {
                    let failed = MarmotService.MarmotMessage(
                        id: Self.failedOptimisticIDPrefix + UUID().uuidString,
                        senderNpub: echo.senderNpub,
                        content: echo.content,
                        createdAt: echo.createdAt,
                        isMine: true,
                        media: echo.media
                    )
                    pendingOptimistic[groupId, default: []].append(failed)
                    messagesByGroup[groupId, default: []].removeAll { $0.id == echo.id }
                    messagesByGroup[groupId, default: []].append(failed)
                }
                onFailure?()
                self.errorText = Self.describe(error)
            }
        }
    }

    func sendSticker(
        groupId: String,
        packCoordinate: String,
        shortcode: String,
        plaintextSha256: String
    ) {
        Task {
            do {
                guard await ensureConnected() else {
                    throw MarmotService.ServiceError.notConnected
                }
                await loadLocalPage(groupId: groupId)
                try await service.sendSticker(
                    groupId: groupId,
                    packCoordinate: packCoordinate,
                    shortcode: shortcode,
                    plaintextSha256: plaintextSha256
                )
                await loadLocalPage(groupId: groupId)
                await refreshWhenConnected(groupId: groupId, hydrateBeforeSync: false)
            } catch {
                self.errorText = Self.describe(error)
            }
        }
    }

    func fetchStickerPack(
        authorPubkeyHex: String,
        identifier: String,
        relayUrls: [String]
    ) async -> StickerPackInfo? {
        let cacheKey = "30030:\(authorPubkeyHex.lowercased()):\(identifier)"
        if let cached = stickerPacksByCoordinate.removeValue(forKey: cacheKey) {
            stickerPacksByCoordinate[cacheKey] = cached
            return cached
        }
        do {
            guard await ensureRelayConnected() else {
                throw MarmotService.ServiceError.notConnected
            }
            let pack = try await service.fetchStickerPack(
                authorPubkeyHex: authorPubkeyHex,
                identifier: identifier,
                relayUrls: relayUrls
            )
            if stickerPacksByCoordinate.count >= 20, let oldest = stickerPacksByCoordinate.keys.first {
                stickerPacksByCoordinate.removeValue(forKey: oldest)
            }
            stickerPacksByCoordinate[cacheKey] = pack
            return pack
        } catch {
            self.errorText = Self.describe(error)
            return nil
        }
    }

    func fetchStickerImage(url: String, expectedSha256: String) async -> Data? {
        let cacheKey = "\(expectedSha256.lowercased())|\(url)"
        if let cached = stickerImagesByURL.removeValue(forKey: cacheKey) {
            stickerImagesByURL[cacheKey] = cached
            return cached
        }
        do {
            let data = try await service.fetchStickerImage(url: url, expectedSha256: expectedSha256)
            if stickerImagesByURL.count >= 500, let oldest = stickerImagesByURL.keys.first {
                stickerImagesByURL.removeValue(forKey: oldest)
            }
            stickerImagesByURL[cacheKey] = data
            return data
        } catch {
            self.errorText = Self.describe(error)
            return nil
        }
    }

    func stickerData(for ref: MarmotService.MarmotStickerRef) async -> Data? {
        guard let parts = Self.stickerPackParts(ref.packCoordinate),
              let pack = await fetchStickerPack(
                  authorPubkeyHex: parts.author,
                  identifier: parts.identifier,
                  relayUrls: []
              ),
              let sticker = pack.stickers.first(where: {
                  $0.shortcode == ref.shortcode &&
                      $0.sha256.caseInsensitiveCompare(ref.plaintextSha256) == .orderedSame
              })
        else { return nil }
        return await fetchStickerImage(url: sticker.url, expectedSha256: ref.plaintextSha256)
    }

    func fetchInstalledPacks() async -> [String] {
        if !installedPackCoordinates.isEmpty {
            return Array(installedPackCoordinates)
        }
        do {
            let coords = try await service.fetchInstalledPacks()
            installedPackCoordinates = Set(coords.map { $0.lowercased() })
            return coords
        } catch {
            self.errorText = Self.describe(error)
            return []
        }
    }

    func refreshInstalledPacks() async {
        do {
            let coords = try await service.fetchInstalledPacks()
            installedPackCoordinates = Set(coords.map { $0.lowercased() })
        } catch {
            self.errorText = Self.describe(error)
        }
    }

    func installStickerPack(coordinate: String) async -> Bool {
        do {
            try await service.installStickerPack(coordinate: coordinate)
            installedPackCoordinates.insert(coordinate.lowercased())
            return true
        } catch {
            self.errorText = Self.describe(error)
            return false
        }
    }

    func uninstallStickerPack(coordinate: String) async -> Bool {
        do {
            try await service.uninstallStickerPack(coordinate: coordinate)
            installedPackCoordinates.remove(coordinate.lowercased())
            return true
        } catch {
            self.errorText = Self.describe(error)
            return false
        }
    }

    /// Download + decrypt a media blob. The store caches the decoded image.
    func fetchMedia(groupId: String, url: String) async -> Data? {
        do {
            return try await service.fetchMedia(groupId: groupId, url: url)
        } catch {
            let description = Self.describe(error)
            SecureLogger.warning("SonarMedia: Marmot fetchMedia failed group=\(groupId.prefix(12)) urlHash=\(Self.mediaLogId(for: url)) error=\(description)", category: .session)
            self.errorText = description
            return nil
        }
    }

    private static func mediaLogId(for url: String) -> String {
        SHA256.hash(data: Data(url.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func stickerPackParts(_ coordinate: String) -> (author: String, identifier: String)? {
        let parts = coordinate.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "30030" else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    /// Drive LIVE updates off the core's watermarked relay subscriptions: park
    /// on `waitForMarmotEvent` and, the instant a welcome/message is pushed,
    /// drain + process it and reload the UI from the local DB. On the idle
    /// timeout (no push), re-subscribe with the current watermark to self-heal
    /// after relay disconnects — much lighter than the old `refresh()`/`sync()`
    /// poll that did a full blocking fetch.
    func startPolling() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let woke = await self.service.waitForMarmotEvent(timeoutSeconds: 25)
                if Task.isCancelled { return }
                #if DEBUG
                // SONAR_BENCH: first waitForMarmotEvent returned (T3b). t3a→t3b is
                // the wait; t3b→t4 is the drainPending() MLS processing cost.
                if !self.benchFirstWakeLogged {
                    self.benchFirstWakeLogged = true
                    SecureLogger.info("SONAR_BENCH t3b_first_wake woke=\(woke ? 1 : 0)", category: .session)
                }
                #endif
                if woke {
                    let notifications = (try? await self.service.drainPending()) ?? []
                    #if DEBUG
                    // SONAR_BENCH: first post-connect event burst applied to local
                    // storage (T4) — the cold-start relay sync has produced data.
                    if !self.benchFirstDrainLogged {
                        self.benchFirstDrainLogged = true
                        SecureLogger.info("SONAR_BENCH t4_first_drain woke=1 notif=\(notifications.count)", category: .session)
                    }
                    #endif
                    if !notifications.isEmpty {
                        await self.loadLocalSummaries()
                    }
                } else {
                    #if DEBUG
                    // SONAR_BENCH: first wait cycle resolved with no buffered events
                    // (initial subscription EOSE was empty — nothing new to sync).
                    if !self.benchFirstDrainLogged {
                        self.benchFirstDrainLogged = true
                        SecureLogger.info("SONAR_BENCH t4_first_drain woke=0 notif=0", category: .session)
                    }
                    #endif
                    try? await self.service.ensureSubscriptions()
                }
            }
        }
    }

    func stopPolling() {
        startupLocalSummaryTask?.cancel()
        startupLocalSummaryTask = nil
        relayConnectTask?.cancel()
        relayConnectTask = nil
        syncTask?.cancel()
        syncTask = nil
    }

    // MARK: - P2P calls (pass-throughs to the call engine in MarmotService)

    func callStart() async throws {
        guard await ensureRelayConnected() else { throw MarmotService.ServiceError.notConnected }
        try await service.callStart()
    }
    func callLocalAddress() async throws -> String { try await service.callLocalAddress() }
    func callPlace(callId: String, video: Bool) async throws { try await service.callPlace(callId: callId, video: video) }
    func callIncomingOffer(callId: String, addrB64: String, video: Bool) async throws {
        try await service.callIncomingOffer(callId: callId, addrB64: addrB64, video: video)
    }
    func callAnswer(callId: String, answer: CallAnswerKind, addrB64: String) async throws {
        try await service.callAnswer(callId: callId, answer: answer, addrB64: addrB64)
    }
    func callAccept(callId: String) async throws { try await service.callAccept(callId: callId) }
    func callHangup(callId: String) async throws { try await service.callHangup(callId: callId) }
    func callSetMuted(callId: String, muted: Bool) async throws {
        try await service.callSetMuted(callId: callId, muted: muted)
    }
    func callWaitEvent(timeoutSeconds: UInt64) async -> CallEventInfo? {
        await service.callWaitEvent(timeoutSeconds: timeoutSeconds)
    }

    /// Delete ONE White Noise / Marmot chat locally (messages + MLS keys), then
    /// drop it from the in-memory state. Local-only — the peer is not notified.
    func deleteGroup(_ groupId: String) async {
        try? await service.deleteGroup(groupId: groupId)
        groups.removeAll { $0.id == groupId }
        messagesByGroup[groupId] = nil
        pendingOptimistic[groupId] = nil
        profileFetches = []
        installedPackCoordinates = []
        SNMarmotChatSnapshotCache.save(groups: groups, messagesByGroup: messagesByGroup, to: defaults)
    }

    /// Leave a multi-member Marmot group, then drop it from the in-memory state.
    func leaveGroup(_ groupId: String) async {
        do {
            try await service.leaveGroup(groupId)
        } catch {
            errorText = Self.describe(error)
            return
        }
        groups.removeAll { $0.id == groupId }
        messagesByGroup[groupId] = nil
        pendingOptimistic[groupId] = nil
        profileFetches = []
        installedPackCoordinates = []
        SNMarmotChatSnapshotCache.save(groups: groups, messagesByGroup: messagesByGroup, to: defaults)
    }

    /// Panic-wipe the encrypted Marmot database + its Keychain key and reset
    /// in-memory state. Called from the emergency-wipe path.
    func wipeDatabase() {
        stopPolling()
        let service = self.service
        Task { await service.wipeDatabase() }
        relayConnected = false
        npub = nil
        groups = []
        pendingGroupInvites = []
        messagesByGroup = [:]
        pendingOptimistic = [:]
        descriptorBolt12Offer = nil
        profilesByNpub = [:]
        profileFetches = []
        installedPackCoordinates = []
        SNMarmotProfileCache.clear(from: defaults)
        SNMarmotChatSnapshotCache.clear(from: defaults)
    }

    /// Erase every White Noise / Marmot chat but KEEP the identity: wipe the
    /// encrypted DB (which preserves `marmot-nsec`, deleting only the DB and
    /// its SQLCipher key), then reconnect with the same nsec so a fresh, empty
    /// store is opened and our KeyPackage is republished — new secure chats
    /// keep working. Used by "erase all chats" (not the full panic wipe).
    func eraseChatsKeepIdentity() async {
        let wasPolling = syncTask != nil
        stopPolling()
        relayConnected = false
        await service.wipeDatabase()
        npub = nil
        groups = []
        pendingGroupInvites = []
        messagesByGroup = [:]
        pendingOptimistic = [:]
        profilesByNpub = [:]
        profileFetches = []
        installedPackCoordinates = []
        SNMarmotProfileCache.clear(from: defaults)
        SNMarmotChatSnapshotCache.clear(from: defaults)
        errorText = nil
        // Reopen a fresh DB with the SAME identity and republish our KeyPackage.
        // Await a FORCED reconnect (not `connectIfNeeded()`, whose busy/npub
        // guard could silently skip it and leave the node "not connected yet").
        busy = true
        let connected = await performConnect()
        busy = false
        if wasPolling && connected { startPolling() }
    }

    /// Short label for a 1:1 group: the other member's npub prefix.
    func title(for group: MarmotService.MarmotGroup) -> String {
        if !group.name.isEmpty { return group.name }
        let others = otherMembers(in: group)
        guard others.count == 1, let other = others.first else { return "Group chat" }
        // Prefer the counterpart's resolved kind-0 profile name; fetch it if we
        // haven't yet; fall back to a short npub until it lands.
        if let name = displayName(forNpub: other) { return name }
        ensureProfile(other)
        return String(other.prefix(12)) + "…"
    }

    func otherMembers(in group: MarmotService.MarmotGroup) -> [String] {
        let ownKey = npub.map(SNMarmotProfileCache.canonicalKey)
        return Array(Set(group.memberNpubs.map(SNMarmotProfileCache.canonicalKey).filter {
            guard !$0.isEmpty else { return false }
            guard let ownKey else { return true }
            return $0 != ownKey
        })).sorted()
    }

    func isDirectGroup(_ group: MarmotService.MarmotGroup) -> Bool {
        otherMembers(in: group).count == 1
    }

    func startGroup(name: String, members: [String]) async throws -> String {
        let cleanMembers = Array(Set(members.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        guard cleanMembers.count >= 2 else {
            throw MarmotService.ServiceError.invalidInput("add at least two people")
        }
        let id = try await service.startGroup(with: cleanMembers, name: name)
        await loadLocal()
        return id
    }

    func addGroupMembers(_ members: [String], to groupId: String) async throws {
        try await service.addGroupMembers(members, to: groupId)
        await loadLocal()
    }

    func removeGroupMembers(_ members: [String], from groupId: String) async throws {
        try await service.removeGroupMembers(members, from: groupId)
        await loadLocal()
    }

    func createInviteLink(groupId: String, groupName: String) async throws -> String {
        try await service.createInviteLink(groupId: groupId, groupName: groupName)
    }

    func pendingJoinRequests(groupId: String) async throws -> [JoinRequestInfo] {
        try await service.pendingJoinRequests(groupId: groupId)
    }

    func approveJoinRequest(groupId: String, requesterNpub: String) async throws {
        try await service.approveJoinRequest(groupId: groupId, requesterNpub: requesterNpub)
        await loadLocal()
    }

    func declineJoinRequest(groupId: String, requesterNpub: String) async throws {
        try await service.declineJoinRequest(groupId: groupId, requesterNpub: requesterNpub)
    }

    func requestJoinViaLink(token: String) async throws {
        try await service.requestJoinViaLink(token: token)
    }

    func acceptGroupInvite(_ invite: MarmotService.GroupInvite) async throws -> String {
        let id = try await service.acceptGroupInvite(invite.id)
        await loadLocal()
        return id
    }

    func declineGroupInvite(_ invite: MarmotService.GroupInvite) async throws {
        try await service.declineGroupInvite(invite.id)
        await loadLocal()
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case MarmotService.ServiceError.notConnected:
            return "Not connected yet — try again in a moment."
        case MarmotService.ServiceError.cancelled:
            return "Operation cancelled."
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
    @State private var isNearBottom = true

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
                        Color.clear
                            .frame(height: 1)
                            .id("bottom-anchor")
                            .onAppear { isNearBottom = true }
                            .onDisappear { isNearBottom = false }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .onChange(of: messages.count) { _ in
                    guard isNearBottom, let last = messages.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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
