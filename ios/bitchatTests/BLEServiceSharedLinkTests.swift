//
// BLEServiceSharedLinkTests.swift
// bitchatTests
//
// Two mesh apps on one device share its radio, so both reach us through ONE
// central: seen on a Pixel running Sonar beside stock bitchat-android
// (2026-10-29), where the iPhone bound the link to stock bitchat and dropped
// every Sonar packet as "spoofing". These tests drive the REAL write path
// (`receiveCentralPacket`, through `_test_receiveCentralPacket`).
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import Sonar

struct BLEServiceSharedLinkTests {

    /// The second app's own full-TTL announce must reach the peer list, not
    /// die as a sender mismatch against the app that bound the link first.
    @Test
    func secondAppOnTheSameCentralIsSeen() async throws {
        let ble = makeService()
        let bitchat = MeshApp(nickname: "stock bitchat")
        let sonar = MeshApp(nickname: "sonar")
        let central = "CENTRAL-PIXEL"

        ble._test_receiveCentralPacket(try bitchat.directAnnounce(), fromCentralUUID: central)
        ble._test_receiveCentralPacket(try sonar.directAnnounce(), fromCentralUUID: central)

        #expect(await TestHelpers.waitUntil({ ble.isPeerConnected(bitchat.peerID) }, timeout: TestConstants.defaultTimeout))
        #expect(await TestHelpers.waitUntil({ ble.isPeerConnected(sonar.peerID) }, timeout: TestConstants.defaultTimeout),
                "the second app on the device must be seen")
        #expect(ble._test_centralLinkPeers(central) == [bitchat.peerID, sonar.peerID])
    }

    /// Joining a bound link takes a signature that verifies AND matches the
    /// key already pinned for that peer: pairing a known peer's public Noise
    /// key with your own signing key gets you nothing.
    @Test
    func aForgedSecondIdentityStaysOut() async throws {
        let ble = makeService()
        let victim = MeshApp(nickname: "victim")
        let neighbour = MeshApp(nickname: "neighbour")

        ble._test_receiveCentralPacket(try victim.directAnnounce(), fromCentralUUID: "CENTRAL-VICTIM")
        #expect(await TestHelpers.waitUntil({ ble.isPeerConnected(victim.peerID) }, timeout: TestConstants.defaultTimeout))

        let central = "CENTRAL-NEIGHBOUR"
        ble._test_receiveCentralPacket(try neighbour.directAnnounce(), fromCentralUUID: central)
        ble._test_receiveCentralPacket(try neighbour.directAnnounce(claimingNoiseKeyOf: victim), fromCentralUUID: central)
        ble._test_receiveCentralPacket(try victim.unsignedDirectAnnounce(), fromCentralUUID: central)

        #expect(ble._test_centralLinkPeers(central) == [neighbour.peerID])
    }

    /// The radio link outlives an app that quit (stock bitchat keeps it up),
    /// so on a shared link each app must keep announcing to stay online.
    @Test
    func anAppThatStoppedAnnouncingDropsOffASharedLink() throws {
        let ble = makeService()
        let bitchat = MeshApp(nickname: "stock bitchat")
        let sonar = MeshApp(nickname: "sonar")
        let central = "CENTRAL-PIXEL"
        let lastHeardFromSonar = Date().addingTimeInterval(-(TransportConfig.bleSharedLinkIdentityTimeoutSeconds + 10))

        ble._test_receiveCentralPacket(try bitchat.directAnnounce(), fromCentralUUID: central)
        ble._test_receiveCentralPacket(try sonar.directAnnounce(), fromCentralUUID: central, receivedAt: lastHeardFromSonar)
        ble._test_receiveCentralPacket(try bitchat.directAnnounce(), fromCentralUUID: central)

        #expect(!ble._test_hasCentralLink(to: sonar.peerID), "an app that quit must not stay linked")
        #expect(ble._test_hasCentralLink(to: bitchat.peerID))
    }

    /// One app per link is the common case and keeps today's behaviour: the
    /// link vouches for as long as it is up, however long since the announce.
    @Test
    func aLinkWithOneAppVouchesWhileItIsUp() throws {
        let ble = makeService()
        let peer = MeshApp(nickname: "peer")
        let longAgo = Date().addingTimeInterval(-(TransportConfig.bleSharedLinkIdentityTimeoutSeconds * 4))

        ble._test_receiveCentralPacket(try peer.directAnnounce(), fromCentralUUID: "CENTRAL-ONE", receivedAt: longAgo)

        #expect(ble._test_hasCentralLink(to: peer.peerID))
    }
}

