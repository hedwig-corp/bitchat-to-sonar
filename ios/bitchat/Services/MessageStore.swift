//
// MessageStore.swift
// bitchat
//
// On-disk persistence for the Swift app's chat history, so conversations
// survive an app restart. Everything below the UI was in-memory until now:
//   - mesh / bitchat private chats        (keyed by PeerID)
//   - public + geohash channel transcripts (keyed by channel id)
//   - (the ⚡PAY ledger already persists via UserDefaults — see note below)
//
// STORAGE CHOICE — Codable JSON files under Application Support, each
// written with `NSFileProtectionComplete` (iOS Data Protection):
//
//   * At-rest encryption: NSFileProtectionComplete ties the file's
//     encryption to the device passcode — the bytes are unreadable while the
//     device is locked. This is the same guarantee an app-level AES-GCM +
//     Keychain scheme would give, but without us hand-rolling crypto or
//     managing a key, and it is what iOS recommends for message data.
//   * No new dependency / no pbxproj edit: BitchatMessage, PeerID and
//     DeliveryStatus are ALREADY Codable, so a JSON file store needs nothing
//     linked (raw libsqlite3 would mean touching the project to add
//     libsqlite3.tbd, which the persistence handoff forbids). The rest of the
//     app already stores data as Application Support files (media, identity
//     caches), so this matches the codebase.
//   * macOS has no Data Protection; there the files are plain JSON in the
//     app's Application Support (same as every other file the app writes).
//
// LOCAL-ONLY invariant: this is a private on-device store. Nothing here is
// ever sent to a relay — mesh DMs and channel transcripts persist locally and
// are erased by `wipeAll()` on panic.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import Foundation
#if canImport(Darwin)
import Darwin
#endif

typealias DirectoryLister = (_ directory: URL) throws -> [URL]

enum MeshOutboundKind: String, Codable {
    case text
    case favorite
    case paymentControl
    case callControl

    var ttl: TimeInterval {
        switch self {
        case .callControl: return 60
        case .text, .favorite, .paymentControl: return 24 * 60 * 60
        }
    }

    static func classify(_ content: String) -> MeshOutboundKind {
        let trimmed = content.drop(while: { $0.isWhitespace })
        if trimmed.hasPrefix("☎CALL") { return .callControl }
        if trimmed.hasPrefix("⚡PAY") { return .paymentControl }
        if trimmed.hasPrefix("[FAVORITED]") || trimmed.hasPrefix("[UNFAVORITED]") { return .favorite }
        return .text
    }
}

struct MeshOutboundObligation: Codable, Equatable {
    let messageID: String
    let peerID: PeerID
    let recipientNickname: String
    let content: String
    let kind: MeshOutboundKind
    let createdAt: Date
    let expiresAt: Date
    let sequence: UInt64
    let wireTimestampMillis: UInt64
    var attemptCount: Int
    var lastAttemptAt: Date?
}

struct MeshOutboxEnqueueResult: Equatable {
    let obligation: MeshOutboundObligation
    let evictedMessageIDs: [String]
}

struct MeshOutboxLoadResult: Equatable {
    let obligations: [MeshOutboundObligation]
    let expiredMessageIDs: [String]
}

enum MeshOutboxAckResult: Equatable {
    case removed
    case notFound
    case peerMismatch
    case failed
}

struct PrivateStoreSnapshot {
    let chats: [PeerID: [BitchatMessage]]
    let pendingReceiveEffects: [(peerID: PeerID, message: BitchatMessage)]
    /// Number of transcript files inspected for this page. Callers advance by
    /// this count rather than by decoded-chat count because corrupt/empty files
    /// are intentionally skipped.
    let scannedFileCount: Int
    let hasMore: Bool
    /// Exclusive ordering cursor for the next page. Unlike an integer offset,
    /// this remains deterministic when a conversation is promoted to the
    /// front of the index between page reads.
    let nextCursor: PrivateConversationCursor?
}

struct PrivateConversationCursor: Codable, Equatable {
    fileprivate let latestMessageAt: Date
    fileprivate let latestMessageID: String
    fileprivate let peerID: PeerID
}

struct MessageStoreWipeResult: Equatable, Sendable {
    /// The old account tree is no longer reachable at the live store path and
    /// a fresh tree exists. New-account work may only start when this is true.
    let quarantined: Bool
    /// Tombstones are deleted best-effort after the atomic quarantine. A false
    /// value is privacy-relevant, but cannot let cleanup target the new tree;
    /// the named tombstones are retried on the next store initialization/wipe.
    let cleanupComplete: Bool

    static let failed = MessageStoreWipeResult(quarantined: false, cleanupComplete: false)
}

enum DirectoryDurabilityStage: Equatable {
    case open
    case fsync
    case close
}

/// Darwin directory durability barrier shared by transcript and media panic
/// transactions. Every syscall is checked; the hook makes otherwise rare
/// device/filesystem failures deterministic in tests.
enum DirectoryDurability {
    typealias FaultInjector = (_ directory: URL, _ stage: DirectoryDurabilityStage) throws -> Void

    static func synchronize(
        _ directory: URL,
        faultInjector: FaultInjector? = nil
    ) throws {
        #if canImport(Darwin)
        try faultInjector?(directory, .open)
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var needsClose = true
        defer {
            if needsClose { _ = Darwin.close(descriptor) }
        }

        try faultInjector?(directory, .fsync)
        guard Darwin.fsync(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        try faultInjector?(directory, .close)
        let closeStatus = Darwin.close(descriptor)
        needsClose = false
        guard closeStatus == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        #else
        _ = directory
        try faultInjector?(directory, .open)
        try faultInjector?(directory, .fsync)
        try faultInjector?(directory, .close)
        #endif
    }
}

/// Panic-only media directory transaction. The live `files/` tree is renamed
/// first, then an empty replacement is created. Cleanup is restricted to the
/// detached tombstone name, so a slow deletion can never erase media written
/// by a newly activated account.
enum PanicMediaStore {
    static func quarantineAndRecreate(
        supportDirectory: URL? = nil,
        beforeQuarantine: (() throws -> Void)? = nil,
        beforeTombstoneCleanup: ((_ live: URL, _ tombstone: URL) throws -> Void)? = nil,
        directorySyncFault: DirectoryDurability.FaultInjector? = nil,
        directoryLister: @escaping DirectoryLister = { directory in
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        }
    ) -> MessageStoreWipeResult {
        let fileManager = FileManager.default
        let support: URL
        do {
            support = try supportDirectory ?? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            SecureLogger.error("Panic media support directory unavailable: \(error)", category: .session)
            return .failed
        }

        let live = support.appendingPathComponent("files", isDirectory: true)
        let tombstone = support.appendingPathComponent(
            ".files.panic-\(UUID().uuidString)",
            isDirectory: true
        )
        var movedOldTree = false
        do {
            try beforeQuarantine?()
            if fileManager.fileExists(atPath: live.path) {
                try fileManager.moveItem(at: live, to: tombstone)
                movedOldTree = true
            }
            do {
                try createEmptyTree(at: live, fileManager: fileManager)
                try DirectoryDurability.synchronize(
                    support,
                    faultInjector: directorySyncFault
                )
            } catch {
                try? fileManager.removeItem(at: live)
                if movedOldTree { try? fileManager.moveItem(at: tombstone, to: live) }
                try? DirectoryDurability.synchronize(
                    support,
                    faultInjector: directorySyncFault
                )
                SecureLogger.error("Panic media replacement tree failed: \(error)", category: .session)
                return .failed
            }

            var cleanupComplete = true
            if movedOldTree {
                do {
                    try beforeTombstoneCleanup?(live, tombstone)
                    try fileManager.removeItem(at: tombstone)
                } catch {
                    cleanupComplete = false
                    SecureLogger.error("Panic media tombstone cleanup deferred: \(error)", category: .session)
                }
            }
            // Retry older, uniquely named tombstones without ever touching the
            // live `files/` path.
            let oldTombstones: [URL]
            do {
                oldTombstones = try directoryLister(support)
                    .filter { $0.lastPathComponent.hasPrefix(".files.panic-") }
            } catch {
                oldTombstones = []
                cleanupComplete = false
                SecureLogger.error("Panic media tombstone enumeration failed: \(error)", category: .session)
            }
            for old in oldTombstones {
                do { try fileManager.removeItem(at: old) }
                catch { cleanupComplete = false }
            }
            if movedOldTree || !oldTombstones.isEmpty {
                do {
                    try DirectoryDurability.synchronize(
                        support,
                        faultInjector: directorySyncFault
                    )
                } catch {
                    cleanupComplete = false
                    SecureLogger.error("Panic media tombstone durability failed: \(error)", category: .session)
                }
            }
            return MessageStoreWipeResult(quarantined: true, cleanupComplete: cleanupComplete)
        } catch {
            SecureLogger.error("Panic media quarantine failed: \(error)", category: .session)
            return .failed
        }
    }

    private static func createEmptyTree(at root: URL, fileManager: FileManager) throws {
        let directories = [
            root,
            root.appendingPathComponent("voicenotes/incoming", isDirectory: true),
            root.appendingPathComponent("voicenotes/outgoing", isDirectory: true),
            root.appendingPathComponent("images/incoming", isDirectory: true),
            root.appendingPathComponent("images/outgoing", isDirectory: true),
            root.appendingPathComponent("files/incoming", isDirectory: true),
            root.appendingPathComponent("files/outgoing", isDirectory: true),
        ]
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: root.path
        )
        #endif
    }
}

/// Encrypted-at-rest, on-disk store for chat history. Thread-safe (an internal
/// serial queue guards all disk access). Normal writes are asynchronous; the
/// explicit `commit*` APIs suspend until the atomic write is durable.
final class MessageStore {

