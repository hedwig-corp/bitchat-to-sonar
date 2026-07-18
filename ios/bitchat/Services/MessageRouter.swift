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
        var awaitingCleanup = false
    }

    private var outbox: [PeerID: [QueuedMessage]] = [:]
    private var pendingQueueWrites: [PeerID: Int] = [:]
    private var flushingOutboxPeers: Set<PeerID> = []
    private var outboxGeneration: UInt = 0
    private var persistQueuedMessage: ((PeerID, String, String, String, Date) async -> Bool)?
    private var completeQueuedMessage: ((String) async -> Bool)?

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
                    await self.flushOutbox(for: peerID)
                }
            }
            // Handle key updates
            if let newKey = note.userInfo?["peerPublicKey"] as? Data,
               let _ = note.userInfo?["isKeyUpdate"] as? Bool {
                let peerID = PeerID(publicKey: newKey)
                Task { @MainActor in
                    await self.flushOutbox(for: peerID)
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
        complete: @escaping (String) async -> Bool
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
            await flushOutbox(for: peerID)
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
        await flushOutbox(for: peerID)
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
            if let id = evicted?.messageID, let completeQueuedMessage {
                _ = await completeQueuedMessage(id)
            }
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

    func flushOutbox(for peerID: PeerID) async {
        guard !flushingOutboxPeers.contains(peerID),
              let queued = outbox[peerID],
              !queued.isEmpty
        else { return }
        flushingOutboxPeers.insert(peerID)
        defer { flushingOutboxPeers.remove(peerID) }
        let generation = outboxGeneration
        SecureLogger.debug("Flushing outbox for \(peerID.id.prefix(8))… count=\(queued.count)", category: .session)

        var remaining: [QueuedMessage] = []

        for (index, queuedMessage) in queued.enumerated() {
            var message = queuedMessage
            if !message.awaitingCleanup, let transport = reachableTransport(for: peerID) {
                SecureLogger.debug("Outbox -> \(type(of: transport)) for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…", category: .session)
                transport.sendPrivateMessage(message.content, to: peerID, recipientNickname: message.nickname, messageID: message.messageID)
                message.awaitingCleanup = true
            } else if !message.awaitingCleanup {
                remaining.append(contentsOf: queued[index...])
                break
            }

            guard let completeQueuedMessage,
                  await completeQueuedMessage(message.messageID)
            else {
                // The transport already accepted this stable message id. Keep
                // the row, but retry deletion only — never send it again in
                // this process while durable cleanup is pending.
                remaining.append(message)
                remaining.append(contentsOf: queued.dropFirst(index + 1))
                break
            }
        }

        // Awaiting durable cleanup yields the main actor. Preserve messages
        // queued during that suspension, while allowing a newer explicit
        // clear/wipe to win over this stale flush snapshot.
        guard generation == outboxGeneration else { return }
        let snapshotIDs = Set(queued.map(\.messageID))
        let appended = outbox[peerID, default: []].filter { !snapshotIDs.contains($0.messageID) }
        let next = remaining + appended
        if next.isEmpty {
            outbox.removeValue(forKey: peerID)
        } else {
            outbox[peerID] = next
        }
        if remaining.isEmpty, !appended.isEmpty {
            Task { @MainActor [weak self] in
                await self?.flushOutbox(for: peerID)
            }
        }
    }

    func flushAllOutbox() async {
        for key in Array(outbox.keys) { await flushOutbox(for: key) }
    }

    func discardOutbox() {
        outboxGeneration &+= 1
        outbox = [:]
    }

    func clearOutbox() async {
        outboxGeneration &+= 1
        let generation = outboxGeneration
        let snapshot = outbox
        var retained: [PeerID: [QueuedMessage]] = [:]
        for (peerID, messages) in snapshot {
            for message in messages {
                if let completeQueuedMessage,
                   await completeQueuedMessage(message.messageID) == false {
                    retained[peerID, default: []].append(message)
                }
            }
        }
        guard generation == outboxGeneration else { return }
        let snapshotIDs = Set(snapshot.values.flatMap { $0 }.map(\.messageID))
        var next = outbox.mapValues { messages in
            messages.filter { !snapshotIDs.contains($0.messageID) }
        }.filter { !$0.value.isEmpty }
        for (peerID, messages) in retained {
            next[peerID, default: []].append(contentsOf: messages)
        }
        outbox = next
    }
}
