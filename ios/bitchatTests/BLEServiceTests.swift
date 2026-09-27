//
// BLEServiceTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import CoreBluetooth
@testable import Sonar

struct BLEServiceTests {
    private let service: MockBLEService
    private let myUUID = UUID()
    private let bus = MockBLEBus()
    
    init() {
        service = MockBLEService.init(bus: bus)
        service.myPeerID = PeerID(str: myUUID.uuidString)
        service.mockNickname = "TestUser"
    }
    
    // MARK: - Basic Functionality Tests
    
    @Test func serviceInitialization() {
        #expect(service.myPeerID == PeerID(str: myUUID.uuidString))
        #expect(service.myNickname == "TestUser")
    }
    
    @Test func peerConnection() {
        let somePeerID = PeerID(str: UUID().uuidString)
        
        service.simulateConnectedPeer(somePeerID)
        #expect(service.isPeerConnected(somePeerID))
        #expect(service.getConnectedPeers().count == 1)
        
        service.simulateDisconnectedPeer(somePeerID)
        #expect(!service.isPeerConnected(somePeerID))
        #expect(service.getConnectedPeers().count == 0)
    }
    
    @Test func multiplePeerConnections() {
        let peerID1 = PeerID(str: UUID().uuidString)
        let peerID2 = PeerID(str: UUID().uuidString)
        let peerID3 = PeerID(str: UUID().uuidString)

        service.simulateConnectedPeer(peerID1)
        service.simulateConnectedPeer(peerID2)
        service.simulateConnectedPeer(peerID3)
        
        #expect(service.getConnectedPeers().count == 3)
        #expect(service.isPeerConnected(peerID1))
        #expect(service.isPeerConnected(peerID2))
        #expect(service.isPeerConnected(peerID3))
        
        service.simulateDisconnectedPeer(peerID2)
        #expect(service.getConnectedPeers().count == 2)
        #expect(!service.isPeerConnected(peerID2))
    }
    
    // MARK: - Message Sending Tests
    
    @Test func sendPublicMessage() async throws {
        try await confirmation { receivedPublicMessage in
            let delivered = CallCounter()
            let delegate = MockBitchatDelegate { message in
                #expect(message.content == "Hello, world!")
                #expect(message.sender == "TestUser")
                #expect(!message.isPrivate)
                receivedPublicMessage()
                delivered.hit()
            }
            service.delegate = delegate
            service.sendMessage("Hello, world!")
            
            // Delivery hops through the main queue, which the parallel suite
            // can hold for seconds: wait for it rather than a fixed second.
            await delivered.wait()
        }
        #expect(service.sentMessages.count == 1)
    }
    
    @Test func sendPrivateMessage() async throws {
        try await confirmation { receivedPrivateMessage in
            let delivered = CallCounter()
            let delegate = MockBitchatDelegate { message in
                #expect(message.content == "Secret message")
                #expect(message.sender == "TestUser")
                #expect(message.senderPeerID == PeerID(str: myUUID.uuidString))
                #expect(message.isPrivate)
                #expect(message.recipientNickname == "Bob")
                receivedPrivateMessage()
                delivered.hit()
            }
            service.delegate = delegate
            service.sendPrivateMessage(
                "Secret message",
                to: PeerID(str: UUID().uuidString),
                recipientNickname: "Bob",
                messageID: "MSG123"
            )
            
            // Delivery hops through the main queue, which the parallel suite
            // can hold for seconds: wait for it rather than a fixed second.
            await delivered.wait()
        }
        #expect(service.sentMessages.count == 1)
    }
    
    @Test func sendMessageWithMentions() async throws {
        try await confirmation { receivedMessageWithMentions in
            let delivered = CallCounter()
            let delegate = MockBitchatDelegate { message in
                #expect(message.content == "@alice @bob check this out")
                #expect(message.mentions == ["alice", "bob"])
                receivedMessageWithMentions()
                delivered.hit()
            }
            service.delegate = delegate
            service.sendMessage("@alice @bob check this out", mentions: ["alice", "bob"])
            
            // Delivery hops through the main queue, which the parallel suite
            // can hold for seconds: wait for it rather than a fixed second.
            await delivered.wait()
        }
    }
    
    // MARK: - Message Reception Tests
    
    @Test func simulateIncomingMessage() async throws {
        try await confirmation { receiveMessage in
            let delivered = CallCounter()
            let peerID = PeerID(str: UUID().uuidString)
            
            let delegate = MockBitchatDelegate { message in
                #expect(message.content == "Incoming message")
                #expect(message.sender == "RemoteUser")
                #expect(message.senderPeerID == peerID)
                receiveMessage()
                delivered.hit()
            }
            service.delegate = delegate
            
            let incomingMessage = BitchatMessage(
                id: "MSG456",
                sender: "RemoteUser",
                content: "Incoming message",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: peerID,
                mentions: nil
            )
            service.simulateIncomingMessage(incomingMessage)
            
            // Delivery hops through the main queue, which the parallel suite
            // can hold for seconds: wait for it rather than a fixed second.
            await delivered.wait()
        }
    }
    
