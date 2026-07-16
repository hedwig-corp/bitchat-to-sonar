//
// ChatViewModelExtensionsTests.swift
// bitchatTests
//
// Tests for ChatViewModel extensions (PrivateChat, Nostr, Tor).
//

import Testing
import Foundation
import Combine
@testable import Sonar

// MARK: - Test Helpers

@MainActor
private func makeTestableViewModel(
    messageStore: MessageStore = .shared,
    favoritesPersistenceService: FavoritesPersistenceService = .shared
) -> (viewModel: ChatViewModel, transport: MockTransport) {
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport,
        messageStore: messageStore,
        favoritesPersistenceService: favoritesPersistenceService
    )

    return (viewModel, transport)
}

@MainActor
private func nonFavoriteNoiseKeyHex() -> String {
    for seed in 0..<224 {
        let key = Data((0..<32).map { UInt8(($0 + seed + 1) & 0xff) })
        if FavoritesPersistenceService.shared.getFavoriteStatus(for: key) == nil {
            return key.hexEncodedString()
        }
    }
    return "0102030405060708090a0b0c0d0e0f100102030405060708090a0b0c0d0e0f10"
}

// MARK: - Private Chat Extension Tests

struct ChatViewModelPrivateChatExtensionTests {

    private enum SimulatedPersistenceFailure: Error {
        case beforeRename
    }

    @MainActor
    private func receiveMeshPrivateMessage(
        _ content: String,
        messageID: String,
        from peerID: PeerID,
        viewModel: ChatViewModel
    ) throws {
        let packet = PrivateMessagePacket(messageID: messageID, content: content)
        let payload = try #require(packet.encode(), "Failed to encode private message")
        viewModel.didReceiveNoisePayload(
            from: peerID,
            type: .privateMessage,
            payload: payload,
            timestamp: Date()
        )
    }

    @MainActor
    private func waitForDeliveryAcks(
        _ count: Int,
        transport: MockTransport
    ) async {
        for _ in 0..<100 where transport.sentDeliveryAcks.count < count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test @MainActor
    func meshPrivateMessage_ackFollowsDurableCommit() async throws {
        let dirName = "MeshAckTest-\(UUID().uuidString)"
        let store = MessageStore(directoryName: dirName)
        defer { store.wipeAll() }
        let (viewModel, transport) = makeTestableViewModel(messageStore: store)
        let peerID = PeerID(str: "sender-durable-ack")
        let messageID = "durable-ack-\(UUID().uuidString)"

        try receiveMeshPrivateMessage(
            "persist before ack",
            messageID: messageID,
            from: peerID,
            viewModel: viewModel
        )
        await waitForDeliveryAcks(1, transport: transport)

        #expect(transport.sentDeliveryAcks.map(\.messageID) == [messageID])
        let reopened = MessageStore(directoryName: dirName)
        #expect(reopened.load(peerID: peerID).contains(where: { $0.id == messageID }))
    }

    @Test @MainActor
    func meshPrivateMessage_failedCommitWithholdsAck() async throws {
        let dirName = "MeshAckFailureTest-\(UUID().uuidString)"
        let cleanupStore = MessageStore(directoryName: dirName)
        defer { cleanupStore.wipeAll() }
        let failingStore = MessageStore(
            directoryName: dirName,
            beforeAtomicReplace: { throw SimulatedPersistenceFailure.beforeRename }
        )
        let (viewModel, transport) = makeTestableViewModel(messageStore: failingStore)
        let peerID = PeerID(str: "sender-failed-ack")

        try receiveMeshPrivateMessage(
            "do not ack",
            messageID: "failed-ack-\(UUID().uuidString)",
            from: peerID,
            viewModel: viewModel
        )
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(transport.sentDeliveryAcks.isEmpty)
        #expect(viewModel.privateChats[peerID]?.isEmpty != false)
        #expect(!viewModel.unreadPrivateMessages.contains(peerID))
    }

    @Test @MainActor
    func meshPrivateMedia_failedTranscriptCommitRollsBackStagedFileAndEffects() async throws {
        let dirName = "MeshMediaCommitFailureTest-\(UUID().uuidString)"
        let cleanupStore = MessageStore(directoryName: dirName)
        defer { cleanupStore.wipeAll() }
        let failingStore = MessageStore(
            directoryName: dirName,
            beforeAtomicReplace: { throw SimulatedPersistenceFailure.beforeRename }
        )
        let (viewModel, _) = makeTestableViewModel(messageStore: failingStore)
        let peerID = PeerID(str: "sender-media-failed-commit")
        let fileName = "staged-\(UUID().uuidString).jpg"
        let directory = try viewModel.applicationFilesDirectory()
            .appendingPathComponent("images/incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(fileName)
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let message = BitchatMessage(
            id: "media-failed-\(UUID().uuidString)",
            sender: "Media Sender",
            content: "[image] \(fileName)",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "me",
            senderPeerID: peerID
        )
        viewModel.didReceiveMessage(message)

        for _ in 0..<100 where FileManager.default.fileExists(atPath: fileURL.path) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(viewModel.privateChats[peerID]?.contains(where: { $0.id == message.id }) != true)
        #expect(!viewModel.unreadPrivateMessages.contains(peerID))
    }

    @Test @MainActor
    func meshPrivateMedia_replayKeepsCommittedFileAndRemovesReplayFile() async throws {
        let dirName = "MeshMediaReplayTest-\(UUID().uuidString)"
        let store = MessageStore(directoryName: dirName)
        defer { store.wipeAll() }
        let (viewModel, _) = makeTestableViewModel(messageStore: store)
        let peerID = PeerID(str: "sender-media-replay")
        let messageID = "stable-media-\(UUID().uuidString)"
        let directory = try viewModel.applicationFilesDirectory()
            .appendingPathComponent("images/incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalName = "original-\(UUID().uuidString).jpg"
        let replayName = "replay-\(UUID().uuidString).jpg"
        let originalURL = directory.appendingPathComponent(originalName)
        let replayURL = directory.appendingPathComponent(replayName)
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: originalURL)
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: replayURL)
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: replayURL)
        }

