//
// BLEServicePrivateMediaTests.swift
// bitchatTests
//
// Drives the REAL BLEService through the private-media negotiation that
// core/bitchat-protocol/SPEC.md §8.5 and §10 describe, with the far side
// played by a bare NoiseEncryptionService (the same crypto a reference
// client runs). No radio: packets go in through `_test_handlePacket` and come
// out through `_test_outboundObserver`.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import CoreBluetooth
@testable import Sonar

struct BLEServicePrivateMediaTests {

    /// After the XX handshake the service proves its capabilities (Noise 0x21)
    /// unprompted; once the peer proves `.privateMedia`, a file the peer sends
    /// as Noise 0x20 surfaces like a verified 0x22, and a file we send rides
    /// encrypted inside the session instead of as a signed plaintext 0x22.
    @Test
    func handshakeProvesCapabilitiesAndMediaGoesEncrypted() async throws {
        let ble = makeService()
        let delegate = CaptureDelegate()
        ble.delegate = delegate
        let outbound = OutboundCapture()
        ble._test_outboundObserver = { outbound.append($0) }

        let (peer, peerID) = try await announcedPeer(to: ble)
        let me = ble.myPeerID
        try await completeHandshake(peer: peer, peerID: peerID, with: ble, outbound: outbound)

        // 1. Our authenticated peer state went out on its own, carrying the
        //    capabilities this build implements and a 32-byte signing key.
        let ourState = try #require(
            await decryptedPayloads(from: outbound, peer: peer, me: me)
                .first { $0.first == NoisePayloadType.authenticatedPeerState.rawValue }
        )
        let decodedState = try #require(AuthenticatedPeerStatePacket.decode(from: ourState.dropFirst()))
        #expect(decodedState.capabilities.contains(.privateMedia))
        #expect(decodedState.capabilities.contains(.privateMediaReceipts))
        #expect(decodedState.signingPublicKey.count == 32)

