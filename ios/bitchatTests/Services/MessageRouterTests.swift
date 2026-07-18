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
        let result = await router.sendPrivate("Hello", to: peerID, recipientNickname: "Peer", messageID: "m1")

        #expect(result == .routed)
        #expect(transportA.sentPrivateMessages.isEmpty)
        #expect(transportB.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func sendPrivate_queuesThenFlushesWhenReachable() async {
        let peerID = PeerID(str: "0000000000000002")
        let transport = MockTransport()

        let router = MessageRouter(transports: [transport])
        router.configureDurableOutbox(persist: { _, _, _, _, _ in true }, complete: { _ in true })
        let result = await router.sendPrivate("Queued", to: peerID, recipientNickname: "Peer", messageID: "m2")

        #expect(result == .queued)
        #expect(transport.sentPrivateMessages.isEmpty)

        transport.reachablePeers.insert(peerID)
        await router.flushOutbox(for: peerID)

        #expect(transport.sentPrivateMessages.count == 1)
    }

    @Test @MainActor
    func sendPrivate_rejectsWhenDurableJournalFails() async {
        let peerID = PeerID(str: "0000000000000005")
        let router = MessageRouter(transports: [MockTransport()])
        router.configureDurableOutbox(persist: { _, _, _, _, _ in false }, complete: { _ in true })

        let result = await router.sendPrivate("Lost", to: peerID, recipientNickname: "Peer", messageID: "m5")

        #expect(result == .rejected)
    }

    @Test @MainActor
    func sendPrivate_preservesQueuedOrderWhenTransportReturns() async {
        let peerID = PeerID(str: "0000000000000006")
        let transport = MockTransport()
        let router = MessageRouter(transports: [transport])
        router.configureDurableOutbox(persist: { _, _, _, _, _ in true }, complete: { _ in true })
        #expect(await router.sendPrivate("First", to: peerID, recipientNickname: "Peer", messageID: "m6-1") == .queued)

        transport.reachablePeers.insert(peerID)
        let result = await router.sendPrivate("Second", to: peerID, recipientNickname: "Peer", messageID: "m6-2")

        #expect(result == .queued)
        #expect(transport.sentPrivateMessages.map(\.content) == ["First", "Second"])
    }

    @Test @MainActor
    func flushOutbox_retriesCleanupWithoutResending() async {
        let peerID = PeerID(str: "0000000000000007")
        let transport = MockTransport()
        let router = MessageRouter(transports: [transport])
        var cleanupAttempts = 0
        router.configureDurableOutbox(
            persist: { _, _, _, _, _ in true },
            complete: { _ in
                cleanupAttempts += 1
                return cleanupAttempts > 1
            }
        )
        #expect(await router.sendPrivate("Once", to: peerID, recipientNickname: "Peer", messageID: "m7") == .queued)

        transport.reachablePeers.insert(peerID)
        await router.flushOutbox(for: peerID)
        await router.flushOutbox(for: peerID)

        #expect(cleanupAttempts == 2)
        #expect(transport.sentPrivateMessages.map(\.content) == ["Once"])
    }

    @Test @MainActor
    func flushOutbox_preservesMessageQueuedWhileCleanupIsAwaited() async {
        let peerID = PeerID(str: "0000000000000008")
        let transport = MockTransport()
        let router = MessageRouter(transports: [transport])
        var queuedSecond = false
        router.configureDurableOutbox(
            persist: { _, _, _, _, _ in true },
            complete: { messageID in
                if messageID == "m8-1", !queuedSecond {
                    queuedSecond = true
                    let result = await router.sendPrivate(
                        "Second",
                        to: peerID,
                        recipientNickname: "Peer",
                        messageID: "m8-2"
                    )
                    #expect(result == .queued)
                }
                return true
            }
        )
        #expect(await router.sendPrivate("First", to: peerID, recipientNickname: "Peer", messageID: "m8-1") == .queued)

        transport.reachablePeers.insert(peerID)
        await router.flushOutbox(for: peerID)
        await router.flushOutbox(for: peerID)

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
