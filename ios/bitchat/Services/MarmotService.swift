//
// MarmotService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import SonarCore

/// Swift-side facade over the Rust `sonar-core` engine (Marmot protocol:
/// MLS-over-Nostr, White Noise interop) exposed through the SonarCore package.
///
/// Design:
/// - No singleton: construct one per identity/session and inject it (relay
///   list is constructor-injected with sensible defaults).
/// - The underlying `SonarNode` methods are BLOCKING (they drive a tokio
///   runtime inside the Rust core), so every call here hops onto a private
///   serial `DispatchQueue` and is exposed as `async` Swift. Never call the
///   SonarCore types directly from the main thread.
/// - This service owns no UI state. ViewModels observe/own their own state
///   and call into this service.
final class MarmotService: @unchecked Sendable {

    // MARK: - Public model types (UI layers must not import SonarCore)

    struct MarmotGroup: Sendable, Equatable, Codable {
        /// Hex MLS group id; pass it back to `sendText`/`messages`.
        let id: String
        let name: String
        let memberNpubs: [String]
    }

    struct GroupInvite: Sendable, Equatable {
        /// Hex kind-444 welcome event id; pass it to accept/decline.
        let id: String
        let groupId: String
        let groupName: String
        let groupDescription: String
        let welcomerNpub: String
        let memberCount: UInt32
        let relays: [String]
    }

    struct MarmotMessage: Sendable, Equatable, Codable {
        let id: String
        let senderNpub: String
        let content: String
        let createdAt: Date
        /// True when the local identity sent it.
        let isMine: Bool
        /// Core-owned local delivery state: received, pending, sent, or failed.
        let deliveryState: String?
        /// Encrypted media attachments (Marmot MIP-04), empty for plain text.
        let media: [MarmotMedia]

        init(
            id: String,
            senderNpub: String,
            content: String,
            createdAt: Date,
            isMine: Bool,
            deliveryState: String? = nil,
            media: [MarmotMedia]
        ) {
            self.id = id
            self.senderNpub = senderNpub
            self.content = content
            self.createdAt = createdAt
            self.isMine = isMine
            self.deliveryState = deliveryState
            self.media = media
        }

        enum CodingKeys: String, CodingKey {
            case id
            case senderNpub
            case content
            case createdAt
            case isMine
            case deliveryState
            case media
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.senderNpub = try container.decode(String.self, forKey: .senderNpub)
            self.content = try container.decode(String.self, forKey: .content)
            self.createdAt = try container.decode(Date.self, forKey: .createdAt)
            self.isMine = try container.decode(Bool.self, forKey: .isMine)
            self.deliveryState = try container.decodeIfPresent(String.self, forKey: .deliveryState)
            self.media = try container.decode([MarmotMedia].self, forKey: .media)
        }
    }

    struct RecentMessagePage: Sendable, Equatable {
        let groupId: String
        let latestCreatedAt: Date
        let messages: [MarmotMessage]
    }

    /// A reference to an encrypted media attachment. `url` is the Blossom URL of
    /// the CIPHERTEXT; call `fetchMedia(groupId:url:)` to download + decrypt.
    struct MarmotMedia: Sendable, Equatable, Codable {
        let url: String
        let mimeType: String
        let filename: String
        let width: UInt32?
        let height: UInt32?
        let durationMs: UInt64?
        var isImage: Bool { mimeType.hasPrefix("image/") }
        var isVideo: Bool { mimeType.hasPrefix("video/") }
        var isAudio: Bool { mimeType.hasPrefix("audio/") }
    }

    /// A peer's Nostr profile (kind-0 metadata, NIP-01). A Marmot member's
    /// identity is a Nostr pubkey, so this resolves a human name + avatar
    /// instead of a raw npub.
    struct Profile: Sendable, Equatable, Codable {
        let name: String?
        let displayName: String?
        let about: String?
        let picture: String?
        let nip05: String?
        /// Best human label: display name, else name, else nil.
        var bestName: String? {
            if let d = displayName, !d.trimmingCharacters(in: .whitespaces).isEmpty { return d }
            if let n = name, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
            return nil
        }
    }

