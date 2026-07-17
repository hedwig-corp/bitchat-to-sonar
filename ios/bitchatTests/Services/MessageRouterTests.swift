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
        let result = router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m1")

        #expect(result == .routed)
        #expect(transportA.sentPrivateMessages.isEmpty)
        #expect(transportB.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func sendPrivate_queuesThenFlushesWhenReachable() async {
        let peerID = PeerID(str: "0000000000000002")
        let transport = MockTransport()

        let router = MessageRouter(transports: [transport])
        router.configureDurableOutbox(persist: { _, _, _, _, _ in true }, complete: { _ in })
        let result = router.sendPrivate("Queued", to: peerID, recipientNickname: "Peer", messageID: "m2")

        #expect(result == .queued)
        #expect(transport.sentPrivateMessages.isEmpty)

        transport.reachablePeers.insert(peerID)
        router.flushOutbox(for: peerID)

        #expect(transport.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func sendPrivate_rejectsWhenDurableJournalFails() async {
        let peerID = PeerID(str: "0000000000000005")
        let router = MessageRouter(transports: [MockTransport()])
        router.configureDurableOutbox(persist: { _, _, _, _, _ in false }, complete: { _ in })

        let result = router.sendPrivate("Lost", to: peerID, recipientNickname: "Peer", messageID: "m5")

        #expect(result == .rejected)
    }

    @Test @MainActor
    func sendPrivate_preservesQueuedOrderWhenTransportReturns() async {
        let peerID = PeerID(str: "0000000000000006")
        let transport = MockTransport()
        let router = MessageRouter(transports: [transport])
        router.configureDurableOutbox(persist: { _, _, _, _, _ in true }, complete: { _ in })
        #expect(router.sendPrivate("First", to: peerID, recipientNickname: "Peer", messageID: "m6-1") == .queued)

        transport.reachablePeers.insert(peerID)
        let result = router.sendPrivate("Second", to: peerID, recipientNickname: "Peer", messageID: "m6-2")

        #expect(result == .queued)
        #expect(transport.sentPrivateMessages.map(\.content) == ["First", "Second"])
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
