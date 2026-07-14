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
    func linkSenderPolicy_rebindsOnlyVerifiedFullTtlAnnounces() {
        #expect(MeshLinkSenderPolicy.allowsDirectIdentityRebind(
            type: MessageType.announce.rawValue,
            ttl: TransportConfig.messageTTLDefault,
            identityVerified: true
        ))
        #expect(!MeshLinkSenderPolicy.allowsDirectIdentityRebind(
            type: MessageType.announce.rawValue,
            ttl: TransportConfig.messageTTLDefault,
            identityVerified: false
        ))
        #expect(!MeshLinkSenderPolicy.allowsDirectIdentityRebind(
            type: MessageType.noiseHandshake.rawValue,
            ttl: TransportConfig.messageTTLDefault,
            identityVerified: true
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
