//
// MarmotService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import CryptoKit
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

    private final class NodeLifecycleLease: @unchecked Sendable {
        private let lock = NSLock()
        private var group: DispatchGroup?

        init(group: DispatchGroup) {
            self.group = group
            group.enter()
        }

        func release() {
            lock.lock()
            let group = self.group
            self.group = nil
            lock.unlock()
            group?.leave()
        }

        deinit { release() }
    }

    private final class OperationCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

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

    /// Core-computed content classification (mirrors FFI `MessageClassInfo`).
    /// Hosts render from this instead of re-parsing `content` per render.
    enum MarmotMessageClass: Sendable, Equatable, Codable {
        case text
        /// ⚡PAY receipt — render a payment bubble.
        case payReceipt(paymentId: String, amountSats: UInt64)
        /// ⚡PAYDONE settlement — control line, hidden from the transcript.
        case payDone(paymentId: String, preimageHex: String?)
        /// ☎CALL signaling — control line, hidden from the transcript.
        case callControl
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
        /// Sticker reference, if this message is a sticker.
        let stickerRef: MarmotStickerRef?
        /// Core-computed classification; `.text` for local echoes and rows
        /// decoded from older on-disk encodes.
        let classification: MarmotMessageClass

        init(
            id: String,
            senderNpub: String,
            content: String,
            createdAt: Date,
            isMine: Bool,
            deliveryState: String? = nil,
            media: [MarmotMedia],
            stickerRef: MarmotStickerRef? = nil,
            classification: MarmotMessageClass = .text
        ) {
            self.id = id
            self.senderNpub = senderNpub
            self.content = content
            self.createdAt = createdAt
            self.isMine = isMine
            self.deliveryState = deliveryState
            self.media = media
            self.stickerRef = stickerRef
            self.classification = classification
        }

        enum CodingKeys: String, CodingKey {
            case id
            case senderNpub
            case content
            case createdAt
            case isMine
            case deliveryState
            case media
            case stickerRef
            case classification
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
            self.stickerRef = try container.decodeIfPresent(MarmotStickerRef.self, forKey: .stickerRef)
            self.classification =
                try container.decodeIfPresent(MarmotMessageClass.self, forKey: .classification) ?? .text
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
        /// Optional user caption for this media item (Signal-style: part of
        /// the media model from day one, even before the UI exposes it).
        /// Synthesized Codable decodes optionals with decodeIfPresent, so
        /// payloads written before this field existed decode with nil.
        var caption: String? = nil
        var isImage: Bool { mimeType.hasPrefix("image/") }
        var isVideo: Bool { mimeType.hasPrefix("video/") }
        var isAudio: Bool { mimeType.hasPrefix("audio/") }
    }

    struct MarmotStickerRef: Sendable, Equatable, Codable {
        let packCoordinate: String
        let shortcode: String
        let plaintextSha256: String
    }

    struct ConversationSummary: Sendable, Equatable {
        let groupIdHex: String
        let name: String
        let latestContent: String
        let latestSenderNpub: String
        let latestAt: Date
        let latestMine: Bool
        let messageCount: UInt64
        let unreadCount: UInt64
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

    /// A unified handle (`vincenzo` / `alice@example.com`) resolved to its
    /// owner via NIP-05. `address` is the canonical lowercased `name@domain`.
    struct ResolvedHandle: Sendable, Equatable {
        let address: String
        let npub: String
        let pubkeyHex: String
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
        /// A newer session change superseded this async operation.
        case cancelled
        /// Invalid caller input (bad nsec/npub/group id/relay URL).
        case invalidInput(String)
        /// Failure inside the Rust core (relay I/O, MLS, MDK...).
        case core(String)
    }

    let conversationChanged = PassthroughSubject<String, Never>()

    // MARK: - Configuration

    /// Well-known public relays used when none are injected.
    static let defaultRelayUrls = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://relay.kaleidoswap.com",
        "wss://nostr.relay.hedwig.sh",
    ]

    private let relayUrls: [String]

    /// Serial queue: serializes engine maintenance (connect, sync,
    /// group management) and `node`/`identity` writes. Keeps the blocking
    /// Rust calls off the main thread and off the Swift concurrency
    /// cooperative pool. Text/sticker sends run on `sendQueue` and live
    /// `drainPending` on `drainQueue` — they must not share this lane
    /// (each sync can park it for a 10s relay timeout). Same shape as
    /// Android: lifecycle serialization only; sync/drain hop independently.
    private let workQueue = DispatchQueue(label: "chat.bitchat.marmot-service", qos: .userInitiated)

    /// Serial send lane for text/sticker sends: they must stay ordered with
    /// each other, but must never FIFO-queue behind sync relay quorum
    /// fetches on `workQueue` (each can park it for a 10s timeout — the
    /// documented 6.6s p95 / 19.3s max send dispatch tail). The core engine
    /// serializes MLS mutations internally (`MarmotEngine::write_lock`), so a
    /// send here runs concurrently with an in-flight sync and waits at most
    /// for one in-flight MLS mutation, never for a relay fetch.
    private let sendQueue = DispatchQueue(label: "chat.bitchat.marmot-send", qos: .userInitiated)

    /// Serial receive/drain lane (Android `Dispatchers.IO` parity for drain).
    /// Must never FIFO-queue behind blocking UniFFI `syncForce` on
    /// `workQueue` — that was the ~10s banner→UI lag. Core `write_lock`
    /// serializes MLS mutations; drain waits at most for one in-flight
    /// mutation, never for a relay quorum fetch.
    private let drainQueue = DispatchQueue(label: "chat.bitchat.marmot-drain", qos: .userInitiated)

    /// Concurrent queue for read-only FFI calls (groups, messages, summaries).
    /// SQLCipher supports concurrent readers; these never touch MLS state, so
    /// they are safe to run in parallel with each other (and alongside writes
    /// that are serialized on `workQueue`). Modeled after WhiteNoise's
    /// concurrent `ffiQueue`.
    private let readQueue = DispatchQueue(label: "chat.bitchat.marmot-ffi-read", qos: .userInitiated, attributes: .concurrent)

    /// Installed-pack fetch/modify/publish is a separate FIFO network lane.
    /// It must stay ordered without parking MLS text/sticker sends for the
    /// relay timeout or blocking unrelated concurrent image reads.
    private let installedPackQueue = DispatchQueue(label: "chat.bitchat.marmot-installed-packs", qos: .utility)

    /// Relay connection setup can be slow and must not block local transcript
    /// reads on `workQueue`. Build the relay-backed node here, then swap it in
    /// under `workQueue` once ready.
    private let relayConnectQueue = DispatchQueue(label: "chat.bitchat.marmot-relay-connect", qos: .utility)

    /// Separate queue for the parked `waitForMarmotEvent` call ONLY. It blocks
    /// for up to its timeout, so it must NOT share the serial engine queue (that
    /// would stall syncs/sends). The wait touches no MLS state, so this is safe.
    private let waitQueue = DispatchQueue(label: "chat.bitchat.marmot-wait", qos: .utility)

    // Identity is guarded by `workQueue`; node/relay connection state is
    // guarded by `nodeLock` so read-only transfers can safely snapshot it.
    private var identity: SonarIdentity?
    private var node: SonarNode?
    private var relayConnected = false
    private var sessionGeneration: UInt64 = 0

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
        let (identity, generation) = try await run { service in
            guard !service.nodeClosing else { throw ServiceError.cancelled }
            let identity: SonarIdentity
            if let nsec {
                identity = try SonarIdentity.import(nsec: nsec)
            } else if let existing = service.identity {
                identity = existing
            } else {
                identity = SonarIdentity.generate()
            }
            service.identity = identity
            service.sessionGeneration = service.sessionGeneration &+ 1
            return (identity, service.sessionGeneration)
        }
        let (dbPath, dbKeyHex) = try Self.databaseConfig()
        let (node, nodeLease) = try await connectNode(
            identity: identity,
            relayUrls: relayUrls,
            dbPath: dbPath,
            dbKeyHex: dbKeyHex
        )
        defer { nodeLease.release() }
        let installed = await runNonThrowing { service in
            guard service.sessionGeneration == generation,
                  service.identity?.npub() == identity.npub()
            else {
                return false
            }
            service.identity = identity
            service.nodeLock.lock()
            service.node = node
            service.relayConnected = true
            service.nodeLock.unlock()
            service.installConversationListener(on: node)
            #if os(iOS)
            SonarPushRegistration.shared.setSonarNode(node)
            #endif
            return true
        }
        guard installed else {
            throw ServiceError.cancelled
        }
        try await run { try $0.requireNode().retryOutbox() }
        return identity.npub()
    }

    /// Open the encrypted local DB without attaching any relays. This is the
    /// Signal-style first-paint path: local transcript reads become available
    /// before network setup has a chance to block them.
    @discardableResult
    func connectLocal(nsec: String? = nil) async throws -> String {
        try await run { service in
            guard !service.nodeClosing else { throw ServiceError.cancelled }
            let identity: SonarIdentity
            if let nsec {
                identity = try SonarIdentity.import(nsec: nsec)
            } else if let existing = service.identity {
                identity = existing
            } else {
                identity = SonarIdentity.generate()
            }
            let (dbPath, dbKeyHex) = try Self.databaseConfig()
            SonarDiagnostics.installCoreLoggingIfNeeded()
            let node = try SonarNode.connect(
                identity: identity,
                relayUrls: [],
                dbPath: dbPath,
                dbKeyHex: dbKeyHex
            )
            service.identity = identity
            service.nodeLock.lock()
            service.node = node
            service.relayConnected = false
            service.nodeLock.unlock()
            service.installConversationListener(on: node)
            #if os(iOS)
            SonarPushRegistration.shared.setSonarNode(node)
            #endif
            service.sessionGeneration = service.sessionGeneration &+ 1
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
            service.sessionGeneration = service.sessionGeneration &+ 1
            return identity.npub()
        }
    }

    /// `npub1...` of the connected identity (nil before `connect`).
    func currentNpub() async -> String? {
        await runNonThrowing { $0.identity?.npub() }
    }

    /// True once `connect` has opened the node (relays + encrypted DB). False
    /// before the first connect and during a reconnect (e.g. after erase).
    func isConnected() -> Bool {
        nodeLock.lock()
        let connected = node != nil
        nodeLock.unlock()
        return connected
    }

    /// True when the current node was opened with the real relay set.
    func isRelayConnected() -> Bool {
        nodeLock.lock()
        let connected = node != nil && relayConnected
        nodeLock.unlock()
        return connected
    }

    /// `nsec1...` backup export of the connected identity (nil before `connect`).
    /// Handle with care; intended for user-driven backup only.
    func exportNsec() async -> String? {
        await runNonThrowing { $0.identity?.nsec() }
    }

    /// JSON snapshot of relay/sync state (relay statuses, sync watermark,
    /// per-group catch-up floors) for the Diagnostics screen and the exported
    /// debug bundle. No message content or key material. Nil before `connect`.
    /// Read-only — never queues behind serialized engine work.
    func syncStateSnapshotJson() async -> String? {
        await readOnlyNonThrowing({ try? $0.syncStateSnapshotJson() }, default: nil)
    }

    // MARK: - Marmot operations

    /// Publish our MLS KeyPackage (kind 30443) so peers can invite us.
    func publishKeyPackage() async throws {
        try await run { try $0.requireNode().publishKeyPackage() }
    }

    /// Like `publishKeyPackage()`, but returns once the event is created and
    /// persisted; the relay send (with its per-relay OK wait) runs inside the
    /// core in the background. For the relay-connect republish path, where the
    /// OK wait must not hold the serial engine queue ahead of the first drain.
    func publishKeyPackageBackground() async throws {
        try await run { try $0.requireNode().publishKeyPackageBackground() }
    }

    /// Publish our kind-0 Nostr profile (NIP-01) so peers can show our name
    /// instead of a raw npub. `name` becomes both name + display_name.
    func publishProfile(name: String, about: String? = nil, picture: String? = nil) async throws {
        try await run { try $0.requireNode().publishProfile(name: name, about: about, picture: picture) }
    }

    /// Like `publishProfile(name:about:picture:)`, but the relay send runs in
    /// the background inside the core — same contract as
    /// `publishKeyPackageBackground()`.
    func publishProfileBackground(name: String, about: String? = nil, picture: String? = nil) async throws {
        try await run { try $0.requireNode().publishProfileBackground(name: name, about: about, picture: picture) }
    }

    /// Fetch a peer's kind-0 profile (npub or hex). nil if they have none.
    func fetchProfile(npub: String) async throws -> Profile? {
        try await run {
            try $0.requireNode().fetchProfile(npub: npub).map {
                Profile(name: $0.name, displayName: $0.displayName, about: $0.about, picture: $0.picture, nip05: $0.nip05)
            }
        }
    }

    /// Pure string gate for handle claim/lookup input. Safe per keystroke —
    /// no network, no node required. False for npub1/lno1/etc. lookalikes.
    static func handleLooksValid(_ input: String) -> Bool {
        SonarCore.handleLooksValid(input: input)
    }

    /// Claim `handle` at the Sonar registrar (blocking network POST inside the
    /// core). Returns the claimed address (`name@sonarprivacy.xyz`). On success
    /// the core persists the handle and merges it as nip05 into every kind-0
    /// publish — republish the profile afterwards so peers see it immediately.
    /// A taken handle surfaces as `ServiceError.core("handle taken: ...")`.
    ///
    /// Concurrent read lane, NOT `run`: the claim doesn't mutate MLS state
    /// (registrar POST + sidecar write + in-memory mutex in core), and its
    /// 15s-capped network wait must never park connect/sync/drain on the
    /// serial `workQueue`.
    func claimHandle(handle: String, offer: String?) async throws -> String {
        try await readOnly { try $0.claimHandle(handle: handle, offer: offer) }
    }

    /// Locally stored claimed handle address (nil when never claimed). Local
    /// read only — never touches the network.
    func claimedHandle() async -> String? {
        await readOnlyNonThrowing({ $0.claimedHandle() }, default: nil)
    }

    /// Resolve `vincenzo` (default domain) or `alice@any-domain.com` to its
    /// owner via NIP-05. Bounded network lookup (~10s) on the concurrent read
    /// lane, so it never queues behind serialized engine work.
    func resolveHandle(_ input: String) async throws -> ResolvedHandle {
        try await readOnly {
            let info = try $0.resolveHandle(input: input)
            return ResolvedHandle(address: info.address, npub: info.npub, pubkeyHex: info.pubkeyHex)
        }
    }

    /// True if `address` currently NIP-05-resolves to `npub`. Bounded network
    /// lookup on the concurrent read lane.
    func verifyNip05(address: String, npub: String) async throws -> Bool {
        try await readOnly { try $0.verifyNip05(address: address, npub: npub) }
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
        try await readOnly {
            try $0.pendingGroupInvites().map {
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

    /// Create a shareable invite link for a group.
    func createInviteLink(groupId: String, groupName: String) async throws -> String {
        try await run { try $0.requireNode().createInviteLink(groupIdHex: groupId, groupName: groupName) }
    }

    /// Pending join requests for a group.
    func pendingJoinRequests(groupId: String) async throws -> [JoinRequestInfo] {
        try await readOnly { try $0.pendingJoinRequests(groupIdHex: groupId) }
    }

    /// Approve a pending join request.
    func approveJoinRequest(groupId: String, requesterNpub: String) async throws {
        try await run { try $0.requireNode().approveJoinRequest(groupIdHex: groupId, requesterNpub: requesterNpub) }
    }

    /// Decline a pending join request.
    func declineJoinRequest(groupId: String, requesterNpub: String) async throws {
        try await run { try $0.requireNode().declineJoinRequest(groupIdHex: groupId, requesterNpub: requesterNpub) }
    }

    /// Request to join a group via invite link token.
    func requestJoinViaLink(token: String) async throws {
        try await run { try $0.requireNode().requestJoinViaLink(inviteToken: token) }
    }

    /// Encrypt and publish a text message to the group.
    func sendText(groupId: String, text: String) async throws {
        try await sendLane { try $0.sendText(groupIdHex: groupId, text: text) }
    }

    /// Republish one failed message from the durable local outbox.
    func retryMessage(messageId: String) async throws -> String {
        try await run {
            try $0.requireNode().retryMessage(messageIdHex: messageId)
        }
    }

    /// Encrypt `data`, upload the ciphertext to a Blossom server, and publish a
    /// media message to the group. `serverUrl` empty → the core default.
    func sendMedia(
        groupId: String,
        data: Data,
        filename: String,
        mime: String,
        caption: String,
        serverUrl: String = "",
        requestId: String = ""
    ) async throws {
        try await run {
            try $0.requireNode().sendMediaRetryable(
                groupIdHex: groupId,
                data: data,
                filename: filename,
                mime: mime,
                caption: caption,
                serverUrl: serverUrl,
                requestId: requestId
            )
        }
    }

    /// One attachment of an album send (one message, N attachments).
    struct MediaAlbumItem: Sendable {
        let data: Data
        let filename: String
        let mime: String
    }

    /// Send N attachments as ONE album message: encrypt + upload every item,
    /// then publish a single kind-445 event carrying all `imeta` tags (in
    /// order) plus the optional `caption`. If ANY upload fails nothing is
    /// published. `serverUrl` empty → the core default.
    func sendMediaMulti(
        groupId: String,
        items: [MediaAlbumItem],
        caption: String,
        serverUrl: String = "",
        requestId: String = ""
    ) async throws {
        try await run {
            try $0.requireNode().sendMediaMultiRetryable(
                groupIdHex: groupId,
                items: items.map {
                    MediaUploadItem(data: $0.data, filename: $0.filename, mime: $0.mime)
                },
                caption: caption,
                serverUrl: serverUrl,
                requestId: requestId
            )
        }
    }

    /// Send a sticker message to the group.
    func sendSticker(
        groupId: String,
        packCoordinate: String,
        shortcode: String,
        plaintextSha256: String
    ) async throws {
        try await sendLane {
            try $0.sendSticker(
                groupIdHex: groupId,
                packCoordinate: packCoordinate,
                shortcode: shortcode,
                plaintextSha256: plaintextSha256
            )
        }
    }

    /// Fetch a sticker pack from relays by author and identifier. This can park
    /// for the relay timeout, so it must not occupy the serialized MLS queue.
    func fetchStickerPack(
        authorPubkeyHex: String,
        identifier: String,
        relayUrls: [String]
    ) async throws -> StickerPackInfo {
        try await readOnly { node in
            try node.fetchStickerPack(
                authorPubkeyHex: authorPubkeyHex,
                identifier: identifier,
                relayUrls: relayUrls
            )
        }
    }

    /// Download a public sticker image by its plaintext HTTPS URL.
    /// Runs off the serial workQueue to avoid blocking sends and message reads.
    func fetchStickerImage(url: String, expectedSha256: String) async throws -> Data {
        try await readOnly { node in
            try node.fetchStickerImage(url: url, expectedSha256: expectedSha256)
        }
    }

    /// Read verified sticker bytes only when cached pack metadata authorizes the
    /// full reference. A nil result is an ordinary local validation/cache miss.
    func cachedStickerImage(for ref: MarmotStickerRef) async throws -> Data? {
        try await readOnly { node in
            try node.cachedStickerImageForRef(
                packCoordinate: ref.packCoordinate,
                shortcode: ref.shortcode,
                plaintextSha256: ref.plaintextSha256
            )
        }
    }

    func fetchInstalledPacks() async throws -> [String] {
        try await leasedNodeOperation(on: installedPackQueue) { try $0.fetchInstalledPacks() }
    }

    func installStickerPack(coordinate: String) async throws {
        try await leasedNodeOperation(on: installedPackQueue) {
            try $0.installStickerPack(coordinate: coordinate)
        }
    }

    func uninstallStickerPack(coordinate: String) async throws {
        try await leasedNodeOperation(on: installedPackQueue) {
            try $0.uninstallStickerPack(coordinate: coordinate)
        }
    }

    /// Download + decrypt the media blob at `url` for the group. This read-only
    /// operation must never occupy the serialized MLS mutation queue.
    func fetchMedia(groupId: String, url: String) async throws -> Data {
        try await readOnly { try $0.fetchMedia(groupIdHex: groupId, url: url) }
    }

    /// File-backed attachment transfer with progress and cancellation. The core
    /// writes only to the unique partial path supplied by the app; the caller
    /// atomically promotes it to the persistent cache after this returns.
    func fetchMediaToFile(
        groupId: String,
        url: String,
        destination: URL,
        listener: MediaDownloadListener
    ) async throws -> UInt64 {
        try await readOnly {
            try $0.fetchMediaToFile(
                groupIdHex: groupId,
                url: url,
                destinationPath: destination.path,
                listener: listener
            )
        }
    }

    /// The user's Blossom server list (kind-10063). Empty if unset.
    func blossomServers() async throws -> [String] {
        try await readOnly { try $0.blossomServers() }
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

    /// Force-sync that bypasses the live-subscription short-circuit. Use after
    /// foreground resume to catch events missed while backgrounded.
    func syncForce() async throws {
        try await run { try $0.requireNode().syncForce() }
    }

    /// Prefer this group for cold-start historical catch-up (open chat).
    /// Local-first: never blocks paint/send. Empty/nil clears preference.
    func preferCatchupGroup(_ groupId: String?) async {
        let value = (groupId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Best-effort: local-only sessions may not have a relay-backed node yet.
        try? await run { service in
            guard service.relayConnected else { return }
            // Host ids are MLS group ids (send_text / MarmotGroup.id); core maps to nostr #h.
            try service.requireNode().preferCatchupGroup(mlsGroupIdHex: value)
        }
    }

    /// Re-subscribe with current watermark + group set to self-heal after
    /// relay disconnects. May perform one bounded chat repair fetch; keep this
    /// on the service work queue and never await it before local chat paint.
    func ensureSubscriptions() async throws {
        try await run { try $0.requireNode().ensureSubscriptions() }
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
        var remaining = timeoutSeconds
        while remaining > 0 && !Task.isCancelled {
            let slice = min(remaining, 1)
            let woke = try? await leasedNodeOperation(
                on: waitQueue,
                requireRelay: true
            ) { node in
                node.waitForMarmotEvent(timeoutSecs: slice)
            }
            guard let woke else {
                try? await Task.sleep(nanoseconds: slice * 1_000_000_000)
                remaining -= slice
                continue
            }
            if woke { return true }
            remaining -= slice
        }
        return false
    }

    /// Process buffered live Marmot events through the MLS engine on the
    /// dedicated drain lane (not `workQueue`). Returns notifications for
    /// incoming messages (empty = nothing drained).
    @discardableResult
    func drainPending() async throws -> [DrainNotificationInfo] {
        try await drainLane { try $0.drainPendingMarmot() }
    }

    /// All Marmot groups the identity belongs to.
    func groups() async throws -> [MarmotGroup] {
        try await readOnly {
            try $0.groups().map {
                MarmotGroup(id: $0.idHex, name: $0.name, memberNpubs: $0.memberNpubs)
            }
        }
    }

    /// Decrypted message history for a group, oldest first.
    func messages(groupId: String) async throws -> [MarmotMessage] {
        try await readOnly {
            try $0.messages(groupIdHex: groupId).map(Self.marmotMessage)
        }
    }

    /// Bounded local message window for a group, oldest first within the page.
    func messagesPage(groupId: String, limit: UInt32, offset: UInt32 = 0) async throws -> [MarmotMessage] {
        try await readOnly {
            try $0.messagesPage(groupIdHex: groupId, limit: limit, offset: offset)
                .map(Self.marmotMessage)
        }
    }

    /// Local transcript windows for the most recent groups, newest conversation
    /// first. Used by home list hydration before any relay-aware sync.
    func recentMessagePages(groupLimit: UInt32, pageLimit: UInt32) async throws -> [RecentMessagePage] {
        try await readOnly {
            try $0.recentMessagePages(groupLimit: groupLimit, pageLimit: pageLimit)
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
            },
            stickerRef: message.stickerRef.map {
                MarmotStickerRef(
                    packCoordinate: $0.packCoordinate,
                    shortcode: $0.shortcode,
                    plaintextSha256: $0.plaintextSha256
                )
            },
            classification: Self.marmotMessageClass(message.classification)
        )
    }

    private static func marmotMessageClass(_ c: MessageClassInfo) -> MarmotMessageClass {
        switch c {
        case .text:
            return .text
        case .payReceipt(let paymentId, let amountSats):
            return .payReceipt(paymentId: paymentId, amountSats: amountSats)
        case .payDone(let paymentId, let preimageHex):
            return .payDone(paymentId: paymentId, preimageHex: preimageHex)
        case .callControl:
            return .callControl
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

    #if os(iOS)
    /// Data-Protection class for the SQLite store. Deliberately
    /// `.completeUntilFirstUserAuthentication`, NOT `.complete`:
    ///
    /// The databases run in WAL mode, so SQLite memory-maps the `-shm` index
    /// file. Under `.complete` that file is unreadable while the device is
    /// locked, so any background DB access (BLE wake, push, background refresh)
    /// page-faults the mmap'd page into an uncatchable
    /// `EXC_BAD_ACCESS (SIGBUS) / FS pagein error: Operation not permitted` —
    /// the top TestFlight crash (issue #132). `...UntilFirstUserAuthentication`
    /// keeps the bytes encrypted at rest (protected until the first unlock after
    /// boot) while staying readable for the rest of the session, including
    /// locked background wakes. The DB is also independently SQLCipher-encrypted,
    /// so confidentiality never relied on this class. Matches Signal-iOS's GRDB
    /// store, which uses the same class for exactly this reason.
    private static let dbFileProtection: FileProtectionType = .completeUntilFirstUserAuthentication

    /// (Re)apply `dbFileProtection` to the DB directory and every file already in
    /// it — the SQLite store plus its `-wal`/`-shm`/`-journal` sidecars and the
    /// `.sonar-index.db` set. The directory attribute sets the default for files
    /// SQLite creates later; the per-file pass heals installs whose files an
    /// older build wrote with `.complete`, in place and without a reinstall.
    /// Best-effort: the rewrite only lands while data is accessible (foreground,
    /// or unlocked). On a locked background wake it silently no-ops, so the heal
    /// alone is not enough — `databaseConfig()` gates the open on
    /// `databaseIsBackgroundSafe(_:)` so a still-`.complete` store is never opened
    /// while locked.
    private static func applyDatabaseProtection(to dir: URL) {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any] = [.protectionKey: dbFileProtection]
        try? fm.setAttributes(attrs, ofItemAtPath: dir.path)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? fm.setAttributes(attrs, ofItemAtPath: file.path)
        }
    }

    /// Whether the on-disk store is safe to open during locked background work —
    /// i.e. no DB file is still `NSFileProtectionComplete`. Opening a `.complete`
    /// WAL store while the device is locked is exactly what SIGBUSes (#132), so
    /// when the heal in `applyDatabaseProtection(_:)` could not run (locked wake),
    /// we must defer rather than open.
    ///
    /// - A fresh install (no DB file yet) is safe: the directory default pins the
    ///   class on the files SQLite is about to create.
    /// - An existing store we cannot even enumerate is unsafe — that only happens
    ///   for a `.complete` directory while locked on a real device — so defer.
    /// - Otherwise unsafe only if a file is explicitly a lock-while-locked class
    ///   (`.complete`/`.completeUnlessOpen`). A nil/absent class means no Data
    ///   Protection is in force (e.g. the Simulator, which reports no
    ///   protectionKey, and the bench harness that runs there) — safe to open.
    ///   The protection CLASS is file metadata and stays readable while locked, so
    ///   a real-device pre-migration `.complete` store is still caught here.
    private static func databaseIsBackgroundSafe(_ dbURL: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dbURL.path) { return true }
        guard let files = try? fm.contentsOfDirectory(
            at: dbURL.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ) else {
            return false
        }
        let locksWhileLocked: [FileProtectionType] = [.complete, .completeUnlessOpen]
        for file in files {
            if let prot = (try? fm.attributesOfItem(atPath: file.path))?[.protectionKey] as? FileProtectionType,
               locksWhileLocked.contains(prot) {
                return false
            }
        }
        return true
    }
    #endif

    /// Absolute path of the encrypted Marmot database. The parent dir and any
    /// existing DB files are pinned to `dbFileProtection` so the store stays
    /// readable during locked background work (see `dbFileProtection`).
    private static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent(dbDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(iOS)
        applyDatabaseProtection(to: dir)
        #endif
        return dir.appendingPathComponent(dbFileName)
    }

    /// (path, 64-char hex key). Generates and persists a fresh key the first time.
    private static func databaseConfig() throws -> (String, String) {
        let url = try databaseURL()
        #if DEBUG
        // SONAR_BENCH: derive a STABLE db key from the env identity so the
        // encrypted DB persists across cold-start runs without Keychain. Unsigned
        // simulator builds have no keychain entitlement (errSecMissingEntitlement),
        // which would otherwise block the whole Marmot relay-sync path.
        if let benchNsec = ProcessInfo.processInfo.environment["SONAR_BENCH_NSEC"], !benchNsec.isEmpty {
            let keyHex = SHA256.hash(data: Data(benchNsec.utf8)).map { String(format: "%02x", $0) }.joined()
            return (url.path, keyHex)
        }
        #endif
        #if os(iOS)
        // An older build may have left the store as NSFileProtectionComplete. The
        // heal in databaseURL() only lands while data is accessible; on a locked
        // background wake it no-ops, yet the AfterFirstUnlock DB key is still
        // readable — so without this gate we would open the still-`.complete`
        // WAL/`-shm` and hit the very SIGBUS this fixes (#132). Defer instead; a
        // later foreground/unlocked launch migrates the files and proceeds.
        guard Self.databaseIsBackgroundSafe(url) else {
            throw ServiceError.core("Marmot DB still NSFileProtectionComplete (locked wake, pre-migration) — deferring open to avoid SIGBUS")
        }
        #endif
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
    func wipeDatabase() async throws {
        let url = try Self.databaseURL()
        await runNonThrowing { service in
            service.sessionGeneration = service.sessionGeneration &+ 1
            #if os(iOS)
            SonarPushRegistration.shared.clearSonarNode()
            #endif
            service.nodeLock.lock()
            service.nodeClosing = true
            service.node = nil
            service.relayConnected = false
            service.nodeLock.unlock()
            service.identity = nil
            return ()
        }
        // Do not block workQueue while draining: an off-queue relay connect may
        // need that queue once to reject its stale generation and release its
        // lease. New leases are already rejected by `nodeClosing`.
        await withCheckedContinuation { continuation in
            nodeLifecycleGroup.notify(queue: workQueue) {
                continuation.resume()
            }
        }
        try await run { service in
            defer {
                service.nodeLock.lock()
                service.nodeClosing = false
                service.nodeLock.unlock()
            }
            try wipeMarmotDatabase(dbPath: url.path)
            guard KeychainManager().deleteIdentityKey(forKey: Self.dbKeychainKey) else {
                throw ServiceError.core("failed to delete Marmot database key")
            }
            return ()
        }
    }

    private func connectNode(
        identity: SonarIdentity,
        relayUrls: [String],
        dbPath: String,
        dbKeyHex: String
    ) async throws -> (SonarNode, NodeLifecycleLease) {
        try await withCheckedThrowingContinuation { continuation in
            nodeLock.lock()
            guard !nodeClosing else {
                nodeLock.unlock()
                continuation.resume(throwing: ServiceError.cancelled)
                return
            }
            let lease = NodeLifecycleLease(group: nodeLifecycleGroup)
            relayConnectQueue.async {
                do {
                    // Diagnostics file sink must exist before the node spins
                    // up so relay connect/EOSE/watermark events are captured.
                    SonarDiagnostics.installCoreLoggingIfNeeded()
                    let node = try SonarNode.connect(
                        identity: identity,
                        relayUrls: relayUrls,
                        dbPath: dbPath,
                        dbKeyHex: dbKeyHex
                    )
                    continuation.resume(returning: (node, lease))
                } catch let error as SonarFfiError {
                    lease.release()
                    switch error {
                    case .InvalidInput(let message):
                        continuation.resume(throwing: ServiceError.invalidInput(message))
                    case .Core(let message):
                        continuation.resume(throwing: ServiceError.core(message))
                    }
                } catch {
                    lease.release()
                    continuation.resume(throwing: error)
                }
            }
            nodeLock.unlock()
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
        var remaining = timeoutSeconds
        while remaining > 0 && !Task.isCancelled {
            let slice = min(remaining, 1)
            do {
                let event: CallEventInfo? = try await leasedNodeOperation(
                    on: callWaitQueue,
                    requireRelay: true
                ) { node in
                    node.callWaitEvent(timeoutSecs: slice)
                }
                if let event { return event }
            } catch {
                try? await Task.sleep(nanoseconds: slice * 1_000_000_000)
            }
            remaining -= slice
        }
        return nil
    }

    /// Run a blocking call op on `queue`, with the node grabbed race-free on the
    /// engine queue, mapping Rust errors like `run`.
    private func runCall<T: Sendable>(
        _ queue: DispatchQueue,
        _ body: @escaping @Sendable (SonarNode) throws -> T
    ) async throws -> T {
        try await leasedNodeOperation(on: queue, body)
    }

    // MARK: - Conversation index (Signal-style summary table)

    func conversationSummaries() async -> [ConversationSummary] {
        await readOnlyNonThrowing({ node in
            node.conversationSummaries().map {
                ConversationSummary(
                    groupIdHex: $0.groupIdHex,
                    name: $0.name,
                    latestContent: $0.latestContent,
                    latestSenderNpub: $0.latestSenderNpub,
                    latestAt: Date(timeIntervalSince1970: TimeInterval($0.latestAtSecs)),
                    latestMine: $0.latestMine,
                    messageCount: $0.messageCount,
                    unreadCount: $0.unreadCount
                )
            }
        }, default: [])
    }

    func markConversationRead(groupId: String) async {
        await runNonThrowing { service in
            service.node?.markConversationRead(groupIdHex: groupId)
            return ()
        }
    }

    func messagesCursorPage(
        groupId: String,
        beforeSecs: UInt64? = nil,
        beforeIdHex: String? = nil,
        limit: UInt32
    ) async throws -> [MarmotMessage] {
        try await readOnly {
            try $0.messagesCursorPage(
                    groupIdHex: groupId,
                    beforeSecs: beforeSecs,
                    beforeIdHex: beforeIdHex,
                    limit: limit
                )
                .map(Self.marmotMessage)
        }
    }

    private func installConversationListener(on node: SonarNode) {
        let subject = conversationChanged
        node.setConversationChangeListener(listener: MarmotConversationListener(subject: subject))
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

    /// Read-only FFI calls on the concurrent queue. Never use for MLS-mutating
    /// operations. The node is an Arc (thread-safe ref-counted pointer from
    /// Rust via UniFFI), so reading it under a lock and calling methods on it
    /// from the concurrent queue is safe. This never blocks behind serial
    /// workQueue tasks.
    private let nodeLock = NSLock()
    private let nodeLifecycleGroup = DispatchGroup()
    private var nodeClosing = false

    private func leasedNodeOperation<T: Sendable>(
        on queue: DispatchQueue,
        requireRelay: Bool = false,
        _ body: @escaping @Sendable (SonarNode) throws -> T
    ) async throws -> T {
        let cancellation = OperationCancellation()
        return try await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else { throw ServiceError.cancelled }
            let result: T = try await withCheckedThrowingContinuation { continuation in
                // Snapshot + lease reservation is atomic with the wipe's close.
                nodeLock.lock()
                guard !cancellation.isCancelled else {
                    nodeLock.unlock()
                    continuation.resume(throwing: ServiceError.cancelled)
                    return
                }
                guard !nodeClosing, let nodeRef = node, !requireRelay || relayConnected else {
                    nodeLock.unlock()
                    continuation.resume(throwing: ServiceError.notConnected)
                    return
                }
                let lease = NodeLifecycleLease(group: nodeLifecycleGroup)
                queue.async {
                    defer { lease.release() }
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: ServiceError.cancelled)
                        return
                    }
                    do {
                        continuation.resume(returning: try body(nodeRef))
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
                nodeLock.unlock()
            }
            guard !Task.isCancelled else { throw ServiceError.cancelled }
            return result
        }, onCancel: {
            cancellation.cancel()
        })
    }

    private func readOnly<T: Sendable>(_ body: @escaping @Sendable (SonarNode) throws -> T) async throws -> T {
        try await leasedNodeOperation(on: readQueue, body)
    }

    /// Text/sticker sends on the dedicated serial send lane. Same leased node
    /// snapshot as `readOnly`; MLS-mutation ordering against sync/drain is the
    /// core engine's `write_lock` responsibility.
    private func sendLane<T: Sendable>(_ body: @escaping @Sendable (SonarNode) throws -> T) async throws -> T {
        try await leasedNodeOperation(on: sendQueue, body)
    }

    /// Live receive drain on the dedicated serial drain lane. Must not share
    /// `workQueue` with blocking `syncForce` (see `drainQueue` doc).
    private func drainLane<T: Sendable>(_ body: @escaping @Sendable (SonarNode) throws -> T) async throws -> T {
        try await leasedNodeOperation(on: drainQueue, body)
    }

    private func readOnlyNonThrowing<T: Sendable>(_ body: @escaping @Sendable (SonarNode) -> T, default defaultValue: T) async -> T {
        (try? await leasedNodeOperation(on: readQueue, body)) ?? defaultValue
    }
}

private final class MarmotConversationListener: ConversationChangeListener, @unchecked Sendable {
    private let subject: PassthroughSubject<String, Never>

    init(subject: PassthroughSubject<String, Never>) {
        self.subject = subject
    }

    func onConversationChanged(groupIdHex: String) {
        subject.send(groupIdHex)
    }
}