        // 2. The peer proves `.privateMedia` inside the session.
        let peerState = try #require(
            AuthenticatedPeerStatePacket(capabilities: [.privateMedia], signingPublicKey: peer.getSigningPublicKeyData()).encode()
        )
        var statePlain = Data([NoisePayloadType.authenticatedPeerState.rawValue])
        statePlain.append(peerState)
        ble._test_handlePacket(try encrypted(statePlain, by: peer, from: peerID, to: me), fromPeerID: peerID, preseedPeer: false)
        ble._test_drainMessageQueue()

        // 3. A file the peer sends as Noise 0x20 is delivered like a verified 0x22.
        let jpeg = Self.jpegFixture
        let file = BitchatFilePacket(fileName: "p.jpg", fileSize: UInt64(jpeg.count), mimeType: "image/jpeg", content: jpeg)
        var filePlain = Data([NoisePayloadType.privateFile.rawValue])
        filePlain.append(try #require(file.encode()))
        ble._test_handlePacket(try encrypted(filePlain, by: peer, from: peerID, to: me), fromPeerID: peerID, preseedPeer: false)
        let surfaced = await TestHelpers.waitUntil({
            delegate.snapshot().contains { $0.isPrivate && $0.senderPeerID == peerID && $0.content.hasPrefix("[image]") }
        }, timeout: TestConstants.defaultTimeout)
        #expect(surfaced, "Noise 0x20 file must surface as a private image message, got \(delegate.snapshot().map(\.content))")

        // 4. Our media to a peer that proved the capability is Noise 0x20 — never a 0x22.
        outbound.reset()
        #expect(ble.sendFilePrivate(file, to: peerID, transferId: "t1"))
        let mediaFrames = await outbound.waitForFrames(ofType: MessageType.noiseEncrypted.rawValue)
        #expect(!mediaFrames.isEmpty, "the file must leave as a Noise frame")
        #expect(!outbound.snapshot().contains { $0.type == MessageType.fileTransfer.rawValue },
                "no plaintext 0x22 may be emitted once the peer proved .privateMedia")
        let mediaPlain = try #require(
            try mediaFrames.compactMap { try? peer.decrypt($0.payload, from: me) }
                .first { $0.first == NoisePayloadType.privateFile.rawValue }
        )
        let received = try #require(BitchatFilePacket.decode(mediaPlain.dropFirst()))
        #expect(received.content == jpeg)
        #expect(received.mimeType == "image/jpeg")
        // The 0x05 message-id TLV is a Sonar extension; this peer never sent a
        // Sonar 0x53, so it must not be on the wire.
        #expect(received.messageID == nil)
    }

    /// A peer that completed the handshake but never proved `.privateMedia`
    /// (an older client) gets the legacy wire form: a signed, directed,
    /// plaintext 0x22 whose signature verifies under our announce key.
    @Test
    func withoutAProofMediaFallsBackToSignedPlaintext() async throws {
        let ble = makeService()
        ble.delegate = CaptureDelegate()
        let outbound = OutboundCapture()
        ble._test_outboundObserver = { outbound.append($0) }

        let (peer, peerID) = try await announcedPeer(to: ble)
        let me = ble.myPeerID
        try await completeHandshake(peer: peer, peerID: peerID, with: ble, outbound: outbound)

        // Our own announce (sent after the handshake) tells the peer our signing key.
        let ourAnnounce = try #require(
            await outbound.waitForFrames(ofType: MessageType.announce.rawValue).first,
            "the service re-announces after a handshake"
        )
        let ourSigningKey = try #require(AnnouncementPacket.decode(from: ourAnnounce.payload)?.signingPublicKey)

        outbound.reset()
        let file = BitchatFilePacket(fileName: "p.jpg", fileSize: UInt64(Self.jpegFixture.count), mimeType: "image/jpeg", content: Self.jpegFixture)
        #expect(ble.sendFilePrivate(file, to: peerID, transferId: "t2"))
        let raw = try #require(await outbound.waitForFrames(ofType: MessageType.fileTransfer.rawValue).first)
        #expect(raw.recipientID == Data(hexString: peerID.id))
        let signature = try #require(raw.signature, "legacy raw files must be signed")
        let preimage = try #require(raw.toBinaryDataForSigning())
        #expect(peer.verifySignature(signature, for: preimage, publicKey: ourSigningKey))
        #expect(BitchatFilePacket.decode(raw.payload)?.content == Self.jpegFixture)
        #expect(!outbound.snapshot().contains { $0.type == MessageType.noiseEncrypted.rawValue && (try? peer.decrypt($0.payload, from: me))?.first == NoisePayloadType.privateFile.rawValue },
                "no encrypted copy may be sent alongside the fallback")
    }

    // MARK: - Fixtures and drivers

    /// SOI + APP0 header, filler, EOI: passes the image/jpeg magic check.
    static let jpegFixture: Data = {
        var d = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00])
        d.append(Data(repeating: 0x11, count: 300))
        d.append(Data([0xFF, 0xD9]))
        return d
    }()

    private func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// A reference-style peer (bare Noise service) that has announced itself
    /// to `ble` with a signed full-TTL announce, so its keys are pinned and it
    /// counts as connected.
    private func announcedPeer(to ble: BLEService) async throws -> (NoiseEncryptionService, PeerID) {
        let peer = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "Peer",
            noisePublicKey: peer.getStaticPublicKeyData(),
            signingPublicKey: peer.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        let peerID = PeerID(publicKey: announcement.noisePublicKey)
        let payload = try #require(announcement.encode())
        let announce = try #require(peer.signPacket(BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: peerID.id) ?? Data(),
            recipientID: nil,
            timestamp: now(),
            payload: payload,
            signature: nil,
            ttl: 7
        )))
        ble._test_handlePacket(announce, fromPeerID: peerID, preseedPeer: false)
        let connected = await TestHelpers.waitUntil({ ble.isPeerConnected(peerID) }, timeout: TestConstants.defaultTimeout)
        #expect(connected, "a signed full-TTL announce marks the peer connected")
        return (peer, peerID)
    }

    /// Noise XX, driven entirely by packets, with the peer as initiator:
    /// m1 in, m2 captured from the service, m3 in.
    private func completeHandshake(peer: NoiseEncryptionService, peerID: PeerID, with ble: BLEService, outbound: OutboundCapture) async throws {
        let me = ble.myPeerID
        let m1 = try peer.initiateHandshake(with: me)
        ble._test_handlePacket(handshakePacket(m1, from: peerID, to: me), fromPeerID: peerID, preseedPeer: false)
        let m2 = try #require(await outbound.waitForFrames(ofType: MessageType.noiseHandshake.rawValue).first, "the service answers m1")
        let m3 = try #require(try peer.processHandshakeMessage(from: me, message: m2.payload), "the initiator has a third message")
        ble._test_handlePacket(handshakePacket(m3, from: peerID, to: me), fromPeerID: peerID, preseedPeer: false)
        let established = await TestHelpers.waitUntil({ peer.hasEstablishedSession(with: me) }, timeout: TestConstants.defaultTimeout)
        #expect(established)
        ble._test_drainMessageQueue()
    }

    private func handshakePacket(_ message: Data, from sender: PeerID, to recipient: PeerID) -> BitchatPacket {
        BitchatPacket(
            type: MessageType.noiseHandshake.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: Data(hexString: recipient.id),
            timestamp: now(),
            payload: message,
            signature: nil,
            ttl: 7
        )
    }

    private func encrypted(_ plaintext: Data, by peer: NoiseEncryptionService, from sender: PeerID, to recipient: PeerID) throws -> BitchatPacket {
        BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: Data(hexString: recipient.id),
            timestamp: now(),
            payload: try peer.encrypt(plaintext, for: recipient),
            signature: nil,
            ttl: 7
        )
    }

    /// Every Noise frame the service has emitted so far, decrypted by the peer
    /// in wire order (the window tolerates reordering; we keep order anyway).
    private func decryptedPayloads(from outbound: OutboundCapture, peer: NoiseEncryptionService, me: PeerID) async -> [Data] {
        let frames = await outbound.waitForFrames(ofType: MessageType.noiseEncrypted.rawValue)
        return frames.compactMap { try? peer.decrypt($0.payload, from: me) }
    }
}

