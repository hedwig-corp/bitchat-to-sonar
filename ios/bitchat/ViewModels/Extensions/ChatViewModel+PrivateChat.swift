//
// ChatViewModel+PrivateChat.swift
// bitchat
//
// Private chat and media transfer logic for ChatViewModel
//

import Foundation
import Combine
import BitLogger
import SonarCore
import SwiftUI

extension ChatViewModel {

    nonisolated static func shouldSendGenericPrivateMessageNotification(for content: String) -> Bool {
        SonarPayMessage.decode(content) == nil
            && !content.drop(while: \.isWhitespace).hasPrefix("☎CALL")
    }

    // MARK: - Private Chat Sending

    /// Sends an encrypted private message to a specific peer.
    /// - Parameters:
    ///   - content: The message content to encrypt and send
    ///   - peerID: The recipient's peer ID
    /// - Note: Automatically establishes Noise encryption if not already active
    @MainActor
    func sendPrivateMessage(_ content: String, to peerID: PeerID) {
        guard !content.isEmpty else { return }
        
        // Check if blocked
        if unifiedPeerService.isBlocked(peerID) {
            let nickname = nicknameForPeer(peerID)
            addSystemMessage(
                String(
                    format: String(localized: "system.dm.blocked_recipient", comment: "System message when attempting to message a blocked user"),
                    locale: .current,
                    nickname
                )
            )
            return
        }
        
        // Geohash DM routing: conversation keys start with "nostr_"
        if peerID.isGeoDM {
            sendGeohashDM(content, to: peerID)
            return
        }
        
        // Determine routing method and recipient nickname
        guard let peerKeyData = peerID.noiseKey ?? Data(hexString: peerID.id) else { return }
        let isConnected = meshService.isPeerConnected(peerID)
        let isReachable = meshService.isPeerReachable(peerID)
        let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: peerKeyData)
            ?? FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID)
        let isMutualFavorite = favoriteStatus?.isMutual ?? false
        let hasNostrKey = favoriteStatus?.peerNostrPublicKey != nil
        
        // Get nickname from various sources
        let recipientNickname: String
        if let meshNickname = meshService.peerNickname(peerID: peerID), !meshNickname.isEmpty {
            recipientNickname = meshNickname
        } else if let favoriteNickname = favoriteStatus?.peerNickname, !favoriteNickname.isEmpty {
            recipientNickname = favoriteNickname
        } else {
            recipientNickname = nicknameForPeer(peerID)
        }
        
        // Generate message ID
        let messageID = UUID().uuidString
        
        // Create the message object
        let message = BitchatMessage(
            id: messageID,
            sender: nickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: recipientNickname,
            senderPeerID: meshService.myPeerID,
            mentions: nil,
            deliveryStatus: .sending
        )
        
        // Add to local chat
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
        privateChats[peerID]?.append(message)
        
        // Trigger UI update for sent message
        objectWillChange.send()
        
        // Send via appropriate transport (BLE if connected/reachable, else Nostr when possible)
        if isConnected || isReachable || (isMutualFavorite && hasNostrKey) {
            let disposition = messageRouter.sendPrivate(
                content,
                to: peerID,
                recipientNickname: recipientNickname,
                messageID: messageID
            )
            // BLE stays `.sending` until the peer's encrypted 0x03 ACK removes
            // the durable obligation. Nostr retains its hand-off `.sent` state.
            if case .sent = disposition,
               let idx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[idx].deliveryStatus = .sent
            }
        } else {
            // Update delivery status to failed
            if let index = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[index].deliveryStatus = .failed(
                    reason: String(localized: "content.delivery.reason.unreachable", comment: "Failure reason when a peer is unreachable")
                )
            }
            addSystemMessage(
                String(
                    format: String(localized: "system.dm.unreachable", comment: "System message when a recipient is unreachable"),
                    locale: .current,
                    recipientNickname
                )
            )
        }
    }
    
    func sendGeohashDM(_ content: String, to peerID: PeerID) {
        guard case .location(let ch) = activeChannel else {
            addSystemMessage(
                String(localized: "system.location.not_in_channel", comment: "System message when attempting to send without being in a location channel")
            )
            return
        }
        let messageID = UUID().uuidString
        
        // Local echo in the DM thread
        let message = BitchatMessage(
            id: messageID,
            sender: nickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: nickname,
            senderPeerID: meshService.myPeerID,
            deliveryStatus: .sending
        )
        
        if privateChats[peerID] == nil {
            privateChats[peerID] = []
        }
        
        privateChats[peerID]?.append(message)
        objectWillChange.send()

        // Resolve recipient hex from mapping
        guard let recipientHex = nostrKeyMapping[peerID] else {
            if let msgIdx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[msgIdx].deliveryStatus = .failed(
                    reason: String(localized: "content.delivery.reason.unknown_recipient", comment: "Failure reason when the recipient is unknown")
                )
            }
            return
        }
        
        // Respect geohash blocks
        if identityManager.isNostrBlocked(pubkeyHexLowercased: recipientHex) {
            if let msgIdx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[msgIdx].deliveryStatus = .failed(
                    reason: String(localized: "content.delivery.reason.blocked", comment: "Failure reason when the user is blocked")
                )
            }
            addSystemMessage(
                String(localized: "system.dm.blocked_generic", comment: "System message when sending fails because user is blocked")
            )
            return
        }
        
        // Send via Nostr using per-geohash identity
        do {
            let id = try idBridge.deriveIdentity(forGeohash: ch.geohash)
            // Prevent messaging ourselves
            if recipientHex.lowercased() == id.publicKeyHex.lowercased() {
                if let idx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[idx].deliveryStatus = .failed(
                    reason: String(localized: "content.delivery.reason.self", comment: "Failure reason when attempting to message yourself")
                )
            }
                return
            }
            SecureLogger.debug("GeoDM: local send mid=\(messageID.prefix(8))… to=\(recipientHex.prefix(8))… conv=\(peerID)", category: .session)
            let nostrTransport = NostrTransport(keychain: keychain, idBridge: idBridge)
            nostrTransport.senderPeerID = meshService.myPeerID
            nostrTransport.sendPrivateMessageGeohash(content: content, toRecipientHex: recipientHex, from: id, messageID: messageID)
            if let msgIdx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[msgIdx].deliveryStatus = .sent
            }
        } catch {
            if let idx = privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                privateChats[peerID]?[idx].deliveryStatus = .failed(
                    reason: String(localized: "content.delivery.reason.send_error", comment: "Failure reason for a generic send error")
                )
            }
        }
    }

    // MARK: - Private Chat Handling (Geohash/Ephemeral)

    func handlePrivateMessage(
        _ payload: NoisePayload,
        senderPubkey: String,
        convKey: PeerID,
        id: NostrIdentity,
        messageTimestamp: Date
    ) {
        guard let pm = PrivateMessagePacket.decode(from: payload.data) else { return }
        let messageId = pm.messageID
        
        SecureLogger.info("GeoDM: recv PM <- sender=\(senderPubkey.prefix(8))… mid=\(messageId.prefix(8))…", category: .session)

        sendDeliveryAckIfNeeded(to: messageId, senderPubKey: senderPubkey, from: id)

        // Respect geohash blocks
        if identityManager.isNostrBlocked(pubkeyHexLowercased: senderPubkey) {
            return
        }

        // Duplicate check
        if privateChats[convKey]?.contains(where: { $0.id == messageId }) == true { return }
        for (_, arr) in privateChats {
            if arr.contains(where: { $0.id == messageId }) {
                return
            }
        }
        
        let senderName = displayNameForNostrPubkey(senderPubkey)
        let msg = BitchatMessage(
            id: messageId,
            sender: senderName,
            content: pm.content,
            timestamp: messageTimestamp,
            isRelay: false,
            isPrivate: true,
            recipientNickname: nickname,
            senderPeerID: convKey,
            receivedViaInternet: true,
            deliveryStatus: .delivered(to: nickname, at: Date())
        )
        
        if privateChats[convKey] == nil {
            privateChats[convKey] = []
        }
        privateChats[convKey]?.append(msg)
        
        let isViewing = selectedPrivateChatPeer == convKey
        let wasReadBefore = sentReadReceipts.contains(messageId)
        let isRecentMessage = Date().timeIntervalSince(messageTimestamp) < 30
        let shouldMarkUnread = !wasReadBefore && !isViewing && isRecentMessage
        if shouldMarkUnread {
            unreadPrivateMessages.insert(convKey)
        }
        
        // Send READ if viewing this conversation
        if isViewing {
            sendReadReceiptIfNeeded(to: messageId, senderPubKey: senderPubkey, from: id)
        }
        
        // Notify for truly unread and recent messages when not viewing
        if !isViewing,
           shouldMarkUnread,
           Self.shouldSendGenericPrivateMessageNotification(for: pm.content) {
            Task {
                _ = await NotificationService.shared.sendPrivateMessageNotification(
                    from: senderName,
                    message: pm.content,
                    peerID: convKey,
                    messageID: messageId
                )
            }
        }
        
        objectWillChange.send()
    }
    
    func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        guard let messageID = String(data: payload.data, encoding: .utf8) else { return }
        
        if let idx = privateChats[convKey]?.firstIndex(where: { $0.id == messageID }) {
            privateChats[convKey]?[idx].deliveryStatus = .delivered(to: displayNameForNostrPubkey(senderPubkey), at: Date())
            objectWillChange.send()
            SecureLogger.info("GeoDM: recv DELIVERED for mid=\(messageID.prefix(8))… from=\(senderPubkey.prefix(8))…", category: .session)
        } else {
            SecureLogger.warning("GeoDM: delivered ack for unknown mid=\(messageID.prefix(8))… conv=\(convKey)", category: .session)
        }
    }
    
    func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        guard let messageID = String(data: payload.data, encoding: .utf8) else { return }
        
        if let idx = privateChats[convKey]?.firstIndex(where: { $0.id == messageID }) {
            privateChats[convKey]?[idx].deliveryStatus = .read(by: displayNameForNostrPubkey(senderPubkey), at: Date())
            objectWillChange.send()
            SecureLogger.info("GeoDM: recv READ for mid=\(messageID.prefix(8))… from=\(senderPubkey.prefix(8))…", category: .session)
        } else {
            SecureLogger.warning("GeoDM: read ack for unknown mid=\(messageID.prefix(8))… conv=\(convKey)", category: .session)
        }
    }

    func sendDeliveryAckIfNeeded(to messageId: String, senderPubKey: String, from id: NostrIdentity) {
        guard !sentGeoDeliveryAcks.contains(messageId) else { return }
        let nt = NostrTransport(keychain: keychain, idBridge: idBridge)
        nt.senderPeerID = meshService.myPeerID
        nt.sendDeliveryAckGeohash(for: messageId, toRecipientHex: senderPubKey, from: id)
        sentGeoDeliveryAcks.insert(messageId)
    }
    
    func sendReadReceiptIfNeeded(to messageId: String, senderPubKey: String, from id: NostrIdentity) {
        guard !sentReadReceipts.contains(messageId) else { return }
        let nt = NostrTransport(keychain: keychain, idBridge: idBridge)
        nt.senderPeerID = meshService.myPeerID
        nt.sendReadReceiptGeohash(messageId, toRecipientHex: senderPubKey, from: id)
        sentReadReceipts.insert(messageId)
    }

    // MARK: - Media Transfers

    private enum MediaSendError: Error {
        case encodingFailed
        case tooLarge
        case copyFailed
    }

    @MainActor
    func sendVoiceNote(at url: URL) {
        guard canSendMediaInCurrentContext else {
            SecureLogger.info("Voice note blocked outside mesh/private context", category: .session)
            try? FileManager.default.removeItem(at: url)
            addSystemMessage("Private Bluetooth media is unavailable until end-to-end encryption is established.")
            return
        }

        let targetPeer = selectedPrivateChatPeer
        let data: Data
        do {
            let fileSize = try mediaFileSize(at: url)
            guard fileSize <= FileTransferLimits.maxVoiceNoteBytes else {
                SecureLogger.warning("Voice note exceeds size limit (\(fileSize) bytes)", category: .session)
                try? FileManager.default.removeItem(at: url)
                addSystemMessage("Voice note is too large to send.")
                return
            }

            data = try Data(contentsOf: url)
            guard data.count <= FileTransferLimits.maxVoiceNoteBytes else {
                SecureLogger.warning("Voice note exceeds size limit (\(data.count) bytes)", category: .session)
                try? FileManager.default.removeItem(at: url)
                addSystemMessage("Voice note is too large to send.")
                return
            }
        } catch {
            SecureLogger.error("Voice note preparation failed: \(error)", category: .session)
            try? FileManager.default.removeItem(at: url)
            addSystemMessage("Failed to prepare voice note for sending.")
            return
        }

        guard let outgoing = persistOutgoingVoiceNote(sourceURL: url, data: data) else {
            addSystemMessage("Failed to prepare voice note for sending.")
            return
        }

        let message = enqueueMediaMessage(content: "[voice] \(outgoing.url.lastPathComponent)", targetPeer: targetPeer)
        let messageID = message.id
        let transferId = makeTransferID(messageID: messageID)
        let packet = BitchatFilePacket(
            fileName: outgoing.url.lastPathComponent,
            fileSize: UInt64(data.count),
            mimeType: "audio/mp4",
            content: data
        )

        guard packet.encode() != nil else {
            if outgoing.createdCopy {
                try? FileManager.default.removeItem(at: outgoing.url)
            }
            handleMediaSendFailure(messageID: messageID, reason: "Failed to encode voice note")
            return
        }

        registerTransfer(transferId: transferId, messageID: messageID)
        if let peerID = targetPeer {
            meshService.sendFilePrivate(packet, to: peerID, transferId: transferId)
        } else {
            meshService.sendFileBroadcast(packet, transferId: transferId)
        }
    }

    @MainActor
    func sendImage(from sourceURL: URL, cleanup: (() -> Void)? = nil) {
        guard canSendMediaInCurrentContext else {
            SecureLogger.info("Image send blocked outside mesh/private context", category: .session)
            cleanup?()
            addSystemMessage("Private Bluetooth media is unavailable until end-to-end encryption is established.")
            return
        }

        let targetPeer = selectedPrivateChatPeer

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            var processedURL: URL?
            do {
                let outputURL = try ImageUtils.processImage(at: sourceURL)
                processedURL = outputURL
                let data = try Data(contentsOf: outputURL)
                guard data.count <= FileTransferLimits.maxImageBytes else {
                    SecureLogger.warning("Processed image exceeds size limit (\(data.count) bytes)", category: .session)
                    await MainActor.run {
                        self.addSystemMessage("Image is too large to send.")
                    }
                    try? FileManager.default.removeItem(at: outputURL)
                    return
                }
                let packet = BitchatFilePacket(
                    fileName: outputURL.lastPathComponent,
                    fileSize: UInt64(data.count),
                    mimeType: "image/jpeg",
                    content: data
                )
                guard packet.encode() != nil else { throw MediaSendError.encodingFailed }
                await MainActor.run {
                    let message = self.enqueueMediaMessage(content: "[image] \(outputURL.lastPathComponent)", targetPeer: targetPeer)
                    let messageID = message.id
                    let transferId = self.makeTransferID(messageID: messageID)
                    self.registerTransfer(transferId: transferId, messageID: messageID)
                    if let peerID = targetPeer {
                        self.meshService.sendFilePrivate(packet, to: peerID, transferId: transferId)
                    } else {
                        self.meshService.sendFileBroadcast(packet, transferId: transferId)
                    }
                }
            } catch {
                SecureLogger.error("Image send preparation failed: \(error)", category: .session)
                await MainActor.run {
                    self.addSystemMessage("Failed to prepare image for sending.")
                }
                if let url = processedURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    @MainActor
    func sendFile(data: Data, filename: String, mime: String) {
        guard canSendMediaInCurrentContext else {
            SecureLogger.info("File send blocked outside mesh/private context", category: .session)
            addSystemMessage("Private Bluetooth media is unavailable until end-to-end encryption is established.")
            return
        }

        let mimeType = MimeType(mime) ?? .octetStream
        guard FileTransferLimits.isValidPayload(data.count) else {
            SecureLogger.warning("File exceeds size limit (\(data.count) bytes)", category: .session)
            addSystemMessage("File is too large to send.")
            return
        }

        guard let savedURL = saveOutgoingFile(data: data, filename: filename, mime: mimeType) else {
            addSystemMessage("Failed to prepare file for sending.")
            return
        }

        let targetPeer = selectedPrivateChatPeer
        let marker = mediaMarkerPrefix(for: mimeType) + " \(savedURL.lastPathComponent)"
        let message = enqueueMediaMessage(content: marker, targetPeer: targetPeer)
        let messageID = message.id
        let transferId = makeTransferID(messageID: messageID)
        let packet = BitchatFilePacket(
            fileName: savedURL.lastPathComponent,
            fileSize: UInt64(data.count),
            mimeType: mimeType.mimeString,
            content: data
        )

        guard packet.encode() != nil else {
            handleMediaSendFailure(messageID: messageID, reason: "Failed to encode file")
            try? FileManager.default.removeItem(at: savedURL)
            return
        }

        registerTransfer(transferId: transferId, messageID: messageID)
        if let peerID = targetPeer {
            meshService.sendFilePrivate(packet, to: peerID, transferId: transferId)
        } else {
            meshService.sendFileBroadcast(packet, transferId: transferId)
        }
    }

    private func saveOutgoingFile(data: Data, filename: String, mime: MimeType) -> URL? {
        do {
            let base = try applicationFilesDirectory()
            let directory = base.appendingPathComponent(mediaOutgoingSubdirectory(for: mime), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

            let rawName = (filename as NSString).lastPathComponent
            let fallbackName = "file-\(UUID().uuidString).\(mime.defaultExtension)"
            let safeName = rawName.isEmpty || rawName == "." || rawName == ".." ? fallbackName : rawName
            let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
            try data.write(to: destination, options: [.atomic])
            return destination
        } catch {
            SecureLogger.error("File send preparation failed: \(error)", category: .session)
            return nil
        }
    }

    private func persistOutgoingVoiceNote(sourceURL: URL, data: Data) -> (url: URL, createdCopy: Bool)? {
        do {
            let voiceDirectory = try applicationFilesDirectory()
                .appendingPathComponent("voicenotes/outgoing", isDirectory: true)
            try FileManager.default.createDirectory(at: voiceDirectory, withIntermediateDirectories: true, attributes: nil)

            if sourceURL.standardizedFileURL.deletingLastPathComponent().path == voiceDirectory.standardizedFileURL.path {
                return (sourceURL, false)
            }
        } catch {
            SecureLogger.error("Voice note send preparation failed: \(error)", category: .session)
            return nil
        }

        guard let savedURL = saveOutgoingFile(data: data, filename: sourceURL.lastPathComponent, mime: .mp4Audio) else {
            return nil
        }
        return (savedURL, true)
    }

    private func mediaFileSize(at url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? NSNumber {
            return size.intValue
        }
        if let size = attrs[.size] as? Int {
            return size
        }
        if let size = attrs[.size] as? UInt64 {
            return size > UInt64(Int.max) ? Int.max : Int(size)
        }
        if let size = attrs[.size] as? Int64 {
            return size > Int64(Int.max) ? Int.max : Int(size)
        }
        throw MediaSendError.copyFailed
    }

    private func mediaOutgoingSubdirectory(for mime: MimeType) -> String {
        switch mime.category {
        case .audio:
            return "voicenotes/outgoing"
        case .image:
            return "images/outgoing"
        case .file:
            return "files/outgoing"
        }
    }

    private func mediaMarkerPrefix(for mime: MimeType) -> String {
        switch mime.category {
        case .audio:
            return "[voice]"
        case .image:
            return "[image]"
        case .file:
            return "[file]"
        }
    }

    @MainActor
    func enqueueMediaMessage(content: String, targetPeer: PeerID?) -> BitchatMessage {
        let timestamp = Date()
        let message: BitchatMessage

        if let peerID = targetPeer {
            message = BitchatMessage(
                sender: nickname,
                content: content,
                timestamp: timestamp,
                isRelay: false,
                originalSender: nil,
                isPrivate: true,
                recipientNickname: nicknameForPeer(peerID),
                senderPeerID: meshService.myPeerID,
                deliveryStatus: .sending
            )
            var chats = privateChats
            chats[peerID, default: []].append(message)
            privateChats = chats
            trimMessagesIfNeeded()
        } else {
            let (displayName, senderPeerID) = currentPublicSender()
            message = BitchatMessage(
                sender: displayName,
                content: content,
                timestamp: timestamp,
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: senderPeerID,
                deliveryStatus: .sending
            )
            timelineStore.append(message, to: activeChannel)
            messages = timelineStore.messages(for: activeChannel)
            trimMessagesIfNeeded()
        }

        let key = deduplicationService.normalizedContentKey(message.content)
        deduplicationService.recordContentKey(key, timestamp: timestamp)
        objectWillChange.send()
        return message
    }

    @MainActor
    func registerTransfer(transferId: String, messageID: String) {
        transferIdToMessageIDs[transferId, default: []].append(messageID)
        messageIDToTransferId[messageID] = transferId
    }

    func makeTransferID(messageID: String) -> String {
        "\(messageID)-\(UUID().uuidString)"
    }

    @MainActor
    func clearTransferMapping(for messageID: String) {
        guard let transferId = messageIDToTransferId.removeValue(forKey: messageID) else { return }
        guard var queue = transferIdToMessageIDs[transferId] else { return }
        if !queue.isEmpty {
            if queue.first == messageID {
                queue.removeFirst()
            } else if let idx = queue.firstIndex(of: messageID) {
                queue.remove(at: idx)
            }
        }
        transferIdToMessageIDs[transferId] = queue.isEmpty ? nil : queue
    }

    @MainActor
    func handleMediaSendFailure(messageID: String, reason: String) {
        updateMessageDeliveryStatus(messageID, status: .failed(reason: reason))
        clearTransferMapping(for: messageID)
    }

    @MainActor
    func handleTransferEvent(_ event: TransferProgressManager.Event) {
        switch event {
        case .started(let id, let total):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            updateMessageDeliveryStatus(messageID, status: .partiallyDelivered(reached: 0, total: total))
        case .updated(let id, let sent, let total):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            updateMessageDeliveryStatus(messageID, status: .partiallyDelivered(reached: sent, total: total))
        case .completed(let id, _):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            updateMessageDeliveryStatus(messageID, status: .sent)
            clearTransferMapping(for: messageID)
        case .cancelled(let id, _, _):
            guard let messageID = transferIdToMessageIDs[id]?.first else { return }
            clearTransferMapping(for: messageID)
            removeMessage(withID: messageID, cleanupFile: true)
        }
    }

    func cleanupLocalFile(forMessage message: BitchatMessage) {
        // Check both outgoing and incoming directories for thorough cleanup
        let prefixes = ["[voice] ", "[image] ", "[file] "]
        let subdirs = ["voicenotes/outgoing", "voicenotes/incoming",
                       "images/outgoing", "images/incoming",
                       "files/outgoing", "files/incoming"]

        guard let prefix = prefixes.first(where: { message.content.hasPrefix($0) }) else { return }
        let rawFilename = String(message.content.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawFilename.isEmpty, let base = try? applicationFilesDirectory() else { return }

        // Security: Extract only the last path component to prevent directory traversal
        let safeFilename = (rawFilename as NSString).lastPathComponent
        guard !safeFilename.isEmpty && safeFilename != "." && safeFilename != ".." else { return }

        // Try all possible locations (outgoing and incoming)
        for subdir in subdirs {
            let target = base.appendingPathComponent(subdir, isDirectory: true).appendingPathComponent(safeFilename)

            // Security: Verify target is within expected directory before deletion
            guard target.path.hasPrefix(base.path) else { continue }

            do {
                try FileManager.default.removeItem(at: target)
            } catch CocoaError.fileNoSuchFile {
                // Expected - file not in this directory
            } catch {
                SecureLogger.error("Failed to cleanup \(safeFilename): \(error)", category: .session)
            }
        }
    }

    /// Roll back only the exact incoming media file staged by BLE. The broader
    /// user-delete cleanup intentionally scans outgoing and incoming folders;
    /// receive rollback must not delete an unrelated outgoing file that happens
    /// to share the same last path component.
    func cleanupStagedIncomingMediaFile(forMessage message: BitchatMessage) {
        let mapping: [(prefix: String, subdirectory: String)] = [
            ("[voice] ", "voicenotes/incoming"),
            ("[image] ", "images/incoming"),
            ("[file] ", "files/incoming")
        ]
        guard let match = mapping.first(where: { message.content.hasPrefix($0.prefix) }) else { return }
        let rawName = String(message.content.dropFirst(match.prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = (rawName as NSString).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != "..",
              let base = try? applicationFilesDirectory() else { return }
        let target = base
            .appendingPathComponent(match.subdirectory, isDirectory: true)
            .appendingPathComponent(safeName)
        try? FileManager.default.removeItem(at: target)
    }

    func applicationFilesDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let filesDir = base.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true, attributes: nil)
        return filesDir
    }

    @MainActor
    func cancelMediaSend(messageID: String) {
        if let transferId = messageIDToTransferId[messageID],
           let active = transferIdToMessageIDs[transferId]?.first,
           active == messageID {
            meshService.cancelTransfer(transferId)
        }
        clearTransferMapping(for: messageID)
        removeMessage(withID: messageID, cleanupFile: true)
    }

    @MainActor
    func deleteMediaMessage(messageID: String) {
        clearTransferMapping(for: messageID)
        removeMessage(withID: messageID, cleanupFile: true)
    }
    
    // MARK: - Private Chat Handling (Main)

    @MainActor
    func handlePrivateMessage(
        _ payload: NoisePayload,
        actualSenderNoiseKey: Data?,
        senderNickname: String,
        targetPeerID: PeerID,
        messageTimestamp: Date,
        senderPubkey: String
    ) {
        guard let pm = PrivateMessagePacket.decode(from: payload.data) else { return }
        let messageId = pm.messageID
        let messageContent = pm.content

        // Favorite/unfavorite notifications embedded as private messages
        if messageContent.hasPrefix("[FAVORITED]") || messageContent.hasPrefix("[UNFAVORITED]") {
            if let key = actualSenderNoiseKey {
                handleFavoriteNotificationFromMesh(messageContent, from: PeerID(hexData: key), senderNickname: senderNickname)
            }
            return
        }

        if isDuplicateMessage(messageId, targetPeerID: targetPeerID) {
            return
        }

        let wasReadBefore = sentReadReceipts.contains(messageId)

        // Is viewing?
        var isViewingThisChat = false
        if selectedPrivateChatPeer == targetPeerID {
            isViewingThisChat = true
        } else if let selectedPeer = selectedPrivateChatPeer,
                  let selectedPeerData = unifiedPeerService.getPeer(by: selectedPeer),
                  let key = actualSenderNoiseKey,
                  selectedPeerData.noisePublicKey == key {
            isViewingThisChat = true
        }

        // Recency check
        let isRecentMessage = Date().timeIntervalSince(messageTimestamp) < 30
        let shouldMarkAsUnread = !wasReadBefore && !isViewingThisChat && isRecentMessage

        let message = BitchatMessage(
            id: messageId,
            sender: senderNickname,
            content: messageContent,
            timestamp: messageTimestamp,
            isRelay: false,
            isPrivate: true,
            recipientNickname: nickname,
            senderPeerID: targetPeerID,
            receivedViaInternet: true,
            deliveryStatus: .delivered(to: nickname, at: Date())
        )
        
        addMessageToPrivateChatsIfNeeded(message, targetPeerID: targetPeerID)
        mirrorToEphemeralIfNeeded(message, targetPeerID: targetPeerID, key: actualSenderNoiseKey)

        // Using simplified internal helper in this file (or make the main one internal)
        // sendDeliveryAckViaNostrEmbedded is in ChatViewModel+Nostr.swift and is internal.
        // However, it was missing in ChatViewModel+Nostr.swift in previous step check?
        // Wait, I added `sendDeliveryAckViaNostrEmbedded` to `ChatViewModel+Nostr.swift` in Step 19?
        // Let's re-check `ChatViewModel+Nostr.swift` content in my mind.
        // I see `sendDeliveryAckViaNostrEmbedded` in `ChatViewModel+Nostr.swift` in the output of step 33.
        // So I can call it.
        sendDeliveryAckViaNostrEmbedded(
            message,
            wasReadBefore: wasReadBefore,
            senderPubkey: senderPubkey,
            key: actualSenderNoiseKey
        )

        if wasReadBefore {
            // do nothing
        } else if isViewingThisChat {
            handleViewingThisChat(
                message,
                targetPeerID: targetPeerID,
                key: actualSenderNoiseKey,
                senderPubkey: senderPubkey
            )
        } else {
            markAsUnreadIfNeeded(
                shouldMarkAsUnread: shouldMarkAsUnread,
                targetPeerID: targetPeerID,
                key: actualSenderNoiseKey,
                isRecentMessage: isRecentMessage,
                senderNickname: senderNickname,
                messageContent: messageContent,
                messageID: message.id
            )
        }

        objectWillChange.send()
    }
    
    /// Handle incoming private message (Mesh)
    ///
    /// Stages the accepted message (or non-transcript control receipt), then
    /// suspends off-main until it is atomically durable. UI and receive-side
    /// effects are published only after that barrier succeeds. Callers must
    /// only emit a delivery ACK when this returns true.
    @MainActor
    func handlePrivateMessageDurably(_ message: BitchatMessage) async -> Bool {
        await meshInboundCommitGate.enter()
        let gate = meshInboundCommitGate
        defer { Task { await gate.leave() } }

        guard let peerID = message.senderPeerID ?? getPeerIDForNickname(message.sender) else {
            SecureLogger.warning("⚠️ Could not resolve durable sender for \(message.id)", category: .session)
            return false
        }
        preparePrivateChatRoute(for: peerID, senderNickname: message.sender)
        let storageGeneration = privateChatManager.currentStorageGeneration()

        if message.content.hasPrefix("[FAVORITED]") || message.content.hasPrefix("[UNFAVORITED]") {
            // The receipt is the MessageStore transaction for a control that
            // intentionally never enters the transcript. Apply Keychain/UI
            // state only after that transaction succeeds.
            guard await privateChatManager.commitIncomingControl(
                message.id,
                from: peerID,
                expectedGeneration: storageGeneration
            ), privateChatManager.currentStorageGeneration() == storageGeneration else {
                return false
            }
            return handleFavoriteNotificationFromMesh(
                message.content,
                from: peerID,
                senderNickname: message.sender
            )
        }

        if isDuplicateMessage(message.id, targetPeerID: peerID) {
            guard await privateChatManager.commitIncomingMessage(
                message.id,
                preferredPeerID: peerID,
                expectedGeneration: storageGeneration
            ), privateChatManager.currentStorageGeneration() == storageGeneration else {
                return false
            }
            if privateChatManager.hasPendingReceiveEffects(message.id, preferredPeerID: peerID) {
                guard await handlePrivateMessageReceiveSideEffects(message, peerID: peerID) else {
                    return false
                }
                guard await privateChatManager.commitReceiveEffectsProcessed(
                    message.id,
                    preferredPeerID: peerID,
                    expectedGeneration: storageGeneration
                ), privateChatManager.currentStorageGeneration() == storageGeneration else {
                    return false
                }
            }
            return true
        }

        guard await privateChatManager.commitStagedIncomingMessage(
            message,
            preferredPeerID: peerID,
            expectedGeneration: storageGeneration
        ), privateChatManager.currentStorageGeneration() == storageGeneration else {
            return false
        }
        let noiseKey = peerID.noiseKey ?? unifiedPeerService.getPeer(by: peerID)?.noisePublicKey
        mirrorToEphemeralIfNeeded(message, targetPeerID: peerID, key: noiseKey)
        guard await handlePrivateMessageReceiveSideEffects(message, peerID: peerID) else {
            return false
        }
        guard await privateChatManager.commitReceiveEffectsProcessed(
            message.id,
            preferredPeerID: peerID,
            expectedGeneration: storageGeneration
        ), privateChatManager.currentStorageGeneration() == storageGeneration else {
            return false
        }
        objectWillChange.send()
        return true
    }

    @MainActor
    func replayPendingPrivateReceiveEffectsAtStartup() async {
        let storageGeneration = privateChatManager.currentStorageGeneration()
        for pending in await privateChatManager.pendingReceiveEffectsForStartupReplay() {
            guard privateChatManager.currentStorageGeneration() == storageGeneration else { return }
            guard await handlePrivateMessageReceiveSideEffects(pending.message, peerID: pending.peerID) else {
                continue
            }
            guard await privateChatManager.commitReceiveEffectsProcessed(
                pending.message.id,
                preferredPeerID: pending.peerID,
                expectedGeneration: storageGeneration
            ), privateChatManager.currentStorageGeneration() == storageGeneration else {
                // Leave the in-memory + durable obligation for a stable-id retry.
                continue
            }
        }
        objectWillChange.send()
    }

    @MainActor
    private func preparePrivateChatRoute(for peerID: PeerID, senderNickname: String) {
        migratePrivateChatsIfNeeded(for: peerID, senderNickname: senderNickname)

        // A BLE short ID and its stable Noise-key/Nostr route are one logical
        // conversation. Fold the existing stable transcript before the durable
        // receive snapshot is built, so the commit and ACK target one key.
        guard peerID.id.count == 16,
              let peer = unifiedPeerService.getPeer(by: peerID) else { return }
        let stableKey = PeerID(hexData: peer.noisePublicKey)
        guard stableKey != peerID,
              let stableMessages = privateChats[stableKey],
              !stableMessages.isEmpty else { return }

        var canonical = privateChats[peerID] ?? []
        let existingIDs = Set(canonical.map(\.id))
        canonical.append(contentsOf: stableMessages.filter { !existingIDs.contains($0.id) })
        canonical.sort { $0.timestamp < $1.timestamp }
        privateChats[peerID] = canonical
        privateChats.removeValue(forKey: stableKey)
        privateChatManager.sanitizeChat(for: peerID)
        SecureLogger.info(
            "📥 Consolidated \(stableMessages.count) stable-route messages into \(peerID)",
            category: .session
        )
    }

    @MainActor
    func handlePrivateMessage(_ message: BitchatMessage) {
        SecureLogger.debug("📥 handlePrivateMessage called for message from \(message.sender)", category: .session)
        let senderPeerID = message.senderPeerID ?? getPeerIDForNickname(message.sender)
        
        guard let peerID = senderPeerID else { 
            SecureLogger.warning("⚠️ Could not get peer ID for sender \(message.sender)", category: .session)
            return
        }
        
        // Check if this is a favorite/unfavorite notification
        if message.content.hasPrefix("[FAVORITED]") || message.content.hasPrefix("[UNFAVORITED]") {
            handleFavoriteNotificationFromMesh(message.content, from: peerID, senderNickname: message.sender)
            return  // Don't store as a regular message
        }
        
        preparePrivateChatRoute(for: peerID, senderNickname: message.sender)
        
        // Avoid duplicates
        if isDuplicateMessage(message.id, targetPeerID: peerID) {
            return
        }

        // Store the message
        addMessageToPrivateChatsIfNeeded(message, targetPeerID: peerID)
        
        // Mirror to ephemeral if needed (if we are talking to a stable key peer but have an ephemeral session)
        // Actually, logic usually mirrors TO stable key storage if available?
        // Or mirrors to ephemeral if we received on stable.
        // Let's just use the existing helper which seems to mirror TO ephemeral.
        // But we need to get the noise key.
        let noiseKey = peerID.noiseKey ?? unifiedPeerService.getPeer(by: peerID)?.noisePublicKey
        mirrorToEphemeralIfNeeded(message, targetPeerID: peerID, key: noiseKey)

        Task { @MainActor [weak self] in
            _ = await self?.handlePrivateMessageReceiveSideEffects(message, peerID: peerID)
        }

        objectWillChange.send()
    }

    @MainActor
    private func handlePrivateMessageReceiveSideEffects(_ message: BitchatMessage, peerID: PeerID) async -> Bool {
        // Notifications and read receipts must follow the durable commit on
        // the BLE receive path. Other local-first callers use this immediately.
        // A viewed-message receipt is persisted by stable ID. If we crashed
        // before clearing the effect obligation, boot replay must not convert
        // that already-read message into an unread notification.
        if sentReadReceipts.contains(message.id) { return true }
        let isViewing = selectedPrivateChatPeer == peerID
        
        if isViewing {
            // Mark read immediately if viewing
            // Use the incoming peerID directly - it has the established Noise session.
            // Don't use PeerID(hexData: noiseKey) as that creates a 64-hex ID without a session.
            // Use meshService directly (not messageRouter) so it queues if peer disconnects.
            let receipt = ReadReceipt(originalMessageID: message.id, readerID: meshService.myPeerID, readerNickname: nickname)
            meshService.sendReadReceipt(receipt, to: peerID)
            sentReadReceipts.insert(message.id)
            return true
        } else {
            // Notify — skip ☎CALL / ⚡PAY control lines; SonarAppStore owns those
            // specialized alerts so we don't double-fire BLE sounds.
            unreadPrivateMessages.insert(peerID)
            if Self.shouldSendGenericPrivateMessageNotification(for: message.content) {
                let notifBody = meshParseStickerContent(content: message.content) != nil
                    ? "Sticker" : message.content
                let outcome = await NotificationService.shared.sendPrivateMessageNotification(
                    from: message.sender,
                    message: notifBody,
                    peerID: peerID,
                    messageID: message.id,
                    sound: .ble
                )
                return outcome != .retryableFailure
            }
            return true
        }
    }

    func isDuplicateMessage(_ messageId: String, targetPeerID: PeerID) -> Bool {
        if privateChats[targetPeerID]?.contains(where: { $0.id == messageId }) == true {
            return true
        }
        for (_, messages) in privateChats where messages.contains(where: { $0.id == messageId }) {
            return true
        }
        return false
    }
    
    func addMessageToPrivateChatsIfNeeded(_ message: BitchatMessage, targetPeerID: PeerID) {
        if privateChats[targetPeerID] == nil {
            privateChats[targetPeerID] = []
        }
        if let idx = privateChats[targetPeerID]?.firstIndex(where: { $0.id == message.id }) {
            privateChats[targetPeerID]?[idx] = message
        } else {
            privateChats[targetPeerID]?.append(message)
        }
        // Sanitize to avoid duplicate IDs
        privateChatManager.sanitizeChat(for: targetPeerID)
    }
    
    @MainActor
    func mirrorToEphemeralIfNeeded(_ message: BitchatMessage, targetPeerID: PeerID, key: Data?) {
        guard let key,
              let ephemeralPeerID = unifiedPeerService.peers.first(where: { $0.noisePublicKey == key })?.peerID,
              ephemeralPeerID != targetPeerID
        else {
            return
        }
        
        if privateChats[ephemeralPeerID] == nil {
            privateChats[ephemeralPeerID] = []
        }
        if let idx = privateChats[ephemeralPeerID]?.firstIndex(where: { $0.id == message.id }) {
            privateChats[ephemeralPeerID]?[idx] = message
        } else {
            privateChats[ephemeralPeerID]?.append(message)
        }
        privateChatManager.sanitizeChat(for: ephemeralPeerID)
    }
    
    @MainActor
    func handleViewingThisChat(_ message: BitchatMessage, targetPeerID: PeerID, key: Data?, senderPubkey: String) {
        unreadPrivateMessages.remove(targetPeerID)
        if let key,
           let ephemeralPeerID = unifiedPeerService.peers.first(where: { $0.noisePublicKey == key })?.peerID {
            unreadPrivateMessages.remove(ephemeralPeerID)
        }
        if !sentReadReceipts.contains(message.id) {
            if let key {
                let receipt = ReadReceipt(originalMessageID: message.id, readerID: meshService.myPeerID, readerNickname: nickname)
                SecureLogger.debug("Viewing chat; sending READ ack for \(message.id.prefix(8))… via router", category: .session)
                messageRouter.sendReadReceipt(receipt, to: PeerID(hexData: key))
                sentReadReceipts.insert(message.id)
            } else if let id = try? idBridge.getCurrentNostrIdentity() {
                let nt = NostrTransport(keychain: keychain, idBridge: idBridge)
                nt.senderPeerID = meshService.myPeerID
                nt.sendReadReceiptGeohash(message.id, toRecipientHex: senderPubkey, from: id)
                sentReadReceipts.insert(message.id)
                SecureLogger.debug("Viewing chat; sent READ ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…", category: .session)
            }
        }
    }
    
    @MainActor
    func markAsUnreadIfNeeded(
        shouldMarkAsUnread: Bool,
        targetPeerID: PeerID,
        key: Data?,
        isRecentMessage: Bool,
        senderNickname: String,
        messageContent: String,
        messageID: String
    ) {
        guard shouldMarkAsUnread else { return }
        
        unreadPrivateMessages.insert(targetPeerID)
        if let key,
           let ephemeralPeerID = unifiedPeerService.peers.first(where: { $0.noisePublicKey == key })?.peerID,
           ephemeralPeerID != targetPeerID {
            unreadPrivateMessages.insert(ephemeralPeerID)
        }
        if isRecentMessage,
           Self.shouldSendGenericPrivateMessageNotification(for: messageContent) {
            Task {
                _ = await NotificationService.shared.sendPrivateMessageNotification(
                    from: senderNickname,
                    message: messageContent,
                    peerID: targetPeerID,
                    messageID: messageID
                )
            }
        }
    }
    
    @MainActor
    @discardableResult
    func handleFavoriteNotificationFromMesh(_ content: String, from peerID: PeerID, senderNickname: String) -> Bool {
        // Parse the message format: "[FAVORITED]:npub..." or "[UNFAVORITED]:npub..."
        let isFavorite = content.hasPrefix("[FAVORITED]")
        let parts = content.split(separator: ":")
        
        // Extract Nostr public key if included
        var nostrPubkey: String? = nil
        if parts.count > 1 {
            nostrPubkey = String(parts[1])
            SecureLogger.info("📝 Received Nostr npub in favorite notification: \(nostrPubkey ?? "none")", category: .session)
        }
        
        // Get the noise public key for this peer
        let noiseKey = peerID.noiseKey ?? unifiedPeerService.getPeer(by: peerID)?.noisePublicKey
        
        guard let finalNoiseKey = noiseKey else {
            SecureLogger.warning("⚠️ Cannot get Noise key for peer \(peerID)", category: .session)
            return false
        }
        // Determine prior state to avoid duplicate system messages on repeated notifications
        let prior = favoritesPersistenceService.getFavoriteStatus(for: finalNoiseKey)?.theyFavoritedUs ?? false

        // Update the favorite relationship (idempotent storage)
        guard favoritesPersistenceService.updatePeerFavoritedUs(
            peerNoisePublicKey: finalNoiseKey,
            favorited: isFavorite,
            peerNickname: senderNickname,
            peerNostrPublicKey: nostrPubkey
        ) else {
            return false
        }

        // If they favorited us and provided their Nostr key, ensure it's stored (log only)
        if isFavorite && nostrPubkey != nil {
            SecureLogger.info("💾 Storing Nostr key association for \(senderNickname): \(nostrPubkey!.prefix(16))...", category: .session)
        }

        // Only show a system message when the state changes, and only in mesh
        if prior != isFavorite {
            let action = isFavorite ? "favorited" : "unfavorited"
            addMeshOnlySystemMessage("\(senderNickname) \(action) you")
        }
        return true
    }
    
    /// Process action messages (hugs, slaps) into system messages
    func processActionMessage(_ message: BitchatMessage) -> BitchatMessage {
        let isActionMessage = message.content.hasPrefix("* ") && message.content.hasSuffix(" *") &&
                              (message.content.contains("🫂") || message.content.contains("🐟") || 
                               message.content.contains("took a screenshot"))
        
        if isActionMessage {
            return BitchatMessage(
                id: message.id,
                sender: "system",
                content: String(message.content.dropFirst(2).dropLast(2)), // Remove * * wrapper
                timestamp: message.timestamp,
                isRelay: message.isRelay,
                originalSender: message.originalSender,
                isPrivate: message.isPrivate,
                recipientNickname: message.recipientNickname,
                senderPeerID: message.senderPeerID,
                receivedViaInternet: message.receivedViaInternet,
                mentions: message.mentions,
                deliveryStatus: message.deliveryStatus
            )
        }
        return message
    }
    
    /// Migrate private chats when peer reconnects with new ID
    @MainActor
    func migratePrivateChatsIfNeeded(for peerID: PeerID, senderNickname: String) {
        let currentFingerprint = getFingerprint(for: peerID)
        
        if privateChats[peerID] == nil || privateChats[peerID]?.isEmpty == true {
            var migratedMessages: [BitchatMessage] = []
            var oldPeerIDsToRemove: [PeerID] = []
            
            // Only migrate messages from the last 24 hours to prevent old messages from flooding
            let cutoffTime = Date().addingTimeInterval(-TransportConfig.uiMigrationCutoffSeconds)
            
            for (oldPeerID, messages) in privateChats {
                if oldPeerID != peerID {
                    let oldFingerprint = peerIDToPublicKeyFingerprint[oldPeerID]
                    
                    // Filter messages to only recent ones
                    let recentMessages = messages.filter { $0.timestamp > cutoffTime }
                    
                    // Skip if no recent messages
                    guard !recentMessages.isEmpty else { continue }
                    
                    // Check fingerprint match first (most reliable)
                    if let currentFp = currentFingerprint,
                       let oldFp = oldFingerprint,
                       currentFp == oldFp {
                        migratedMessages.append(contentsOf: recentMessages)
                        
                        // Only remove old peer ID if we migrated ALL its messages
                        if recentMessages.count == messages.count {
                            oldPeerIDsToRemove.append(oldPeerID)
                        } else {
                            // Keep old messages in original location but don't show in UI
                            SecureLogger.info("📦 Partially migrating \(recentMessages.count) of \(messages.count) messages from \(oldPeerID)", category: .session)
                        }
                        
                        SecureLogger.info("📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(peerID) (fingerprint match)", category: .session)
                    } else if currentFingerprint == nil || oldFingerprint == nil {
                        // Check if this chat contains messages with this sender by nickname
                        let isRelevantChat = recentMessages.contains { msg in
                            (msg.sender == senderNickname && msg.sender != nickname) ||
                            (msg.sender == nickname && msg.recipientNickname == senderNickname)
                        }
                        
                        if isRelevantChat {
                            migratedMessages.append(contentsOf: recentMessages)
                            
                            // Only remove if all messages were migrated
                            if recentMessages.count == messages.count {
                                oldPeerIDsToRemove.append(oldPeerID)
                            }
                            
                            SecureLogger.warning("📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(peerID) (nickname match)", category: .session)
                        }
                    }
                }
            }
            
            // Remove old peer ID entries
            if !oldPeerIDsToRemove.isEmpty {
                // Track if we need to update selectedPrivateChatPeer
                let needsSelectedUpdate = oldPeerIDsToRemove.contains { selectedPrivateChatPeer == $0 }
                
                for oldID in oldPeerIDsToRemove {
                    privateChats.removeValue(forKey: oldID)
                    unreadPrivateMessages.remove(oldID)
                    
                    // Also clean up fingerprint mapping
                    if peerIDToPublicKeyFingerprint[oldID] != nil {
                        peerIDToPublicKeyFingerprint.removeValue(forKey: oldID)
                    }
                }
                
                if needsSelectedUpdate {
                    selectedPrivateChatPeer = peerID
                }
            }
            
            // Add migrated messages to new peer ID
            if !migratedMessages.isEmpty {
                if privateChats[peerID] == nil {
                    privateChats[peerID] = []
                }
                privateChats[peerID]?.append(contentsOf: migratedMessages)
                
                // Sort by timestamp
                privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
                
                // De-duplicate just in case
                privateChatManager.sanitizeChat(for: peerID)
                
                objectWillChange.send()
            }
        }
    }
    
    @MainActor
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        // Handle both ephemeral peer IDs and Noise key hex strings
        var noiseKey: Data?
        
        // First check if peerID is a hex-encoded Noise key
        if let hexKey = Data(hexString: peerID.id) {
            noiseKey = hexKey
        } else {
            // It's an ephemeral peer ID, get the Noise key from UnifiedPeerService
            if let peer = unifiedPeerService.getPeer(by: peerID) {
                noiseKey = peer.noisePublicKey
            }
        }
        
        // Try mesh first for connected peers
        if meshService.isPeerConnected(peerID) {
            messageRouter.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
            SecureLogger.debug("📤 Sent favorite notification via BLE to \(peerID)", category: .session)
        } else if let key = noiseKey {
            // Send via Nostr for offline peers (using router)
            messageRouter.sendFavoriteNotification(to: PeerID(hexData: key), isFavorite: isFavorite)
        } else {
            SecureLogger.warning("⚠️ Cannot send favorite notification - peer not connected and no Nostr pubkey", category: .session)
        }
    }

    /// Check if a message should be blocked based on sender
    @MainActor
    func isMessageBlocked(_ message: BitchatMessage) -> Bool {
        if let peerID = message.senderPeerID ?? getPeerIDForNickname(message.sender) {
            // Check mesh/known peers first
            if isPeerBlocked(peerID) { return true }
            // Check geohash (Nostr) blocks using mapping to full pubkey
            if peerID.isGeoChat || peerID.isGeoDM {
                if let full = nostrKeyMapping[peerID]?.lowercased() {
                    if identityManager.isNostrBlocked(pubkeyHexLowercased: full) { return true }
                }
            }
            return false
        }
        return false
    }
}