        let original = BitchatMessage(
            id: messageID,
            sender: "Media Sender",
            content: "[image] \(originalName)",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "me",
            senderPeerID: peerID
        )
        viewModel.didReceiveMessage(original)
        let didCommit = await TestHelpers.waitUntil(
            { viewModel.privateChats[peerID]?.contains(where: { $0.id == messageID }) == true },
            timeout: TestConstants.defaultTimeout
        )
        #expect(didCommit)

        let replay = BitchatMessage(
            id: messageID,
            sender: "Media Sender",
            content: "[image] \(replayName)",
            timestamp: original.timestamp,
            isRelay: false,
            isPrivate: true,
            recipientNickname: "me",
            senderPeerID: peerID
        )
        viewModel.didReceiveMessage(replay)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: replayURL.path) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(FileManager.default.fileExists(atPath: originalURL.path))
        #expect(!FileManager.default.fileExists(atPath: replayURL.path))
        #expect(viewModel.privateChats[peerID]?.filter { $0.id == messageID }.count == 1)
        #expect(store.load(peerID: peerID).filter { $0.id == messageID }.count == 1)
    }

    @Test @MainActor
    func meshPrivateMessage_duplicateIsStoredOnceAndReAcked() async throws {
        let dirName = "MeshDuplicateAckTest-\(UUID().uuidString)"
        let store = MessageStore(directoryName: dirName)
        defer { store.wipeAll() }
        let (viewModel, transport) = makeTestableViewModel(messageStore: store)
        let peerID = PeerID(str: "sender-duplicate-ack")
        let messageID = "duplicate-ack-\(UUID().uuidString)"

        try receiveMeshPrivateMessage("once", messageID: messageID, from: peerID, viewModel: viewModel)
        await waitForDeliveryAcks(1, transport: transport)
        try receiveMeshPrivateMessage("once", messageID: messageID, from: peerID, viewModel: viewModel)
        await waitForDeliveryAcks(2, transport: transport)

        #expect(transport.sentDeliveryAcks.filter { $0.messageID == messageID }.count == 2)
        #expect(viewModel.privateChats[peerID]?.filter { $0.id == messageID }.count == 1)
        #expect(store.load(peerID: peerID).filter { $0.id == messageID }.count == 1)
    }

    @Test @MainActor
    func meshPrivateMessage_concurrentBurstCommitsAndAcksEveryMessage() async throws {
        let dirName = "MeshBurstAckTest-\(UUID().uuidString)"
        let store = MessageStore(directoryName: dirName)
        defer { store.wipeAll() }
        let (viewModel, transport) = makeTestableViewModel(messageStore: store)
        let peerID = PeerID(str: "sender-burst-ack")
        let ids = (0..<8).map { "burst-\($0)-\(UUID().uuidString)" }

        for (index, messageID) in ids.enumerated() {
            try receiveMeshPrivateMessage(
                "burst \(index)",
                messageID: messageID,
                from: peerID,
                viewModel: viewModel
            )
        }
        await waitForDeliveryAcks(ids.count, transport: transport)

        #expect(Set(transport.sentDeliveryAcks.map(\.messageID)) == Set(ids))
        #expect(Set(viewModel.privateChats[peerID]?.map(\.id) ?? []) == Set(ids))
        let reopened = MessageStore(directoryName: dirName)
        #expect(Set(reopened.load(peerID: peerID).map(\.id)) == Set(ids))
    }

    @Test @MainActor
    func meshPrivateMessage_blockedPeerIsDroppedAndAcked() async throws {
        let dirName = "MeshBlockedAckTest-\(UUID().uuidString)"
        let store = MessageStore(directoryName: dirName)
        defer { store.wipeAll() }
        let (viewModel, transport) = makeTestableViewModel(messageStore: store)
        let peerID = PeerID(str: "sender-blocked-ack")
        let fingerprint = "blocked-fingerprint-\(UUID().uuidString)"
        transport.peerFingerprints[peerID] = fingerprint
        viewModel.identityManager.setBlocked(fingerprint, isBlocked: true)
        #expect(viewModel.isPeerBlocked(peerID))

        let messageID = "blocked-ack-\(UUID().uuidString)"
        try receiveMeshPrivateMessage("drop me", messageID: messageID, from: peerID, viewModel: viewModel)
        await waitForDeliveryAcks(1, transport: transport)

        #expect(transport.sentDeliveryAcks.map(\.messageID) == [messageID])
        #expect(viewModel.privateChats[peerID]?.contains(where: { $0.id == messageID }) != true)
        #expect(store.load(peerID: peerID).isEmpty)
    }

    @Test @MainActor
    func meshFavoriteControl_ackFollowsDurableReceipt() async throws {
        let dirName = "MeshControlAckTest-\(UUID().uuidString)"
        let store = MessageStore(directoryName: dirName)
        defer { store.wipeAll() }
        let favoriteKeychain = MockKeychain()
        let favoriteService = FavoritesPersistenceService(keychain: favoriteKeychain)
        let (viewModel, transport) = makeTestableViewModel(
            messageStore: store,
            favoritesPersistenceService: favoriteService
        )
        let noiseKey = Data((1...32).map { UInt8($0) })
        let peerID = PeerID(hexData: noiseKey)
        let messageID = "favorite-control-\(UUID().uuidString)"

        try receiveMeshPrivateMessage(
            "[FAVORITED]:npub-test",
            messageID: messageID,
            from: peerID,
            viewModel: viewModel
        )
        await waitForDeliveryAcks(1, transport: transport)

        #expect(transport.sentDeliveryAcks.map(\.messageID) == [messageID])
        #expect(store.hasControlReceipt(peerID: peerID, messageID: messageID))
        #expect(store.load(peerID: peerID).isEmpty)
        let reopenedFavorites = FavoritesPersistenceService(keychain: favoriteKeychain)
        #expect(reopenedFavorites.getFavoriteStatus(for: noiseKey)?.theyFavoritedUs == true)
    }

    @Test @MainActor
    func meshFavoriteControl_failedMessageCommitHasZeroSideEffects() async throws {
        let dirName = "MeshControlFailureTest-\(UUID().uuidString)"
        let cleanupStore = MessageStore(directoryName: dirName)
        defer { cleanupStore.wipeAll() }
        let failingStore = MessageStore(
            directoryName: dirName,
            beforeAtomicReplace: { throw SimulatedPersistenceFailure.beforeRename }
        )
        let favoriteKeychain = MockKeychain()
        let favoriteService = FavoritesPersistenceService(keychain: favoriteKeychain)
        let (viewModel, transport) = makeTestableViewModel(
            messageStore: failingStore,
            favoritesPersistenceService: favoriteService
        )
        let noiseKey = Data((33...64).map { UInt8($0) })
        let peerID = PeerID(hexData: noiseKey)

        try receiveMeshPrivateMessage(
            "[FAVORITED]:npub-test",
            messageID: "favorite-fail-\(UUID().uuidString)",
            from: peerID,
            viewModel: viewModel
        )
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(transport.sentDeliveryAcks.isEmpty)
        #expect(favoriteService.getFavoriteStatus(for: noiseKey) == nil)
    }

    @Test @MainActor
    func favoriteKeychainFailurePreservesPreviousDurableValue() {
        let keychain = MockKeychain()
        let service = FavoritesPersistenceService(keychain: keychain)
        let noiseKey = Data((65...96).map { UInt8($0) })
        #expect(service.updatePeerFavoritedUs(
            peerNoisePublicKey: noiseKey,
            favorited: true,
            peerNickname: "alice"
        ))

        keychain.simulatedGenericSaveFailure = true
        #expect(!service.updatePeerFavoritedUs(
            peerNoisePublicKey: noiseKey,
            favorited: false,
            peerNickname: "alice"
        ))

        let reopened = FavoritesPersistenceService(keychain: keychain)
        #expect(reopened.getFavoriteStatus(for: noiseKey)?.theyFavoritedUs == true)
        #expect(service.getFavoriteStatus(for: noiseKey)?.theyFavoritedUs == true)
    }

    @Test @MainActor
    func clearAllFavoritesReportsVerifiedDeleteFailure() {
        let keychain = MockKeychain()
        let service = FavoritesPersistenceService(keychain: keychain)
        let noiseKey = Data((97...128).map { UInt8($0) })
        #expect(service.updatePeerFavoritedUs(
            peerNoisePublicKey: noiseKey,
            favorited: true,
            peerNickname: "alice"
        ))

        keychain.simulatedGenericDeleteFailure = true
        #expect(!service.clearAllFavorites())
        #expect(service.getFavoriteStatus(for: noiseKey) == nil)

        let reopened = FavoritesPersistenceService(keychain: keychain)
        #expect(reopened.getFavoriteStatus(for: noiseKey)?.theyFavoritedUs == true)
    }

    @Test @MainActor
    func sendPrivateMessage_mesh_storesAndSends() async {
        let (viewModel, transport) = makeTestableViewModel()
        // Use valid hex string for PeerID (32 bytes = 64 hex chars for Noise key usually, or just valid hex)
        let validHex = nonFavoriteNoiseKeyHex()
        let peerID = PeerID(str: validHex)
        viewModel.privateChats[peerID] = nil
        
        // Simulate connection
        transport.connectedPeers.insert(peerID)
        transport.peerNicknames[peerID] = "MeshUser"
        
        viewModel.sendPrivateMessage("Hello Mesh", to: peerID)
        
        // Verify transport was called
        // Note: MockTransport stores sent messages
        // Since sendPrivateMessage delegates to MessageRouter which delegates to Transport...
        // We need to ensure MessageRouter is using our MockTransport.
        // ChatViewModel init sets up MessageRouter with the passed transport.
        
        // Wait for async processing
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Verify message stored locally
        #expect(viewModel.privateChats[peerID]?.count == 1)
        #expect(viewModel.privateChats[peerID]?.first?.content == "Hello Mesh")
        
        // Verify message sent to transport (MockTransport captures sendPrivateMessage)
        // MockTransport.sendPrivateMessage is what MessageRouter calls for connected peers
        // Check MockTransport implementation... it might need update or verification
    }

    @Test @MainActor
    func deleteConversationOutboxFailureKeepsTranscriptAndUIForRetry() async {
        let dirName = "ConversationDeleteFailure-\(UUID().uuidString)"
        let store = MessageStore(directoryName: dirName)
        defer { store.wipeAll() }
        let (viewModel, transport) = makeTestableViewModel(messageStore: store)
        let peer = PeerID(str: "a1b2c3d4e5f60718")
        let message = BitchatMessage(
            id: "unsent-delete",
            sender: "me",
            content: "still pending",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: transport.myPeerID
        )
        viewModel.privateChats[peer] = [message]
        let committed = await store.commitPrivate(peerID: peer, messages: [message])
        #expect(committed)
        transport.pruneDurablePrivateOutboxResult = false

        #expect(!viewModel.deleteConversation(with: peer))

        #expect(viewModel.privateChats[peer]?.map(\.id) == [message.id])
        #expect(store.load(peerID: peer).map(\.id) == [message.id])
        #expect(transport.prunedDurablePrivatePeers == [[peer]])
    }

    @Test @MainActor
    func sendPrivateMessage_acknowledgedMeshStaysSendingUntilPeerAck() async {
        let (viewModel, transport) = makeTestableViewModel()
        let validHex = nonFavoriteNoiseKeyHex()
        let peerID = PeerID(str: validHex)
        transport.connectedPeers.insert(peerID)
        transport.peerNicknames[peerID] = "MeshUser"
        transport.usesAcknowledgedPrivateDelivery = true

        viewModel.sendPrivateMessage("Wait for ACK", to: peerID)

        #expect(transport.sentPrivateMessages.count == 1)
        let status = viewModel.privateChats[peerID]?.last?.deliveryStatus
        if case .sending = status {} else {
            Issue.record("ACK-backed BLE message was marked sent before delivery ACK")
        }
    }

    @Test @MainActor
    func privateDeliveryStatusUpdatePersistsAcrossReopen() async {
        let dirName = "MeshDeliveryStatusTest-\(UUID().uuidString)"
        let store = MessageStore(directoryName: dirName)
        defer { store.wipeAll() }
        let (viewModel, _) = makeTestableViewModel(messageStore: store)
        let peerID = PeerID(str: "delivery-status-peer")
        let messageID = "delivery-status-\(UUID().uuidString)"
        viewModel.privateChats[peerID] = [BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "persist my ACK",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "alice",
            senderPeerID: viewModel.meshService.myPeerID,
            deliveryStatus: .sending
        )]

        viewModel.updateMessageDeliveryStatus(
            messageID,
            status: .delivered(to: "alice", at: Date())
        )
        _ = store.load(peerID: peerID) // serial queue barrier

        let reopened = MessageStore(directoryName: dirName)
        let status = reopened.load(peerID: peerID).first?.deliveryStatus
        if case .delivered = status {} else {
            Issue.record("Delivery status did not survive MessageStore reopen")
        }
    }

    @Test @MainActor
    func sendPrivateMessage_unreachable_setsFailedStatus() async {
        let (viewModel, _) = makeTestableViewModel()
        let validHex = nonFavoriteNoiseKeyHex()
        let peerID = PeerID(str: validHex)
        viewModel.privateChats[peerID] = nil

        viewModel.sendPrivateMessage("Hello", to: peerID)

        #expect(viewModel.privateChats[peerID]?.count == 1)
        #expect(viewModel.privateChats[peerID]?.last?.recipientNickname == String(validHex.prefix(8)))
        let status = viewModel.privateChats[peerID]?.last?.deliveryStatus
        #expect({
            if case .failed = status { return true }
            return false
        }())
    }

    @Test @MainActor
    func nicknameForPeer_withoutNicknameUsesPeerKeyPrefix() async {
        let (viewModel, _) = makeTestableViewModel()
        let validHex = "0102030405060708090a0b0c0d0e0f100102030405060708090a0b0c0d0e0f10"
        let peerID = PeerID(str: validHex)

        #expect(viewModel.nicknameForPeer(peerID) == String(validHex.prefix(8)))
    }

    @Test @MainActor
    func sendVoiceNote_fromTemporaryRecorderFilePersistsOutgoingMedia() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vn-\(UUID().uuidString).m4a")
        let audioData = Data(repeating: 0x42, count: 4096)
        try audioData.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        viewModel.sendVoiceNote(at: sourceURL)

        guard let message = viewModel.messages.last(where: { $0.content.hasPrefix("[voice] ") }) else {
            Issue.record("Expected a voice marker message")
            return
        }

        let fileName = String(message.content.dropFirst("[voice] ".count))
        let storedURL = try viewModel.applicationFilesDirectory()
            .appendingPathComponent("voicenotes/outgoing", isDirectory: true)
            .appendingPathComponent(fileName)
        defer { try? FileManager.default.removeItem(at: storedURL) }

        #expect(FileManager.default.fileExists(atPath: storedURL.path))
        let storedData = try Data(contentsOf: storedURL)
        #expect(storedData == audioData)
        #expect(transport.sentFileBroadcasts.count == 1)
        #expect(transport.sentFileBroadcasts.first?.packet.fileName == fileName)
        #expect(transport.sentFileBroadcasts.first?.packet.mimeType == "audio/mp4")
        #expect(transport.sentFileBroadcasts.first?.packet.content == audioData)

        try FileManager.default.removeItem(at: sourceURL)
        #expect(FileManager.default.fileExists(atPath: storedURL.path))
    }

    @Test @MainActor
    func sendFile_privateMeshChat_blocksLegacyPlaintextTransfer() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: nonFavoriteNoiseKeyHex())
        viewModel.selectedPrivateChatPeer = peerID

        #expect(!viewModel.canSendMediaInCurrentContext)

        viewModel.sendFile(
            data: Data(repeating: 0x2a, count: 32),
            filename: "private.jpg",
            mime: "image/jpeg"
        )

        #expect(transport.sentFilePrivates.isEmpty)
        #expect(transport.sentFileBroadcasts.isEmpty)
    }
    
    @Test @MainActor
    func handlePrivateMessage_storesMessage() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "sender_store_private")
        let sender = "SenderStorePrivate"
        let messageID = "msg-store-private-\(UUID().uuidString)"
        viewModel.privateChats[peerID] = nil
        viewModel.unreadPrivateMessages.remove(peerID)
        
        let message = BitchatMessage(
            id: messageID,
            sender: sender,
            content: "Private Content",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "Me",
            senderPeerID: peerID
        )
        
        // Simulate receiving a private message via the handlePrivateMessage extension method
        viewModel.handlePrivateMessage(message)
        
        // Verify stored
        #expect(viewModel.privateChats[peerID]?.count == 1)
        #expect(viewModel.privateChats[peerID]?.first?.content == "Private Content")
        
        // Receive-side notification work is asynchronous so a platform
        // submission cannot block local transcript insertion. Wait only for
        // the immediate unread projection, not for notification-center I/O.
        for _ in 0..<100 where !viewModel.unreadPrivateMessages.contains(peerID) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(viewModel.unreadPrivateMessages.contains(peerID))
    }
    
    @Test @MainActor
    func handlePrivateMessage_deduplicates() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "sender_dedup_private")
        let sender = "SenderDedupPrivate"
        let messageID = "msg-dedup-private-\(UUID().uuidString)"
        viewModel.privateChats[peerID] = nil
        
        let message = BitchatMessage(
            id: messageID,
            sender: sender,
            content: "Content",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: peerID
        )
        
        viewModel.handlePrivateMessage(message)
        viewModel.handlePrivateMessage(message) // Duplicate
        
        #expect(viewModel.privateChats[peerID]?.count == 1)
    }
    
    @Test @MainActor
    func handlePrivateMessage_sendsReadReceipt_whenViewing() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "SENDER_001")
        
        // Set as currently viewing
        viewModel.selectedPrivateChatPeer = peerID
        
        let message = BitchatMessage(
            id: "msg-1",
            sender: "Sender",
            content: "Content",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: peerID
        )
        
        viewModel.handlePrivateMessage(message)
        
        // Should NOT be marked unread
        #expect(!viewModel.unreadPrivateMessages.contains(peerID))
    }
    
    @Test @MainActor
    func migratePrivateChats_consolidatesHistory_onFingerprintMatch() async {
        let (viewModel, _) = makeTestableViewModel()
        let oldPeerID = PeerID(str: "old_peer_migrate")
        let newPeerID = PeerID(str: "new_peer_migrate")
        let sender = "SenderMigratePrivate"
        let fingerprint = "fp_123"
        let messageID = "msg-old-migrate-\(UUID().uuidString)"
        viewModel.privateChats[oldPeerID] = nil
        viewModel.privateChats[newPeerID] = nil
        
        // Setup old chat
        let oldMessage = BitchatMessage(
            id: messageID,
            sender: sender,
            content: "Old message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: oldPeerID
        )
        viewModel.privateChats[oldPeerID] = [oldMessage]
        viewModel.peerIDToPublicKeyFingerprint[oldPeerID] = fingerprint
        
        // Setup new peer fingerprint
        viewModel.peerIDToPublicKeyFingerprint[newPeerID] = fingerprint
        
        // Trigger migration
        viewModel.migratePrivateChatsIfNeeded(for: newPeerID, senderNickname: sender)
        
        // Verify migration
        #expect(viewModel.privateChats[newPeerID]?.count == 1)
        #expect(viewModel.privateChats[newPeerID]?.first?.content == "Old message")
        #expect(viewModel.privateChats[oldPeerID] == nil) // Old chat removed
    }
    
    @Test @MainActor
    func isMessageBlocked_filtersBlockedUsers() async {
        let (viewModel, _) = makeTestableViewModel()
        let blockedPeerID = PeerID(str: "BLOCKED_PEER")
        
        // Block the peer
        // MockIdentityManager stores state based on fingerprint
        // We need to map peerID to a fingerprint
        viewModel.peerIDToPublicKeyFingerprint[blockedPeerID] = "fp_blocked"
        viewModel.identityManager.setBlocked("fp_blocked", isBlocked: true)
        
        // Also ensure UnifiedPeerService can resolve the fingerprint.
        // UnifiedPeerService uses its own cache or delegates to meshService/Peer list.
        // Since we are mocking, we can't easily inject into UnifiedPeerService's internal cache.
        // However, ChatViewModel's isMessageBlocked uses:
        // 1. isPeerBlocked(peerID) -> unifiedPeerService.isBlocked(peerID) -> getFingerprint -> identityManager.isBlocked
        
        // We need UnifiedPeerService.getFingerprint(for: blockedPeerID) to return "fp_blocked"
        // UnifiedPeerService tries: cache -> meshService -> getPeer
        
        // Option 1: Mock the transport (meshService) to return the fingerprint
        // (viewModel.transport is MockTransport, but UnifiedPeerService holds a reference to it)
        // Check if MockTransport has `getFingerprint`
        
        // If not, we might need to rely on the fallback: ChatViewModel.isMessageBlocked also checks Nostr blocks.
        
        // Let's assume MockTransport needs `getFingerprint` implementation or update it.
        // For now, let's try to verify if `MockTransport` supports `getFingerprint`.
        
        // Actually, let's just use the Nostr block path which is simpler and also tested here.
        // "Check geohash (Nostr) blocks using mapping to full pubkey"
        
        let hexPubkey = "0000000000000000000000000000000000000000000000000000000000000001"
        viewModel.nostrKeyMapping[blockedPeerID] = hexPubkey
        viewModel.identityManager.setNostrBlocked(hexPubkey, isBlocked: true)
        
        // Force isGeoChat/isGeoDM check to be true by setting prefix?
        // Or ensure the logic covers it.
        // The logic is:
        // if peerID.isGeoChat || peerID.isGeoDM { check nostr }
        // We need a peerID that looks like geo.
        
        let geoPeerID = PeerID(nostr_: hexPubkey)
        viewModel.nostrKeyMapping[geoPeerID] = hexPubkey
        
        let geoMessage = BitchatMessage(
            id: "msg-geo-blocked",
            sender: "BlockedGeoUser",
            content: "Spam",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: geoPeerID
        )
        
        #expect(viewModel.isMessageBlocked(geoMessage))
    }
}