    /// Shared instance backed by the real Application Support directory.
    static let shared = MessageStore()
    /// Small Signal-style transcript window used for chat-list first paint and
    /// immediate chat opening. Full capped transcripts remain in `private/`.
    static let privateMessageWindowSize = 50

    // MARK: - Layout

    private let baseDir: URL
    private let privateDir: URL   // one file per peer: <fingerprint>.json
    private let privateWindowDir: URL // bounded derived window per peer
    private let privateIndexNodeDir: URL // immutable persistent-treap nodes
    private let channelDir: URL   // one file per channel: <channel>.json
    private let io = DispatchQueue(label: "chat.bitchat.sonar.messageStore")
    /// Legacy full-transcript migration never occupies `io`; opening a chat
    /// remains one bounded sidecar read even while hundreds of old chats are
    /// being indexed.
    private let legacyMigrationIO = DispatchQueue(
        label: "chat.bitchat.sonar.messageStore.legacyMigration",
        qos: .utility
    )
    /// Pending-effect replay may validate many indexed peers. Keep that work
    /// off `io` so a synchronous bounded chat open never waits behind it.
    private let pendingEffectReplayIO = DispatchQueue(
        label: "chat.bitchat.sonar.messageStore.pendingEffectReplay",
        qos: .utility
    )
    private let indexLock = NSLock()
    private let pendingEffectLock = NSLock()
    private let privateWindowWriteLock = NSLock()
    /// Accessed only on `legacyMigrationIO`; directory filenames are captured
    /// once per process rather than re-enumerated for every migration page.
    private var legacyPrivateFileSnapshot: [URL]?
    private let beforeAtomicReplace: (() throws -> Void)?
    private let beforeWipeQuarantine: (() throws -> Void)?
    private let directorySyncFault: DirectoryDurability.FaultInjector?
    private let directoryLister: DirectoryLister
    private let fullTranscriptReadObserver: (() -> Void)?
    private let fullConversationIndexReadObserver: (() -> Void)?
    private let indexNodeReadObserver: (() -> Void)?
    private let indexNodeWriteObserver: (() -> Void)?
    private var activeMeshOutboxFences: [String: String] = [:]
    private let cap = TransportConfig.privateChatCap
    private let controlReceiptCap = 4_096
    private let meshOutboxPerPeerCap = 100
    private let meshOutboxGlobalCap = 500
    private let privateConversationIndexPageSize = 24
    /// Rotated before every destructive wipe. Suspended receive work must
    /// present the generation it captured before leaving the main actor.
    private var storageGeneration = UUID().uuidString

    /// Cap stored per channel transcript — matches the in-memory timeline cap
    /// so write-through never truncates below what the UI holds.
    private let channelCap = TransportConfig.meshTimelineCap

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// On-disk envelope for a private transcript: the PeerID is recorded
    /// explicitly so `loadAllPrivate()` can re-key it (filenames are hashes).
    private struct StoredPrivateChat: Codable {
        let peerID: PeerID
        let messages: [BitchatMessage]
        /// Stable receive IDs whose transcript is durable but whose local
        /// notification/read/unread effects still need idempotent projection.
        let pendingReceiveEffectIDs: [String]?
    }

    /// Non-transcript mesh controls (currently favorite notifications) still
    /// need a durable acceptance record before their delivery ACK is emitted.
    /// Store hashed keys so neither peer IDs nor message IDs are exposed here.
    private struct StoredControlReceipts: Codable {
        var keys: [String]
    }

    private struct StoredMeshOutbox: Codable {
        let ownerID: String
        var nextSequence: UInt64
        var lastWireTimestampMillis: UInt64
        var obligations: [MeshOutboundObligation]
    }

    private struct PrivateConversationIndexEntry: Codable, Equatable {
        let peerID: PeerID
        let latestMessageAt: Date
        let latestMessageID: String

        var cursor: PrivateConversationCursor {
            PrivateConversationCursor(
                latestMessageAt: latestMessageAt,
                latestMessageID: latestMessageID,
                peerID: peerID
            )
        }
    }

    private struct OrderIndexNode: Codable {
        let entry: PrivateConversationIndexEntry
        let priority: UInt64
        let left: String?
        let right: String?
    }

    private struct PeerIndexNode: Codable {
        let peerID: PeerID
        let entry: PrivateConversationIndexEntry
        let priority: UInt64
        let left: String?
        let right: String?
    }

    private struct IndexMutation {
        var createdOrder: [String: OrderIndexNode] = [:]
        var createdPeer: [String: PeerIndexNode] = [:]
        var supersededOrder: Set<String> = []
        var supersededPeer: Set<String> = []
    }

    private struct PendingReceiveEffectRecord: Codable, Equatable {
        let peerID: PeerID
        let message: BitchatMessage
    }

    private struct PendingReceiveEffectIndex: Codable, Equatable {
        var records: [PendingReceiveEffectRecord]
    }

    /// Atomic roots for two immutable persistent treaps: one keyed by the
    /// newest-first conversation order, one keyed by peer ID. Updating a chat
    /// path-copies O(log N) small nodes and then swaps this manifest. The first
    /// 24 summaries stay inline for truly fixed-work launch.
    private struct PrivateConversationIndexManifest: Codable {
        var version: Int
        var orderRoot: String?
        var peerRoot: String?
        var entryCount: Int
        var firstPage: [PrivateConversationIndexEntry]
        var legacyRebuildComplete: Bool
        var legacyRebuildCursorFilename: String?

        static var emptyLegacy: PrivateConversationIndexManifest {
            PrivateConversationIndexManifest(
                version: 2,
                orderRoot: nil,
                peerRoot: nil,
                entryCount: 0,
                firstPage: [],
                legacyRebuildComplete: false,
                legacyRebuildCursorFilename: nil
            )
        }
    }

    // MARK: - Init

    /// - Parameter directoryName: subfolder under Application Support (tests
    ///   pass a unique name so they don't collide with the real store).
    init(
        directoryName: String = "Messages",
        beforeAtomicReplace: (() throws -> Void)? = nil,
        beforeWipeQuarantine: (() throws -> Void)? = nil,
        directorySyncFault: DirectoryDurability.FaultInjector? = nil,
        fullTranscriptReadObserver: (() -> Void)? = nil,
        fullConversationIndexReadObserver: (() -> Void)? = nil,
        indexNodeReadObserver: (() -> Void)? = nil,
        indexNodeWriteObserver: (() -> Void)? = nil,
        directoryLister: @escaping DirectoryLister = { directory in
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        }
    ) {
        self.beforeAtomicReplace = beforeAtomicReplace
        self.beforeWipeQuarantine = beforeWipeQuarantine
        self.directorySyncFault = directorySyncFault
        self.directoryLister = directoryLister
        self.fullTranscriptReadObserver = fullTranscriptReadObserver
        self.fullConversationIndexReadObserver = fullConversationIndexReadObserver
        self.indexNodeReadObserver = indexNodeReadObserver
        self.indexNodeWriteObserver = indexNodeWriteObserver
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        baseDir = support.appendingPathComponent(directoryName, isDirectory: true)
        privateDir = baseDir.appendingPathComponent("private", isDirectory: true)
        privateWindowDir = baseDir.appendingPathComponent("private-windows", isDirectory: true)
        privateIndexNodeDir = baseDir.appendingPathComponent("private-index-nodes", isDirectory: true)
        channelDir = baseDir.appendingPathComponent("channels", isDirectory: true)
        io.sync {
            ensureDirectories()
            _ = retryPendingWipeCleanup()
        }
    }

