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

    /// Every packet type authenticates its own sender (#244 accepted only
    /// announces, so relayed messages, handshakes and DMs from anyone but the
    /// link peer were dropped as "spoofing": 1,353 on one iPhone on
    /// 2026-10-29).
    @Test
    func linkSenderPolicy_acceptsRelayedPacketsOfEveryTypeButRequestSync() {
        let relayedTypes: [UInt8] = [
            MessageType.announce.rawValue,
            SonarAnnouncePacket.packetType,
            MessageType.message.rawValue,
            MessageType.noiseHandshake.rawValue,
            MessageType.noiseEncrypted.rawValue,
            MessageType.fragment.rawValue,
            MessageType.fileTransfer.rawValue,
            MessageType.leave.rawValue,
        ]
        for type in relayedTypes {
            for ttl in 1..<TransportConfig.messageTTLDefault {
                #expect(MeshLinkSenderPolicy.allowsRelayedPacket(type: type, ttl: ttl, isRSR: false, senderIsSelf: false),
                        "type \(type) at TTL \(ttl) is a relay")
            }
        }
        for ttl in 0...TransportConfig.messageTTLDefault {
            #expect(!MeshLinkSenderPolicy.allowsRelayedPacket(type: MessageType.requestSync.rawValue, ttl: ttl, isRSR: false, senderIsSelf: false),
                    "REQUEST_SYNC is never relayed: it asks for a store replay to whoever the sender claims")
        }
    }

    @Test
    func linkSenderPolicy_neverTreatsFullTtlAsRelayed() {
        #expect(!MeshLinkSenderPolicy.allowsRelayedPacket(
            type: MessageType.announce.rawValue,
            ttl: TransportConfig.messageTTLDefault,
            isRSR: false,
            senderIsSelf: false
        ))
        #expect(!MeshLinkSenderPolicy.allowsRelayedPacket(
            type: SonarAnnouncePacket.packetType,
            ttl: TransportConfig.messageTTLDefault,
            isRSR: false,
            senderIsSelf: false
        ))
        #expect(!MeshLinkSenderPolicy.allowsRelayedPacket(
            type: MessageType.message.rawValue,
            ttl: TransportConfig.messageTTLDefault,
            isRSR: false,
            senderIsSelf: false
        ), "a relay decrements the TTL before forwarding")
    }

    /// TTL 0 is a sync reply. Stock bitchat-android sends its replies
    /// without the RSR flag (SPEC §12.1), so an unflagged one from another
    /// sender is accepted; our own packet comes back only flagged, because an
    /// unflagged copy would be shown as sent by us without a signature check.
    @Test
    func linkSenderPolicy_acceptsOurOwnPacketsBackOnlyAsAFlaggedSyncReply() {
        for isRSR in [false, true] {
            #expect(MeshLinkSenderPolicy.allowsRelayedPacket(type: MessageType.announce.rawValue, ttl: 0, isRSR: isRSR, senderIsSelf: false))
            #expect(MeshLinkSenderPolicy.allowsRelayedPacket(type: MessageType.message.rawValue, ttl: 0, isRSR: isRSR, senderIsSelf: false))
        }
        #expect(MeshLinkSenderPolicy.allowsRelayedPacket(type: MessageType.message.rawValue, ttl: 0, isRSR: true, senderIsSelf: true))
        #expect(!MeshLinkSenderPolicy.allowsRelayedPacket(type: MessageType.message.rawValue, ttl: 0, isRSR: false, senderIsSelf: true))
        #expect(!MeshLinkSenderPolicy.allowsRelayedPacket(type: MessageType.message.rawValue, ttl: 1, isRSR: false, senderIsSelf: true))
        #expect(!MeshLinkSenderPolicy.allowsRelayedPacket(type: MessageType.requestSync.rawValue, ttl: 0, isRSR: true, senderIsSelf: false))
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
    func linkSenderPolicy_letsASecondAppOnTheDeviceAskToJoinTheLink() {
        let bound = PeerID(str: "1111111111111111")
        let other = PeerID(str: "2222222222222222")
        let link = MeshLinkIdentities(primary: bound, at: Date())
        let full = TransportConfig.messageTTLDefault

        #expect(MeshLinkSenderPolicy.ingress(claimed: bound, link: link, type: MessageType.message.rawValue, ttl: full, isRSR: false, senderIsSelf: false) == .trusted)
        #expect(MeshLinkSenderPolicy.ingress(claimed: other, link: link, type: MessageType.announce.rawValue, ttl: full, isRSR: false, senderIsSelf: false) == .candidateDirectIdentity)
        #expect(MeshLinkSenderPolicy.ingress(claimed: other, link: link, type: MessageType.announce.rawValue, ttl: full - 1, isRSR: false, senderIsSelf: false) == .relayed)
        #expect(MeshLinkSenderPolicy.ingress(claimed: other, link: link, type: MessageType.noiseHandshake.rawValue, ttl: full - 1, isRSR: false, senderIsSelf: false) == .relayed)
        #expect(MeshLinkSenderPolicy.ingress(claimed: other, link: link, type: MessageType.noiseHandshake.rawValue, ttl: full, isRSR: false, senderIsSelf: false) == .reject)
        #expect(MeshLinkSenderPolicy.ingress(claimed: other, link: link, type: MessageType.requestSync.rawValue, ttl: full - 1, isRSR: false, senderIsSelf: false) == .reject)
        #expect(MeshLinkSenderPolicy.ingress(claimed: other, link: link, type: SonarAnnouncePacket.packetType, ttl: full, isRSR: false, senderIsSelf: false) == .reject,
                "only a 0x01 announce can prove a new identity; 0x53 is verified against its key")
    }

    @Test
    func linkSenderPolicy_trustsAnIdentityOnceItJoined() {
        let bound = PeerID(str: "1111111111111111")
        let other = PeerID(str: "2222222222222222")
        var link = MeshLinkIdentities(primary: bound, at: Date())
        link.noteDirectAnnounce(from: other, at: Date())

        #expect(MeshLinkSenderPolicy.ingress(claimed: other, link: link, type: MessageType.noiseHandshake.rawValue, ttl: TransportConfig.messageTTLDefault, isRSR: false, senderIsSelf: false) == .trusted)
        #expect(link.identities == [bound, other])
        #expect(link.primary == bound, "joining never rebinds the link")
    }

    @Test
    func linkIdentities_vouchForEachAppOnlyWhileItAnnounces() {
        let window: TimeInterval = 100
        let now = Date()
        let bound = PeerID(str: "1111111111111111")
        let other = PeerID(str: "2222222222222222")

        var single = MeshLinkIdentities(primary: bound, at: now.addingTimeInterval(-10 * window))
        #expect(single.vouches(for: bound, now: now, window: window), "one app: the link vouches while it is up")

        single.noteDirectAnnounce(from: other, at: now)
        #expect(single.isShared)
        #expect(!single.vouches(for: bound, now: now, window: window), "shared: a silent app is not vouched for")
        #expect(single.vouches(for: other, now: now, window: window))
        #expect(single.vouchedPeers(now: now, window: window) == [other])

        single.noteDirectAnnounce(from: bound, at: now)
        #expect(single.vouchedPeers(now: now, window: window) == [bound, other])
        #expect(!single.vouches(for: PeerID(str: "3333333333333333"), now: now, window: window))
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