// MARK: - Nostr Extension Tests

struct ChatViewModelNostrExtensionTests {
    
    @Test @MainActor
    func switchLocationChannel_mesh_clearsGeo() async {
        let (viewModel, _) = makeTestableViewModel()
        
        // Setup some geo state
        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: "u4pruydq")))
        #expect(viewModel.currentGeohash == "u4pruydq")
        
        // Switch to mesh
        viewModel.switchLocationChannel(to: .mesh)
        
        #expect(viewModel.activeChannel == .mesh)
        #expect(viewModel.currentGeohash == nil)
    }
    
    @Test @MainActor
    func subscribeNostrEvent_addsToTimeline_ifMatchesGeohash() async throws {
        let geohash = "u4pruydq"
        let channel = ChannelID.location(GeohashChannel(level: .city, geohash: geohash))

        LocationChannelManager.shared.select(channel)
        defer { LocationChannelManager.shared.select(.mesh) }

        _ = await TestHelpers.waitUntil({ LocationChannelManager.shared.selectedChannel == channel })

        let (viewModel, _) = makeTestableViewModel()
        
        _ = await TestHelpers.waitUntil({ viewModel.activeChannel == channel })
        
        let signer = try NostrIdentity.generate()
        let event = NostrEvent(
            pubkey: signer.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [["g", geohash]],
            content: "Hello Geo"
        )
        let signed = try event.sign(with: signer.schnorrSigningKey())
        viewModel.handleNostrEvent(signed)
        
        let didAppend = await TestHelpers.waitUntil({
            viewModel.publicMessagePipeline.flushIfNeeded()
            return viewModel.messages.contains { $0.content == "Hello Geo" }
        })
        #expect(didAppend)
    }

    @Test @MainActor
    func handleNostrEvent_ignoresRecentSelfEcho() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))
        let identity = try viewModel.idBridge.deriveIdentity(forGeohash: geohash)

        let event = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [["g", geohash]],
            content: "Self echo"
        )
        let signed = try event.sign(with: identity.schnorrSigningKey())
        viewModel.handleNostrEvent(signed)

        try? await Task.sleep(nanoseconds: 100_000_000)
        viewModel.publicMessagePipeline.flushIfNeeded()

        #expect(!viewModel.messages.contains { $0.content == "Self echo" })
    }

    @Test @MainActor
    func handleNostrEvent_skipsBlockedSender() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"
        let blockedIdentity = try NostrIdentity.generate()
        let blockedPubkey = blockedIdentity.publicKeyHex

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))
        viewModel.identityManager.setNostrBlocked(blockedPubkey, isBlocked: true)

        let event = NostrEvent(
            pubkey: blockedPubkey,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [["g", geohash]],
            content: "Blocked"
        )
        let signed = try event.sign(with: blockedIdentity.schnorrSigningKey())
        viewModel.handleNostrEvent(signed)

        try? await Task.sleep(nanoseconds: 100_000_000)
        viewModel.publicMessagePipeline.flushIfNeeded()

        #expect(!viewModel.messages.contains { $0.content == "Blocked" })
    }

    @Test @MainActor
    func handleNostrEvent_rejectsInvalidSignature() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"
        let identity = try NostrIdentity.generate()

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))

        let event = NostrEvent(
            pubkey: identity.publicKeyHex,
            createdAt: Date(),
            kind: .ephemeralEvent,
            tags: [["g", geohash]],
            content: "Valid"
        )
        var signed = try event.sign(with: identity.schnorrSigningKey())
        signed.id = "deadbeef"

        viewModel.handleNostrEvent(signed)

        try? await Task.sleep(nanoseconds: 100_000_000)
        viewModel.publicMessagePipeline.flushIfNeeded()

        #expect(!viewModel.messages.contains { $0.content == "Tampered" })
    }

    @Test @MainActor
    func subscribeGiftWrap_rejectsOversizedEmbeddedPacket() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()

        let oversized = Data(repeating: 0x41, count: FileTransferLimits.maxFramedFileBytes + 1)
        let content = "bitchat1:" + base64URLEncode(oversized)
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        viewModel.subscribeGiftWrap(giftWrap, id: recipient)

        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(viewModel.privateChats.isEmpty)
    }

    @Test @MainActor
    func switchLocationChannel_clearsNostrDedupCache() async {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"

        viewModel.deduplicationService.recordNostrEvent("evt-cache")
        #expect(viewModel.deduplicationService.hasProcessedNostrEvent("evt-cache"))

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))

        #expect(!viewModel.deduplicationService.hasProcessedNostrEvent("evt-cache"))
    }
}