/// A link peer relays other peers' traffic. Sonar iOS accepted only relayed
/// announces through a bound link, so a DM handshake, message or sync reply
/// from anyone beyond the link peer died as "spoofing": 1,353 drops on one
/// iPhone on 2026-10-29, among them every packet the Pixel sent it through a
/// relay while the iPhone was in the background. These tests drive the REAL
/// receive paths of both roles (`receiveCentralPacket`,
/// `receivePeripheralPacket`).
struct BLEServiceRelayedIngressTests {

    @Test
    func aHandshakeRelayedThroughACentralIsAnswered() async throws {
        let ble = makeService()
        let relay = MeshApp(nickname: "relay")
        let far = MeshApp(nickname: "far")
        let central = "CENTRAL-RELAY"
        ble._test_receiveCentralPacket(try relay.directAnnounce(), fromCentralUUID: central)
        ble._test_receiveCentralPacket(try far.relayedAnnounce(), fromCentralUUID: central)

        try await expectHandshakeAnswered(ble: ble, from: far) {
            ble._test_receiveCentralPacket($0, fromCentralUUID: central)
        }
    }

    @Test
    func aHandshakeRelayedThroughAPeripheralIsAnswered() async throws {
        let ble = makeService()
        let relay = MeshApp(nickname: "relay")
        let far = MeshApp(nickname: "far")
        let peripheral = "PERIPHERAL-RELAY"
        ble._test_receivePeripheralPacket(try far.relayedAnnounce(), fromPeripheralUUID: peripheral, boundTo: relay.peerID)

        try await expectHandshakeAnswered(ble: ble, from: far) {
            ble._test_receivePeripheralPacket($0, fromPeripheralUUID: peripheral, boundTo: relay.peerID)
        }
    }

    /// A sync reply replays a stored packet under its author's sender ID at
    /// TTL 0. We asked the link peer, so that is whose request it answers.
    @Test
    func aSyncReplyRelayedByTheLinkPeerWeAskedIsAccepted() async throws {
        let ble = makeService()
        let relay = MeshApp(nickname: "relay")
        let far = MeshApp(nickname: "far")
        let central = "CENTRAL-RELAY"
        ble._test_receiveCentralPacket(try relay.directAnnounce(), fromCentralUUID: central)
        ble._test_registerSyncRequest(to: relay.peerID)

        ble._test_receiveCentralPacket(try far.relayedAnnounce(ttl: 0, isRSR: true), fromCentralUUID: central)

        #expect(await TestHelpers.waitUntil({ ble.currentPeerSnapshots().contains { $0.peerID == far.peerID } }, timeout: TestConstants.defaultTimeout),
                "the replayed announce must reach the peer list")
    }

    @Test
    func anUnsolicitedSyncReplyStaysOut() throws {
        let ble = makeService()
        let relay = MeshApp(nickname: "relay")
        let far = MeshApp(nickname: "far")
        let central = "CENTRAL-RELAY"
        ble._test_receiveCentralPacket(try relay.directAnnounce(), fromCentralUUID: central)

        ble._test_receiveCentralPacket(try far.relayedAnnounce(ttl: 0, isRSR: true), fromCentralUUID: central)
        ble._test_drainMessageQueue()

        #expect(!ble.currentPeerSnapshots().contains { $0.peerID == far.peerID })
    }

    /// `far` opens a Noise XX handshake through the relay (`deliver`); the
    /// service must answer with a second message `far` can complete.
    private func expectHandshakeAnswered(ble: BLEService, from far: MeshApp, deliver: (BitchatPacket) -> Void) async throws {
        ble._test_drainMessageQueue()
        let outbound = OutboundSink()
        ble._test_outboundObserver = { outbound.append($0) }
        let me = ble.myPeerID

        let m1 = try far.noise.initiateHandshake(with: me)
        deliver(far.relayed(type: MessageType.noiseHandshake.rawValue, payload: m1, to: me))

        let answered = await TestHelpers.waitUntil({ outbound.handshakes(to: far.peerID).count > 0 }, timeout: TestConstants.defaultTimeout)
        #expect(answered, "a relayed handshake must be answered, not dropped as spoofing")
        let m2 = try #require(outbound.handshakes(to: far.peerID).first)
        #expect(try far.noise.processHandshakeMessage(from: me, message: m2.payload) != nil, "the answer is the XX second message")
    }
}