    /// Public Sonar capability descriptor discovered from a peer's npub.
    /// Contains stable protocol metadata only, never live call addresses.
    struct SonarDescriptor: Sendable, Equatable {
        let schema: UInt32
        let calls: Bool
        let media: [String]
        let signaling: [String]
        let transports: [String]
        let callIdentity: String
        let bolt12Offer: String?
        let paymentReceipts: [String]
        let publishedAt: Date

        private static let supportedCallIdentity = "iroh-hkdf-sonar-call-iroh-v1"

        var supportsMarmotCallSignaling: Bool {
            calls
                && callIdentity == Self.supportedCallIdentity
                && signaling.contains("marmot")
                && transports.contains("iroh")
        }

        var supportsDirectPayments: Bool {
            guard let offer = bolt12Offer?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !offer.isEmpty
            else { return false }
            return offer.lowercased().hasPrefix("lno")
        }
    }

    enum ServiceError: Error, Equatable {
        /// `connect()` has not completed successfully yet.
        case notConnected
        /// Invalid caller input (bad nsec/npub/group id/relay URL).
        case invalidInput(String)
        /// Failure inside the Rust core (relay I/O, MLS, MDK...).
        case core(String)
    }

    // MARK: - Configuration

    /// Well-known public relays used when none are injected.
    static let defaultRelayUrls = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
    ]

    private let relayUrls: [String]

    /// Serial queue: serializes access to `node`/`identity` AND keeps the
    /// blocking Rust calls off the main thread and off the Swift concurrency
    /// cooperative pool.
    private let workQueue = DispatchQueue(label: "chat.bitchat.marmot-service", qos: .userInitiated)

    /// Relay connection setup can be slow and must not block local transcript
    /// reads on `workQueue`. Build the relay-backed node here, then swap it in
    /// under `workQueue` once ready.
    private let relayConnectQueue = DispatchQueue(label: "chat.bitchat.marmot-relay-connect", qos: .utility)

    /// Separate queue for the parked `waitForMarmotEvent` call ONLY. It blocks
    /// for up to its timeout, so it must NOT share the serial engine queue (that
    /// would stall syncs/sends). The wait touches no MLS state, so this is safe.
    private let waitQueue = DispatchQueue(label: "chat.bitchat.marmot-wait", qos: .utility)

    // Guarded by `workQueue`.
    private var identity: SonarIdentity?
    private var node: SonarNode?
    private var relayConnected = false

    init(relayUrls: [String] = MarmotService.defaultRelayUrls) {
        self.relayUrls = relayUrls
    }

    // MARK: - Identity / lifecycle

    /// Connect to the relays. Pass an `nsec1...`/hex secret to import an
    /// existing identity; pass nil to generate a fresh one.
    /// Returns the identity's npub. Safe to call again to reconnect.
    @discardableResult
    func connect(nsec: String? = nil) async throws -> String {
        let relayUrls = self.relayUrls
        let identity = try await run { service in
            let identity: SonarIdentity
            if let nsec {
                identity = try SonarIdentity.import(nsec: nsec)
            } else if let existing = service.identity {
                identity = existing
            } else {
                identity = SonarIdentity.generate()
            }
            service.identity = identity
            return identity
        }
        let (dbPath, dbKeyHex) = try Self.databaseConfig()
        let node = try await connectNode(
            identity: identity,
            relayUrls: relayUrls,
            dbPath: dbPath,
            dbKeyHex: dbKeyHex
        )
        await runNonThrowing { service in
            service.identity = identity
            service.node = node
            service.relayConnected = true
            return ()
        }
        return identity.npub()
    }

    /// Open the encrypted local DB without attaching any relays. This is the
    /// Signal-style first-paint path: local transcript reads become available
    /// before network setup has a chance to block them.
    @discardableResult
    func connectLocal(nsec: String? = nil) async throws -> String {
        try await run { service in
            let identity: SonarIdentity
            if let nsec {
                identity = try SonarIdentity.import(nsec: nsec)
            } else if let existing = service.identity {
                identity = existing
            } else {
                identity = SonarIdentity.generate()
            }
            let (dbPath, dbKeyHex) = try Self.databaseConfig()
            let node = try SonarNode.connect(
                identity: identity,
                relayUrls: [],
                dbPath: dbPath,
                dbKeyHex: dbKeyHex
            )
            service.identity = identity
            service.node = node
            service.relayConnected = false
            return identity.npub()
        }
    }

    /// Load (or generate + persist into `service.identity`) the identity and
    /// return its `npub1...` WITHOUT connecting to relays. The npub is just the
    /// identity pubkey — available offline — so Sonar discovery (0x53) can
    /// advertise our npub even when the Marmot relay connect is slow or failing.
    /// A subsequent `connect(nsec: nil)` reuses this same `service.identity`.
    func loadIdentityNpub(nsec: String? = nil) async throws -> String {
        try await run { service in
            let identity: SonarIdentity
            if let nsec {
                identity = try SonarIdentity.import(nsec: nsec)
            } else if let existing = service.identity {
                identity = existing
            } else {
                identity = SonarIdentity.generate()
            }
            service.identity = identity
            return identity.npub()
        }
    }

    /// `npub1...` of the connected identity (nil before `connect`).
    func currentNpub() async -> String? {
        await runNonThrowing { $0.identity?.npub() }
    }

    /// True once `connect` has opened the node (relays + encrypted DB). False
    /// before the first connect and during a reconnect (e.g. after erase).
    func isConnected() async -> Bool {
        await runNonThrowing { $0.node != nil }
    }

    /// True when the current node was opened with the real relay set.
    func isRelayConnected() async -> Bool {
        await runNonThrowing { $0.node != nil && $0.relayConnected }
    }

    /// `nsec1...` backup export of the connected identity (nil before `connect`).
    /// Handle with care; intended for user-driven backup only.
    func exportNsec() async -> String? {
        await runNonThrowing { $0.identity?.nsec() }
    }

    // MARK: - Marmot operations

    /// Publish our MLS KeyPackage (kind 30443) so peers can invite us.
    func publishKeyPackage() async throws {
        try await run { try $0.requireNode().publishKeyPackage() }
    }

    /// Publish our kind-0 Nostr profile (NIP-01) so peers can show our name
    /// instead of a raw npub. `name` becomes both name + display_name.
    func publishProfile(name: String, about: String? = nil, picture: String? = nil) async throws {
        try await run { try $0.requireNode().publishProfile(name: name, about: about, picture: picture) }
    }

    /// Fetch a peer's kind-0 profile (npub or hex). nil if they have none.
    func fetchProfile(npub: String) async throws -> Profile? {
        try await run {
            try $0.requireNode().fetchProfile(npub: npub).map {
                Profile(name: $0.name, displayName: $0.displayName, about: $0.about, picture: $0.picture, nip05: $0.nip05)
            }
        }
    }

    /// Publish the public Sonar descriptor for this app build. Keep the route
    /// list honest: account-level internet call signaling currently uses Marmot.
    func publishSonarDescriptor(callsEnabled: Bool = true, bolt12Offer: String? = nil) async throws {
        try await run {
            try $0.requireNode().publishSonarDescriptor(
                callsEnabled: callsEnabled,
                signaling: ["marmot"],
                bolt12Offer: bolt12Offer
            )
        }
    }

    /// Fetch a peer's public Sonar descriptor. nil means not confirmed Sonar,
    /// not necessarily White Noise-only.
    func fetchSonarDescriptor(npub: String) async throws -> SonarDescriptor? {
        try await run {
            try $0.requireNode().fetchSonarDescriptor(npub: npub).map {
                SonarDescriptor(
                    schema: $0.schema,
                    calls: $0.calls,
                    media: $0.media,
                    signaling: $0.signaling,
                    transports: $0.transports,
                    callIdentity: $0.callIdentity,
                    bolt12Offer: $0.bolt12Offer,
                    paymentReceipts: $0.paymentReceipts,
                    publishedAt: Date(timeIntervalSince1970: TimeInterval($0.publishedAtSecs))
                )
            }
        }
    }

    /// Start a 1:1 DM group with `peer` (`npub1...` or hex pubkey). The peer
    /// must have a KeyPackage on the relays. Returns the new group id (hex).
    func startDirectMessage(with peer: String, name: String) async throws -> String {
        try await run { try $0.requireNode().startDm(peer: peer, name: name) }
    }

    /// Start a multi-member group with peers (`npub1...` or hex pubkeys).
    /// Returns the new group id (hex).
    func startGroup(with members: [String], name: String) async throws -> String {
        try await run {
            try $0.requireNode().startGroup(
                members: members.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Pending multi-member group invites awaiting explicit user action.
    func pendingGroupInvites() async throws -> [GroupInvite] {
        try await run {
            try $0.requireNode().pendingGroupInvites().map {
                GroupInvite(
                    id: $0.idHex,
                    groupId: $0.groupIdHex,
                    groupName: $0.groupName,
                    groupDescription: $0.groupDescription,
                    welcomerNpub: $0.welcomerNpub,
                    memberCount: $0.memberCount,
                    relays: $0.relayUrls
                )
            }
        }
    }

    /// Accept a pending group invite. Returns the group id (hex).
    func acceptGroupInvite(_ inviteId: String) async throws -> String {
        try await run { try $0.requireNode().acceptGroupInvite(inviteIdHex: inviteId) }
    }

    /// Decline a pending group invite.
    func declineGroupInvite(_ inviteId: String) async throws {
        try await run { try $0.requireNode().declineGroupInvite(inviteIdHex: inviteId) }
    }

    /// Add members to an existing group.
    func addGroupMembers(_ members: [String], to groupId: String) async throws {
        try await run {
            try $0.requireNode().addGroupMembers(
                groupIdHex: groupId,
                members: members.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            )
        }
    }

    /// Remove members from an existing group.
    func removeGroupMembers(_ members: [String], from groupId: String) async throws {
        try await run {
            try $0.requireNode().removeGroupMembers(
                groupIdHex: groupId,
                members: members.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            )
        }
    }

    /// Leave a group and delete its local chat state after the leave proposal is sent.
    func leaveGroup(_ groupId: String) async throws {
        try await run { try $0.requireNode().leaveGroup(groupIdHex: groupId) }
    }

    /// Encrypt and publish a text message to the group.
    func sendText(groupId: String, text: String) async throws {
        try await run { try $0.requireNode().sendText(groupIdHex: groupId, text: text) }
    }

    /// Encrypt `data`, upload the ciphertext to a Blossom server, and publish a
    /// media message to the group. `serverUrl` empty → the core default.
    func sendMedia(
        groupId: String,
        data: Data,
        filename: String,
        mime: String,
        caption: String,
        serverUrl: String = ""
    ) async throws {
        try await run {
            try $0.requireNode().sendMedia(
                groupIdHex: groupId,
                data: data,
                filename: filename,
                mime: mime,
                caption: caption,
                serverUrl: serverUrl
            )
        }
    }

    /// Download + decrypt the media blob at `url` for the group. Returns plaintext.
    func fetchMedia(groupId: String, url: String) async throws -> Data {
        try await run { try $0.requireNode().fetchMedia(groupIdHex: groupId, url: url) }
    }

    /// The user's Blossom server list (kind-10063). Empty if unset.
    func blossomServers() async throws -> [String] {
        try await run { try $0.requireNode().blossomServers() }
    }

    /// Publish the user's Blossom server list (kind-10063).
    func publishBlossomServers(_ servers: [String]) async throws {
        try await run { try $0.requireNode().publishBlossomServers(servers: servers) }
    }

    /// Poll the relays once for welcomes addressed to us and new group
    /// messages. Call periodically (or after sending) until live
    /// subscriptions land in the core.
    func syncOnce() async throws {
        try await run { try $0.requireNode().syncOnce() }
    }

    /// Delete a single Marmot chat's local state (messages + MLS keys). Local-
    /// only; the peer is not notified. Idempotent.
    func deleteGroup(groupId: String) async throws {
        try await run { try $0.requireNode().deleteGroup(groupIdHex: groupId) }
    }

    /// Park until the relay subscriptions push a live Marmot event (welcome or
    /// group message), or `timeoutSeconds` elapses. Returns true if there is
    /// something to drain. Runs OFF the serial engine queue, so a long park does
    /// not block syncs/sends; `SonarNode` is internally Send+Sync, so calling it
    /// from `waitQueue` with a reference grabbed race-free on `workQueue` is safe.
    func waitForMarmotEvent(timeoutSeconds: UInt64) async -> Bool {
        guard let node = await runNonThrowing({ service -> SonarNode? in
            guard service.relayConnected else { return nil }
            return service.node
        }) else {
            // Local-only startup is intentionally disconnected from relays.
            // Wait out the timeout so polling loops do not busy-spin or call
            // generated non-throwing FFI wait wrappers on a local-only node.
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            return false
        }
        return await withCheckedContinuation { continuation in
            waitQueue.async {
                continuation.resume(returning: node.waitForMarmotEvent(timeoutSecs: timeoutSeconds))
            }
        }
    }

    /// Process buffered live Marmot events through the MLS engine on the serial
    /// engine queue. Returns true if anything was drained (→ reload the UI).
    @discardableResult
    func drainPending() async throws -> Bool {
        try await run { try $0.requireNode().drainPendingMarmot() }
    }

    /// All Marmot groups the identity belongs to.
    func groups() async throws -> [MarmotGroup] {
        try await run {
            try $0.requireNode().groups().map {
                MarmotGroup(id: $0.idHex, name: $0.name, memberNpubs: $0.memberNpubs)
            }
        }
    }

    /// Decrypted message history for a group, oldest first.
    func messages(groupId: String) async throws -> [MarmotMessage] {
        try await run {
            try $0.requireNode().messages(groupIdHex: groupId).map(Self.marmotMessage)
        }
    }

    /// Bounded local message window for a group, oldest first within the page.
    func messagesPage(groupId: String, limit: UInt32, offset: UInt32 = 0) async throws -> [MarmotMessage] {
        try await run {
            try $0.requireNode()
                .messagesPage(groupIdHex: groupId, limit: limit, offset: offset)
                .map(Self.marmotMessage)
        }
    }

    /// Local transcript windows for the most recent groups, newest conversation
    /// first. Used by home list hydration before any relay-aware sync.
    func recentMessagePages(groupLimit: UInt32, pageLimit: UInt32) async throws -> [RecentMessagePage] {
        try await run {
            try $0.requireNode()
                .recentMessagePages(groupLimit: groupLimit, pageLimit: pageLimit)
                .map {
                    RecentMessagePage(
                        groupId: $0.groupIdHex,
                        latestCreatedAt: Date(timeIntervalSince1970: TimeInterval($0.latestCreatedAtSecs)),
                        messages: $0.messages.map(Self.marmotMessage)
                    )
                }
        }
    }

    private static func marmotMessage(_ message: MessageInfo) -> MarmotMessage {
        MarmotMessage(
            id: message.idHex,
            senderNpub: message.senderNpub,
            content: message.content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(message.createdAtSecs)),
            isMine: message.mine,
            deliveryState: message.deliveryState,
            media: message.media.map {
                MarmotMedia(
                    url: $0.url,
                    mimeType: $0.mimeType,
                    filename: $0.filename,
                    width: $0.width,
                    height: $0.height,
                    durationMs: $0.durationMs
                )
            }
        )
    }

    // MARK: - Persistence (SQLCipher store for White Noise / Marmot)

    /// Keychain service + key holding the 32-byte SQLCipher database key. The
    /// SAME key is returned every launch so the existing encrypted database
    /// reopens; wiped by `wipeDatabase()` on panic.
    private static let dbKeychainService = "chat.bitchat.sonar.messages"
    private static let dbKeychainKey = "marmot-db-key"
    private static let dbDirName = "sonar-marmot"
    private static let dbFileName = "marmot.sqlite"

    /// Absolute path of the encrypted Marmot database, parent dir created with
    /// Data-Protection-Complete (at-rest encryption tied to the passcode).
    private static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent(dbDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: dir.path
        )
        #endif
        return dir.appendingPathComponent(dbFileName)
    }

    /// (path, 64-char hex key). Generates and persists a fresh key the first time.
    private static func databaseConfig() throws -> (String, String) {
        let url = try databaseURL()
        let keychain = KeychainManager()
        let keyHex: String
        // Distinguish "no key yet" (safe to generate) from "key not readable
        // right now" (e.g. device locked during a background wake). Generating a
        // new key on a TRANSIENT read failure would overwrite the existing one and
        // make the encrypted DB unreadable FOREVER (all chat history lost) — so we
        // only generate on .itemNotFound, and fail otherwise so setup retries once
        // the keychain is accessible (#13 / chat-state-loss on locked wakes).
        switch keychain.getIdentityKeyWithResult(forKey: dbKeychainKey) {
        case .success(let data):
            guard let existing = String(data: data, encoding: .utf8), existing.count == 64 else {
                // Present but malformed: the DB is encrypted with *something*;
                // refuse to overwrite (that would orphan it).
                throw ServiceError.core("database key malformed — refusing to overwrite (would lose history)")
            }
            keyHex = existing
            // Migration (#13): re-save to upgrade a legacy WhenUnlocked item to
            // AfterFirstUnlockThisDeviceOnly, so it stays readable on background/
            // locked wakes (this read just succeeded → keychain is accessible).
            _ = keychain.saveIdentityKey(Data(keyHex.utf8), forKey: dbKeychainKey)
        case .itemNotFound:
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                // Never fall back to a weak/zero key for an encrypted DB.
                throw ServiceError.core("failed to generate database encryption key")
            }
            keyHex = bytes.map { String(format: "%02x", $0) }.joined()
            guard keychain.saveIdentityKey(Data(keyHex.utf8), forKey: dbKeychainKey) else {
                throw ServiceError.core("failed to persist database encryption key")
            }
        case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
            // The key likely EXISTS but isn't readable now. Do NOT regenerate.
            throw ServiceError.core("database key not readable yet (device locked?) — deferring")
        }
        return (url.path, keyHex)
    }

    /// Panic-wipe: drop the open node, erase the encrypted database (and its
    /// SQLite sidecars), and forget the Keychain DB key. Idempotent.
    func wipeDatabase() async {
        await runNonThrowing { service in
            service.node = nil
            service.identity = nil
            service.relayConnected = false
            if let url = try? Self.databaseURL() {
                try? wipeMarmotDatabase(dbPath: url.path)
            }
            _ = KeychainManager().deleteIdentityKey(forKey: Self.dbKeychainKey)
            return ()
        }
    }

    private func connectNode(
        identity: SonarIdentity,
        relayUrls: [String],
        dbPath: String,
        dbKeyHex: String
    ) async throws -> SonarNode {
        try await withCheckedThrowingContinuation { continuation in
            relayConnectQueue.async {
                do {
                    continuation.resume(returning: try SonarNode.connect(
                        identity: identity,
                        relayUrls: relayUrls,
                        dbPath: dbPath,
                        dbKeyHex: dbKeyHex
                    ))
                } catch let error as SonarFfiError {
                    switch error {
                    case .InvalidInput(let message):
                        continuation.resume(throwing: ServiceError.invalidInput(message))
                    case .Core(let message):
                        continuation.resume(throwing: ServiceError.core(message))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - P2P calls (iroh transport; separate from the MLS engine)

    /// Quick call ops run here; `callWaitQueue` parks separately so a long
    /// `callWaitEvent` never blocks `callAccept`/`callHangup`. The call engine is
    /// independent of MLS, and `SonarNode` is Send+Sync, so a dedicated queue
    /// (grabbing the node ref race-free on `workQueue`) is safe.
    private let callQueue = DispatchQueue(label: "chat.bitchat.marmot-call", qos: .userInitiated)
    private let callWaitQueue = DispatchQueue(label: "chat.bitchat.marmot-call-wait", qos: .utility)

    func callStart() async throws { try await runCall(callQueue) { try $0.callStart() } }
    func callLocalAddress() async throws -> String { try await runCall(callQueue) { try $0.callLocalAddress() } }
    func callPlace(callId: String, video: Bool) async throws {
        try await runCall(callQueue) { try $0.callPlace(callId: callId, video: video) }
    }
    func callIncomingOffer(callId: String, addrB64: String, video: Bool) async throws {
        try await runCall(callQueue) { try $0.callOnIncomingOffer(callId: callId, remoteAddrB64: addrB64, video: video) }
    }
    func callAnswer(callId: String, answer: CallAnswerKind, addrB64: String) async throws {
        try await runCall(callQueue) { try $0.callOnAnswer(callId: callId, answer: answer, remoteAddrB64: addrB64) }
    }
    func callAccept(callId: String) async throws { try await runCall(callQueue) { try $0.callAccept(callId: callId) } }
    func callHangup(callId: String) async throws { try await runCall(callQueue) { try $0.callHangup(callId: callId) } }
    func callSetMuted(callId: String, muted: Bool) async throws {
        try await runCall(callQueue) { try $0.callSetMuted(callId: callId, muted: muted) }
    }

    /// Park up to `timeoutSeconds` for the next call state change (off the engine
    /// + action queues), mirroring `waitForMarmotEvent`.
    func callWaitEvent(timeoutSeconds: UInt64) async -> CallEventInfo? {
        guard let node = await runNonThrowing({ service -> SonarNode? in
            guard service.relayConnected else { return nil }
            return service.node
        }) else {
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            return nil
        }
        return await withCheckedContinuation { continuation in
            callWaitQueue.async {
                continuation.resume(returning: node.callWaitEvent(timeoutSecs: timeoutSeconds))
            }
        }
    }

    /// Run a blocking call op on `queue`, with the node grabbed race-free on the
    /// engine queue, mapping Rust errors like `run`.
    private func runCall<T: Sendable>(
        _ queue: DispatchQueue,
        _ body: @escaping @Sendable (SonarNode) throws -> T
    ) async throws -> T {
        guard let node = await runNonThrowing({ $0.node }) else { throw ServiceError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body(node))
                } catch let error as SonarFfiError {
                    switch error {
                    case .InvalidInput(let message):
                        continuation.resume(throwing: ServiceError.invalidInput(message))
                    case .Core(let message):
                        continuation.resume(throwing: ServiceError.core(message))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Internals

    private func requireNode() throws -> SonarNode {
        guard let node else { throw ServiceError.notConnected }
        return node
    }

    /// Hop onto the work queue, run the blocking body, map Rust errors.
    private func run<T: Sendable>(_ body: @escaping @Sendable (MarmotService) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async { [self] in
                do {
                    continuation.resume(returning: try body(self))
                } catch let error as SonarFfiError {
                    switch error {
                    case .InvalidInput(let message):
                        continuation.resume(throwing: ServiceError.invalidInput(message))
                    case .Core(let message):
                        continuation.resume(throwing: ServiceError.core(message))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runNonThrowing<T: Sendable>(_ body: @escaping @Sendable (MarmotService) -> T) async -> T {
        await withCheckedContinuation { continuation in
            workQueue.async { [self] in
                continuation.resume(returning: body(self))
            }
        }
    }
}
