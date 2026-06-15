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

    struct MarmotGroup: Sendable, Equatable {
        /// Hex MLS group id; pass it back to `sendText`/`messages`.
        let id: String
        let name: String
        let memberNpubs: [String]
    }

    struct MarmotMessage: Sendable, Equatable {
        let id: String
        let senderNpub: String
        let content: String
        let createdAt: Date
        /// True when the local identity sent it.
        let isMine: Bool
        /// Encrypted media attachments (Marmot MIP-04), empty for plain text.
        let media: [MarmotMedia]
    }

    /// A reference to an encrypted media attachment. `url` is the Blossom URL of
    /// the CIPHERTEXT; call `fetchMedia(groupId:url:)` to download + decrypt.
    struct MarmotMedia: Sendable, Equatable {
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
    struct Profile: Sendable, Equatable {
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

    // Guarded by `workQueue`.
    private var identity: SonarIdentity?
    private var node: SonarNode?

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
        return try await run { service in
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
                relayUrls: relayUrls,
                dbPath: dbPath,
                dbKeyHex: dbKeyHex
            )
            service.identity = identity
            service.node = node
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

    /// Start a 1:1 DM group with `peer` (`npub1...` or hex pubkey). The peer
    /// must have a KeyPackage on the relays. Returns the new group id (hex).
    func startDirectMessage(with peer: String, name: String) async throws -> String {
        try await run { try $0.requireNode().startDm(peer: peer, name: name) }
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
            try $0.requireNode().messages(groupIdHex: groupId).map {
                MarmotMessage(
                    id: $0.idHex,
                    senderNpub: $0.senderNpub,
                    content: $0.content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval($0.createdAtSecs)),
                    isMine: $0.mine,
                    media: $0.media.map {
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
        }
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
            if let url = try? Self.databaseURL() {
                try? wipeMarmotDatabase(dbPath: url.path)
            }
            _ = KeychainManager().deleteIdentityKey(forKey: Self.dbKeychainKey)
            return ()
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
