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

    /// The regression: Sonar's optional message-id TLV (0x05) went out to every
    /// peer. bitchat-android's `BitchatFilePacket.decode` resolves each tag
    /// through a four-value enum and returns null on the first miss, so that one
    /// extra TLV made every image, voice note and file a Sonar user sent to an
    /// Android bitchat user vanish — no row, no error, on either side.
    @Test
    func fileTransferToNonSonarPeer_carriesNoUnknownTLV() throws {
        let packet = BitchatFilePacket(
            fileName: "photo.jpg",
            fileSize: 3,
            mimeType: "image/jpeg",
            messageID: "media-mid",
            content: Data([0xFF, 0xD8, 0xFF])
        )

        let stock = BLEService.wireFilePacket(packet, sonarCapableRecipient: false)
        #expect(stock.messageID == nil)
        let stockBytes = try #require(stock.encode(), "Failed to encode stripped packet")
        let decodedByAndroid = try #require(
            Self.decodeLikeBitchatAndroid(stockBytes),
            "stock bitchat must be able to decode Sonar's media"
        )
        #expect(decodedByAndroid.fileName == "photo.jpg")
        #expect(decodedByAndroid.content == packet.content)

        // Not removed, only gated: a peer known to speak Sonar still gets the
        // id that earns a delivery receipt.
        let sonar = BLEService.wireFilePacket(packet, sonarCapableRecipient: true)
        #expect(sonar.messageID == "media-mid")
        let sonarBytes = try #require(sonar.encode(), "Failed to encode Sonar packet")
        #expect(Self.decodeLikeBitchatAndroid(sonarBytes) == nil,
                "this is exactly the packet bitchat-android drops")
        #expect(BitchatFilePacket.decode(sonarBytes)?.messageID == "media-mid")
    }

    /// Only a *verified* 0x53 may mark a peer Sonar-capable — that flag is what
    /// unlocks the extension, so an unverified or absent announce must leave the
    /// stock-bitchat wire format in place.
    @Test
    func sonarCapability_requiresAVerifiedSonarAnnounce() async throws {
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

        #expect(ble.isSonarCapable(peerID) == false)

        let announcePayload = try #require(announcement.encode(), "Failed to encode announcement")
        let announcePacket = try #require(signer.signPacket(BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: peerID.id) ?? Data(),
            recipientID: nil,
            timestamp: now,
            payload: announcePayload,
            signature: nil,
            ttl: 7
        )), "Failed to sign announce packet")
        ble._test_handlePacket(announcePacket, fromPeerID: peerID, preseedPeer: false)

        // A plain bitchat announce says nothing about Sonar support.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(ble.isSonarCapable(peerID) == false)

        let sonarPayload = try #require(SonarAnnouncePacket(
            npub: Data((0..<32).map { UInt8($0) }),
            bip353: nil,
            capabilities: SonarCapability.marmotDM
        ).encode(), "Failed to encode Sonar announce")
        let sonarPacket = try #require(signer.signPacket(BitchatPacket(
            type: SonarAnnouncePacket.packetType,
            senderID: Data(hexString: peerID.id) ?? Data(),
            recipientID: nil,
            timestamp: now + 1,
            payload: sonarPayload,
            signature: nil,
            ttl: 7
        )), "Failed to sign Sonar packet")
        ble._test_handlePacket(sonarPacket, fromPeerID: peerID, preseedPeer: false)

        let becameCapable = await TestHelpers.waitUntil({ ble.isSonarCapable(peerID) },
                                                        timeout: TestConstants.shortTimeout)
        #expect(becameCapable)
    }

    /// bitchat-android's `BitchatFilePacket.decode`, transcribed: every tag is
    /// resolved through a four-value enum and an unknown one aborts the whole
    /// packet. This is the decoder Sonar's media has to survive.
    private static func decodeLikeBitchatAndroid(_ data: Data) -> (fileName: String, content: Data)? {
        var offset = 0
        var fileName: String?
        var content: Data?
        let bytes = [UInt8](data)

        while offset + 3 <= bytes.count {
            let tag = bytes[offset]
            guard (0x01...0x04).contains(tag) else { return nil }
            offset += 1

            let length: Int
            if tag == 0x04 {
                guard offset + 4 <= bytes.count else { return nil }
                length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
                offset += 4
            } else {
                guard offset + 2 <= bytes.count else { return nil }
                length = bytes[offset..<offset + 2].reduce(0) { ($0 << 8) | Int($1) }
                offset += 2
            }
            guard offset + length <= bytes.count else { return nil }
            let value = Data(bytes[offset..<offset + length])
            offset += length

            switch tag {
            case 0x01: fileName = String(data: value, encoding: .utf8)
            case 0x02: guard length == 4 else { return nil }
            case 0x04: content = value
            default: break
            }
        }

        guard let name = fileName, let payload = content else { return nil }
        return (name, payload)
    }

    // The reachability retention window must survive two LOST announces,
    // which means lasting until the THIRD emission: announce emissions are
    // spaced [interval, interval + maintenance tick] apart because the
    // cadence is only evaluated once per tick. At 21s (original value) a
    // relayed peer was evicted between two dense-mode announces; at 90s it
    // still could not survive a second consecutive loss (3×43 = 129s).
    @Test
    func reachabilityRetentionToleratesTwoMissedAnnounceCycles() {
        // Include the dispatch-timer leeway: the maintenance timer may fire up
        // to `bleMaintenanceLeewaySeconds` late, so a cadence check can land 6s
        // after the previous one, not 5s.
        let denseWorstGap = TransportConfig.bleConnectedAnnounceBaseSecondsDense
            + TransportConfig.bleConnectedAnnounceJitterDense
            + TransportConfig.bleMaintenanceInterval
            + TimeInterval(TransportConfig.bleMaintenanceLeewaySeconds)

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

        // ...but never tighter than ONE worst-case announce gap. `ChatViewModel`
        // gates sending on this same `isPeerReachable`, so a shorter window
        // marks a healthily-announcing peer unreachable for part of every cycle
        // and a mesh-only contact's DM is marked `.failed` ("recipient
        // unreachable") while the radar still shows them.
        // Include the dispatch-timer leeway: the maintenance timer may fire up
        // to `bleMaintenanceLeewaySeconds` late, so a cadence check can land 6s
        // after the previous one, not 5s.
        let denseWorstGap = TransportConfig.bleConnectedAnnounceBaseSecondsDense
            + TransportConfig.bleConnectedAnnounceJitterDense
            + TransportConfig.bleMaintenanceInterval
            + TimeInterval(TransportConfig.bleMaintenanceLeewaySeconds)
        #expect(TransportConfig.bleRoutingReachabilitySeconds >= denseWorstGap)

        // Routing gives up after ONE missed announce, the radar after two.
        #expect(TransportConfig.bleReachabilityRetentionVerifiedSeconds
                >= 2 * TransportConfig.bleRoutingReachabilitySeconds)
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