// MARK: - Fixtures

/// One mesh app: its own Noise static key and announce-signing key.
private struct MeshApp {
    let nickname: String
    let noise = NoiseEncryptionService(keychain: MockKeychain())

    init(nickname: String) { self.nickname = nickname }

    var peerID: PeerID { PeerID(publicKey: noise.getStaticPublicKeyData()) }

    /// A signed full-TTL announce, as the app sends it to its direct neighbour.
    func directAnnounce() throws -> BitchatPacket {
        try signedAnnounce(noiseKey: noise.getStaticPublicKeyData(), signer: self)
    }

    /// An announce for `other`'s peer ID (its public Noise key) that carries
    /// and is signed with OUR signing key.
    func directAnnounce(claimingNoiseKeyOf other: MeshApp) throws -> BitchatPacket {
        try signedAnnounce(noiseKey: other.noise.getStaticPublicKeyData(), signer: self)
    }

    /// Our own announce with the signature stripped.
    func unsignedDirectAnnounce() throws -> BitchatPacket {
        var packet = try directAnnounce()
        packet.signature = nil
        return packet
    }

    /// Our announce as a relay forwards it (one hop down by default), or as
    /// a sync reply (TTL 0, RSR). TTL and RSR are outside the signature.
    func relayedAnnounce(ttl: UInt8 = TransportConfig.messageTTLDefault - 1, isRSR: Bool = false) throws -> BitchatPacket {
        var packet = try directAnnounce()
        packet.ttl = ttl
        packet.isRSR = isRSR
        return packet
    }

    /// An unsigned packet of ours, one hop down, addressed to `recipient`.
    func relayed(type: UInt8, payload: Data, to recipient: PeerID) -> BitchatPacket {
        BitchatPacket(
            type: type,
            senderID: Data(hexString: peerID.id) ?? Data(),
            recipientID: Data(hexString: recipient.id),
            timestamp: AnnounceClock.shared.next(),
            payload: payload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault - 1
        )
    }

    private func signedAnnounce(noiseKey: Data, signer: MeshApp) throws -> BitchatPacket {
        let announcement = AnnouncementPacket(
            nickname: nickname,
            noisePublicKey: noiseKey,
            signingPublicKey: signer.noise.getSigningPublicKeyData(),
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode())
        let sender = PeerID(publicKey: noiseKey)
        return try #require(signer.noise.signPacket(BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: nil,
            timestamp: AnnounceClock.shared.next(),
            payload: payload,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )))
    }
}

/// Strictly increasing milliseconds, so two announces never collide in the
/// deduplicator (its key is sender, timestamp and type).
private final class AnnounceClock: @unchecked Sendable {
    static let shared = AnnounceClock()
    private let lock = NSLock()
    private var last: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        last = max(last + 1, UInt64(Date().timeIntervalSince1970 * 1000))
        return last
    }
}

private func makeService() -> BLEService {
    let keychain = MockKeychain()
    let identityManager = MockIdentityManager(keychain)
    let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
    return BLEService(keychain: keychain, idBridge: idBridge, identityManager: identityManager)
}

/// Thread-safe sink for `_test_outboundObserver`.
private final class OutboundSink: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [BitchatPacket] = []

    func append(_ packet: BitchatPacket) {
        lock.lock(); packets.append(packet); lock.unlock()
    }

    func handshakes(to peerID: PeerID) -> [BitchatPacket] {
        lock.lock(); defer { lock.unlock() }
        return packets.filter {
            $0.type == MessageType.noiseHandshake.rawValue && PeerID(hexData: $0.recipientID) == peerID
        }
    }
}
