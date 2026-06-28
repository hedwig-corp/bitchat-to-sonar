//
// BLEServiceCoreTests.swift
// bitchatTests
//
// Focused BLEService tests for packet handling behavior.
//

import Testing
import Foundation
import CoreBluetooth
@testable import Sonar

struct BLEServiceCoreTests {

    @Test
    func duplicatePacket_isDeduped() async {
        let ble = makeService()
        let delegate = PublicCaptureDelegate()
        ble.delegate = delegate

        let sender = PeerID(str: "1122334455667788")
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let packet = makePublicPacket(content: "Hello", sender: sender, timestamp: timestamp)

        ble._test_handlePacket(packet, fromPeerID: sender)
        ble._test_handlePacket(packet, fromPeerID: sender)

        _ = await TestHelpers.waitUntil({ delegate.publicMessagesSnapshot().count == 1 },
                                        timeout: TestConstants.shortTimeout)

        let messages = delegate.publicMessagesSnapshot()
        #expect(messages.count == 1)
        #expect(messages.first?.content == "Hello")
    }

    @Test
    func staleBroadcast_isIgnored() async {
        let ble = makeService()
        let delegate = PublicCaptureDelegate()
        ble.delegate = delegate

        let sender = PeerID(str: "A1B2C3D4E5F60708")
        let oldTimestamp = UInt64(Date().addingTimeInterval(-901).timeIntervalSince1970 * 1000)
        let packet = makePublicPacket(content: "Old", sender: sender, timestamp: oldTimestamp)

        ble._test_handlePacket(packet, fromPeerID: sender)

        let didReceive = await TestHelpers.waitUntil({ !delegate.publicMessagesSnapshot().isEmpty }, timeout: 0.3)
        #expect(!didReceive)
        #expect(delegate.publicMessagesSnapshot().isEmpty)
    }

    @Test
    func announceSenderMismatch_isRejected() async throws {
        let ble = makeService()

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "Spoof",
            noisePublicKey: signer.getStaticPublicKeyData(),
            signingPublicKey: signer.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode(), "Failed to encode announcement")

        let derivedPeerID = PeerID(publicKey: announcement.noisePublicKey)
        let wrongFirst = derivedPeerID.bare.first == "0" ? "1" : "0"
        let wrongBare = String(wrongFirst) + String(derivedPeerID.bare.dropFirst())
        let wrongPeerID = PeerID(str: wrongBare)
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: wrongPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let signed = try #require(signer.signPacket(packet), "Failed to sign announce packet")

        ble._test_handlePacket(signed, fromPeerID: wrongPeerID, preseedPeer: false)