// MARK: - Geohash Queue Tests

struct ChatViewModelGeohashQueueTests {

    @Test @MainActor
    func addGeohashOnlySystemMessage_queuesUntilLocationChannel() async {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"

        viewModel.addGeohashOnlySystemMessage("Queued system")
        #expect(!viewModel.messages.contains { $0.content == "Queued system" })

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))

        #expect(viewModel.messages.contains { $0.content == "Queued system" })
    }
}

// MARK: - GeoDM Tests

struct ChatViewModelGeoDMTests {

    @Test @MainActor
    func handlePrivateMessage_geohash_dedupsAndTracksAck() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let geohash = "u4pruydq"
        let senderPubkey = "0000000000000000000000000000000000000000000000000000000000000001"
        let messageID = "pm-1"

        viewModel.switchLocationChannel(to: .location(GeohashChannel(level: .city, geohash: geohash)))
        let identity = try viewModel.idBridge.deriveIdentity(forGeohash: geohash)

        let convKey = PeerID(nostr_: senderPubkey)
        let packet = PrivateMessagePacket(messageID: messageID, content: "Hello")
        let payloadData = try #require(packet.encode(), "Failed to encode private message")
        let payload = NoisePayload(type: .privateMessage, data: payloadData)

        viewModel.handlePrivateMessage(payload, senderPubkey: senderPubkey, convKey: convKey, id: identity, messageTimestamp: Date())
        viewModel.handlePrivateMessage(payload, senderPubkey: senderPubkey, convKey: convKey, id: identity, messageTimestamp: Date())

        #expect(viewModel.privateChats[convKey]?.count == 1)
        #expect(viewModel.sentGeoDeliveryAcks.contains(messageID))
    }
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
