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
    func peerConnectionOptions_doNotRequestSystemAlerts() {
        let options = BLEService.peerConnectionOptions ?? [:]

        #expect((options[CBConnectPeripheralOptionNotifyOnConnectionKey] as? Bool) != true)
        #expect((options[CBConnectPeripheralOptionNotifyOnDisconnectionKey] as? Bool) != true)
        #expect((options[CBConnectPeripheralOptionNotifyOnNotificationKey] as? Bool) != true)
    }

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

    // Turning Bluetooth off must retire the mesh links right away. CoreBluetooth
    // delivers no disconnect callback for links the radio drops, so without this
    // the peer stays "connected" until the inactivity sweep notices ~8-13s later
    // and DM routing keeps handing sends to a radio that is off.
    @Test
    func bluetoothPoweredOff_stopsRoutingOverMesh() {
        let ble = makeService()
        let sender = PeerID(str: "1122334455667788")
        let packet = makePublicPacket(
            content: "Hello",
            sender: sender,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        ble._test_handlePacket(packet, fromPeerID: sender)
        #expect(ble.isPeerConnected(sender))

        ble._test_handleCentralState(.poweredOff)

        #expect(!ble.isPeerConnected(sender))
        #expect(!ble.isPeerReachable(sender))
    }

    // Revoking Bluetooth permission kills the links the same way powering the
    // radio off does, and with the same silence from CoreBluetooth.
    @Test
    func bluetoothUnauthorized_stopsRoutingOverMesh() {
        let ble = makeService()
        let sender = PeerID(str: "1122334455667788")
        let packet = makePublicPacket(
            content: "Hello",
            sender: sender,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        ble._test_handlePacket(packet, fromPeerID: sender)
        #expect(ble.isPeerConnected(sender))

        ble._test_handleCentralState(.unauthorized)

        #expect(!ble.isPeerConnected(sender))
        #expect(!ble.isPeerReachable(sender))
    }

    // A stack reset invalidates every connection with no callback either. The
    // link maps must be cleared too, otherwise linkState(for:) keeps reporting a
    // live link — which both re-marks the peer connected off a relayed announce
    // and disables the checkPeerConnectivity sweep that would demote it.
    @Test
    func bluetoothResetting_stopsRoutingOverMesh() {
        let ble = makeService()
        let sender = PeerID(str: "1122334455667788")
        let packet = makePublicPacket(
            content: "Hello",
            sender: sender,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        ble._test_handlePacket(packet, fromPeerID: sender)
        #expect(ble.isPeerConnected(sender))

        ble._test_handleCentralState(.resetting)

        #expect(!ble.isPeerConnected(sender))
        #expect(!ble.isPeerReachable(sender))
    }

    // Announces are processed on messageQueue, so one received a few ms before
    // the radio died can land after the invalidation. A full-TTL announce alone
    // used to re-mark the peer connected with no radio check, resurrecting the
    // dead route and putting the ~8-13s demote back on the critical path.
    @Test
    func announceAfterRadioOffDoesNotResurrectMeshRoute() async throws {
        let ble = makeService()

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "Late Announce",
            noisePublicKey: signer.getStaticPublicKeyData(),
            signingPublicKey: signer.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        let peerID = PeerID(publicKey: announcement.noisePublicKey)
        let announcePayload = try #require(announcement.encode(), "Failed to encode announcement")

        func signedAnnounce(at timestamp: UInt64) throws -> BitchatPacket {
            // ttl == messageTTL marks this a direct (full-TTL) announce — the
            // exact shape that used to imply "connected" on its own.
            try #require(signer.signPacket(BitchatPacket(
                type: MessageType.announce.rawValue,
                senderID: Data(hexString: peerID.id) ?? Data(),
                recipientID: nil,
                timestamp: timestamp,
                payload: announcePayload,
                signature: nil,
                ttl: 7
            )), "Failed to sign announce packet")
        }

        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        // preseedPeer: false throughout — the preseed path sets isConnected
        // directly and would defeat the test.
        ble._test_handlePacket(try signedAnnounce(at: now), fromPeerID: peerID, preseedPeer: false)

        let didConnect = await TestHelpers.waitUntil({ ble.isPeerConnected(peerID) },
                                                     timeout: TestConstants.shortTimeout)
        #expect(didConnect)

        ble._test_handleCentralState(.poweredOff)
        #expect(!ble.isPeerConnected(peerID))

        // The announce that was already in flight when the radio died.
        ble._test_handlePacket(try signedAnnounce(at: now + 1), fromPeerID: peerID, preseedPeer: false)

        let didResurrect = await TestHelpers.waitUntil({ ble.isPeerConnected(peerID) }, timeout: 0.3)
        #expect(!didResurrect)
        #expect(!ble.isPeerConnected(peerID))
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

    // The reachability retention window must survive two LOST announces,
    // which means lasting until the THIRD emission: announce emissions are
    // spaced [interval, interval + maintenance tick] apart because the
    // cadence is only evaluated once per tick. At 21s (original value) a
    // relayed peer was evicted between two dense-mode announces; at 90s it
    // still could not survive a second consecutive loss (3×43 = 129s).
    @Test
    func reachabilityRetentionToleratesTwoMissedAnnounceCycles() {
        let denseWorstGap = TransportConfig.bleConnectedAnnounceBaseSecondsDense
            + TransportConfig.bleConnectedAnnounceJitterDense
            + TransportConfig.bleMaintenanceInterval

        // BOTH trust classes are held to the DENSE bar: the cadence comes from
        // topology (`connectedCount`) and the window from identity trust, so an
        // unverified peer can be announcing at 30+-8s. Holding the unverified
        // window to the sparse gap let it flap after a single lost announce.
        #expect(TransportConfig.bleReachabilityRetentionVerifiedSeconds >= 3 * denseWorstGap)
        #expect(TransportConfig.bleReachabilityRetentionUnverifiedSeconds >= 3 * denseWorstGap)
    }

    // The radar retention window must never leak into DM transport selection.
    // `MessageRouter` is built as `[meshService, nostrTransport]` and takes the
    // first transport whose `isPeerReachable` is true, so a radar-sized window
    // in `BLEService.isPeerReachable` hands DMs to a stale mesh route — which
    // is marked `.sent` with no receipt timeout (#312) and never falls back to
    // Nostr. Widening radar retention must not widen routing.
    @Test
    func dmRoutingWindowStaysTighterThanRadarRetention() {
        #expect(TransportConfig.bleRoutingReachabilitySeconds
                < TransportConfig.bleReachabilityRetentionUnverifiedSeconds)
        #expect(TransportConfig.bleRoutingReachabilitySeconds
                < TransportConfig.bleReachabilityRetentionVerifiedSeconds)

        // At or below one worst-case announce gap: beyond that the peer has
        // already missed an announce and Nostr is the better transport.
        let sparseWorstGap = TransportConfig.bleConnectedAnnounceBaseSecondsSparse
            + TransportConfig.bleConnectedAnnounceJitterSparse
            + TransportConfig.bleMaintenanceInterval
        #expect(TransportConfig.bleRoutingReachabilitySeconds <= sparseWorstGap)
    }

    // A Sonar 0x53 from a peer we have no verified 0x01 for must trigger an
    // announce-back in .knownOnly too, not just .normal: Low Power Mode maps to
    // .knownOnly, and the "unknown" sender there may be a known contact whose
    // announce we missed. Without the announce-back, mutual discovery under
    // Low Power Mode waits on the periodic announce timer alone.
    @Test
    func sonarAnnounceFromUnknownPeerInKnownOnly_triggersAnnounceBack() async throws {
        let ble = makeService()
        ble.discoveryMode = .knownOnly

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let peerID = PeerID(publicKey: signer.getStaticPublicKeyData())
        // The sender is a KNOWN contact whose 0x01 we missed — the exact case
        // the announce-back exists for. Strangers are covered by the
        // ...announceBackRequiresKnownContact test below.
        ble.knownPeerProvider = { candidate, _ in candidate == peerID }
        let npub = Data((0..<32).map { UInt8($0) })
        let sonarPayload = try #require(SonarAnnouncePacket(
            npub: npub,
            bip353: nil,
            capabilities: SonarCapability.marmotDM
        ).encode(), "Failed to encode Sonar announce")
        let sonarPacket = try #require(signer.signPacket(BitchatPacket(
            type: SonarAnnouncePacket.packetType,
            senderID: Data(hexString: peerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: sonarPayload,
            signature: nil,
            ttl: 7
        )), "Failed to sign Sonar packet")

        let before = ble._test_lastAnnounceSentAt
        ble._test_handlePacket(sonarPacket, fromPeerID: peerID, preseedPeer: false)

        let didAnnounceBack = await TestHelpers.waitUntil(
            { ble._test_lastAnnounceSentAt > before },
            timeout: TestConstants.shortTimeout
        )
        #expect(didAnnounceBack)
    }

    // In .knownOnly a STRANGER's 0x53 must not elicit an announce-back: any
    // nearby sender could otherwise provoke signed mesh-wide broadcasts
    // precisely while battery saving is active (Codex P1 on PR #444). The
    // allowlist gate (shouldAcceptPeer) decides, not the cooldown.
    @Test
    func sonarAnnounceBackInKnownOnlyRequiresKnownContact() async throws {
        let ble = makeService()
        ble.discoveryMode = .knownOnly
        ble.knownPeerProvider = { _, _ in false }

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let peerID = PeerID(publicKey: signer.getStaticPublicKeyData())
        let sonarPayload = try #require(SonarAnnouncePacket(
            npub: Data((0..<32).map { UInt8($0) }),
            bip353: nil,
            capabilities: SonarCapability.marmotDM
        ).encode(), "Failed to encode Sonar announce")
        let sonarPacket = try #require(signer.signPacket(BitchatPacket(
            type: SonarAnnouncePacket.packetType,
            senderID: Data(hexString: peerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: sonarPayload,
            signature: nil,
            ttl: 7
        )), "Failed to sign Sonar packet")

        ble._test_handlePacket(sonarPacket, fromPeerID: peerID, preseedPeer: false)

        let didAnnounceBack = await TestHelpers.waitUntil(
            { ble._test_lastAnnounceSentAt > Date.distantPast },
            timeout: 0.6
        )
        #expect(!didAnnounceBack)
        #expect(ble._test_lastAnnounceSentAt == Date.distantPast)
    }

    // A stream of 0x53s from unknown peers must not elicit one forced
    // announce each: the dedicated cooldown allows one announce-back per
    // window (a single broadcast serves every queued sender), so a hostile
    // flood cannot use us as an announce amplifier.
    @Test
    func sonarAnnounceBackIsRateLimitedByCooldown() async throws {
        let ble = makeService()
        ble.discoveryMode = .normal

        func signedSonarPacket(_ signer: NoiseEncryptionService) throws -> BitchatPacket {
            let peerID = PeerID(publicKey: signer.getStaticPublicKeyData())
            let payload = try #require(SonarAnnouncePacket(
                npub: Data((0..<32).map { UInt8($0) }),
                bip353: nil,
                capabilities: SonarCapability.marmotDM
            ).encode(), "Failed to encode Sonar announce")
            return try #require(signer.signPacket(BitchatPacket(
                type: SonarAnnouncePacket.packetType,
                senderID: Data(hexString: peerID.id) ?? Data(),
                recipientID: nil,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: 7
            )), "Failed to sign Sonar packet")
        }

        let firstSigner = NoiseEncryptionService(keychain: MockKeychain())
        let firstPacket = try signedSonarPacket(firstSigner)
        let firstPeer = PeerID(publicKey: firstSigner.getStaticPublicKeyData())

        ble._test_handlePacket(firstPacket, fromPeerID: firstPeer, preseedPeer: false)
        let didAnnounceBack = await TestHelpers.waitUntil(
            { ble._test_lastAnnounceSentAt > Date.distantPast },
            timeout: TestConstants.shortTimeout
        )
        #expect(didAnnounceBack)
        let firstAnnounceAt = ble._test_lastAnnounceSentAt

        // A second unknown sender inside the cooldown window must not elicit
        // another forced announce.
        let secondSigner = NoiseEncryptionService(keychain: MockKeychain())
        let secondPacket = try signedSonarPacket(secondSigner)
        let secondPeer = PeerID(publicKey: secondSigner.getStaticPublicKeyData())

        ble._test_handlePacket(secondPacket, fromPeerID: secondPeer, preseedPeer: false)
        let didAnnounceAgain = await TestHelpers.waitUntil(
            { ble._test_lastAnnounceSentAt > firstAnnounceAt },
            timeout: 0.6
        )
        #expect(!didAnnounceAgain)
        #expect(ble._test_lastAnnounceSentAt == firstAnnounceAt)
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