        _ = await TestHelpers.waitUntil({ !ble.currentPeerSnapshots().isEmpty }, timeout: 0.3)
        #expect(ble.currentPeerSnapshots().isEmpty)
    }

    @Test
    func sonarAnnounceBeforeVerifiedAnnounce_isProcessedAfterAnnounce() async throws {
        let ble = makeService()

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "Sara D",
            noisePublicKey: signer.getStaticPublicKeyData(),
            signingPublicKey: signer.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        let peerID = PeerID(publicKey: announcement.noisePublicKey)
        let now = UInt64(Date().timeIntervalSince1970 * 1000)

        let npub = Data((0..<32).map { UInt8($0) })
        let sonarPayload = try #require(SonarAnnouncePacket(
            npub: npub,
            bip353: nil,
            capabilities: SonarCapability.marmotDM | SonarCapability.calls
        ).encode(), "Failed to encode Sonar announce")
        let sonarPacket = try #require(signer.signPacket(BitchatPacket(
            type: SonarAnnouncePacket.packetType,
            senderID: Data(hexString: peerID.id) ?? Data(),
            recipientID: nil,
            timestamp: now,
            payload: sonarPayload,
            signature: nil,
            ttl: 7
        )), "Failed to sign Sonar packet")

        let announcePayload = try #require(announcement.encode(), "Failed to encode announcement")
        let announcePacket = try #require(signer.signPacket(BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: peerID.id) ?? Data(),
            recipientID: nil,
            timestamp: now + 1,
            payload: announcePayload,
            signature: nil,
            ttl: 7
        )), "Failed to sign announce packet")

        let capture = SonarProfileCapture(peerID: peerID.id)
        let observer = NotificationCenter.default.addObserver(
            forName: .sonarPeerProfileUpdated,
            object: nil,
            queue: nil
        ) { note in
            capture.record(note)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        ble._test_handlePacket(sonarPacket, fromPeerID: peerID, preseedPeer: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        ble._test_handlePacket(announcePacket, fromPeerID: peerID, preseedPeer: false)

        let didReceive = await TestHelpers.waitUntil({ capture.profile != nil }, timeout: TestConstants.shortTimeout)
        #expect(didReceive)
        #expect(capture.profile?.npub == npub)
    }

    @Test
    func restrictedDiscoveryReapply_prunesPeerAfterAllowlistChange() async throws {
        let ble = makeService()

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "Known Then Removed",
            noisePublicKey: signer.getStaticPublicKeyData(),
            signingPublicKey: signer.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        let peerID = PeerID(publicKey: announcement.noisePublicKey)
        let announcePayload = try #require(announcement.encode(), "Failed to encode announcement")
        let announcePacket = try #require(signer.signPacket(BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: peerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: announcePayload,
            signature: nil,
            ttl: 7
        )), "Failed to sign announce packet")

        ble.knownPeerProvider = { candidate, _ in candidate == peerID }
        ble.discoveryMode = .knownOnly
        ble._test_handlePacket(announcePacket, fromPeerID: peerID, preseedPeer: false)

        let didAdd = await TestHelpers.waitUntil({
            ble.currentPeerSnapshots().contains { $0.peerID == peerID }
        }, timeout: TestConstants.shortTimeout)
        #expect(didAdd)

        ble.knownPeerProvider = { _, _ in false }
        ble.reapplyDiscoveryModePolicy()

        let didPrune = await TestHelpers.waitUntil({
            !ble.currentPeerSnapshots().contains { $0.peerID == peerID }
        }, timeout: TestConstants.shortTimeout)
        #expect(didPrune)
    }
}

private func makeService() -> BLEService {
    let keychain = MockKeychain()
    let identityManager = MockIdentityManager(keychain)
    let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
    return BLEService(keychain: keychain, idBridge: idBridge, identityManager: identityManager)
}

private func makePublicPacket(content: String, sender: PeerID, timestamp: UInt64) -> BitchatPacket {
    BitchatPacket(
        type: MessageType.message.rawValue,
        senderID: Data(hexString: sender.id) ?? Data(),
        recipientID: nil,
        timestamp: timestamp,
        payload: Data(content.utf8),
        signature: nil,
        ttl: 3
    )
}

private final class PublicCaptureDelegate: BitchatDelegate {
    private let lock = NSLock()
    private(set) var publicMessages: [BitchatMessage] = []

    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {
        let message = BitchatMessage(
            id: messageID,
            sender: nickname,
            content: content,
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: peerID,
            mentions: nil
        )
        lock.lock()
        publicMessages.append(message)
        lock.unlock()
    }

    func didReceiveMessage(_ message: BitchatMessage) {}
    func didConnectToPeer(_ peerID: PeerID) {}
    func didDisconnectFromPeer(_ peerID: PeerID) {}
    func didUpdatePeerList(_ peers: [PeerID]) {}
    func didUpdateBluetoothState(_ state: CBManagerState) {}

    func publicMessagesSnapshot() -> [BitchatMessage] {
        lock.lock()
        defer { lock.unlock() }
        return publicMessages
    }
}

private final class SonarProfileCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let peerID: String
    private var _profile: SonarAnnouncePacket?

    init(peerID: String) {
        self.peerID = peerID
    }

    var profile: SonarAnnouncePacket? {
        lock.lock()
        defer { lock.unlock() }
        return _profile
    }

    func record(_ note: Notification) {
        guard note.userInfo?[SonarDiscoveryUserInfoKey.peerID] as? String == peerID,
              let profile = note.userInfo?[SonarDiscoveryUserInfoKey.profile] as? SonarAnnouncePacket
        else { return }
        lock.lock()
        _profile = profile
        lock.unlock()
    }
}
