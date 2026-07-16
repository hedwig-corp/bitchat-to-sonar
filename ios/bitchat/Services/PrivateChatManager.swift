//
// PrivateChatManager.swift
// bitchat
//
// Manages private chat sessions and messages
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import Foundation
import SwiftUI

/// Manages all private chat functionality
final class PrivateChatManager: ObservableObject {
    /// First paint reads a fixed number of summary rows. Remaining summaries
    /// page in after render; transcript windows load only when opened.
    static let startupChatPageSize = 24
    /// Encrypted on-disk store backing the in-memory transcripts: hydrated on
    /// launch, written through on every change so chats survive a restart.
    /// Mesh DMs stay LOCAL-ONLY — this store is private to the device.
    private let store: MessageStore

    @Published var privateChats: [PeerID: [BitchatMessage]] = [:] {
        didSet {
            guard !isNormalizingPrivateChats else { return }
            let normalized = normalizedPrivateChats(privateChats)
            if normalized != privateChats {
                isNormalizingPrivateChats = true
                privateChats = normalized
                isNormalizingPrivateChats = false
            }
            persistChanges(old: normalizedPrivateChats(oldValue), new: normalized)
        }
    }
    @Published var selectedPeer: PeerID? = nil
    @Published var unreadMessages: Set<PeerID> = []

    private var selectedPeerFingerprint: String? = nil
    var sentReadReceipts: Set<String> = []  // Made accessible for ChatViewModel

    weak var meshService: Transport?
    // Route acks/receipts via MessageRouter (chooses mesh or Nostr)
    weak var messageRouter: MessageRouter?
    // Peer service for looking up peer info during consolidation
    weak var unifiedPeerService: UnifiedPeerService?

    /// Set while we are hydrating from disk on launch, so the write-through
    /// `didSet` doesn't echo the loaded data straight back to disk.
    private var isHydrating = false
    /// A receive transaction publishes its canonical in-memory snapshot before
    /// awaiting the durable barrier. Suppress the ordinary detached didSet
    /// writer for that one mutation; the awaited commit owns its ordering.
    private var isDurableReceiveStaging = false
    private var isNormalizingPrivateChats = false
    /// Only these peers may retain a transcript window. Every other dictionary
    /// value is a one-message chat-list summary.
    private var hydratedTranscriptPeers: Set<PeerID> = []
    private var peersWithNoOlderHistory: Set<PeerID> = []
    private var peersLoadingOlderHistory: Set<PeerID> = []
    private var nextStoredChatCursor: PrivateConversationCursor?
    private var hasMoreStoredChats = false

    init(meshService: Transport? = nil, store: MessageStore = .shared) {
        self.meshService = meshService
        self.store = store
        hydrateFromStore()
    }

    // Hard cap for every live/open private-chat window.
    private let privateChatCap = TransportConfig.privateChatCap

    // MARK: - Persistence (write-through to MessageStore)

