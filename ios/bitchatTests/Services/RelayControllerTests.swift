//
// RelayControllerTests.swift
// bitchatTests
//
// Tests for relay decision logic.
//

import Testing
import Foundation
@testable import Sonar

struct RelayControllerTests {

    @Test
    func linkSenderPolicy_acceptsOnlyRelayedIdentityPackets() {
        #expect(MeshLinkSenderPolicy.allowsRelayedIdentityPacket(
            type: MessageType.announce.rawValue,
            ttl: TransportConfig.messageTTLDefault - 1
        ))
        #expect(MeshLinkSenderPolicy.allowsRelayedIdentityPacket(
            type: SonarAnnouncePacket.packetType,
            ttl: TransportConfig.messageTTLDefault - 1
        ))
        #expect(!MeshLinkSenderPolicy.allowsRelayedIdentityPacket(
            type: MessageType.noiseHandshake.rawValue,
            ttl: TransportConfig.messageTTLDefault - 1
        ))
        #expect(!MeshLinkSenderPolicy.allowsRelayedIdentityPacket(
            type: MessageType.announce.rawValue,
            ttl: TransportConfig.messageTTLDefault
        ))
    }

    @Test
    func linkSenderPolicy_neverTreatsFullTtlAsRelayedIdentity() {
        #expect(!MeshLinkSenderPolicy.allowsRelayedIdentityPacket(
            type: MessageType.announce.rawValue,
            ttl: TransportConfig.messageTTLDefault
        ))
        #expect(!MeshLinkSenderPolicy.allowsRelayedIdentityPacket(
            type: SonarAnnouncePacket.packetType,
            ttl: TransportConfig.messageTTLDefault
        ))
        #expect(!MeshLinkSenderPolicy.allowsRelayedIdentityPacket(
            type: MessageType.announce.rawValue,
            ttl: 0
        ))
    }

    @Test
    func linkSenderPolicy_pinsSigningKeyForKnownIdentity() {
        let original = Data([0x01, 0x02])
        #expect(MeshLinkSenderPolicy.preservesSigningIdentity(existing: nil, announced: original))
        #expect(MeshLinkSenderPolicy.preservesSigningIdentity(existing: original, announced: original))
        #expect(!MeshLinkSenderPolicy.preservesSigningIdentity(
            existing: original,
            announced: Data([0x03, 0x04])
        ))
    }

    @Test
    func linkSenderPolicy_dropsLoopedPacketsButDoesNotMisclassifySyncReplay() {
        #expect(MeshLinkSenderPolicy.isSelfEcho(senderIsSelf: true, ttl: 6))
        #expect(!MeshLinkSenderPolicy.isSelfEcho(senderIsSelf: true, ttl: 0))
        #expect(!MeshLinkSenderPolicy.isSelfEcho(senderIsSelf: false, ttl: 6))
    }

    @Test
    func ttlOne_doesNotRelay() async {
        let decision = RelayController.decide(
            ttl: 1,
            senderIsSelf: false,
            isEncrypted: false,
            isDirectedEncrypted: false,
            isFragment: false,
            isDirectedFragment: false,
            isHandshake: false,
            isAnnounce: false,
            degree: 0,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )

        #expect(!decision.shouldRelay)
        #expect(decision.newTTL == 1)
    }

    @Test
    func handshake_alwaysRelaysWithTTLDecrement() async {
        let decision = RelayController.decide(
            ttl: 3,
            senderIsSelf: false,
            isEncrypted: false,
            isDirectedEncrypted: false,
            isFragment: false,
            isDirectedFragment: false,
            isHandshake: true,
            isAnnounce: false,
            degree: 3,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )

        #expect(decision.shouldRelay)
        #expect(decision.newTTL == 2)
        #expect(decision.delayMs >= 10 && decision.delayMs <= 35)
    }

    @Test
    func fragment_relaysWithFragmentCap() async {
        let decision = RelayController.decide(
            ttl: 10,
            senderIsSelf: false,
            isEncrypted: false,
            isDirectedEncrypted: false,
            isFragment: true,
            isDirectedFragment: false,
            isHandshake: false,
            isAnnounce: false,
            degree: 3,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )

        let ttlCap = min(UInt8(10), TransportConfig.bleFragmentRelayTtlCap)
        let expected = ttlCap &- 1

        #expect(decision.shouldRelay)
        #expect(decision.newTTL == expected)
        #expect(decision.delayMs >= TransportConfig.bleFragmentRelayMinDelayMs)
        #expect(decision.delayMs <= TransportConfig.bleFragmentRelayMaxDelayMs)
    }

    @Test
    func denseGraph_capsTTL() async {
        let decision = RelayController.decide(
            ttl: 10,
            senderIsSelf: false,
            isEncrypted: false,
            isDirectedEncrypted: false,
            isFragment: false,
            isDirectedFragment: false,
            isHandshake: false,
            isAnnounce: false,
            degree: TransportConfig.bleHighDegreeThreshold,
            highDegreeThreshold: TransportConfig.bleHighDegreeThreshold
        )

        #expect(decision.shouldRelay)
        #expect(decision.newTTL == 4)
    }
}
