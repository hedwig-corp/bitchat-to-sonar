//
// MarmotService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
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

/// Soft-try result for Blossom Marmot backup restore during nsec import.
enum AccountBackupRestoreOutcome: Equatable, Sendable {
    case restored
    case missing
    case failed
    /// The pasted key is the one already signed in — nothing was wiped,
    /// downloaded, or replaced. Distinct from `restored`: there is no backup
    /// involved and no toast to show, because nothing happened.
    case unchanged
}

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
        /// NIP-C7 reply pointer. Content is already the display body.
        let reply: MarmotReplyRef?

        init(
            id: String,
            senderNpub: String,
            content: String,
            createdAt: Date,
            isMine: Bool,
            deliveryState: String? = nil,
            media: [MarmotMedia],
            stickerRef: MarmotStickerRef? = nil,
            classification: MarmotMessageClass = .text,
            reply: MarmotReplyRef? = nil
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
            self.reply = reply
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
            case reply
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
            self.reply = try container.decodeIfPresent(MarmotReplyRef.self, forKey: .reply)
        }
    }

    struct MarmotReplyRef: Sendable, Equatable, Codable {
        let parentId: String
        let parentNpub: String?
        let preview: String?
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
    struct SonarDescriptor: Sendable, Equatable, Codable {
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
        /// Settings → Backup chats re-entry while an upload is already sealing.
        case backupAlreadyInProgress
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
    /// cooperative pool. Text/stickers run on `sendQueue`, Blossom media on
    /// `mediaQueue`, and live `drainPending` on `drainQueue` — none of those
    /// share this lane (each sync can park it for a 10s relay timeout). Same
    /// shape as Android: lifecycle serialization only; sync/drain hop
    /// independently.
    private let workQueue = DispatchQueue(label: "chat.bitchat.marmot-service", qos: .userInitiated)

    /// Serial send lane for text/sticker sends: they must stay ordered with
    /// each other, but must never FIFO-queue behind sync relay quorum
    /// fetches on `workQueue` (each can park it for a 10s timeout — the
    /// documented 6.6s p95 / 19.3s max send dispatch tail) **or** behind a
    /// multi-minute Blossom PUT on `mediaQueue`. The core engine serializes
    /// MLS mutations internally (`MarmotEngine::write_lock`), so a send here
    /// runs concurrently with an in-flight sync/upload and waits at most for
    /// one in-flight MLS mutation, never for a relay fetch or Blossom PUT.
    /// Same intent as Signal keeping plain text off a stuck media send path.
    private let sendQueue = DispatchQueue(label: "chat.bitchat.marmot-send", qos: .userInitiated)

    /// Serial Blossom media lane. Encrypt+PUT can take minutes — must not park
    /// text on `sendQueue` or sync on `workQueue` (Android keeps media off
    /// `marmotSendMutex`; Signal isolates upload work from sync/text runners).
    /// Host-lane isolation only: encrypt→Blossom→outbox still runs as one
    /// UniFFI `block_on` (not a separate AttachmentUploadJob). Resume shares
    /// this lane so reconnect resume cannot FIFO-block composer text; new
    /// uploads serialize with resume (core `try_claim_media_upload` still
    /// guards double-work). Serial-by-design vs Compose’s overlapping IO —
    /// tradeoff for UniFFI `block_on` + resume ordering.
    private let mediaQueue = DispatchQueue(label: "chat.bitchat.marmot-media", qos: .userInitiated)

    /// Serial receive/drain lane (Android `Dispatchers.IO` parity for drain).
    /// Must never FIFO-queue behind blocking UniFFI `syncForce` on
    /// `workQueue` — that was the ~10s banner→UI lag. Core `write_lock`
    /// serializes MLS mutations; drain waits at most for one in-flight
    /// mutation, never for a relay quorum fetch.
    private let drainQueue = DispatchQueue(label: "chat.bitchat.marmot-drain", qos: .userInitiated)

    /// Serial identity-publish lane: KeyPackage (kind 30443) and our own
    /// kind-0 profile, plus the self-profile relay fetch that gates the
    /// republish.
    ///
    /// These used to run through `run { }` on `workQueue` — the SAME serial
    /// lane as `sync`/`syncForce` — so on a cold start every per-relay
    /// publish and the self-profile fetch (each parkable for the core's ~10s
    /// timeout) sat between relay-connect and the sync work that produces the
    /// first drain. On a 43-group account that showed up as a 25-57s
    /// `t3→t3a` in the cold-start benchmark (#265): not the publishes being
    /// slow so much as them holding the queue the drain needs. They are pure
    /// relay I/O and touch no MLS state, so a lane of their own costs nothing
    /// and takes them off the critical path — same reasoning that gave send,
    /// media and drain their own lanes.
    private let publishQueue = DispatchQueue(label: "chat.bitchat.marmot-publish", qos: .utility)

    /// Membership approvals can include a bounded relay fetch plus commit and
    /// Welcome publication. Keep that network wait off `workQueue` so sync,
    /// reconnect, and unrelated group operations remain responsive. The Rust
    /// core's membership gate + MLS write lock preserve mutation ordering.
    private let membershipQueue = DispatchQueue(label: "chat.bitchat.marmot-membership", qos: .userInitiated)

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

    // Identity is guarded by `identityLock` so export/npub reads never
    // FIFO-wait behind sync/connect on `workQueue`. Node/relay connection
    // state is guarded by `nodeLock` so read-only transfers can snapshot it.
    private let identityLock = NSLock()
    private var identity: SonarIdentity?
    private var node: SonarNode?
    private var relayConnected = false
    /// Bumped by `invalidateRelayConnection()` so an attach that began before a
    /// background suspension cannot latch `relayConnected` when it completes.
    private var relayEpoch: UInt64 = 0
    private var sessionGeneration: UInt64 = 0
    #if os(iOS)
    /// Cross-process exclusive lock — held while `node` is open so the NSE
    /// cannot open the shared SQLCipher store concurrently.
    private var storeLock: MarmotStoreLock?
    #endif

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
            } else if let existing = service.snapshotIdentity() {
                identity = existing
            } else {
                identity = SonarIdentity.generate()
            }
            service.setIdentity(identity)
            service.sessionGeneration = service.sessionGeneration &+ 1
            return (identity, service.sessionGeneration)
        }
        // Snapshot the relay epoch before the long attach: a background
        // invalidate landing mid-connect must win over this connect's latch.
        nodeLock.lock()
        let attachEpoch = relayEpoch
        nodeLock.unlock()
        let (dbPath, dbKeyHex) = try Self.databaseConfig()
        // The lease and the latch are taken BEFORE the store lock, and the lease
        // is released only when this whole function unwinds. Both boundaries
        // matter for the close: the lease used to start inside `connectNode` and
        // end in its error path, so a failing connect could release it — letting
        // `closeNode()` return and `endBackgroundTask` fire — while this function
        // had not yet reached `abandonStoreLockHold`. iOS then suspends us
        // holding the App Group flock, which is the same kill by a narrower
        // margin. Latching the connect makes that failure the COMMON case, so
        // the window has to be closed in the same change.
        let connectLatch = try registerPendingConnectLatch()
        let connectLease = NodeLifecycleLease(group: nodeLifecycleGroup)
        defer {
            clearPendingConnectLatch(connectLatch)
            connectLease.release()
        }
        #if os(iOS)
        // Reuse connectLocal's lock when present — a second blocking flock on a
        // new fd deadlocks the same process on Darwin (EWOULDBLOCK / hang).
        let storeLockHold = try await prepareStoreLockForConnect()
        #endif
        let node: SonarNode
        do {
            // Cheap recheck: the flock acquire above runs on `workQueue` and can
            // itself take time, so a suspend landing during it should not go on
            // to open SQLCipher.
            guard !connectLatch.isInterrupted() else { throw ServiceError.cancelled }
            node = try await connectNode(
                identity: identity,
                relayUrls: relayUrls,
                dbPath: dbPath,
                dbKeyHex: dbKeyHex,
                suspendLatch: connectLatch
            )
        } catch {
            #if os(iOS)
            abandonStoreLockHold(storeLockHold)
            #endif
            throw error
        }
        let installed = await runNonThrowing { service in
            guard service.sessionGeneration == generation,
                  service.snapshotIdentity()?.npub() == identity.npub()
            else {
                return false
            }
            service.setIdentity(identity)
            service.nodeLock.lock()
            // A close/wipe already fenced this session. Checking `nodeClosing`
            // (not just `sessionGeneration`) is required: the generation is
            // bumped in the close's OWN `workQueue` hop, which is queued behind
            // this one, so it still reads as current here. Installing anyway
            // would publish an un-latched node to `SonarPushRegistration`,
            // whose blocking `registerPushToken` holds the SQLCipher handle
            // outside `nodeLifecycleGroup` and past the close (0xdead10cc).
            //
            // The check and the assignment MUST stay in this single `nodeLock`
            // hold. Releasing between them lets `interruptNodeForSuspend()` run
            // in the gap — it would set `nodeClosing` and latch only the OLD
            // node, and this closure would then install the fresh one anyway.
            // The close hop's `removedNode?.interruptForSuspend()` does catch
            // that, but only after `setSonarNode` may already have handed the
            // node to a registration thread the close never waits for, while
            // `storeLock` has been released — so the SQLCipher handle can
            // outlive the close and overlap NSE access to the same store.
            guard !service.nodeClosing else {
                service.nodeLock.unlock()
                return false
            }
            service.node = node
            service.relayConnected = RelayConnectionPolicy.latchAfterAttach(
                startEpoch: attachEpoch,
                currentEpoch: service.relayEpoch
            )
            #if os(iOS)
            service.installStoreLockHold(storeLockHold)
            #endif
            service.nodeLock.unlock()
            service.installConversationListener(on: node)
            #if os(iOS)
            SonarPushRegistration.shared.setSonarNode(node)
            #endif
            return true
        }
        guard installed else {
            #if os(iOS)
            abandonStoreLockHold(storeLockHold)
            #endif
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
            } else if let existing = service.snapshotIdentity() {
                identity = existing
            } else {
                identity = SonarIdentity.generate()
            }
            let (dbPath, dbKeyHex) = try Self.databaseConfig()
            SonarDiagnostics.installCoreLoggingIfNeeded()
            #if os(iOS)
            let storeLockHold = try service.prepareStoreLockForConnectSync()
            #endif
            let node: SonarNode
            do {
                // Deliberately NOT latched — see R-031 for the full trade. With
                // no relays there is nothing to await, so a latch could not
                // abort anything here; it could only *refuse to start*, one
                // checkpoint later than the `nodeClosing` guard above. That
                // refusal is the expensive part: a suspend landing during an
                // nsec restore would fail `performConnect()`, and
                // `restoreIdentity`'s `guard … else` rolls back through
                // `wipeDatabase()`. A plain `nodeClosing` re-check here would
                // cost exactly the same, so this is not about the latch.
                node = try SonarNode.connect(
                    identity: identity,
                    relayUrls: [],
                    dbPath: dbPath,
                    dbKeyHex: dbKeyHex,
                    suspendLatch: nil
                )
            } catch {
                #if os(iOS)
                service.abandonStoreLockHold(storeLockHold)
                #endif
                throw error
            }
            service.setIdentity(identity)
            service.nodeLock.lock()
            // Same atomic fence as the relay install path: `connectLocal`
            // checked `nodeClosing` before opening, but `SonarNode.connect`
            // opens SQLCipher in between, and a close/wipe can fence during
            // that window. Installing anyway hands the fresh node to
            // `setSonarNode`, whose push registration retains the handle after
            // the close releases `storeLock` — the NSE-overlap hazard, not just
            // a background kill. Dropping `node` on the bail path closes the
            // handle; the store lock hold has to be abandoned explicitly.
            guard !service.nodeClosing else {
                service.nodeLock.unlock()
                #if os(iOS)
                service.abandonStoreLockHold(storeLockHold)
                #endif
                throw ServiceError.cancelled
            }
            service.node = node
            service.relayConnected = false
            #if os(iOS)
            service.installStoreLockHold(storeLockHold)
            #endif
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
            } else if let existing = service.snapshotIdentity() {
                identity = existing
            } else {
                identity = SonarIdentity.generate()
            }
            service.setIdentity(identity)
            service.sessionGeneration = service.sessionGeneration &+ 1
            return identity.npub()
        }
    }

    /// `npub1...` of the connected identity (nil before `connect`).
    /// Offline-derivable — must not wait on `workQueue` sync/connect.
    func currentNpub() async -> String? {
        snapshotIdentity()?.npub()
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

    /// Clear the host-side relay latch so the next `connect()` rebuilds sockets.
    /// Background suspension / doze can tear down websockets while this flag
    /// stays true; push wakes then skip reconnect and sync against a dead node
    /// (killed-app works because a fresh process starts with the latch false).
    func invalidateRelayConnection() {
        nodeLock.lock()
        relayEpoch = relayEpoch &+ 1
        relayConnected = RelayConnectionPolicy.afterInvalidate()
        nodeLock.unlock()
    }

    /// `nsec1...` backup export of the connected identity (nil before `connect`).
    /// Handle with care; intended for user-driven backup only.
    /// Offline-derivable — must not wait on `workQueue` sync/connect (Settings
    /// → Export private key; Compose reads secrets synchronously).
    func exportNsec() async -> String? {
        snapshotIdentity()?.nsec()
    }

    private func snapshotIdentity() -> SonarIdentity? {
        identityLock.lock()
        defer { identityLock.unlock() }
        return identity
    }

    private func setIdentity(_ newValue: SonarIdentity?) {
        identityLock.lock()
        defer { identityLock.unlock() }
        identity = newValue
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
        try await publishLane { try $0.publishKeyPackageBackground() }
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
        try await publishLane { try $0.publishProfileBackground(name: name, about: about, picture: picture) }
    }

    /// Fetch a peer's kind-0 profile (npub or hex). nil if they have none.
    /// Our OWN kind-0, fetched on the publish lane: it gates the profile
    /// republish, so it belongs with the publishes and off `workQueue` (#265).
    /// Peer profile fetches keep using `fetchProfile` — they are driven by UI
    /// hydration, not by the cold-start publish chain.
    func fetchOwnProfile(npub: String) async throws -> Profile? {
        try await publishLane {
            try $0.fetchProfile(npub: npub).map {
                Profile(name: $0.name, displayName: $0.displayName, about: $0.about, picture: $0.picture, nip05: $0.nip05)
            }
        }
    }

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
        try await membershipLane {
            try $0.approveJoinRequest(groupIdHex: groupId, requesterNpub: requesterNpub)
        }
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

    func sendTextReply(
        groupId: String,
        text: String,
        replyToHex: String,
        replyToNpub: String,
        preview: String?
    ) async throws {
        try await sendLane {
            try $0.sendTextReply(
                groupIdHex: groupId,
                text: text,
                replyToHex: replyToHex,
                replyToNpub: replyToNpub,
                preview: preview
            )
        }
    }

    /// Republish one failed message from the durable local outbox.
    func retryMessage(messageId: String) async throws -> String {
        try await run {
            try $0.requireNode().retryMessage(messageIdHex: messageId)
        }
    }

    /// Encrypt `data`, upload the ciphertext to a Blossom server, and publish a
    /// media message to the group. `serverUrl` empty → the core default.
    ///
    /// Uses `mediaLane` (not `workQueue` / `sendLane`): Blossom PUTs can take
    /// minutes and must not FIFO-block sync or text/sticker sends — Android
    /// media-off-`marmotSendMutex` host isolation (not full Signal job-split).
    func sendMedia(
        groupId: String,
        data: Data,
        filename: String,
        mime: String,
        caption: String,
        serverUrl: String = ""
    ) async throws {
        try await mediaLane {
            try $0.sendMedia(
                groupIdHex: groupId,
                data: data,
                filename: filename,
                mime: mime,
                caption: caption,
                serverUrl: serverUrl
            )
        }
    }

    /// Like `sendMedia`, with Blossom upload progress for the optimistic bubble.
    func sendMediaWithProgress(
        groupId: String,
        data: Data,
        filename: String,
        mime: String,
        caption: String,
        clientPendingId: String,
        listener: MediaUploadListener,
        serverUrl: String = ""
    ) async throws {
        try await mediaLane {
            try $0.sendMediaWithProgress(
                groupIdHex: groupId,
                data: data,
                filename: filename,
                mime: mime,
                caption: caption,
                serverUrl: serverUrl,
                clientPendingId: clientPendingId,
                listener: listener
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
        serverUrl: String = ""
    ) async throws {
        try await mediaLane {
            try $0.sendMediaMulti(
                groupIdHex: groupId,
                items: items.map {
                    MediaUploadItem(data: $0.data, filename: $0.filename, mime: $0.mime)
                },
                caption: caption,
                serverUrl: serverUrl
            )
        }
    }

    /// Like `sendMediaMulti`, with aggregated album upload progress.
    func sendMediaMultiWithProgress(
        groupId: String,
        items: [MediaAlbumItem],
        caption: String,
        clientPendingId: String,
        listener: MediaUploadListener,
        serverUrl: String = ""
    ) async throws {
        try await mediaLane {
            try $0.sendMediaMultiWithProgress(
                groupIdHex: groupId,
                items: items.map {
                    MediaUploadItem(data: $0.data, filename: $0.filename, mime: $0.mime)
                },
                caption: caption,
                serverUrl: serverUrl,
                clientPendingId: clientPendingId,
                listener: listener
            )
        }
    }

    /// Resume durable pre-Blossom media staging after disconnect/kill.
    /// On `mediaLane` so a multi-minute Blossom resume cannot park `workQueue`
    /// (sync) or `sendLane` (text/stickers).
    @discardableResult
    func resumePendingMediaUploads() async throws -> UInt32 {
        try await mediaLane {
            try $0.resumePendingMediaUploadsQuiet()
        }
    }

    /// Cooperative cancel for quiet resume / Blossom work (stopPolling, wipe).
    /// Must not wait on `mediaLane` — that is the work being cancelled.
    func cancelAllMediaUploads() {
        nodeLock.lock()
        let nodeRef = node
        nodeLock.unlock()
        nodeRef?.cancelAllMediaUploads()
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

    /// Reload the durable outbox and republish pending/failed sends. Called
    /// after relay connect (not on the active-chat wake path — that would
    /// restack in-flight Pending). Core auto-retries Failed after publish
    /// failure; idle `ensureSubscriptions` also flushes the outbox.
    func retryOutbox() async throws {
        try await run { try $0.requireNode().retryOutbox() }
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
            classification: Self.marmotMessageClass(message.classification),
            reply: message.reply.map {
                MarmotReplyRef(
                    parentId: $0.parentIdHex,
                    parentNpub: $0.parentNpub,
                    preview: $0.preview
                )
            }
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

    /// Absolute path of the encrypted Marmot database. On iOS this lives in the
    /// App Group container (shared with the Notification Service Extension);
    /// macOS keeps Application Support. Parent dir and existing DB files are
    /// pinned to `dbFileProtection` so the store stays readable during locked
    /// background work (see `dbFileProtection`).
    private static func databaseURL() throws -> URL {
        let dir = try MarmotAppGroupStore.databaseDirectory()
        #if os(iOS)
        applyDatabaseProtection(to: dir)
        #endif
        return dir.appendingPathComponent(MarmotAppGroupStore.dbFileName)
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
            try? reconcileAccountRestore(dbPath: url.path, dbKeyHex: keyHex)
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
        // Resume an interrupted stage→persist→commit (crash after key write).
        // Wrong/orphan staging is aborted so connect never pairs ciphertext with
        // a minted key. If staging remains after a reconcile error, refuse open.
        do {
            _ = try reconcileAccountRestore(dbPath: url.path, dbKeyHex: keyHex)
        } catch {
            if accountRestoreStagingPresent(dbPath: url.path) {
                throw ServiceError.core(
                    "account restore staging present after reconcile failure — refusing connect"
                )
            }
            SecureLogger.warning(
                "⚠️ Account restore reconcile failed: \(error.localizedDescription)",
                category: .session
            )
        }
        return (url.path, keyHex)
    }

    /// Fence new node installs, then flip the live node's one-way suspend latch
    /// so interruptible relay FFI parked on `workQueue` returns instead of
    /// blocking the close hop. Safe from any thread; no-op when disconnected.
    ///
    /// The fence and the snapshot MUST happen under one `nodeLock` hold, and
    /// the fence MUST be set here rather than in the caller's `workQueue` hop.
    /// A relay connect that finished just before this runs has already enqueued
    /// its install closure, and `workQueue` is FIFO — so that closure runs
    /// *first*, before the close hop that bumps `sessionGeneration`. Without
    /// the fence it installs a brand-new node this call never latched, hands it
    /// to `SonarPushRegistration.setSonarNode`, and that kicks a blocking
    /// `registerPushToken` on the global utility queue which holds a strong
    /// `SonarNode` **outside** `nodeLifecycleGroup` — so the close cannot wait
    /// for it and the SQLCipher handle outlives the close. That is the exact
    /// 0xdead10cc shape this whole path exists to prevent.
    ///
    /// `nodeClosing` is cleared again by `closeNode(keepClosed: false)` and by
    /// `wipeDatabase()`, so fencing early only widens the window in which new
    /// leases and installs are refused — which is what a close wants anyway.
    ///
    /// The pending-connect latch is flipped in the SAME snapshot as the node. A
    /// connect between `registerPendingConnectLatch()` and installing its node
    /// has an open SQLCipher store and no `node` for `interruptForSuspend()` to
    /// reach — that is the whole of R-031 — and the `nodeClosing` fence alone
    /// cannot help, because that connect is already past its guard and parked in
    /// uncancellable Rust.
    private func interruptNodeForSuspend() {
        nodeLock.lock()
        nodeClosing = true
        let liveNode = node
        let pendingLatches = pendingConnectLatches
        nodeLock.unlock()
        liveNode?.interruptForSuspend()
        pendingLatches.forEach { $0.interrupt() }
    }

    /// Panic-wipe: drop the open node, erase the encrypted database (and its
    /// SQLite sidecars), and forget the Keychain DB key. Idempotent.
    /// Resolves wipe targets from fixed App Group + legacy roots — never via
    /// `databaseURL()` / `databaseDirectory()` (those migrate before open).
    func wipeDatabase() async throws {
        var wipePaths: [String] = []
        if let shared = MarmotAppGroupStore.existingSharedDatabaseURL() {
            wipePaths.append(shared.path)
        }
        #if os(iOS)
        if let legacyDir = MarmotAppGroupStore.legacyApplicationSupportDirectory() {
            let legacyDb = legacyDir.appendingPathComponent(MarmotAppGroupStore.dbFileName)
            if FileManager.default.fileExists(atPath: legacyDb.path) {
                wipePaths.append(legacyDb.path)
            }
        }
        #endif
        // Same reason as `closeNode()`: the close hop below must not queue
        // behind blocking relay FFI already parked on the serial `workQueue`.
        interruptNodeForSuspend()
        await runNonThrowing { service in
            service.sessionGeneration = service.sessionGeneration &+ 1
            #if os(iOS)
            SonarPushRegistration.shared.clearSonarNode()
            #endif
            service.nodeLock.lock()
            service.nodeClosing = true
            let removedNode = service.node
            // Not cleared: the connect that registered each one owns that.
            // Latching a stale entry is harmless — they are one-way and their
            // connect is gone.
            let pendingLatches = service.pendingConnectLatches
            service.node = nil
            service.relayConnected = false
            #if os(iOS)
            service.storeLock?.release()
            service.storeLock = nil
            #endif
            service.nodeLock.unlock()
            // Belt and braces for the node actually being dropped: the fence in
            // `interruptNodeForSuspend()` should mean this is the same node we
            // already latched, but any future install path that skips the fence
            // would otherwise leave a live, un-latched node whose blocking FFI
            // keeps the SQLCipher handle open past this close. Idempotent.
            removedNode?.interruptForSuspend()
            pendingLatches.forEach { $0.interrupt() }
            service.setIdentity(nil)
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
            for path in wipePaths {
                try wipeMarmotDatabase(dbPath: path)
            }
            // Drop directory roots (sidecars, empty dirs) without remigrating.
            // Must succeed before Keychain db-key delete — a surviving store with
            // a missing key is unrecoverable.
            do {
                try MarmotAppGroupStore.removeAllStoreFiles()
            } catch {
                throw ServiceError.core(error.localizedDescription)
            }
            guard KeychainManager().deleteIdentityKey(forKey: Self.dbKeychainKey) else {
                throw ServiceError.core("failed to delete Marmot database key")
            }
            return ()
        }
    }

    /// Drop the live `SonarNode` so DB files can be read/replaced. Does not
    /// delete files or the Keychain DB key. When `keepClosed` is true, leaves
    /// `nodeClosing` set so reconnect cannot race the following FFI work;
    /// caller must clear it (via another `closeNode(keepClosed: false)` path
    /// or by completing connect after clearing).
    func closeNode(keepClosed: Bool = false) async {
        // Abort interruptible in-flight relay FFI (sync, push-token
        // registration, descriptor/profile fetches) BEFORE the first hop onto
        // the serial `workQueue`: that hop — the one that drops the node and
        // releases the store lock — queues behind whatever blocking Rust is
        // already parked there, and iOS grants only ~30s of background grace.
        // An uninterrupted relay sync held the SQLCipher store past that
        // deadline on TestFlight 1.12.2 (30) → RUNNINGBOARD 0xdead10cc
        // (round 3). Cheap and thread-safe; the node is torn down right after.
        interruptNodeForSuspend()
        await runNonThrowing { service in
            service.sessionGeneration = service.sessionGeneration &+ 1
            #if os(iOS)
            SonarPushRegistration.shared.clearSonarNode()
            #endif
            service.nodeLock.lock()
            service.nodeClosing = true
            let removedNode = service.node
            // Not cleared: the connect that registered each one owns that.
            // Latching a stale entry is harmless — they are one-way and their
            // connect is gone.
            let pendingLatches = service.pendingConnectLatches
            service.node = nil
            service.relayConnected = false
            #if os(iOS)
            service.storeLock?.release()
            service.storeLock = nil
            #endif
            service.nodeLock.unlock()
            // Belt and braces for the node actually being dropped: the fence in
            // `interruptNodeForSuspend()` should mean this is the same node we
            // already latched, but any future install path that skips the fence
            // would otherwise leave a live, un-latched node whose blocking FFI
            // keeps the SQLCipher handle open past this close. Idempotent.
            removedNode?.interruptForSuspend()
            pendingLatches.forEach { $0.interrupt() }
            return ()
        }
        await withCheckedContinuation { continuation in
            nodeLifecycleGroup.notify(queue: workQueue) {
                continuation.resume()
            }
        }
        if !keepClosed {
            await runNonThrowing { service in
                service.nodeLock.lock()
                service.nodeClosing = false
                service.nodeLock.unlock()
                return ()
            }
        }
    }

    /// Clear the close fence after backup/restore FFI finishes.
    func clearNodeClosingFence() async {
        await runNonThrowing { service in
            service.nodeLock.lock()
            service.nodeClosing = false
            service.nodeLock.unlock()
            return ()
        }
    }

    /// Persist the SQLCipher key used by Marmot (host-owned). Used after a
    /// Blossom account restore so `connect` opens with the restored key.
    func persistDatabaseKey(_ dbKeyHex: String) throws {
        guard dbKeyHex.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw ServiceError.core("database key malformed — refusing to persist")
        }
        guard KeychainManager().saveIdentityKey(Data(dbKeyHex.utf8), forKey: Self.dbKeychainKey) else {
            throw ServiceError.core("failed to persist database encryption key")
        }
    }

    /// Close the node and seal DB+key (exclusive access). Clears the close
    /// fence so the caller can reconnect before uploading — chat must not wait
    /// on the Blossom RTT. Seal (checkpoint + AEAD) runs off the main actor
    /// via `runAccountBackupHostWork` / `runAccountBackupFFI` (Compose hops to
    /// `Dispatchers.IO`; mirror that here).
    func prepareSealedAccountBackup() async throws -> (nsec: String, dbPath: String, sealed: Data) {
        accountBackupLock.lock()
        if accountBackupInFlight {
            accountBackupLock.unlock()
            throw ServiceError.backupAlreadyInProgress
        }
        accountBackupInFlight = true
        accountBackupLock.unlock()
        defer {
            accountBackupLock.lock()
            accountBackupInFlight = false
            accountBackupLock.unlock()
        }

        guard let nsec = snapshotIdentity()?.nsec() else {
            throw ServiceError.core("no identity to back up")
        }

        // Hold the cross-process store lock across close+seal. The Notification
        // Service Extension is a SEPARATE PROCESS that tries this same lock
        // non-blocking and hydrates the store when it wins; if nothing holds it
        // between `closeNode` and the end of the seal it can write the SQLCipher
        // files while we checkpoint(TRUNCATE) + read them, capturing a torn
        // database. Pluck the existing hold off `storeLock` (under `nodeLock`)
        // WITHOUT releasing it so `closeNode` below sees `storeLock == nil` and
        // leaves it alone; take a fresh one when no node was open.
        #if os(iOS)
        let sealStoreLock: MarmotStoreLock = try await run { service -> MarmotStoreLock in
            service.nodeLock.lock()
            defer { service.nodeLock.unlock() }
            if let held = service.storeLock {
                service.storeLock = nil
                return held
            }
            return try MarmotStoreLock.acquireExclusive()
        }
        #endif

        await closeNode(keepClosed: true)
        do {
            let config = try await runAccountBackupHostWork {
                try Self.databaseConfig()
            }
            let sealed = try await runAccountBackupFFI {
                try sealAccountBackup(
                    nsec: nsec,
                    dbPath: config.0,
                    dbKeyHex: config.1
                )
            }
            // Release BEFORE clearing the fence: once `nodeClosing` drops,
            // reconnect runs `prepareStoreLockForConnectSync`, which on Darwin
            // takes a second LOCK_EX on a DIFFERENT fd in this same process —
            // that conflicts (EWOULDBLOCK) with a seal lock still held here and
            // would leave the Marmot store permanently closed.
            #if os(iOS)
            sealStoreLock.release()
            #endif
            await clearNodeClosingFence()
            return (nsec, config.0, sealed)
        } catch {
            #if os(iOS)
            sealStoreLock.release()
            #endif
            await clearNodeClosingFence()
            throw error
        }
    }

    /// Upload already-sealed ciphertext. Does not need a closed node.
    /// Runs off the main queue so Blossom RTT cannot freeze SwiftUI.
    @discardableResult
    func pushSealedAccountBackup(
        nsec: String,
        sealed: Data,
        blossomServer: String? = nil
    ) async throws -> AccountBackupUploadInfo {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let info = try uploadSealedAccountBackup(
                        nsec: nsec,
                        sealed: sealed,
                        blossomServer: blossomServer
                    )
                    continuation.resume(returning: info)
                } catch let error as SonarFfiError {
                    continuation.resume(throwing: Self.mapFfi(error))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Legacy one-shot seal+upload while the node stays closed (blocks until
    /// Blossom returns). Prefer prepare → reconnect → push for auto-backup.
    @discardableResult
    func uploadAccountBackup(blossomServer: String? = nil) async throws -> AccountBackupUploadInfo {
        let sealedBundle = try await prepareSealedAccountBackup()
        return try await pushSealedAccountBackup(
            nsec: sealedBundle.nsec,
            sealed: sealedBundle.sealed,
            blossomServer: blossomServer
        )
    }

    func loadBackupPolicy() throws -> BackupPolicyInfo {
        let (dbPath, _) = try Self.databaseConfig()
        return getBackupPolicy(dbPath: dbPath)
    }

    func updateBackupEnabled(_ enabled: Bool) throws {
        let (dbPath, _) = try Self.databaseConfig()
        do {
            try setBackupEnabled(dbPath: dbPath, enabled: enabled)
        } catch let error as SonarFfiError {
            throw Self.mapFfi(error)
        }
    }

    /// On-disk footprint of this account (DB, index, sidecars, media, stickers;
    /// logs excluded). Static + off-actor: it walks the directory, so it must
    /// not run on a render pass.
    static func accountStorageBytesOnDisk() throws -> UInt64 {
        let (dbPath, _) = try Self.databaseConfig()
        return accountStorageBytes(dbPath: dbPath)
    }

    /// Dry run: what a restore would bring back. The core call never stages,
    /// commits, or opens the live store, so no lock and no closeNode here —
    /// safe to run while chatting. Named `previewBackup` (not the FFI's
    /// `previewAccountBackup`) so the member cannot shadow the global and
    /// recurse.
    func previewBackup() async throws -> AccountBackupPreviewInfo {
        guard let nsec = snapshotIdentity()?.nsec() else {
            throw ServiceError.core("no identity to preview")
        }
        // Passed only to place the scratch copy in app-private storage; the
        // core never reads or writes this file during a preview.
        let (dbPath, _) = try Self.databaseConfig()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(
                        returning: try previewAccountBackup(
                            nsec: nsec,
                            dbPath: dbPath,
                            blossomServer: nil
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Settings cadence: "manual" | "daily" | "weekly".
    func updateBackupFrequency(_ frequency: String) throws {
        let (dbPath, _) = try Self.databaseConfig()
        do {
            try setBackupFrequency(dbPath: dbPath, frequency: frequency)
        } catch let error as SonarFfiError {
            throw Self.mapFfi(error)
        }
    }

    func isBackupDue() throws -> Bool {
        let (dbPath, _) = try Self.databaseConfig()
        return backupIsDue(dbPath: dbPath)
    }

    /// Record a successful upload. [sizeBytes] is the sealed blob's size — the
    /// Settings stats strip describes what was uploaded, so it comes from the
    /// bytes we actually pushed rather than a later measurement of a DB that has
    /// moved on.
    func noteBackupSuccess(sizeBytes: UInt64? = nil) throws {
        let (dbPath, dbKeyHex) = try Self.databaseConfig()
        do {
            try recordBackupSuccess(dbPath: dbPath, sizeBytes: sizeBytes, dbKeyHex: dbKeyHex)
        } catch let error as SonarFfiError {
            throw Self.mapFfi(error)
        }
    }

    func noteBackupFailure(_ message: String) throws {
        let (dbPath, _) = try Self.databaseConfig()
        do {
            try recordBackupFailure(dbPath: dbPath, error: message)
        } catch let error as SonarFfiError {
            throw Self.mapFfi(error)
        }
    }

    /// After wipe + before reconnect during nsec restore: download latest
    /// Blossom account backup if any, stage files, persist `db_key`, then
    /// commit. Missing backup is soft (`.missing`); staging/persist/network
    /// failures roll back and return `.failed` so connect never pairs restored
    /// ciphertext with a newly minted key. Identity import still proceeds.
    @discardableResult
    func tryRestoreAccountFromBlossom(
        nsec: String,
        blossomServer: String? = nil
    ) async -> AccountBackupRestoreOutcome {
        let url: URL
        do {
            url = try Self.databaseURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            SecureLogger.warning(
                "⚠️ Account backup restore skipped (db path): \(error.localizedDescription)",
                category: .session
            )
            return .failed
        }
        await closeNode(keepClosed: true)
        do {
            // Same MainActor hazard as upload: restore downloads + decrypts under
            // `runtime.block_on` and must stay off the UI thread.
            let dbKeyHex = try await runAccountBackupFFI {
                try restoreAccountFromBlossom(
                    nsec: nsec,
                    dbPath: url.path,
                    blossomServer: blossomServer
                )
            }
            do {
                try persistDatabaseKey(dbKeyHex)
                try commitAccountRestore(dbPath: url.path)
            } catch {
                // Clear the restored key only while staging is still present
                // (DB not promoted). After a successful main-DB rename, clearing
                // the key orphans live ciphertext forever.
                if accountRestoreStagingPresent(dbPath: url.path) {
                    try? abortAccountRestore(dbPath: url.path)
                    _ = KeychainManager().deleteIdentityKey(forKey: Self.dbKeychainKey)
                }
                SecureLogger.warning(
                    "⚠️ Account backup staged but key persist/commit failed — aborted: \(error.localizedDescription)",
                    category: .session
                )
                await clearNodeClosingFence()
                return .failed
            }
            await clearNodeClosingFence()
            SecureLogger.info("✅ Restored Marmot account backup from Blossom", category: .session)
            return .restored
        } catch {
            try? abortAccountRestore(dbPath: url.path)
            let msg = error.localizedDescription
            let missing = isMissingAccountBackupError(message: msg)
            SecureLogger.warning(
                missing
                    ? "⚠️ No Blossom account backup for this key"
                    : "⚠️ Blossom account backup restore failed: \(msg)",
                category: .session
            )
            await clearNodeClosingFence()
            return missing ? .missing : .failed
        }
    }

    private static func mapFfi(_ error: SonarFfiError) -> ServiceError {
        switch error {
        case .InvalidInput(let message): return .invalidInput(message)
        case .Core(let message): return .core(message)
        }
    }

    /// Dedicated lane for blocking account-backup UniFFI (`block_on` network).
    /// Kept off `workQueue` so a long upload cannot stall unrelated Marmot ops
    /// once the close fence is cleared / reconnect begins.
    private let accountBackupQueue = DispatchQueue(
        label: "chat.bitchat.marmot-account-backup",
        qos: .userInitiated
    )
    private let accountBackupLock = NSLock()
    private var accountBackupInFlight = false

    /// Hop Keychain/fs work off MainActor without FFI error remapping.
    private func runAccountBackupHostWork<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            accountBackupQueue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runAccountBackupFFI<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            accountBackupQueue.async {
                do {
                    continuation.resume(returning: try body())
                } catch let error as SonarFfiError {
                    continuation.resume(throwing: Self.mapFfi(error))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    #if os(iOS)
    /// Either reuses the lock already held (connectLocal → connect) or acquires
    /// a fresh exclusive lock. Never blocking-flocks a second fd against ourselves.
    private enum StoreLockHold {
        case reused
        case fresh(MarmotStoreLock)
    }

    private func prepareStoreLockForConnect() async throws -> StoreLockHold {
        try await run { try $0.prepareStoreLockForConnectSync() }
    }

    private func prepareStoreLockForConnectSync() throws -> StoreLockHold {
        nodeLock.lock()
        if storeLock != nil {
            nodeLock.unlock()
            return .reused
        }
        nodeLock.unlock()
        return .fresh(try MarmotStoreLock.acquireExclusive())
    }

    private func installStoreLockHold(_ hold: StoreLockHold) {
        // Caller must hold `nodeLock` when installing a fresh lock.
        switch hold {
        case .reused:
            break
        case .fresh(let lock):
            storeLock?.release()
            storeLock = lock
        }
    }

    private func abandonStoreLockHold(_ hold: StoreLockHold) {
        switch hold {
        case .reused:
            // Prior connectLocal lock stays on `storeLock`.
            break
        case .fresh(let lock):
            lock.release()
        }
    }
    #endif

    /// The caller owns the lifecycle lease and the suspend latch — see
    /// `connect()`. This function must not shorten either: the store is open
    /// from inside `SonarNode.connect` until the caller has installed the node
    /// or abandoned its store lock.
    private func connectNode(
        identity: SonarIdentity,
        relayUrls: [String],
        dbPath: String,
        dbKeyHex: String,
        suspendLatch: SonarSuspendLatch
    ) async throws -> SonarNode {
        try await withCheckedThrowingContinuation { continuation in
            nodeLock.lock()
            guard !nodeClosing else {
                nodeLock.unlock()
                continuation.resume(throwing: ServiceError.cancelled)
                return
            }
            relayConnectQueue.async {
                do {
                    // Diagnostics file sink must exist before the node spins
                    // up so relay connect/EOSE/watermark events are captured.
                    SonarDiagnostics.installCoreLoggingIfNeeded()
                    let node = try SonarNode.connect(
                        identity: identity,
                        relayUrls: relayUrls,
                        dbPath: dbPath,
                        dbKeyHex: dbKeyHex,
                        suspendLatch: suspendLatch
                    )
                    continuation.resume(returning: node)
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
    /// Suspend latch for a connect that has NOT installed its node yet.
    ///
    /// `SonarNode.connect` opens SQLCipher and then awaits the relay quorum,
    /// `subscribe_marmot` and `retry_outbox` — the store is live for all of it,
    /// but `node` is still nil, so `interruptNodeForSuspend()` has nothing to
    /// latch and `closeNode()` can only park on `nodeLifecycleGroup` until the
    /// connect returns on its own. On TestFlight 1.12.3 (31) it did not, and
    /// RunningBoard killed the process 0xdead10cc (R-031). This holds the latch
    /// the connect was handed, so the suspend hook can abort it in flight.
    /// Guarded by `nodeLock`; each entry is owned and removed by the connect
    /// that registered it, never by the close.
    ///
    /// A **collection**, not one optional, and that is load-bearing. `connect()`
    /// has no single-flight guard of its own — it relies on `relayBusy` in
    /// `MarmotChatView.connectRelaysIfNeeded`, a flag in another file that no
    /// test pins. With one slot, a second connect registering would orphan the
    /// first connect's latch while its `SonarNode.connect` still held SQLCipher
    /// open, and the orphan is unreachable forever after: that is R-031 again,
    /// reintroduced by the fix for it. Holding every in-flight latch keeps the
    /// invariant inside this file instead of depending on a caller's flag.
    private var pendingConnectLatches: [SonarSuspendLatch] = []

    /// Register a latch for a connect that is about to open the store, atomically
    /// with the close fence: either this sees `nodeClosing` and the connect never
    /// starts, or `interruptNodeForSuspend()` sees the latch and aborts it.
    /// Must be called WITHOUT `nodeLock` held.
    private func registerPendingConnectLatch() throws -> SonarSuspendLatch {
        let latch = SonarSuspendLatch()
        nodeLock.lock()
        defer { nodeLock.unlock() }
        guard !nodeClosing else { throw ServiceError.cancelled }
        pendingConnectLatches.append(latch)
        return latch
    }

    /// Identity comparison, not `removeAll()`: a concurrent connect may have
    /// registered its own latch by the time this one unwinds, and dropping that
    /// would leave the live connect unlatchable — the hazard this list exists
    /// to remove.
    private func clearPendingConnectLatch(_ latch: SonarSuspendLatch) {
        nodeLock.lock()
        pendingConnectLatches.removeAll { $0 === latch }
        nodeLock.unlock()
    }

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

    /// Blossom encrypt+upload (+ staging resume) on the dedicated media lane.
    /// Must not share `sendQueue` with text/stickers or `workQueue` with sync.
    private func mediaLane<T: Sendable>(_ body: @escaping @Sendable (SonarNode) throws -> T) async throws -> T {
        try await leasedNodeOperation(on: mediaQueue, body)
    }

    /// Live receive drain on the dedicated serial drain lane. Must not share
    /// `workQueue` with blocking `syncForce` (see `drainQueue` doc).
    private func drainLane<T: Sendable>(_ body: @escaping @Sendable (SonarNode) throws -> T) async throws -> T {
        try await leasedNodeOperation(on: drainQueue, body)
    }

    /// Identity publishes + the self-profile fetch that gates them. Off
    /// `workQueue` so they never sit between relay-connect and first drain
    /// (#265).
    private func publishLane<T: Sendable>(_ body: @escaping @Sendable (SonarNode) throws -> T) async throws -> T {
        try await leasedNodeOperation(on: publishQueue, body)
    }

    /// MLS membership changes on their own lane. The Rust core serializes these
    /// against sends and competing membership commits.
    ///
    /// Same lease residual as the media/send lanes (REGRESSIONS.md, R-028): the
    /// close releases `storeLock` with the node in its first `workQueue` hop and
    /// only then waits on `nodeLifecycleGroup`, so an approval in flight at
    /// background holds the SQLCipher handle for the remainder of its FFI. That
    /// window is bounded by the core's fetch timeout plus commit + Welcome
    /// publish — far shorter than the media lane's, and shorter than the
    /// unbounded `workQueue` block this replaces.
    private func membershipLane<T: Sendable>(_ body: @escaping @Sendable (SonarNode) throws -> T) async throws -> T {
        try await leasedNodeOperation(on: membershipQueue, body)
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