    private func ensureDirectories() {
        for dir in [baseDir, privateDir, privateWindowDir, privateIndexNodeDir, channelDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Protect the whole tree at rest (best effort; no-op on macOS).
        applyProtection(to: baseDir)
    }

    // MARK: - Private chats (keyed by PeerID)

    /// Load the stored transcript for one peer (oldest → newest). Empty when
    /// nothing was stored yet.
    func load(peerID: PeerID) -> [BitchatMessage] {
        io.sync { readPrivate(at: privateFileURL(for: peerID))?.messages ?? [] }
    }

    /// Read the strictly bounded derived window used by first paint/open. This
    /// never parses the full transcript JSON file.
    func loadRecent(peerID: PeerID) -> [BitchatMessage] {
        io.sync { readPrivateWindow(at: privateWindowFileURL(for: peerID))?.messages ?? [] }
    }

    /// Replace the stored transcript for a peer (used to mirror an in-memory
    /// array exactly, e.g. after consolidation/dedup).
    func savePrivate(peerID: PeerID, messages: [BitchatMessage]) {
        io.async { [weak self] in
            guard let self else { return }
            self.writePrivate(peerID: peerID, messages: self.trimmed(messages, cap: self.cap))
        }
    }

    /// Apply a UI window as an idempotent patch over the full transcript. The
    /// manager never lets its 50-row render window truncate older local rows.
    func savePrivateWindow(peerID: PeerID, messages: [BitchatMessage]) {
        io.async { [weak self] in
            guard let self else { return }
            let existing = self.readPrivate(at: self.privateFileURL(for: peerID))?.messages ?? []
            self.writePrivate(
                peerID: peerID,
                messages: self.mergedPrivateMessages(existing: existing, incoming: messages)
            )
        }
    }

    /// Move a logical conversation key without trusting the bounded UI window
    /// to represent the entire source transcript.
    func migratePrivateTranscript(from source: PeerID, to destination: PeerID) {
        guard source != destination else { return }
        io.async { [weak self] in
            guard let self,
                  let sourceChat = self.readPrivate(
                    at: self.privateFileURL(for: source)
                  ) else { return }
            let destinationChat = self.readPrivate(
                at: self.privateFileURL(for: destination)
            )
            let merged = self.mergedPrivateMessages(
                existing: destinationChat?.messages ?? [],
                incoming: sourceChat.messages
            )
            let pending = Array(Set(
                (destinationChat?.pendingReceiveEffectIDs ?? []) +
                    (sourceChat.pendingReceiveEffectIDs ?? [])
            ))
            let envelope = StoredPrivateChat(
                peerID: destination,
                messages: merged,
                pendingReceiveEffectIDs: pending
            )
            let window = self.privateWindowEnvelope(from: envelope)
            guard self.mergePendingReceiveEffectIndex(for: envelope, durable: true),
                  let data = try? self.encoder.encode(envelope),
                  self.write(data, to: self.privateFileURL(for: destination)),
                  self.writePrivateWindow(window, durable: false),
                  self.updatePrivateConversationIndex(for: window, durable: true),
                  self.updatePendingReceiveEffectIndex(for: envelope, durable: true) else { return }
            _ = self.deletePrivateOnQueue(peerID: source)
        }
    }

    /// Atomically replace a private transcript and suspend until the bytes
    /// have been flushed and renamed into place. This is the receive-side
    /// delivery-ACK barrier; it never blocks the main thread.
    func currentStorageGeneration() -> String {
        io.sync { storageGeneration }
    }

    func commitPrivate(
        peerID: PeerID,
        messages: [BitchatMessage],
        expectedGeneration: String? = nil,
        pendingReceiveEffectMessageID: String? = nil,
        mergeExistingTranscript: Bool = false
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            io.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                guard expectedGeneration == nil || expectedGeneration == self.storageGeneration else {
                    continuation.resume(returning: false)
                    return
                }
                let incoming = self.trimmed(messages, cap: self.cap)
                let snapshot: [BitchatMessage]
                if mergeExistingTranscript {
                    let existing = self.readPrivate(
                        at: self.privateFileURL(for: peerID)
                    )?.messages ?? []
                    snapshot = self.mergedPrivateMessages(
                        existing: existing,
                        incoming: incoming
                    )
                } else {
                    snapshot = incoming
                }
                continuation.resume(returning: self.writePrivateDurably(
                    peerID: peerID,
                    messages: snapshot,
                    pendingReceiveEffectMessageID: pendingReceiveEffectMessageID
                ))
            }
        }
    }

    func hasPendingReceiveEffects(peerID: PeerID, messageID: String) -> Bool {
        io.sync {
            readPrivate(at: privateFileURL(for: peerID))?
                .pendingReceiveEffectIDs?.contains(messageID) == true
        }
    }

    /// Clear the durable effect obligation only after idempotent local effects
    /// were submitted. A crash before this barrier replays with the same stable
    /// notification identifier; a crash after it may safely receive an ACK.
    func commitReceiveEffectsProcessed(
        peerID: PeerID,
        messageID: String,
        expectedGeneration: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            io.async { [weak self] in
                guard let self, expectedGeneration == self.storageGeneration,
                      let stored = self.readPrivate(at: self.privateFileURL(for: peerID)) else {
                    continuation.resume(returning: false)
                    return
                }
                let pending = (stored.pendingReceiveEffectIDs ?? []).filter { $0 != messageID }
                continuation.resume(returning: self.writePrivateDurably(
                    peerID: peerID,
                    messages: stored.messages,
                    pendingReceiveEffectIDs: pending
                ))
            }
        }
    }

    /// Persist acceptance of a mesh control that intentionally does not
    /// appear in a private transcript. Duplicate controls can consult the same
    /// record and safely receive another delivery ACK.
    func commitControlReceipt(
        peerID: PeerID,
        messageID: String,
        expectedGeneration: String? = nil
    ) async -> Bool {
        let key = controlReceiptKey(peerID: peerID, messageID: messageID)
        return await withCheckedContinuation { continuation in
            io.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                guard expectedGeneration == nil || expectedGeneration == self.storageGeneration else {
                    continuation.resume(returning: false)
                    return
                }
                var receipts = self.readControlReceipts()
                if receipts.contains(key) {
                    continuation.resume(returning: true)
                    return
                }
                receipts.append(key)
                if receipts.count > self.controlReceiptCap {
                    receipts.removeFirst(receipts.count - self.controlReceiptCap)
                }
                guard let data = try? self.encoder.encode(StoredControlReceipts(keys: receipts)) else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: self.writeDurably(data, to: self.controlReceiptsURL))
            }
        }
    }

    func hasControlReceipt(peerID: PeerID, messageID: String) -> Bool {
        let key = controlReceiptKey(peerID: peerID, messageID: messageID)
        return io.sync { readControlReceipts().contains(key) }
    }

    // MARK: - Durable mesh outbound obligations

    /// Activate one process-local fence for an account. Every mutating outbox
    /// operation must present the same fence, preventing work captured before
    /// a panic/account reset from recreating wiped data.
    func activateMeshOutbox(ownerID: String, fence: String) {
        io.sync { activeMeshOutboxFences[ownerID] = fence }
    }

    func invalidateMeshOutbox(ownerID: String, fence: String) {
        io.sync {
            guard activeMeshOutboxFences[ownerID] == fence else { return }
            activeMeshOutboxFences.removeValue(forKey: ownerID)
            try? FileManager.default.removeItem(at: meshOutboxURL)
        }
    }

    func enqueueMeshObligation(
        ownerID: String,
        fence: String,
        messageID: String,
        peerID: PeerID,
        recipientNickname: String,
        content: String,
        kind: MeshOutboundKind,
        createdAt: Date = Date()
    ) -> MeshOutboxEnqueueResult? {
        io.sync {
            guard activeMeshOutboxFences[ownerID] == fence else { return nil }
            guard var envelope = readMeshOutbox(ownerID: ownerID) else { return nil }

            // A stable identifier may retry only the exact immutable
            // obligation it originally admitted. Treating a different peer,
            // payload, or control kind as idempotent could send bytes under a
            // stale UI row or acknowledge the wrong delivery contract.
            if let existing = envelope.obligations.first(where: { $0.messageID == messageID }) {
                guard existing.peerID == peerID,
                      existing.content == content,
                      existing.kind == kind else {
                    SecureLogger.error(
                        "Mesh outbox stable-ID collision; refusing mismatched retry",
                        category: .session
                    )
                    return nil
                }
                return MeshOutboxEnqueueResult(obligation: existing, evictedMessageIDs: [])
            }

            // Admission is fail-closed. Once accepted, an obligation is never
            // silently displaced by newer work; it remains until ACK, expiry,
            // explicit conversation deletion, or account wipe.
            guard envelope.obligations.count < meshOutboxGlobalCap,
                  envelope.obligations.lazy.filter({ $0.peerID == peerID }).count < meshOutboxPerPeerCap else {
                return nil
            }
            guard envelope.nextSequence < UInt64.max,
                  envelope.lastWireTimestampMillis < UInt64.max else {
                SecureLogger.error("Mesh outbox ordering counter exhausted", category: .session)
                return nil
            }
            let nowMillis = UInt64(max(0, createdAt.timeIntervalSince1970 * 1_000))
            let sequence = envelope.nextSequence
            envelope.nextSequence += 1
            let wireTimestamp = max(nowMillis, envelope.lastWireTimestampMillis + 1)
            envelope.lastWireTimestampMillis = wireTimestamp

            let obligation = MeshOutboundObligation(
                messageID: messageID,
                peerID: peerID,
                recipientNickname: recipientNickname,
                content: content,
                kind: kind,
                createdAt: createdAt,
                expiresAt: createdAt.addingTimeInterval(kind.ttl),
                sequence: sequence,
                wireTimestampMillis: wireTimestamp,
                attemptCount: 0,
                lastAttemptAt: nil
            )
            envelope.obligations.append(obligation)
            envelope.obligations.sort { $0.sequence < $1.sequence }

            guard writeMeshOutbox(envelope) else { return nil }
            return MeshOutboxEnqueueResult(obligation: obligation, evictedMessageIDs: [])
        }
    }

    func loadMeshObligations(
        ownerID: String,
        fence: String,
        now: Date = Date()
    ) -> MeshOutboxLoadResult? {
        io.sync {
            guard activeMeshOutboxFences[ownerID] == fence else { return nil }
            guard var envelope = readMeshOutbox(ownerID: ownerID) else { return nil }
            let expired = envelope.obligations.filter { $0.expiresAt <= now }.map(\.messageID)
            if !expired.isEmpty {
                let expiredSet = Set(expired)
                envelope.obligations.removeAll { expiredSet.contains($0.messageID) }
                guard writeMeshOutbox(envelope) else { return nil }
            }
            return MeshOutboxLoadResult(
                obligations: envelope.obligations.sorted { $0.sequence < $1.sequence },
                expiredMessageIDs: expired
            )
        }
    }

    /// Record the retry before bytes hit BLE. A process death therefore cannot
    /// reset backoff and spin-send an obligation on every relaunch.
    func markMeshObligationAttempt(
        ownerID: String,
        fence: String,
        messageID: String,
        at date: Date
    ) -> MeshOutboundObligation? {
        io.sync {
            guard activeMeshOutboxFences[ownerID] == fence else { return nil }
            guard var envelope = readMeshOutbox(ownerID: ownerID) else { return nil }
            guard let index = envelope.obligations.firstIndex(where: { $0.messageID == messageID }) else {
                return nil
            }
            envelope.obligations[index].attemptCount += 1
            envelope.obligations[index].lastAttemptAt = date
            guard writeMeshOutbox(envelope) else { return nil }
            return envelope.obligations[index]
        }
    }

    func acknowledgeMeshObligation(
        ownerID: String,
        fence: String,
        messageID: String,
        from peerID: PeerID
    ) -> MeshOutboxAckResult {
        io.sync {
            guard activeMeshOutboxFences[ownerID] == fence else { return .failed }
            guard var envelope = readMeshOutbox(ownerID: ownerID) else { return .failed }
            guard let index = envelope.obligations.firstIndex(where: { $0.messageID == messageID }) else {
                return .notFound
            }
            guard envelope.obligations[index].peerID == peerID else { return .peerMismatch }
            envelope.obligations.remove(at: index)
            return writeMeshOutbox(envelope) ? .removed : .failed
        }
    }

    /// Remove every unsent obligation for a deleted conversation before the
    /// transcript/UI can report success. The outbox rewrite is crash durable;
    /// a failure leaves both the old journal and transcript available to retry.
    func pruneMeshObligations(
        ownerID: String,
        fence: String,
        peerIDs: Set<PeerID>
    ) -> Bool {
        io.sync {
            guard activeMeshOutboxFences[ownerID] == fence else { return false }
            guard var envelope = readMeshOutbox(ownerID: ownerID) else { return false }
            let previousCount = envelope.obligations.count
            envelope.obligations.removeAll { peerIDs.contains($0.peerID) }
            guard envelope.obligations.count != previousCount else { return true }
            return writeMeshOutbox(envelope)
        }
    }

    /// Append one message to a peer's transcript (deduped by id, trimmed to cap).
    func appendPrivate(peerID: PeerID, message: BitchatMessage) {
        io.async { [weak self] in
            guard let self else { return }
            let url = self.privateFileURL(for: peerID)
            var messages = self.readPrivate(at: url)?.messages ?? []
            guard !messages.contains(where: { $0.id == message.id }) else { return }
            messages.append(message)
            self.writePrivate(peerID: peerID, messages: self.trimmed(messages, cap: self.cap))
        }
    }

    /// All bounded private render windows, keyed by their persisted PeerID.
    /// Retained for diagnostics/tests; app startup uses one page below.
    func loadAllPrivate() -> [PeerID: [BitchatMessage]] {
        loadPrivateSnapshot().chats
    }

    /// Load at most `chatLimit` locally persisted conversations from the
    /// durable newest-first index. Each decoded sidecar contains at most
    /// `privateMessageWindowSize` rows; no directory listing, metadata stat,
    /// global sort, or full transcript parse occurs on this path.
    func loadPrivateSnapshot(
        after cursor: PrivateConversationCursor? = nil,
        chatLimit: Int = .max
    ) -> PrivateStoreSnapshot {
        io.sync { loadPrivateSnapshotOnQueue(after: cursor, chatLimit: chatLimit) }
    }

    /// Background page used after the first local page has painted.
    func loadPrivateSnapshotPage(
        after cursor: PrivateConversationCursor?,
        chatLimit: Int
    ) async -> PrivateStoreSnapshot {
        await withCheckedContinuation { continuation in
            io.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: PrivateStoreSnapshot(
                        chats: [:],
                        pendingReceiveEffects: [],
                        scannedFileCount: 0,
                        hasMore: false,
                        nextCursor: nil
                    ))
                    return
                }
                continuation.resume(returning: self.loadPrivateSnapshotOnQueue(
                    after: cursor,
                    chatLimit: chatLimit
                ))
            }
        }
    }

    private func loadPrivateSnapshotOnQueue(
        after cursor: PrivateConversationCursor?,
        chatLimit: Int
    ) -> PrivateStoreSnapshot {
        let limit = max(0, chatLimit)
        let pageEntries: [PrivateConversationIndexEntry]
        let hasMore: Bool
        indexLock.lock()
        if cursor == nil, limit <= privateConversationIndexPageSize,
           let manifest = readPrivateConversationIndexManifestUnlocked() {
            pageEntries = Array(manifest.firstPage.prefix(limit))
            hasMore = pageEntries.count < manifest.entryCount
        } else if let manifest = readPrivateConversationIndexManifestUnlocked() {
            fullConversationIndexReadObserver?()
            let page = orderedIndexPageUnlocked(
                root: manifest.orderRoot,
                after: cursor,
                limit: limit
            )
            pageEntries = page.entries
            hasMore = page.hasMore
        } else {
            pageEntries = []
            hasMore = false
        }
        indexLock.unlock()

        var out: [PeerID: [BitchatMessage]] = [:]
        var pending: [(peerID: PeerID, message: BitchatMessage)] = []
        for entry in pageEntries {
            let file = privateWindowFileURL(for: entry.peerID)
            guard let chat = readPrivateWindow(at: file), !chat.messages.isEmpty else { continue }
            out[chat.peerID] = chat.messages
            let pendingIDs = Set(chat.pendingReceiveEffectIDs ?? [])
            pending.append(contentsOf: chat.messages.compactMap { message in
                pendingIDs.contains(message.id) ? (chat.peerID, message) : nil
            })
        }
        return PrivateStoreSnapshot(
            chats: out,
            pendingReceiveEffects: pending,
            scannedFileCount: pageEntries.count,
            hasMore: hasMore,
            nextCursor: pageEntries.last?.cursor
        )
    }

    /// Incrementally migrates legacy full-transcript-only files into bounded
    /// window sidecars. It runs on a separate utility queue after first paint;
    /// opening a chat on `io` never waits behind unrelated full-file parsing.
    func rebuildLegacyPrivateWindowPage(chatLimit: Int) async -> PrivateStoreSnapshot {
        await withCheckedContinuation { continuation in
            legacyMigrationIO.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: PrivateStoreSnapshot(
                        chats: [:], pendingReceiveEffects: [],
                        scannedFileCount: 0, hasMore: false,
                        nextCursor: nil
                    ))
                    return
                }
                continuation.resume(returning: self.rebuildLegacyPrivateWindowPageOnQueue(
                    chatLimit: chatLimit
                ))
            }
        }
    }

    private func rebuildLegacyPrivateWindowPageOnQueue(chatLimit: Int) -> PrivateStoreSnapshot {
        indexLock.lock()
        let startingManifest = readPrivateConversationIndexManifestUnlocked() ?? .emptyLegacy
        indexLock.unlock()
        guard !startingManifest.legacyRebuildComplete else {
            return PrivateStoreSnapshot(
                chats: [:], pendingReceiveEffects: [],
                scannedFileCount: 0, hasMore: false,
                nextCursor: nil
            )
        }

        if legacyPrivateFileSnapshot == nil {
            do {
                legacyPrivateFileSnapshot = try directoryLister(privateDir)
                    .filter { $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                SecureLogger.error("Legacy transcript enumeration failed: \(error)", category: .session)
                return PrivateStoreSnapshot(
                    chats: [:], pendingReceiveEffects: [],
                    scannedFileCount: 0, hasMore: false,
                    nextCursor: nil
                )
            }
        }
        let candidates = (legacyPrivateFileSnapshot ?? []).filter { file in
            guard let cursor = startingManifest.legacyRebuildCursorFilename else { return true }
            return file.lastPathComponent > cursor
        }

        let files = Array(candidates.prefix(max(0, chatLimit)))
        var chats: [PeerID: [BitchatMessage]] = [:]
        var envelopes: [StoredPrivateChat] = []
        for file in files {
            guard let full = readPrivate(at: file) else { continue }
            let window = privateWindowEnvelope(from: full)
            guard writeLegacyPrivateWindowIfAbsent(window) else { continue }
            envelopes.append(window)
            // Legacy bootstrap only adds obligations. It must never erase a
            // newer live receive-effect record for the same peer.
            _ = mergePendingReceiveEffectIndex(for: full, durable: true)
            if !window.messages.isEmpty { chats[window.peerID] = window.messages }
        }
        let hasMore = files.count < candidates.count
        guard updatePrivateConversationIndexBatch(
            for: envelopes,
            legacyCursorFilename: hasMore ? files.last?.lastPathComponent : nil,
            legacyRebuildComplete: !hasMore,
            onlyIfNewer: true
        ) else {
            return PrivateStoreSnapshot(
                chats: [:], pendingReceiveEffects: [],
                scannedFileCount: 0, hasMore: true,
                nextCursor: nil
            )
        }
        return PrivateStoreSnapshot(
            chats: chats,
            pendingReceiveEffects: [],
            scannedFileCount: files.count,
            hasMore: hasMore,
            nextCursor: nil
        )
    }

    /// Crash-replay obligations are maintained in their own durable keyed
    /// sidecar. Replay never enumerates or parses unrelated transcripts.
    func loadPendingReceiveEffects() async -> [(peerID: PeerID, message: BitchatMessage)] {
        await withCheckedContinuation { continuation in
            pendingEffectReplayIO.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }
                guard let stored = self.readPendingReceiveEffectIndex() else {
                    continuation.resume(returning: [])
                    return
                }
                // A pending add is written before its transcript, while a
                // pending removal is written after its transcript. Validate
                // against only the peers named by the sidecar so either crash
                // window is safe without a global transcript scan.
                var valid: [PendingReceiveEffectRecord] = []
                var stale: [PendingReceiveEffectRecord] = []
                for record in stored.records {
                    let chat = self.readPrivate(
                        at: self.privateFileURL(for: record.peerID)
                    )
                    if chat?.pendingReceiveEffectIDs?.contains(record.message.id) == true,
                       chat?.messages.contains(where: { $0.id == record.message.id }) == true {
                        valid.append(record)
                    } else {
                        stale.append(record)
                    }
                }
                if !stale.isEmpty {
                    _ = self.removePendingReceiveEffectRecordsIfUnchanged(
                        stale,
                        durable: true
                    )
                }
                continuation.resume(returning: valid.map { ($0.peerID, $0.message) })
            }
        }
    }

    // MARK: - Channels (keyed by channel id: "mesh" / "geo:<gh>")

    func loadChannel(_ channelID: String) -> [BitchatMessage] {
        io.sync { readMessages(at: channelFileURL(for: channelID)) }
    }

    func appendChannel(_ channelID: String, message: BitchatMessage) {
        io.async { [weak self] in
            guard let self else { return }
            let url = self.channelFileURL(for: channelID)
            var messages = self.readMessages(at: url)
            guard !messages.contains(where: { $0.id == message.id }) else { return }
            messages.append(message)
            self.writeMessages(self.trimmed(messages, cap: self.channelCap), to: url)
        }
    }

    /// Mirror an in-memory channel transcript exactly (write-through on a
    /// timeline refresh that may have reordered/deduped).
    func saveChannel(_ channelID: String, messages: [BitchatMessage]) {
        io.async { [weak self] in
            guard let self else { return }
            self.writeMessages(self.trimmed(messages, cap: self.channelCap), to: self.channelFileURL(for: channelID))
        }
    }

    // MARK: - ⚡PAY ledger (generic Codable blob)
    //
    // NOTE: the live ⚡PAY ledger already persists across restart via
    // UserDefaults (SonarPayLedger, key "sonar.pay.ledger.v1") — UserDefaults
    // IS durable, so payments were never the persistence gap. These methods
    // exist so the ledger CAN be backed by the same encrypted-at-rest store if
    // desired; the app keeps the ledger in UserDefaults today.

    func loadPayLedger<T: Decodable>(_ type: T.Type) -> T? {
        io.sync {
            guard let data = try? Data(contentsOf: payLedgerURL) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
    }

    func savePayLedger<T: Encodable>(_ ledger: T) {
        io.async { [weak self] in
            guard let self else { return }
            guard let data = try? self.encoder.encode(ledger) else { return }
            self.write(data, to: self.payLedgerURL)
        }
    }

    // MARK: - Panic wipe

    /// Erase EVERYTHING this store holds: delete the whole on-disk tree (mesh
    /// DMs, channel transcripts, any pay-ledger blob) and recreate empty
    /// directories. Called from the panic paths.
    @discardableResult
    func wipeAll() -> MessageStoreWipeResult {
        io.sync {
            // Fence every suspended old-account commit before attempting any
            // filesystem mutation. A failed wipe may be retried, but stale
            // work must never repopulate either the restored or fresh tree.
            storageGeneration = UUID().uuidString
            activeMeshOutboxFences.removeAll()

            let fileManager = FileManager.default
            let tombstone = baseDir.deletingLastPathComponent().appendingPathComponent(
                ".\(baseDir.lastPathComponent).wipe-\(UUID().uuidString)",
                isDirectory: true
            )
            var movedOldTree = false
            do {
                try beforeWipeQuarantine?()
                if fileManager.fileExists(atPath: baseDir.path) {
                    try fileManager.moveItem(at: baseDir, to: tombstone)
                    movedOldTree = true
                }
                do {
                    try createDirectories()
                    try syncDirectory(baseDir.deletingLastPathComponent())
                } catch {
                    // If creating the replacement failed, restore the old tree
                    // when possible. Either way report failure and never permit
                    // identity reactivation against an ambiguous live path.
                    try? fileManager.removeItem(at: baseDir)
                    if movedOldTree {
                        try? fileManager.moveItem(at: tombstone, to: baseDir)
                    }
                    SecureLogger.error("MessageStore wipe could not create replacement tree: \(error)", category: .session)
                    return .failed
                }

                let cleanupComplete = retryPendingWipeCleanup()
                SecureLogger.info("🗑️ MessageStore quarantined (private chats + channel transcripts)", category: .session)
                return MessageStoreWipeResult(
                    quarantined: true,
                    cleanupComplete: cleanupComplete
                )
            } catch {
                SecureLogger.error("MessageStore wipe quarantine failed: \(error)", category: .session)
                return .failed
            }
        }
    }

    /// Delete one peer's private transcript file (used by per-chat delete). The
    /// raw key never hits the FS, so we remove the hashed file for this PeerID.
    func deletePrivate(peerID: PeerID) {
        io.async { [weak self] in
            _ = self?.deletePrivateOnQueue(peerID: peerID)
        }
    }

    /// Awaitable deletion barrier used by per-conversation erase. Returning
    /// true means the unlink (or already-missing state) and parent directory
    /// entry are durable.
    func deletePrivateDurably(peerID: PeerID) -> Bool {
        io.sync { deletePrivateOnQueue(peerID: peerID) }
    }

    private func deletePrivateOnQueue(peerID: PeerID) -> Bool {
        let urls = [privateFileURL(for: peerID), privateWindowFileURL(for: peerID)]
        do {
            var removedFull = false
            var removedWindow = false
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                if url.deletingLastPathComponent() == privateDir { removedFull = true }
                if url.deletingLastPathComponent() == privateWindowDir { removedWindow = true }
            }
            if removedFull { try syncDirectory(privateDir) }
            if removedWindow { try syncDirectory(privateWindowDir) }
            let empty = StoredPrivateChat(
                peerID: peerID,
                messages: [],
                pendingReceiveEffectIDs: []
            )
            guard updatePrivateConversationIndex(for: empty, durable: true) else { return false }
            return updatePendingReceiveEffectIndex(for: empty, durable: true)
        } catch {
            SecureLogger.error("MessageStore conversation delete failed: \(error)", category: .session)
            return false
        }
    }

    // MARK: - File helpers

    /// One file per peer. Keyed by a filesystem-safe hash of the PeerID so the
    /// raw id never lands in a filename.
    private func privateFileURL(for peerID: PeerID) -> URL {
        privateDir.appendingPathComponent(Self.fileSafeKey(peerID.id) + ".json")
    }

    private func privateWindowFileURL(for peerID: PeerID) -> URL {
        privateWindowDir.appendingPathComponent(Self.fileSafeKey(peerID.id) + ".json")
    }

    private func channelFileURL(for channelID: String) -> URL {
        channelDir.appendingPathComponent(Self.fileSafeKey(channelID) + ".json")
    }

    private var payLedgerURL: URL {
        baseDir.appendingPathComponent("payledger.json")
    }

    private var controlReceiptsURL: URL {
        baseDir.appendingPathComponent("mesh-control-receipts.json")
    }

    private var meshOutboxURL: URL {
        baseDir.appendingPathComponent("mesh-outbox.json")
    }

    private var privateConversationIndexURL: URL {
        baseDir.appendingPathComponent("private-conversation-index.json")
    }

    private var pendingReceiveEffectIndexURL: URL {
        baseDir.appendingPathComponent("pending-receive-effects.json")
    }

    private func orderIndexNodeURL(_ id: String) -> URL {
        privateIndexNodeDir.appendingPathComponent("o-\(id).json")
    }

    private func peerIndexNodeURL(_ id: String) -> URL {
        privateIndexNodeDir.appendingPathComponent("p-\(id).json")
    }

    private func readMessages(at url: URL) -> [BitchatMessage] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([BitchatMessage].self, from: data)) ?? []
    }

    private func writeMessages(_ messages: [BitchatMessage], to url: URL) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        write(data, to: url)
    }

    private func readPrivate(at url: URL) -> StoredPrivateChat? {
        fullTranscriptReadObserver?()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredPrivateChat.self, from: data)
    }

    private func readPrivateWindow(at url: URL) -> StoredPrivateChat? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredPrivateChat.self, from: data)
    }

    private func privateWindowEnvelope(from full: StoredPrivateChat) -> StoredPrivateChat {
        let messages = Array(full.messages.suffix(Self.privateMessageWindowSize))
        let visibleIDs = Set(messages.map(\.id))
        return StoredPrivateChat(
            peerID: full.peerID,
            messages: messages,
            pendingReceiveEffectIDs: (full.pendingReceiveEffectIDs ?? [])
                .filter { visibleIDs.contains($0) }
        )
    }

    private func readPendingReceiveEffectIndex() -> PendingReceiveEffectIndex? {
        pendingEffectLock.lock(); defer { pendingEffectLock.unlock() }
        return readPendingReceiveEffectIndexUnlocked()
    }

    private func readPendingReceiveEffectIndexUnlocked() -> PendingReceiveEffectIndex? {
        guard FileManager.default.fileExists(atPath: pendingReceiveEffectIndexURL.path) else {
            return PendingReceiveEffectIndex(records: [])
        }
        do {
            let data = try Data(contentsOf: pendingReceiveEffectIndexURL)
            return try JSONDecoder().decode(PendingReceiveEffectIndex.self, from: data)
        } catch {
            SecureLogger.error(
                "Pending receive-effect index is corrupt; refusing to overwrite it",
                category: .session
            )
            return nil
        }
    }

    private func writePendingReceiveEffectIndexUnlocked(
        _ index: PendingReceiveEffectIndex,
        durable: Bool
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(index) else { return false }
        return durable
            ? writeDurably(data, to: pendingReceiveEffectIndexURL)
            : write(data, to: pendingReceiveEffectIndexURL)
    }

    /// Union the envelope's obligations into the durable sidecar. Used before
    /// transcript commits and during legacy bootstrap; it deliberately never
    /// removes a record belonging to a concurrent/newer writer.
    private func mergePendingReceiveEffectIndex(
        for envelope: StoredPrivateChat,
        durable: Bool
    ) -> Bool {
        pendingEffectLock.lock(); defer { pendingEffectLock.unlock() }
        guard let existing = readPendingReceiveEffectIndexUnlocked()?.records else { return false }
        var records = existing
        let pendingIDs = Set(envelope.pendingReceiveEffectIDs ?? [])
        let existingKeys = Set(records.map { "\($0.peerID.id)\u{0}\($0.message.id)" })
        var seen = existingKeys
        for message in envelope.messages where pendingIDs.contains(message.id) {
            let key = "\(envelope.peerID.id)\u{0}\(message.id)"
            if seen.insert(key).inserted {
                records.append(PendingReceiveEffectRecord(peerID: envelope.peerID, message: message))
            }
        }
        records.sort {
            if $0.peerID.id != $1.peerID.id { return $0.peerID.id < $1.peerID.id }
            return $0.message.id < $1.message.id
        }
        if records == existing { return true }
        return writePendingReceiveEffectIndexUnlocked(
            PendingReceiveEffectIndex(records: records), durable: durable
        )
    }

    /// Replace one peer's obligations after its transcript commit. Records for
    /// all other peers remain untouched, so legacy and live writers can safely
    /// operate on separate queues.
    private func updatePendingReceiveEffectIndex(
        for envelope: StoredPrivateChat,
        durable: Bool
    ) -> Bool {
        pendingEffectLock.lock(); defer { pendingEffectLock.unlock() }
        guard let existing = readPendingReceiveEffectIndexUnlocked()?.records else { return false }
        var records = existing.filter {
            $0.peerID != envelope.peerID
        }
        let pendingIDs = Set(envelope.pendingReceiveEffectIDs ?? [])
        records.append(contentsOf: envelope.messages.compactMap { message in
            pendingIDs.contains(message.id)
                ? PendingReceiveEffectRecord(peerID: envelope.peerID, message: message)
                : nil
        })
        records.sort {
            if $0.peerID.id != $1.peerID.id { return $0.peerID.id < $1.peerID.id }
            return $0.message.id < $1.message.id
        }
        if records == existing { return true }
        return writePendingReceiveEffectIndexUnlocked(
            PendingReceiveEffectIndex(records: records), durable: durable
        )
    }

    /// Replay validates a snapshot without holding `pendingEffectLock`. Merge
    /// its cleanup into the latest sidecar so a commit that arrives during
    /// transcript validation cannot have its new obligation overwritten.
    /// A same-key record is removed only when its full payload is unchanged
    /// from the stale snapshot; concurrent replacements remain pending.
    private func removePendingReceiveEffectRecordsIfUnchanged(
        _ stale: [PendingReceiveEffectRecord],
        durable: Bool
    ) -> Bool {
        pendingEffectLock.lock(); defer { pendingEffectLock.unlock() }
        guard let existing = readPendingReceiveEffectIndexUnlocked()?.records else { return false }
        var staleByKey: [String: [PendingReceiveEffectRecord]] = [:]
        for record in stale {
            let key = "\(record.peerID.id)\u{0}\(record.message.id)"
            staleByKey[key, default: []].append(record)
        }
        let records = existing.filter { record in
            let key = "\(record.peerID.id)\u{0}\(record.message.id)"
            return staleByKey[key]?.contains(record) != true
        }
        if records == existing { return true }
        return writePendingReceiveEffectIndexUnlocked(
            PendingReceiveEffectIndex(records: records), durable: durable
        )
    }

    private func readPrivateConversationIndexManifestUnlocked() -> PrivateConversationIndexManifest? {
        guard FileManager.default.fileExists(atPath: privateConversationIndexURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: privateConversationIndexURL)
            let manifest = try JSONDecoder().decode(PrivateConversationIndexManifest.self, from: data)
            guard manifest.version == 2,
                  manifest.entryCount >= 0,
                  manifest.firstPage.count == min(
                    manifest.entryCount,
                    privateConversationIndexPageSize
                  ) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return manifest
        } catch {
            SecureLogger.error("Private conversation index manifest is unreadable: \(error)", category: .session)
            return nil
        }
    }

    private func orderNode(_ id: String, mutation: IndexMutation? = nil) -> OrderIndexNode? {
        if let created = mutation?.createdOrder[id] { return created }
        indexNodeReadObserver?()
        guard let data = try? Data(contentsOf: orderIndexNodeURL(id)) else { return nil }
        return try? JSONDecoder().decode(OrderIndexNode.self, from: data)
    }

    private func peerNode(_ id: String, mutation: IndexMutation? = nil) -> PeerIndexNode? {
        if let created = mutation?.createdPeer[id] { return created }
        indexNodeReadObserver?()
        guard let data = try? Data(contentsOf: peerIndexNodeURL(id)) else { return nil }
        return try? JSONDecoder().decode(PeerIndexNode.self, from: data)
    }

    private func conversationEntry(
        _ lhs: PrivateConversationIndexEntry,
        sortsBefore rhs: PrivateConversationIndexEntry
    ) -> Bool {
        if lhs.latestMessageAt != rhs.latestMessageAt {
            return lhs.latestMessageAt > rhs.latestMessageAt
        }
        if lhs.latestMessageID != rhs.latestMessageID {
            return lhs.latestMessageID > rhs.latestMessageID
        }
        return lhs.peerID.id > rhs.peerID.id
    }

    /// True when `entry` belongs strictly after the exclusive cursor in the
    /// newest-first total order.
    private func conversationEntry(
        _ entry: PrivateConversationIndexEntry,
        isAfter cursor: PrivateConversationCursor
    ) -> Bool {
        let cursorEntry = PrivateConversationIndexEntry(
            peerID: cursor.peerID,
            latestMessageAt: cursor.latestMessageAt,
            latestMessageID: cursor.latestMessageID
        )
        return conversationEntry(cursorEntry, sortsBefore: entry)
    }

    private func orderCompare(
        _ lhs: PrivateConversationIndexEntry,
        _ rhs: PrivateConversationIndexEntry
    ) -> Int {
        if lhs == rhs { return 0 }
        return conversationEntry(lhs, sortsBefore: rhs) ? -1 : 1
    }

    private func indexPriority(_ stableKey: String) -> UInt64 {
        let hex = Data(stableKey.utf8).sha256Fingerprint()
        return UInt64(hex.prefix(16), radix: 16) ?? 0
    }

    private func makeOrderNode(
        entry: PrivateConversationIndexEntry,
        priority: UInt64,
        left: String?,
        right: String?,
        mutation: inout IndexMutation
    ) -> String {
        let id = UUID().uuidString
        mutation.createdOrder[id] = OrderIndexNode(
            entry: entry, priority: priority, left: left, right: right
        )
        return id
    }

    private func makePeerNode(
        peerID: PeerID,
        entry: PrivateConversationIndexEntry,
        priority: UInt64,
        left: String?,
        right: String?,
        mutation: inout IndexMutation
    ) -> String {
        let id = UUID().uuidString
        mutation.createdPeer[id] = PeerIndexNode(
            peerID: peerID, entry: entry, priority: priority, left: left, right: right
        )
        return id
    }

    private func orderSplit(
        _ root: String?,
        at key: PrivateConversationIndexEntry,
        mutation: inout IndexMutation
    ) -> (String?, String?) {
        guard let root, let node = orderNode(root, mutation: mutation) else { return (nil, nil) }
        mutation.supersededOrder.insert(root)
        if orderCompare(node.entry, key) < 0 {
            let (leftOfKey, rightOfKey) = orderSplit(node.right, at: key, mutation: &mutation)
            let copied = makeOrderNode(
                entry: node.entry, priority: node.priority,
                left: node.left, right: leftOfKey, mutation: &mutation
            )
            return (copied, rightOfKey)
        }
        let (leftOfKey, rightOfKey) = orderSplit(node.left, at: key, mutation: &mutation)
        let copied = makeOrderNode(
            entry: node.entry, priority: node.priority,
            left: rightOfKey, right: node.right, mutation: &mutation
        )
        return (leftOfKey, copied)
    }

    private func orderMerge(
        _ left: String?,
        _ right: String?,
        mutation: inout IndexMutation
    ) -> String? {
        guard let left else { return right }
        guard let right else { return left }
        guard let leftNode = orderNode(left, mutation: mutation),
              let rightNode = orderNode(right, mutation: mutation) else { return nil }
        if leftNode.priority >= rightNode.priority {
            mutation.supersededOrder.insert(left)
            let merged = orderMerge(leftNode.right, right, mutation: &mutation)
            return makeOrderNode(
                entry: leftNode.entry, priority: leftNode.priority,
                left: leftNode.left, right: merged, mutation: &mutation
            )
        }
        mutation.supersededOrder.insert(right)
        let merged = orderMerge(left, rightNode.left, mutation: &mutation)
        return makeOrderNode(
            entry: rightNode.entry, priority: rightNode.priority,
            left: merged, right: rightNode.right, mutation: &mutation
        )
    }

    private func orderDelete(
        _ root: String?,
        key: PrivateConversationIndexEntry,
        mutation: inout IndexMutation
    ) -> String? {
        guard let root, let node = orderNode(root, mutation: mutation) else { return root }
        let comparison = orderCompare(key, node.entry)
        guard comparison != 0 else {
            mutation.supersededOrder.insert(root)
            return orderMerge(node.left, node.right, mutation: &mutation)
        }
        mutation.supersededOrder.insert(root)
        if comparison < 0 {
            let left = orderDelete(node.left, key: key, mutation: &mutation)
            return makeOrderNode(
                entry: node.entry, priority: node.priority,
                left: left, right: node.right, mutation: &mutation
            )
        }
        let right = orderDelete(node.right, key: key, mutation: &mutation)
        return makeOrderNode(
            entry: node.entry, priority: node.priority,
            left: node.left, right: right, mutation: &mutation
        )
    }

    private func orderInsert(
        _ root: String?,
        entry: PrivateConversationIndexEntry,
        mutation: inout IndexMutation
    ) -> String {
        let priority = indexPriority(entry.peerID.id)
        guard let root, let node = orderNode(root, mutation: mutation) else {
            return makeOrderNode(
                entry: entry, priority: priority,
                left: nil, right: nil, mutation: &mutation
            )
        }
        if priority > node.priority {
            let (left, right) = orderSplit(root, at: entry, mutation: &mutation)
            return makeOrderNode(
                entry: entry, priority: priority,
                left: left, right: right, mutation: &mutation
            )
        }
        mutation.supersededOrder.insert(root)
        if orderCompare(entry, node.entry) < 0 {
            let left = orderInsert(node.left, entry: entry, mutation: &mutation)
            return makeOrderNode(
                entry: node.entry, priority: node.priority,
                left: left, right: node.right, mutation: &mutation
            )
        }
        let right = orderInsert(node.right, entry: entry, mutation: &mutation)
        return makeOrderNode(
            entry: node.entry, priority: node.priority,
            left: node.left, right: right, mutation: &mutation
        )
    }

    private func peerLookup(_ root: String?, peerID: PeerID, mutation: IndexMutation? = nil) -> PrivateConversationIndexEntry? {
        var current = root
        while let id = current, let node = peerNode(id, mutation: mutation) {
            if peerID == node.peerID { return node.entry }
            current = peerID.id < node.peerID.id ? node.left : node.right
        }
        return nil
    }

    private func peerSplit(
        _ root: String?,
        at peerID: PeerID,
        mutation: inout IndexMutation
    ) -> (String?, String?) {
        guard let root, let node = peerNode(root, mutation: mutation) else { return (nil, nil) }
        mutation.supersededPeer.insert(root)
        if node.peerID.id < peerID.id {
            let (leftOfKey, rightOfKey) = peerSplit(node.right, at: peerID, mutation: &mutation)
            let copied = makePeerNode(
                peerID: node.peerID, entry: node.entry, priority: node.priority,
                left: node.left, right: leftOfKey, mutation: &mutation
            )
            return (copied, rightOfKey)
        }
        let (leftOfKey, rightOfKey) = peerSplit(node.left, at: peerID, mutation: &mutation)
        let copied = makePeerNode(
            peerID: node.peerID, entry: node.entry, priority: node.priority,
            left: rightOfKey, right: node.right, mutation: &mutation
        )
        return (leftOfKey, copied)
    }

    private func peerMerge(
        _ left: String?, _ right: String?, mutation: inout IndexMutation
    ) -> String? {
        guard let left else { return right }
        guard let right else { return left }
        guard let leftNode = peerNode(left, mutation: mutation),
              let rightNode = peerNode(right, mutation: mutation) else { return nil }
        if leftNode.priority >= rightNode.priority {
            mutation.supersededPeer.insert(left)
            let merged = peerMerge(leftNode.right, right, mutation: &mutation)
            return makePeerNode(
                peerID: leftNode.peerID, entry: leftNode.entry, priority: leftNode.priority,
                left: leftNode.left, right: merged, mutation: &mutation
            )
        }
        mutation.supersededPeer.insert(right)
        let merged = peerMerge(left, rightNode.left, mutation: &mutation)
        return makePeerNode(
            peerID: rightNode.peerID, entry: rightNode.entry, priority: rightNode.priority,
            left: merged, right: rightNode.right, mutation: &mutation
        )
    }

    private func peerDelete(
        _ root: String?, peerID: PeerID, mutation: inout IndexMutation
    ) -> String? {
        guard let root, let node = peerNode(root, mutation: mutation) else { return root }
        guard peerID != node.peerID else {
            mutation.supersededPeer.insert(root)
            return peerMerge(node.left, node.right, mutation: &mutation)
        }
        mutation.supersededPeer.insert(root)
        if peerID.id < node.peerID.id {
            let left = peerDelete(node.left, peerID: peerID, mutation: &mutation)
            return makePeerNode(
                peerID: node.peerID, entry: node.entry, priority: node.priority,
                left: left, right: node.right, mutation: &mutation
            )
        }
        let right = peerDelete(node.right, peerID: peerID, mutation: &mutation)
        return makePeerNode(
            peerID: node.peerID, entry: node.entry, priority: node.priority,
            left: node.left, right: right, mutation: &mutation
        )
    }

    private func peerInsert(
        _ root: String?, entry: PrivateConversationIndexEntry, mutation: inout IndexMutation
    ) -> String {
        let priority = indexPriority(entry.peerID.id)
        guard let root, let node = peerNode(root, mutation: mutation) else {
            return makePeerNode(
                peerID: entry.peerID, entry: entry, priority: priority,
                left: nil, right: nil, mutation: &mutation
            )
        }
        if priority > node.priority {
            let (left, right) = peerSplit(root, at: entry.peerID, mutation: &mutation)
            return makePeerNode(
                peerID: entry.peerID, entry: entry, priority: priority,
                left: left, right: right, mutation: &mutation
            )
        }
        mutation.supersededPeer.insert(root)
        if entry.peerID.id < node.peerID.id {
            let left = peerInsert(node.left, entry: entry, mutation: &mutation)
            return makePeerNode(
                peerID: node.peerID, entry: node.entry, priority: node.priority,
                left: left, right: node.right, mutation: &mutation
            )
        }
        let right = peerInsert(node.right, entry: entry, mutation: &mutation)
        return makePeerNode(
            peerID: node.peerID, entry: node.entry, priority: node.priority,
            left: node.left, right: right, mutation: &mutation
        )
    }

    private func orderedIndexPageUnlocked(
        root: String?,
        after cursor: PrivateConversationCursor?,
        limit: Int
    ) -> (entries: [PrivateConversationIndexEntry], hasMore: Bool) {
        let cursorEntry = cursor.map {
            PrivateConversationIndexEntry(
                peerID: $0.peerID,
                latestMessageAt: $0.latestMessageAt,
                latestMessageID: $0.latestMessageID
            )
        }
        var stack: [OrderIndexNode] = []
        var current = root
        while let id = current, let node = orderNode(id) {
            if let cursorEntry {
                if orderCompare(node.entry, cursorEntry) > 0 {
                    stack.append(node)
                    current = node.left
                } else {
                    current = node.right
                }
            } else {
                stack.append(node)
                current = node.left
            }
        }

        var entries: [PrivateConversationIndexEntry] = []
        let target = limit == Int.max ? Int.max : limit + 1
        while !stack.isEmpty, entries.count < target {
            let node = stack.removeLast()
            entries.append(node.entry)
            var right = node.right
            while let id = right, let next = orderNode(id) {
                stack.append(next)
                right = next.left
            }
        }
        let hasMore = entries.count > limit
        if hasMore { entries.removeLast() }
        return (entries, hasMore)
    }

    private func latestEntry(for envelope: StoredPrivateChat) -> PrivateConversationIndexEntry? {
        guard let latest = envelope.messages.max(by: { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }) else { return nil }
        return PrivateConversationIndexEntry(
            peerID: envelope.peerID,
            latestMessageAt: latest.timestamp,
            latestMessageID: latest.id
        )
    }

    private func writeImmutableIndexNode(_ data: Data, to url: URL) -> Bool {
        do {
            indexNodeWriteObserver?()
            try data.write(to: url, options: [])
            applyProtection(to: url)
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            return true
        } catch {
            SecureLogger.error("Conversation index node write failed: \(error)", category: .session)
            return false
        }
    }

    private func persistIndexMutationUnlocked(
        _ mutation: IndexMutation,
        manifest: PrivateConversationIndexManifest
    ) -> Bool {
        let liveOrder = mutation.createdOrder.filter { !mutation.supersededOrder.contains($0.key) }
        let livePeer = mutation.createdPeer.filter { !mutation.supersededPeer.contains($0.key) }
        var createdURLs: [URL] = []
        for (id, node) in liveOrder {
            let url = orderIndexNodeURL(id)
            guard let data = try? JSONEncoder().encode(node), writeImmutableIndexNode(data, to: url) else {
                createdURLs.forEach { try? FileManager.default.removeItem(at: $0) }
                return false
            }
            createdURLs.append(url)
        }
        for (id, node) in livePeer {
            let url = peerIndexNodeURL(id)
            guard let data = try? JSONEncoder().encode(node), writeImmutableIndexNode(data, to: url) else {
                createdURLs.forEach { try? FileManager.default.removeItem(at: $0) }
                return false
            }
            createdURLs.append(url)
        }
        do {
            if !createdURLs.isEmpty { try syncDirectory(privateIndexNodeDir) }
        } catch {
            createdURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            return false
        }
        guard let manifestData = try? JSONEncoder().encode(manifest),
              writeDurably(manifestData, to: privateConversationIndexURL) else {
            createdURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            try? syncDirectory(privateIndexNodeDir)
            return false
        }

        var removed = false
        for id in mutation.supersededOrder where mutation.createdOrder[id] == nil {
            let url = orderIndexNodeURL(id)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                removed = true
            }
        }
        for id in mutation.supersededPeer where mutation.createdPeer[id] == nil {
            let url = peerIndexNodeURL(id)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                removed = true
            }
        }
        if removed { try? syncDirectory(privateIndexNodeDir) }
        return true
    }

    private func updatePrivateConversationIndexBatch(
        for envelopes: [StoredPrivateChat],
        legacyCursorFilename: String? = nil,
        legacyRebuildComplete: Bool? = nil,
        onlyIfNewer: Bool = false
    ) -> Bool {
        indexLock.lock(); defer { indexLock.unlock() }
        var manifest = readPrivateConversationIndexManifestUnlocked() ?? .emptyLegacy
        var mutation = IndexMutation()
        var indexChanged = false
        for envelope in envelopes {
            let old = peerLookup(manifest.peerRoot, peerID: envelope.peerID, mutation: mutation)
            let candidate = latestEntry(for: envelope)
            if old == candidate { continue }
            if onlyIfNewer {
                guard let candidate else { continue }
                // A live writer may have committed after the legacy worker
                // parsed this file. Never let that stale migration page move
                // the conversation backwards.
                if let old, orderCompare(old, candidate) <= 0 { continue }
            }
            if let old {
                manifest.orderRoot = orderDelete(
                    manifest.orderRoot, key: old, mutation: &mutation
                )
                manifest.peerRoot = peerDelete(
                    manifest.peerRoot, peerID: envelope.peerID, mutation: &mutation
                )
                manifest.entryCount -= 1
                indexChanged = true
            }
            if let entry = candidate {
                manifest.orderRoot = orderInsert(
                    manifest.orderRoot, entry: entry, mutation: &mutation
                )
                manifest.peerRoot = peerInsert(
                    manifest.peerRoot, entry: entry, mutation: &mutation
                )
                manifest.entryCount += 1
                indexChanged = true
            }
        }
        if let legacyRebuildComplete {
            manifest.legacyRebuildComplete = legacyRebuildComplete
            manifest.legacyRebuildCursorFilename = legacyCursorFilename
        }
        if !indexChanged, legacyRebuildComplete == nil { return true }
        manifest.firstPage = orderedIndexPageForMutation(
            root: manifest.orderRoot,
            limit: privateConversationIndexPageSize,
            mutation: mutation
        )
        return persistIndexMutationUnlocked(mutation, manifest: manifest)
    }

    private func orderedIndexPageForMutation(
        root: String?, limit: Int, mutation: IndexMutation
    ) -> [PrivateConversationIndexEntry] {
        var stack: [OrderIndexNode] = []
        var current = root
        while let id = current, let node = orderNode(id, mutation: mutation) {
            stack.append(node)
            current = node.left
        }
        var entries: [PrivateConversationIndexEntry] = []
        while !stack.isEmpty, entries.count < limit {
            let node = stack.removeLast()
            entries.append(node.entry)
            var right = node.right
            while let id = right, let next = orderNode(id, mutation: mutation) {
                stack.append(next)
                right = next.left
            }
        }
        return entries
    }

    private func updatePrivateConversationIndex(
        for envelope: StoredPrivateChat,
        durable: Bool
    ) -> Bool {
        _ = durable
        return updatePrivateConversationIndexBatch(for: [envelope])
    }

    @discardableResult
    private func writePrivateWindow(_ envelope: StoredPrivateChat, durable: Bool) -> Bool {
        privateWindowWriteLock.lock(); defer { privateWindowWriteLock.unlock() }
        return writePrivateWindowUnlocked(envelope, durable: durable)
    }

    private func writeLegacyPrivateWindowIfAbsent(_ envelope: StoredPrivateChat) -> Bool {
        privateWindowWriteLock.lock(); defer { privateWindowWriteLock.unlock() }
        let url = privateWindowFileURL(for: envelope.peerID)
        guard !FileManager.default.fileExists(atPath: url.path) else { return true }
        return writePrivateWindowUnlocked(envelope, durable: false)
    }

    private func writePrivateWindowUnlocked(_ envelope: StoredPrivateChat, durable: Bool) -> Bool {
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        let url = privateWindowFileURL(for: envelope.peerID)
        return durable ? writeDurably(data, to: url) : write(data, to: url)
    }

    @discardableResult
    private func writePrivate(peerID: PeerID, messages: [BitchatMessage]) -> Bool {
        let pending = readPrivate(at: privateFileURL(for: peerID))?.pendingReceiveEffectIDs
        let envelope = StoredPrivateChat(peerID: peerID, messages: messages, pendingReceiveEffectIDs: pending)
        guard let data = try? encoder.encode(envelope) else { return false }
        guard write(data, to: privateFileURL(for: peerID)) else { return false }
        let window = privateWindowEnvelope(from: envelope)
        guard writePrivateWindow(window, durable: false) else { return false }
        guard updatePrivateConversationIndex(for: window, durable: true) else { return false }
        return updatePendingReceiveEffectIndex(for: envelope, durable: true)
    }

    private func writePrivateDurably(
        peerID: PeerID,
        messages: [BitchatMessage],
        pendingReceiveEffectMessageID: String? = nil,
        pendingReceiveEffectIDs: [String]? = nil
    ) -> Bool {
        var pending = pendingReceiveEffectIDs ??
            readPrivate(at: privateFileURL(for: peerID))?.pendingReceiveEffectIDs ?? []
        if let pendingReceiveEffectMessageID, !pending.contains(pendingReceiveEffectMessageID) {
            pending.append(pendingReceiveEffectMessageID)
        }
        let envelope = StoredPrivateChat(
            peerID: peerID,
            messages: messages,
            pendingReceiveEffectIDs: pending
        )
        // Additions become discoverable before the transcript commit; replay
        // validates them against the transcript. Removals happen only after
        // the transcript/index commits, making both crash windows safe.
        guard mergePendingReceiveEffectIndex(for: envelope, durable: true) else { return false }
        guard let data = try? encoder.encode(envelope) else { return false }
        guard writeDurably(data, to: privateFileURL(for: peerID)) else { return false }
        let window = privateWindowEnvelope(from: envelope)
        guard writePrivateWindow(window, durable: true) else { return false }
        guard updatePrivateConversationIndex(for: window, durable: true) else { return false }
        return updatePendingReceiveEffectIndex(for: envelope, durable: true)
    }

    private func mergedPrivateMessages(
        existing: [BitchatMessage],
        incoming: [BitchatMessage]
    ) -> [BitchatMessage] {
        var byID: [String: BitchatMessage] = [:]
        for message in existing { byID[message.id] = message }
        for message in incoming { byID[message.id] = message }
        return trimmed(Array(byID.values), cap: cap)
    }

    private func readControlReceipts() -> [String] {
        guard let data = try? Data(contentsOf: controlReceiptsURL),
              let stored = try? decoder.decode(StoredControlReceipts.self, from: data)
        else { return [] }
        return stored.keys
    }

    private func controlReceiptKey(peerID: PeerID, messageID: String) -> String {
        Data("\(peerID.id)\u{0}\(messageID)".utf8).sha256Fingerprint()
    }

    private func readMeshOutbox(ownerID: String) -> StoredMeshOutbox? {
        guard FileManager.default.fileExists(atPath: meshOutboxURL.path) else {
            return StoredMeshOutbox(
                ownerID: ownerID,
                nextSequence: 0,
                lastWireTimestampMillis: 0,
                obligations: []
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: meshOutboxURL)
        } catch {
            SecureLogger.error("Could not read durable mesh outbox: \(error)", category: .session)
            return nil
        }
        guard let stored = try? decoder.decode(StoredMeshOutbox.self, from: data) else {
            // Never reinterpret a corrupt journal as an empty one and overwrite
            // obligations that may still be recoverable from a backup/forensics.
            SecureLogger.error("Durable mesh outbox is corrupt; refusing to overwrite it", category: .session)
            return nil
        }
        guard stored.ownerID == ownerID else {
            SecureLogger.warning("Discarding mesh outbox owned by a different identity", category: .session)
            try? FileManager.default.removeItem(at: meshOutboxURL)
            return StoredMeshOutbox(
                ownerID: ownerID,
                nextSequence: 0,
                lastWireTimestampMillis: 0,
                obligations: []
            )
        }
        return stored
    }

    private func writeMeshOutbox(_ envelope: StoredMeshOutbox) -> Bool {
        guard let data = try? encoder.encode(envelope) else { return false }
        return writeDurably(data, to: meshOutboxURL)
    }

    /// Best-effort atomic write used by normal write-through persistence. The
    /// explicit delivery barrier below adds fsync and reports its result.
    @discardableResult
    private func write(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: [.atomic])
            applyProtection(to: url)
            return true
        } catch {
            SecureLogger.error("MessageStore write failed: \(error)", category: .session)
            return false
        }
    }

    /// Write to a sibling temporary file, fsync it, then atomically rename it
    /// over the destination. A crash before the rename leaves the previous
    /// committed value intact; a crash after it sees the complete new value.
    private func writeDurably(_ data: Data, to url: URL) -> Bool {
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            try data.write(to: temporaryURL, options: [])
            applyProtection(to: temporaryURL)

            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            try beforeAtomicReplace?()

            #if canImport(Darwin)
            guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try syncDirectory(url.deletingLastPathComponent())
            #else
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
            #endif

            applyProtection(to: url)
            return true
        } catch {
            SecureLogger.error("MessageStore write failed: \(error)", category: .session)
            return false
        }
    }

    private func createDirectories() throws {
        for dir in [baseDir, privateDir, privateWindowDir, privateIndexNodeDir, channelDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        applyProtection(to: baseDir)
    }

    /// Delete only uniquely named, already-detached old-account trees. Never
    /// enumerate/delete the live `baseDir`, so a delayed retry cannot erase
    /// media/transcripts written by a newly activated account.
    private func retryPendingWipeCleanup() -> Bool {
        let parent = baseDir.deletingLastPathComponent()
        let prefix = ".\(baseDir.lastPathComponent).wipe-"
        let tombstones: [URL]
        do {
            tombstones = try directoryLister(parent)
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
        } catch {
            SecureLogger.error("MessageStore tombstone enumeration failed: \(error)", category: .session)
            return false
        }
        var complete = true
        for tombstone in tombstones {
            do {
                try FileManager.default.removeItem(at: tombstone)
            } catch {
                complete = false
                SecureLogger.error("MessageStore tombstone cleanup deferred: \(error)", category: .session)
            }
        }
        if !tombstones.isEmpty {
            do { try syncDirectory(parent) }
            catch {
                complete = false
                SecureLogger.error("MessageStore tombstone durability deferred: \(error)", category: .session)
            }
        }
        return complete
    }

    private func syncDirectory(_ directory: URL) throws {
        try DirectoryDurability.synchronize(
            directory,
            faultInjector: directorySyncFault
        )
    }

    private func trimmed(_ messages: [BitchatMessage], cap: Int) -> [BitchatMessage] {
        let deduped = messages.cleanedAndDeduped()
        guard deduped.count > cap else { return deduped }
        return Array(deduped.suffix(cap))
    }

    /// Apply `NSFileProtectionComplete` at rest. No-op where Data Protection
    /// is unavailable (macOS); failures are non-fatal.
    private func applyProtection(to url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path
        )
        #endif
    }

    /// Map an arbitrary id to a safe, collision-resistant filename component.
    static func fileSafeKey(_ id: String) -> String {
        Data(id.utf8).sha256Fingerprint()
    }
}