    private func boundedMessages(_ messages: [BitchatMessage], for peerID: PeerID) -> [BitchatMessage] {
        var byID: [String: BitchatMessage] = [:]
        // Preserve caller precedence for duplicate stable IDs (for example an
        // in-memory delivery-status update must win over an older disk row).
        for message in messages {
            byID[message.id] = message
        }
        let ordered = byID.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }
        let limit = hydratedTranscriptPeers.contains(peerID) ? privateChatCap : 1
        return Array(ordered.suffix(limit))
    }

    private func normalizedPrivateChats(
        _ chats: [PeerID: [BitchatMessage]]
    ) -> [PeerID: [BitchatMessage]] {
        chats.reduce(into: [:]) { result, entry in
            // Preserve explicitly-created empty conversations: send/receive
            // paths commonly insert `[]` and then append through the computed
            // ChatViewModel dictionary property in a second mutation.
            result[entry.key] = boundedMessages(entry.value, for: entry.key)
        }
    }

    private func replaceWithoutPersistence(_ body: () -> Void) {
        isHydrating = true
        body()
        isHydrating = false
    }

    private func compactToSummary(_ peerID: PeerID) {
        hydratedTranscriptPeers.remove(peerID)
        peersLoadingOlderHistory.remove(peerID)
        peersWithNoOlderHistory.remove(peerID)
        replaceWithoutPersistence {
            if let latest = privateChats[peerID]?.last {
                privateChats[peerID] = [latest]
            }
        }
    }

    /// Load only the newest bounded summary page synchronously for first paint.
    private func hydrateFromStore() {
        let snapshot = store.loadPrivateSnapshot(chatLimit: Self.startupChatPageSize)
        let persisted = snapshot.chats
        nextStoredChatCursor = snapshot.nextCursor
        hasMoreStoredChats = snapshot.hasMore
        guard !persisted.isEmpty else { return }
        isHydrating = true
        privateChats = persisted
        isHydrating = false
    }

    /// Page only chat-list summaries after first paint. No transcript window is
    /// retained for a conversation until [startChat] opens it.
    @MainActor
    func hydrateRemainingChatPages() async {
        while hasMoreStoredChats {
            let page = await store.loadPrivateSnapshotPage(
                after: nextStoredChatCursor,
                chatLimit: Self.startupChatPageSize
            )
            guard page.scannedFileCount > 0 else {
                hasMoreStoredChats = false
                break
            }
            mergeSummaryPage(page)
            nextStoredChatCursor = page.nextCursor
            hasMoreStoredChats = page.hasMore
            objectWillChange.send()
            await Task.yield()
        }

        // Existing installs may not have bounded window sidecars yet. Rebuild
        // them in very small background pages; never parse legacy full bodies
        // on the synchronous first-paint path.
        while true {
            let page = await store.rebuildLegacyPrivateWindowPage(chatLimit: 4)
            guard page.scannedFileCount > 0 else { break }
            mergeSummaryPage(page)
            objectWillChange.send()
            guard page.hasMore else { break }
            await Task.yield()
        }
    }

    @MainActor
    private func mergeSummaryPage(_ page: PrivateStoreSnapshot) {
        replaceWithoutPersistence {
            for (peerID, persisted) in page.chats {
                let current = privateChats[peerID] ?? []
                privateChats[peerID] = boundedMessages(persisted + current, for: peerID)
            }
        }
    }

    func pendingReceiveEffectsForStartupReplay() async -> [(peerID: PeerID, message: BitchatMessage)] {
        await store.loadPendingReceiveEffects()
    }

    /// Write through only the peers whose transcript actually changed.
    private func persistChanges(old: [PeerID: [BitchatMessage]], new: [PeerID: [BitchatMessage]]) {
        guard !isHydrating, !isDurableReceiveStaging else { return }
        // Peers added or modified: re-save their (deduped, capped) transcript.
        for (peerID, messages) in new where old[peerID] != messages {
            store.savePrivateWindow(peerID: peerID, messages: messages)
        }
        // Peers removed (e.g. consolidation merged them away): drop their file.
        for peerID in old.keys where new[peerID] == nil {
            let removedIDs = Set((old[peerID] ?? []).map(\.id))
            let migrationTarget = new.first { _, messages in
                !removedIDs.isEmpty && removedIDs.isSubset(of: Set(messages.map(\.id)))
            }?.key
            if let migrationTarget {
                store.migratePrivateTranscript(from: peerID, to: migrationTarget)
            } else {
                store.savePrivate(peerID: peerID, messages: [])
            }
        }
    }

    /// Force write-through after mutating a property on a BitchatMessage class
    /// instance. Dictionary `oldValue` and `newValue` can share that reference,
    /// so equality-based didSet detection alone cannot observe status changes.
    @MainActor
    func persistCurrentTranscript(for peerID: PeerID) {
        guard let messages = privateChats[peerID] else { return }
        let bounded = boundedMessages(messages, for: peerID)
        if bounded != messages { privateChats[peerID] = bounded }
        store.savePrivateWindow(peerID: peerID, messages: bounded)
    }

    func currentStorageGeneration() -> String {
        store.currentStorageGeneration()
    }

    /// Apply a receipt by stable message ID against the full local transcript.
    /// Closed chats retain only their latest summary in memory, so an older row
    /// is deliberately left off-screen while its durable status is updated.
    @MainActor
    func commitDeliveryStatus(
        messageID: String,
        status: DeliveryStatus,
        preferredPeerIDs: [PeerID],
        expectedGeneration: String
    ) async -> PrivateDeliveryStatusMutationResult {
        var candidates: [PeerID] = []
        var seen = Set<PeerID>()
        let requestedPeers = preferredPeerIDs.isEmpty
            ? Array(privateChats.keys)
            : preferredPeerIDs
        for peerID in requestedPeers
        where seen.insert(peerID).inserted {
            candidates.append(peerID)
        }

        let result = await store.commitPrivateDeliveryStatus(
            peerIDs: candidates,
            messageID: messageID,
            status: status,
            expectedGeneration: expectedGeneration
        )
        guard store.currentStorageGeneration() == expectedGeneration else {
            return .failed
        }
        guard let peerID = result.peerID,
              let persistedStatus = result.message?.deliveryStatus,
              let index = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) else {
            return result
        }

        // This branch covers an open transcript or the actual latest summary.
        // A closed non-latest target is absent and therefore cannot displace the
        // newer summary row.
        replaceWithoutPersistence {
            guard let messages = privateChats[peerID], index < messages.count else { return }
            messages[index].deliveryStatus = persistedStatus
            privateChats[peerID] = boundedMessages(messages, for: peerID)
        }
        objectWillChange.send()
        return result
    }

    /// Stable-ID admission shared by internet and mesh receive paths. Disk
    /// dedupe and insertion are one transaction; UI state is projected only
    /// after that transaction succeeds.
    @MainActor
    func commitIncomingMessageAtomically(
        _ message: BitchatMessage,
        preferredPeerID: PeerID,
        expectedGeneration: String
    ) async -> PrivateReceiveCommitResult {
        let result = await store.commitIncomingPrivate(
            peerID: preferredPeerID,
            message: message,
            expectedGeneration: expectedGeneration
        )
        guard result.disposition != .failed,
              store.currentStorageGeneration() == expectedGeneration else {
            return .failed
        }
        if let storedMessage = result.message {
            isDurableReceiveStaging = true
            privateChats[preferredPeerID] = boundedMessages(
                privateChats[preferredPeerID, default: []] + [storedMessage],
                for: preferredPeerID
            )
            isDurableReceiveStaging = false
        }
        return result
    }

    /// Flush the transcript that contains an accepted mesh message. The
    /// preferred peer covers the normal path; scanning aliases preserves
    /// correctness after Noise/Nostr chat migration or mirroring.
    @MainActor
    func commitIncomingMessage(
        _ messageID: String,
        preferredPeerID: PeerID,
        expectedGeneration: String
    ) async -> Bool {
        if let messages = privateChats[preferredPeerID],
           messages.contains(where: { $0.id == messageID }) {
            return await store.commitPrivate(
                peerID: preferredPeerID,
                messages: messages,
                expectedGeneration: expectedGeneration,
                mergeExistingTranscript: true
            )
        }

        guard let (peerID, messages) = privateChats.first(where: { _, messages in
            messages.contains(where: { $0.id == messageID })
        }) else {
            return false
        }
        return await store.commitPrivate(
            peerID: peerID,
            messages: messages,
            expectedGeneration: expectedGeneration,
            mergeExistingTranscript: true
        )
    }

    /// Install the received message in the canonical snapshot before awaiting
    /// its durable commit. Any same-peer mutation queued while this suspends is
    /// therefore based on a snapshot that already contains the received row;
    /// it cannot overwrite an ACKed message with an older transcript.
    @MainActor
    func commitStagedIncomingMessage(
        _ message: BitchatMessage,
        preferredPeerID: PeerID,
        expectedGeneration: String
    ) async -> Bool {
        let previous = privateChats[preferredPeerID] ?? []
        var staged = previous
        guard !staged.contains(where: { $0.id == message.id }) else {
            return await store.commitPrivate(
                peerID: preferredPeerID,
                messages: staged,
                expectedGeneration: expectedGeneration,
                mergeExistingTranscript: true
            )
        }
        staged.append(message)
        staged = boundedMessages(staged, for: preferredPeerID)
        isDurableReceiveStaging = true
        privateChats[preferredPeerID] = staged
        isDurableReceiveStaging = false
        let committed = await store.commitPrivate(
            peerID: preferredPeerID,
            messages: staged,
            expectedGeneration: expectedGeneration,
            pendingReceiveEffectMessageID: message.id,
            mergeExistingTranscript: true
        )
        guard committed else {
            // Keep later same-peer changes, but restore the summary/window that
            // existed before this unpublished row was staged.
            isDurableReceiveStaging = true
            let later = (privateChats[preferredPeerID] ?? []).filter { $0.id != message.id }
            privateChats[preferredPeerID] = boundedMessages(previous + later, for: preferredPeerID)
            isDurableReceiveStaging = false
            return false
        }
        return true
    }

    func hasPendingReceiveEffects(_ messageID: String, preferredPeerID: PeerID) -> Bool {
        if store.hasPendingReceiveEffects(peerID: preferredPeerID, messageID: messageID) {
            return true
        }
        return privateChats.keys.contains {
            $0 != preferredPeerID && store.hasPendingReceiveEffects(peerID: $0, messageID: messageID)
        }
    }

    @MainActor
    func commitReceiveEffectsProcessed(
        _ messageID: String,
        preferredPeerID: PeerID,
        expectedGeneration: String
    ) async -> Bool {
        let owner = privateChats.keys.first {
            store.hasPendingReceiveEffects(peerID: $0, messageID: messageID)
        } ?? preferredPeerID
        return await store.commitReceiveEffectsProcessed(
            peerID: owner,
            messageID: messageID,
            expectedGeneration: expectedGeneration
        )
    }

    /// Favorite/unfavorite controls intentionally do not enter the transcript,
    /// so persist a bounded acceptance receipt before acknowledging them.
    @MainActor
    func commitIncomingControl(
        _ messageID: String,
        from peerID: PeerID,
        expectedGeneration: String
    ) async -> Bool {
        await store.commitControlReceipt(peerID: peerID, messageID: messageID, expectedGeneration: expectedGeneration)
    }

    // MARK: - Message Consolidation

    /// Consolidates messages from different peer ID representations into a single chat.
    /// This ensures messages from stable Noise keys and temporary Nostr peer IDs are merged.
    /// - Parameters:
    ///   - peerID: The target peer ID to consolidate messages into
    ///   - peerNickname: The peer's display name (lowercased for matching)
    ///   - persistedReadReceipts: The persisted read receipts set from ChatViewModel (UserDefaults-backed)
    /// - Returns: True if any unread messages were found during consolidation
    @MainActor
    func consolidateMessages(for peerID: PeerID, peerNickname: String, persistedReadReceipts: Set<String>) -> Bool {
        guard let meshService = meshService else { return false }
        var hasUnreadMessages = false

        // 1. Consolidate from stable Noise key (64-char hex)
        if let peer = unifiedPeerService?.getPeer(by: peerID) {
            let noiseKeyHex = PeerID(hexData: peer.noisePublicKey)

            if noiseKeyHex != peerID, let nostrMessages = privateChats[noiseKeyHex], !nostrMessages.isEmpty {
                if privateChats[peerID] == nil {
                    privateChats[peerID] = []
                }

                let existingMessageIds = Set(privateChats[peerID]?.map { $0.id } ?? [])
                for message in nostrMessages {
                    if !existingMessageIds.contains(message.id) {
                        // Update senderPeerID for correct read receipts
                        let updatedMessage = BitchatMessage(
                            id: message.id,
                            sender: message.sender,
                            content: message.content,
                            timestamp: message.timestamp,
                            isRelay: message.isRelay,
                            originalSender: message.originalSender,
                            isPrivate: message.isPrivate,
                            recipientNickname: message.recipientNickname,
                            senderPeerID: message.senderPeerID == meshService.myPeerID ? meshService.myPeerID : peerID,
                            receivedViaInternet: message.receivedViaInternet,
                            mentions: message.mentions,
                            deliveryStatus: message.deliveryStatus
                        )
                        privateChats[peerID]?.append(updatedMessage)

                        // Check for recent unread messages (< 60s, not sent by us, not already read)
                        // Use persistedReadReceipts to correctly identify already-read messages after app restart
                        if message.senderPeerID != meshService.myPeerID {
                            let messageAge = Date().timeIntervalSince(message.timestamp)
                            if messageAge < 60 && !persistedReadReceipts.contains(message.id) {
                                hasUnreadMessages = true
                            }
                        }
                    }
                }

                privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }

                if hasUnreadMessages {
                    unreadMessages.insert(peerID)
                } else if unreadMessages.contains(noiseKeyHex) {
                    unreadMessages.remove(noiseKeyHex)
                }

                store.migratePrivateTranscript(from: noiseKeyHex, to: peerID)
                privateChats.removeValue(forKey: noiseKeyHex)
            }
        }

        // 2. Consolidate from temporary Nostr peer IDs (nostr_* prefixed)
        let normalizedNickname = peerNickname.lowercased()
        var tempPeerIDsToConsolidate: [PeerID] = []

        for (storedPeerID, messages) in privateChats {
            if storedPeerID.isGeoDM && storedPeerID != peerID {
                let nicknamesMatch = messages.allSatisfy { $0.sender.lowercased() == normalizedNickname }
                if nicknamesMatch && !messages.isEmpty {
                    tempPeerIDsToConsolidate.append(storedPeerID)
                }
            }
        }

        if !tempPeerIDsToConsolidate.isEmpty {
            if privateChats[peerID] == nil {
                privateChats[peerID] = []
            }

            let existingMessageIds = Set(privateChats[peerID]?.map { $0.id } ?? [])
            var consolidatedCount = 0
            var hadUnreadTemp = false

            for tempPeerID in tempPeerIDsToConsolidate {
                if unreadMessages.contains(tempPeerID) {
                    hadUnreadTemp = true
                }

                if let tempMessages = privateChats[tempPeerID] {
                    for message in tempMessages {
                        if !existingMessageIds.contains(message.id) {
                            let updatedMessage = BitchatMessage(
                                id: message.id,
                                sender: message.sender,
                                content: message.content,
                                timestamp: message.timestamp,
                                isRelay: message.isRelay,
                                originalSender: message.originalSender,
                                isPrivate: message.isPrivate,
                                recipientNickname: message.recipientNickname,
                                senderPeerID: peerID,
                                receivedViaInternet: message.receivedViaInternet,
                                mentions: message.mentions,
                                deliveryStatus: message.deliveryStatus
                            )
                            privateChats[peerID]?.append(updatedMessage)
                            consolidatedCount += 1
                        }
                    }
                    store.migratePrivateTranscript(from: tempPeerID, to: peerID)
                    privateChats.removeValue(forKey: tempPeerID)
                    unreadMessages.remove(tempPeerID)
                }
            }

            if hadUnreadTemp {
                unreadMessages.insert(peerID)
                hasUnreadMessages = true
                SecureLogger.debug("📬 Transferred unread status from temp peer IDs to \(peerID)", category: .session)
            }

            if consolidatedCount > 0 {
                privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
                SecureLogger.info("📥 Consolidated \(consolidatedCount) Nostr messages from temporary peer IDs to \(peerNickname)", category: .session)
            }
        }

        return hasUnreadMessages
    }

    /// Syncs the read receipt tracking between manager and view model for sent messages
    @MainActor
    func syncReadReceiptsForSentMessages(peerID: PeerID, nickname: String, externalReceipts: inout Set<String>) {
        guard let messages = privateChats[peerID] else { return }

        for message in messages {
            if message.sender == nickname {
                if let status = message.deliveryStatus {
                    switch status {
                    case .read, .delivered:
                        externalReceipts.insert(message.id)
                        sentReadReceipts.insert(message.id)
                    case .failed, .partiallyDelivered, .sending, .sent:
                        break
                    }
                }
            }
        }
    }
    
    /// Start a private chat with a peer
    func startChat(with peerID: PeerID) {
        if let selectedPeer, selectedPeer != peerID {
            compactToSummary(selectedPeer)
        }
        selectedPeer = peerID
        
        // Store fingerprint for persistence across reconnections
        if let fingerprint = meshService?.getFingerprint(for: peerID) {
            selectedPeerFingerprint = fingerprint
        }
        
        // Every open starts from one bounded local window. A summary already in
        // the chat-list map is not mistaken for a hydrated transcript.
        if !hydratedTranscriptPeers.contains(peerID) {
            let persisted = store.loadRecent(peerID: peerID)
            hydratedTranscriptPeers.insert(peerID)
            if persisted.count < MessageStore.privateMessageWindowSize {
                peersWithNoOlderHistory.insert(peerID)
            } else {
                peersWithNoOlderHistory.remove(peerID)
            }
            replaceWithoutPersistence {
                privateChats[peerID] = boundedMessages(
                    persisted + (privateChats[peerID] ?? []),
                    for: peerID
                )
            }
        }

        // Mark the bounded local window as read only after it is present; this
        // keeps chat opening local-first and does not require a full history
        // parse before read receipts can be projected.
        markAsRead(from: peerID)
    }
    
    /// End the current private chat
    func endChat() {
        if let selectedPeer { compactToSummary(selectedPeer) }
        selectedPeer = nil
        selectedPeerFingerprint = nil
    }

    func canLoadOlderMessages(for peerID: PeerID) -> Bool {
        hydratedTranscriptPeers.contains(peerID) &&
            !peersWithNoOlderHistory.contains(peerID) &&
            !peersLoadingOlderHistory.contains(peerID) &&
            (privateChats[peerID]?.count ?? 0) < privateChatCap
    }

    /// Page older rows only for the open conversation. The retained live window
    /// remains capped even if the UI repeatedly reaches the older edge.
    @MainActor
    func loadOlderMessages(for peerID: PeerID) async -> Bool {
        guard canLoadOlderMessages(for: peerID),
              let anchorID = privateChats[peerID]?.first?.id else { return false }
        peersLoadingOlderHistory.insert(peerID)
        defer { peersLoadingOlderHistory.remove(peerID) }
        let remaining = privateChatCap - (privateChats[peerID]?.count ?? 0)
        let page = await store.loadPrivatePage(
            peerID: peerID,
            beforeMessageID: anchorID,
            limit: min(MessageStore.privateMessageWindowSize, remaining)
        )
        if !page.hasMore { peersWithNoOlderHistory.insert(peerID) }
        guard !page.messages.isEmpty, hydratedTranscriptPeers.contains(peerID) else { return false }
        replaceWithoutPersistence {
            privateChats[peerID] = boundedMessages(
                page.messages + (privateChats[peerID] ?? []),
                for: peerID
            )
        }
        return true
    }

    /// Remove duplicate messages by ID and keep chronological order
    func sanitizeChat(for peerID: PeerID) {
        guard let arr = privateChats[peerID] else { return }
        if arr.count <= 1 {
            return
        }

        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(arr.count)
        var deduped: [BitchatMessage] = []
        deduped.reserveCapacity(arr.count)

        for msg in arr.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let existing = indexByID[msg.id] {
                deduped[existing] = msg
            } else {
                indexByID[msg.id] = deduped.count
                deduped.append(msg)
            }
        }

        privateChats[peerID] = boundedMessages(deduped, for: peerID)
    }
    
    /// Mark messages from a peer as read
    func markAsRead(from peerID: PeerID) {
        unreadMessages.remove(peerID)
        
        // Send read receipts for unread messages that haven't been sent yet
        if let messages = privateChats[peerID] {
            for message in messages {
                if message.senderPeerID == peerID && !message.isRelay && !sentReadReceipts.contains(message.id) {
                    sendReadReceipt(for: message)
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func sendReadReceipt(for message: BitchatMessage) {
        guard !sentReadReceipts.contains(message.id),
              let senderPeerID = message.senderPeerID else {
            return
        }
        
        sentReadReceipts.insert(message.id)
        
        // Create read receipt using the simplified method
        let receipt = ReadReceipt(
            originalMessageID: message.id,
            readerID: meshService?.myPeerID ?? PeerID(str: ""),
            readerNickname: meshService?.myNickname ?? ""
        )
        
        // Route via MessageRouter to avoid handshakeRequired spam when session isn't established
        if let router = messageRouter {
            SecureLogger.debug("PrivateChatManager: sending READ ack for \(message.id.prefix(8))… to \(senderPeerID.id.prefix(8))… via router", category: .session)
            Task { @MainActor in
                router.sendReadReceipt(receipt, to: senderPeerID)
            }
        } else {
            // Fallback: preserve previous behavior
            meshService?.sendReadReceipt(receipt, to: senderPeerID)
        }
    }
}
