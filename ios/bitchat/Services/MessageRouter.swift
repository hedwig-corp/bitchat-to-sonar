import BitLogger
import Foundation

enum PrivateSendDisposition {
    case awaitingDeliveryAck
    case sent
    case unavailable
}

/// Routes messages using available transports (Mesh, Nostr, etc.)
@MainActor
final class MessageRouter {
    private let transports: [Transport]

    init(transports: [Transport]) {
        self.transports = transports
    }

    // MARK: - Transport Selection

    private func reachableTransport(for peerID: PeerID) -> Transport? {
        transports.first { $0.isPeerReachable(peerID) }
    }

    private func connectedTransport(for peerID: PeerID) -> Transport? {
        transports.first { $0.isPeerConnected(peerID) }
    }

    // MARK: - Message Sending

    @discardableResult
    func sendPrivate(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) -> PrivateSendDisposition {
        let transport = reachableTransport(for: peerID)
            ?? transports.first(where: { $0.usesAcknowledgedPrivateDelivery })
        guard let transport else { return .unavailable }

        SecureLogger.debug("Routing PM via \(type(of: transport)) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
        transport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        return transport.usesAcknowledgedPrivateDelivery ? .awaitingDeliveryAck : .sent
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
        } else if let transport = transports.first(where: { $0.usesAcknowledgedPrivateDelivery }) {
            transport.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        }
    }

    // MARK: - Outbox Management

    func flushOutbox(for peerID: PeerID) {
        // Durable acknowledged transports restore and retry their own journal.
        _ = peerID
    }

    func flushAllOutbox() {
        // Kept for source compatibility; BLEService restores on start.
    }

    /// Periodically clean up expired messages from all outboxes
    func cleanupExpiredMessages() {
        // TTL pruning is part of the durable outbox load transaction.
    }
}
