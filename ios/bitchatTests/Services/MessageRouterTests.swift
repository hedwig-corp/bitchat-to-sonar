//
// MessageRouterTests.swift
// bitchatTests
//
// Tests for MessageRouter transport selection and outbox behavior.
//

import Testing
import Foundation
@testable import Sonar

struct MessageRouterTests {

    @Test @MainActor
    func sendPrivate_usesReachableTransport() async {
        let peerID = PeerID(str: "0000000000000001")
        let transportA = MockTransport()
        let transportB = MockTransport()
        transportB.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transportA, transportB])
        router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m1")

        #expect(transportA.sentPrivateMessages.isEmpty)
        #expect(transportB.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func sendPrivate_unavailableTransportDoesNotKeepVolatileRouterQueue() async {
        let peerID = PeerID(str: "0000000000000002")
        let transport = MockTransport()

        let router = MessageRouter(transports: [transport])
        let disposition = router.sendPrivate("Queued", to: peerID, recipientNickname: "Peer", messageID: "m2")

        if case .unavailable = disposition {} else {
            Issue.record("Expected unavailable disposition")
        }
        #expect(transport.sentPrivateMessages.isEmpty)

        transport.reachablePeers.insert(peerID)
        router.flushOutbox(for: peerID)

        #expect(transport.sentPrivateMessages.isEmpty)
    }

    @Test @MainActor
    func sendPrivate_unreachableAcknowledgedTransportOwnsDurableSubmission() async {
        let peerID = PeerID(str: "0000000000000005")
        let transport = MockTransport()
        transport.usesAcknowledgedPrivateDelivery = true

        let router = MessageRouter(transports: [transport])
        let disposition = router.sendPrivate(
            "Durable",
            to: peerID,
            recipientNickname: "Peer",
            messageID: "m5"
        )

        if case .awaitingDeliveryAck = disposition {} else {
            Issue.record("Expected ACK-backed disposition")
        }
        #expect(transport.sentPrivateMessages.map(\.messageID) == ["m5"])
    }

    @Test @MainActor
    func sendReadReceipt_usesReachableTransport() async {
        let peerID = PeerID(str: "0000000000000003")
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        let receipt = ReadReceipt(originalMessageID: "m3", readerID: transport.myPeerID, readerNickname: "Me")
        router.sendReadReceipt(receipt, to: peerID)

        #expect(transport.sentReadReceipts.count == 1)
    }

    @Test @MainActor
    func sendFavoriteNotification_usesConnectedOrReachable() async {
        let peerID = PeerID(str: "0000000000000004")
        let transport = MockTransport()
        transport.reachablePeers.insert(peerID)

        let router = MessageRouter(transports: [transport])
        router.sendFavoriteNotification(to: peerID, isFavorite: true)

        #expect(transport.sentFavoriteNotifications.count == 1)
    }
}