    @Test func simulateIncomingPacket() async throws {
        try await confirmation { processPacket in
            let delivered = CallCounter()
            let peerID = PeerID(str: UUID().uuidString)
            
            let delegate = MockBitchatDelegate { message in
                #expect(message.content == "Packet message")
                #expect(message.senderPeerID == peerID)
                processPacket()
                delivered.hit()
            }
            service.delegate = delegate
            
            let message = BitchatMessage(
                id: "MSG789",
                sender: "PacketSender",
                content: "Packet message",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: peerID,
                mentions: nil
            )
            
            let payload = try #require(message.toBinaryPayload(), "Failed to create binary payload")
            
            let packet = BitchatPacket(
                type: 0x01,
                senderID: peerID.id.data(using: .utf8)!,
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: 3
            )
            
            service.simulateIncomingPacket(packet)
            
            // Delivery hops through the main queue, which the parallel suite
            // can hold for seconds: wait for it rather than a fixed second.
            await delivered.wait()
        }
    }
    
    // MARK: - Peer Nickname Tests
    
    @Test func getPeerNicknames() {
        let peerID1 = PeerID(str: UUID().uuidString)
        let peerID2 = PeerID(str: UUID().uuidString)

        service.simulateConnectedPeer(peerID1)
        service.simulateConnectedPeer(peerID2)
        
        let nicknames = service.getPeerNicknames()
        #expect(nicknames.count == 2)
        #expect(nicknames[peerID1] == "MockPeer_\(peerID1)")
        #expect(nicknames[peerID2] == "MockPeer_\(peerID2)")
    }
    
    // MARK: - Service State Tests
    
    @Test func startStopServices() {
        service.startServices()
        service.stopServices()
        let somePeerID = PeerID(str: UUID().uuidString)
        service.simulateConnectedPeer(somePeerID)
        #expect(service.isPeerConnected(somePeerID))
    }
    
    // MARK: - Message Delivery Handler Tests
    
    @Test func messageDeliveryHandler() async throws {
        try await confirmation { deliveryHandler in
            let delivered = CallCounter()
            service.packetDeliveryHandler = { packet in
                if let msg = BitchatMessage(packet.payload) {
                    #expect(msg.content == "Test delivery")
                    deliveryHandler()
                    delivered.hit()
                }
            }
            service.sendMessage("Test delivery")
            
            // Delivery hops through the main queue, which the parallel suite
            // can hold for seconds: wait for it rather than a fixed second.
            await delivered.wait()
        }
    }
    
    @Test func packetDeliveryHandler() async throws {
        try await confirmation("Packet handler called") { packetHandler in
            let delivered = CallCounter()
            let peerID = PeerID(str: UUID().uuidString)
            
            service.packetDeliveryHandler = { packet in
                #expect(packet.type == 0x01)
                #expect(packet.senderID == Data(peerID.id.utf8))
                packetHandler()
                delivered.hit()
            }
            
            let message = BitchatMessage(
                id: "PKT123",
                sender: "TestSender",
                content: "Test packet",
                timestamp: Date(),
                isRelay: false,
                originalSender: nil,
                isPrivate: false,
                recipientNickname: nil,
                senderPeerID: peerID,
                mentions: nil
            )
            
            let payload = try #require(message.toBinaryPayload(), "Failed to create payload")
            
            let packet = BitchatPacket(
                type: 0x01,
                senderID: peerID.id.data(using: .utf8)!,
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: 3
            )
            
            service.simulateIncomingPacket(packet)
            
            // Delivery hops through the main queue, which the parallel suite
            // can hold for seconds: wait for it rather than a fixed second.
            await delivered.wait()
        }
    }
}

// MARK: - Mock Delegate Helper

/// Counts callbacks from any thread. `wait()` returns once one has arrived
/// (bounded), then gives a duplicate a moment to land inside the enclosing
/// `confirmation`, which expects exactly one.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func hit() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func wait() async {
        _ = await TestHelpers.waitUntil({ self.count >= 1 }, timeout: TestConstants.longTimeout)
        try? await sleep(0.2)
    }
}

private final class MockBitchatDelegate: BitchatDelegate {
    private let messageHandler: (BitchatMessage) -> Void
    
    init(_ handler: @escaping (BitchatMessage) -> Void) {
        self.messageHandler = handler
    }
    
    func didReceiveMessage(_ message: BitchatMessage) {
        messageHandler(message)
    }
    
    func didConnectToPeer(_ peerID: PeerID) {}
    func didDisconnectFromPeer(_ peerID: PeerID) {}
    func didUpdatePeerList(_ peers: [PeerID]) {}
    func isFavorite(fingerprint: String) -> Bool { return false }
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {}
    func didReceiveNoisePayload(from peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date) {}
    func didUpdateBluetoothState(_ state: CBManagerState) {}
    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {}
}
