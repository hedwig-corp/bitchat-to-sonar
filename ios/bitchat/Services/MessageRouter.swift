import BitLogger
import Foundation

enum PrivateMessageRoutingResult: Equatable {
    case routed
    case queued
    case rejected
}

/// Routes messages using available transports (Mesh, Nostr, etc.)
@MainActor
final class MessageRouter {
    private let transports: [Transport]

    // Outbox entry with timestamp for stable restore ordering.
    private struct QueuedMessage {
        let content: String
        let nickname: String
        let messageID: String
        let timestamp: Date
    }

    private var outbox: [PeerID: [QueuedMessage]] = [:]
    private var pendingQueueWrites: [PeerID: Int] = [:]
    private var persistQueuedMessage: ((PeerID, String, String, String, Date) async -> Bool)?
    private var completeQueuedMessage: ((String) -> Void)?

    // Outbox limits to prevent unbounded memory growth
    private static let maxMessagesPerPeer = 100

    init(transports: [Transport]) {
        self.transports = transports

        // Observe favorites changes to learn Nostr mapping and flush queued messages
        NotificationCenter.default.addObserver(
            forName: .favoriteStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let data = note.userInfo?["peerPublicKey"] as? Data {
                let peerID = PeerID(publicKey: data)
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
            // Handle key updates
            if let newKey = note.userInfo?["peerPublicKey"] as? Data,
               let _ = note.userInfo?["isKeyUpdate"] as? Bool {
                let peerID = PeerID(publicKey: newKey)
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
        }
    }

    // MARK: - Transport Selection

    private func reachableTransport(for peerID: PeerID) -> Transport? {
        transports.first { $0.isPeerReachable(peerID) }
    }

    private func connectedTransport(for peerID: PeerID) -> Transport? {
        transports.first { $0.isPeerConnected(peerID) }
    }

    // MARK: - Message Sending

    /// Attach the encrypted shared-core journal. The in-memory dictionary is
    /// only a transient mirror; restored records are supplied separately after
    /// local startup and replay happens later in the background.
    func configureDurableOutbox(
        persist: @escaping (PeerID, String, String, String, Date) async -> Bool,
        complete: @escaping (String) -> Void
    ) {
        persistQueuedMessage = persist
        completeQueuedMessage = complete
    }

    func restoreQueuedMessage(
        content: String,
        peerID: PeerID,
        recipientNickname: String,
        messageID: String,
        timestamp: Date
    ) {
        let message = QueuedMessage(
            content: content,
            nickname: recipientNickname,
            messageID: messageID,
            timestamp: timestamp
        )
        var queue = outbox[peerID, default: []]
        guard queue.contains(where: { $0.messageID == messageID }) == false else { return }
        queue.append(message)
        queue.sort { $0.timestamp < $1.timestamp }
        outbox[peerID] = queue
    }

    @discardableResult
    func sendPrivate(
        _ content: String,
        to peerID: PeerID,
        recipientNickname: String,
        messageID: String
    ) async -> PrivateMessageRoutingResult {
        if outbox[peerID]?.isEmpty == false || pendingQueueWrites[peerID, default: 0] > 0 {
            let result = await queuePrivate(
                content,
                to: peerID,
                recipientNickname: recipientNickname,
                messageID: messageID
            )
            // Drain the older durable backlog whenever possible even if this
            // newest row was rejected by persistence.
            flushOutbox(for: peerID)
            return result
        }
        if let transport = reachableTransport(for: peerID) {
            SecureLogger.debug("Routing PM via \(type(of: transport)) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            transport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
            return .routed
        }
        let result = await queuePrivate(
            content,
            to: peerID,
            recipientNickname: recipientNickname,
            messageID: messageID
        )
        // Reachability may have changed while the durable write was in flight.
        flushOutbox(for: peerID)
        return result
    }

    private func queuePrivate(
        _ content: String,
        to peerID: PeerID,
        recipientNickname: String,
        messageID: String
    ) async -> PrivateMessageRoutingResult {
        // Queue for later with a timestamp for stable restore ordering.
        let message = QueuedMessage(content: content, nickname: recipientNickname, messageID: messageID, timestamp: Date())
        pendingQueueWrites[peerID, default: 0] += 1
        defer {
            let remaining = pendingQueueWrites[peerID, default: 1] - 1
            if remaining == 0 {
                pendingQueueWrites.removeValue(forKey: peerID)
            } else {
                pendingQueueWrites[peerID] = remaining
            }
        }
        guard let persistQueuedMessage,
              await persistQueuedMessage(peerID, content, recipientNickname, messageID, message.timestamp)
        else {
            SecureLogger.error("Could not durably queue PM for \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            return .rejected
        }
        if outbox[peerID] == nil { outbox[peerID] = [] }
        outbox[peerID]?.append(message)

        // Enforce per-peer size limit with FIFO eviction
        if let count = outbox[peerID]?.count, count > Self.maxMessagesPerPeer {
            let evicted = outbox[peerID]?.removeFirst()
            if let id = evicted?.messageID { completeQueuedMessage?(id) }
            SecureLogger.warning("📤 Outbox overflow for \(peerID.id.prefix(8))… - evicted oldest message: \(evicted?.messageID.prefix(8) ?? "?")…", category: .session)
        }

        SecureLogger.debug("Queued PM for \(peerID.id.prefix(8))… (no reachable transport) id=\(messageID.prefix(8))… queue=\(outbox[peerID]?.count ?? 0)", category: .session)
        return .queued
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        if let transport = reachableTransport(for: peerID) {
            SecureLogger.debug("Routing READ ack via \(type(of: transport)) to \(peerID.id.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…", category: .session)
            transport.sendReadReceipt(receipt, to: peerID)
        } else if !transports.isEmpty {
            SecureLogger.debug("No reachable transport for READ ack to \(peerID.id.prefix(8))…", category: .session)
        }
    }

    func sendDeliveryAck(_ messageID: String, to peerID: PeerID) {
        if let transport = reachableTransport(for: peerID) {
            SecureLogger.debug("Routing DELIVERED ack via \(type(of: transport)) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            transport.sendDeliveryAck(for: messageID, to: peerID)
        }
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        if let transport = connectedTransport(for: peerID) {
            transport.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        } else if let transport = reachableTransport(for: peerID) {
            transport.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        }
    }

    // MARK: - Outbox Management

    func flushOutbox(for peerID: PeerID) {
        guard let queued = outbox[peerID], !queued.isEmpty else { return }
        SecureLogger.debug("Flushing outbox for \(peerID.id.prefix(8))… count=\(queued.count)", category: .session)

        var remaining: [QueuedMessage] = []

        for message in queued {
            if let transport = reachableTransport(for: peerID) {
                SecureLogger.debug("Outbox -> \(type(of: transport)) for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…", category: .session)
                transport.sendPrivateMessage(message.content, to: peerID, recipientNickname: message.nickname, messageID: message.messageID)
                completeQueuedMessage?(message.messageID)
            } else {
                remaining.append(message)
            }
        }

        if remaining.isEmpty {
            outbox.removeValue(forKey: peerID)
        } else {
            outbox[peerID] = remaining
        }
    }

    func flushAllOutbox() {
        for key in Array(outbox.keys) { flushOutbox(for: key) }
    }

    func clearOutbox(completingDurable: Bool = true) {
        if completingDurable {
            for messages in outbox.values {
                for message in messages { completeQueuedMessage?(message.messageID) }
            }
        }
        outbox = [:]
    }
}