private func makeService() -> BLEService {
    let keychain = MockKeychain()
    let identityManager = MockIdentityManager(keychain)
    let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
    return BLEService(keychain: keychain, idBridge: idBridge, identityManager: identityManager)
}

/// Thread-safe sink for `_test_outboundObserver`.
private final class OutboundCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [BitchatPacket] = []

    func append(_ p: BitchatPacket) {
        lock.lock(); packets.append(p); lock.unlock()
    }

    func reset() {
        lock.lock(); packets.removeAll(); lock.unlock()
    }

    func snapshot() -> [BitchatPacket] {
        lock.lock(); defer { lock.unlock() }
        return packets
    }

    /// Waits until at least one frame of `type` was emitted, then returns all
    /// of them in emission order (empty on timeout).
    func waitForFrames(ofType type: UInt8) async -> [BitchatPacket] {
        _ = await TestHelpers.waitUntil({ self.snapshot().contains { $0.type == type } }, timeout: TestConstants.defaultTimeout)
        return snapshot().filter { $0.type == type }
    }
}

private final class CaptureDelegate: BitchatDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [BitchatMessage] = []

    func snapshot() -> [BitchatMessage] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }

    func didReceiveMessage(_ message: BitchatMessage) {
        lock.lock(); messages.append(message); lock.unlock()
    }
    func didConnectToPeer(_ peerID: PeerID) {}
    func didDisconnectFromPeer(_ peerID: PeerID) {}
    func didUpdatePeerList(_ peers: [PeerID]) {}
    func didUpdateBluetoothState(_ state: CBManagerState) {}
    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {}
}
