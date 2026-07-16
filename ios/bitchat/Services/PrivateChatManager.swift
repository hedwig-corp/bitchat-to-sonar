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
    /// First paint reads a fixed number of local transcript files. Remaining
    /// pages hydrate on the MessageStore queue after the UI can render.
    static let startupChatPageSize = 24
    /// Encrypted on-disk store backing the in-memory transcripts: hydrated on
    /// launch, written through on every change so chats survive a restart.
    /// Mesh DMs stay LOCAL-ONLY — this store is private to the device.
    private let store: MessageStore

    @Published var privateChats: [PeerID: [BitchatMessage]] = [:] {
        didSet { persistChanges(old: oldValue, new: privateChats) }
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
    private var nextStoredChatCursor: PrivateConversationCursor?
    private var hasMoreStoredChats = false

    init(meshService: Transport? = nil, store: MessageStore = .shared) {
        self.meshService = meshService
        self.store = store
        hydrateFromStore()
    }

    // Cap for messages stored per private chat
    private let privateChatCap = TransportConfig.privateChatCap

    // MARK: - Persistence (write-through to MessageStore)

    /// Load only the newest bounded local page synchronously for first paint.
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

    /// Page the rest of local storage without blocking first paint. Merging is
    /// idempotent so a message received while a page is in flight wins over the
    /// older on-disk row with the same stable ID.
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
            mergeHydratedPage(page)
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
            mergeHydratedPage(page)
            objectWillChange.send()
            guard page.hasMore else { break }
            await Task.yield()
        }
    }

    @MainActor
    private func mergeHydratedPage(_ page: PrivateStoreSnapshot) {
        isHydrating = true
        for (peerID, persisted) in page.chats {
            let current = privateChats[peerID] ?? []
            var byID: [String: BitchatMessage] = [:]
            for message in persisted { byID[message.id] = message }
            for message in current { byID[message.id] = message }
            privateChats[peerID] = Array(byID.values)
                .sorted { $0.timestamp < $1.timestamp }
        }
        isHydrating = false
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
        store.savePrivateWindow(peerID: peerID, messages: messages)
    }

    func currentStorageGeneration() -> String {
        store.currentStorageGeneration()
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
        var staged = privateChats[preferredPeerID] ?? []
        guard !staged.contains(where: { $0.id == message.id }) else {
            return await store.commitPrivate(
                peerID: preferredPeerID,
                messages: staged,
                expectedGeneration: expectedGeneration,
                mergeExistingTranscript: true
            )
        }
        staged.append(message)
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
            // Keep later same-peer changes, but withdraw this unpublished row.
            isDurableReceiveStaging = true
            privateChats[preferredPeerID]?.removeAll { $0.id == message.id }
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
        selectedPeer = peerID
        
        // Store fingerprint for persistence across reconnections
        if let fingerprint = meshService?.getFingerprint(for: peerID) {
            selectedPeerFingerprint = fingerprint
        }
        
        // Initialize chat if needed
        if privateChats[peerID] == nil {
            // A chat outside the first list page paints from its one bounded
            // local transcript file and never waits for relay/network sync.
            let persisted = store.loadRecent(peerID: peerID)
            isHydrating = true
            privateChats[peerID] = persisted
            isHydrating = false
        }

        // Mark the bounded local window as read only after it is present; this
        // keeps chat opening local-first and does not require a full history
        // parse before read receipts can be projected.
        markAsRead(from: peerID)
    }
    
    /// End the current private chat
    func endChat() {
        selectedPeer = nil
        selectedPeerFingerprint = nil
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

        privateChats[peerID] = deduped
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
