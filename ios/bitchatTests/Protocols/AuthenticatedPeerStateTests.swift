import XCTest
@testable import Sonar

/// Mirrors `core/bitchat-protocol/src/peer_state.rs` and the capability
/// tests in `announce.rs`: the two platforms must agree on every byte of the
/// Noise 0x21 payload and the announce TLV 0x05, or a capability one side
/// proves is one the other never sees.
final class AuthenticatedPeerStateTests: XCTestCase {

    // MARK: - PeerCapabilities wire form

    func testCapabilitiesEncodingIsMinimalLittleEndian() {
        XCTAssertEqual(PeerCapabilities(rawValue: 0).encoded(), Data([0]))
        XCTAssertEqual(PeerCapabilities(rawValue: 1).encoded(), Data([1]))
        XCTAssertEqual(PeerCapabilities(rawValue: 0x100).encoded(), Data([0, 1]))
        XCTAssertEqual(PeerCapabilities(rawValue: 0x301).encoded(), Data([1, 3]))
        XCTAssertEqual(PeerCapabilities(rawValue: 0x10000).encoded(), Data([0, 0, 1]))
        XCTAssertEqual(PeerCapabilities(rawValue: UInt64.max).encoded(), Data(repeating: 0xFF, count: 8))

        XCTAssertEqual(PeerCapabilities(encoded: Data()), PeerCapabilities(rawValue: 0))
        XCTAssertEqual(PeerCapabilities(encoded: Data(repeating: 0xFF, count: 9)), PeerCapabilities(rawValue: UInt64.max))
        XCTAssertEqual(PeerCapabilities(encoded: Data([0, 1])), .privateMedia)

        XCTAssertTrue(PeerCapabilities.isCanonical(Data([0, 1])))
        XCTAssertFalse(PeerCapabilities.isCanonical(Data([0, 1, 0])), "trailing zero is not minimal")
        XCTAssertFalse(PeerCapabilities.isCanonical(Data()))
        XCTAssertFalse(PeerCapabilities.isCanonical(Data(repeating: 1, count: 9)))

        XCTAssertTrue(PeerCapabilities(rawValue: 0x300).contains(.privateMedia))
        XCTAssertFalse(PeerCapabilities(rawValue: 0x200).contains(.privateMedia))
        // The bits this build advertises: 8 and 9 → 0x300 → [0x00, 0x03].
        XCTAssertEqual(PeerCapabilities.sonarLocal.encoded(), Data([0x00, 0x03]))
    }

    // MARK: - AuthenticatedPeerStatePacket (Noise 0x21)

    private let key = Data(repeating: 7, count: 32)

    func testRoundTripAndExactBytes() throws {
        let state = AuthenticatedPeerStatePacket(capabilities: .privateMedia, signingPublicKey: key)
        let bytes = try XCTUnwrap(state.encode())
        // version, caps TLV (type 1, len 2, 0x0100 LE), key TLV header
        XCTAssertEqual(Array(bytes.prefix(5)), [0x01, 0x01, 0x02, 0x00, 0x01])
        XCTAssertEqual(bytes[5], 0x02)
        XCTAssertEqual(bytes[6], 32)
        XCTAssertEqual(bytes.count, 1 + 4 + 2 + 32)
        XCTAssertEqual(AuthenticatedPeerStatePacket.decode(from: bytes), state)
    }

    func testUnknownTLVIsSkipped() throws {
        let state = AuthenticatedPeerStatePacket(capabilities: .privateMedia, signingPublicKey: key)
        var bytes = try XCTUnwrap(state.encode())
        bytes.append(contentsOf: [0x7F, 1, 0xAA])
        XCTAssertEqual(AuthenticatedPeerStatePacket.decode(from: bytes), state)
    }

    func testStrictDecodeRejectsMalformedInput() throws {
        let state = AuthenticatedPeerStatePacket(capabilities: .privateMedia, signingPublicKey: key)
        let bytes = try XCTUnwrap(state.encode())

        // Unknown version.
        var v2 = bytes
        v2[0] = 2
        XCTAssertNil(AuthenticatedPeerStatePacket.decode(from: v2))

        // Non-canonical capabilities (0x100 as three bytes).
        var nonCanonical = Data([0x01, 0x01, 0x03, 0x00, 0x01, 0x00])
        nonCanonical.append(contentsOf: [0x02, 32])
        nonCanonical.append(key)
        XCTAssertNil(AuthenticatedPeerStatePacket.decode(from: nonCanonical))

        // Duplicate key TLV.
        var dup = bytes
        dup.append(bytes[5...])
        XCTAssertNil(AuthenticatedPeerStatePacket.decode(from: dup))

        // 31-byte key.
        var shortKey = Data([0x01, 0x01, 0x02, 0x00, 0x01, 0x02, 31])
        shortKey.append(Data(repeating: 7, count: 31))
        XCTAssertNil(AuthenticatedPeerStatePacket.decode(from: shortKey))

        // Missing signing key, missing capabilities, empty, truncated TLV.
        XCTAssertNil(AuthenticatedPeerStatePacket.decode(from: bytes.prefix(5)))
        var noCaps = Data([0x01, 0x02, 32])
        noCaps.append(key)
        XCTAssertNil(AuthenticatedPeerStatePacket.decode(from: noCaps))
        XCTAssertNil(AuthenticatedPeerStatePacket.decode(from: Data()))
        XCTAssertNil(AuthenticatedPeerStatePacket.decode(from: Data([0x01, 0x01])))
        var overrun = bytes
        overrun[6] = 40
        XCTAssertNil(AuthenticatedPeerStatePacket.decode(from: overrun))
    }

    func testEncodeRefusesBadKeyLength() {
        XCTAssertNil(AuthenticatedPeerStatePacket(capabilities: .privateMedia, signingPublicKey: Data(repeating: 1, count: 31)).encode())
    }

    // MARK: - Announce TLV 0x05 / 0x06

    func testAnnounceCarriesCapabilitiesAndBridgeGeohash() throws {
        var announce = AnnouncementPacket(
            nickname: "carol",
            noisePublicKey: Data(repeating: 5, count: 32),
            signingPublicKey: Data(repeating: 6, count: 32),
            directNeighbors: [Data(repeating: 1, count: 8), Data(repeating: 2, count: 8)]
        )
        announce.capabilities = PeerCapabilities(rawValue: 0x301)
        announce.bridgeGeohash = "u4pruyd"
        let bytes = try XCTUnwrap(announce.encode())
        // nickname(2+5) noise(2+32) signing(2+32) neighbors(2+16) caps(2+2) geo(2+7)
        XCTAssertEqual(bytes.count, 7 + 34 + 34 + 18 + 4 + 9)
        let capsAt = 7 + 34 + 34 + 18
        XCTAssertEqual(Array(bytes[capsAt..<capsAt + 4]), [0x05, 2, 0x01, 0x03])
        XCTAssertEqual(Array(bytes[(capsAt + 4)..<(capsAt + 6)]), [0x06, 7])

        let decoded = try XCTUnwrap(AnnouncementPacket.decode(from: bytes))
        XCTAssertEqual(decoded.nickname, "carol")
        XCTAssertEqual(decoded.capabilities, PeerCapabilities(rawValue: 0x301))
        XCTAssertEqual(decoded.bridgeGeohash, "u4pruyd")
        XCTAssertEqual(decoded.directNeighbors?.count, 2)
    }

    func testAnnounceWithoutOptionalTLVsDecodesNilCapabilities() throws {
        let announce = AnnouncementPacket(
            nickname: "x",
            noisePublicKey: Data(repeating: 1, count: 32),
            signingPublicKey: Data(repeating: 2, count: 32),
            directNeighbors: nil
        )
        let bytes = try XCTUnwrap(announce.encode())
        XCTAssertEqual(bytes.count, 3 + 34 + 34)
        let decoded = try XCTUnwrap(AnnouncementPacket.decode(from: bytes))
        XCTAssertNil(decoded.capabilities)
        XCTAssertNil(decoded.bridgeGeohash)
        // An over-long geohash is skipped on encode, not fatal.
        var tooLong = announce
        tooLong.bridgeGeohash = String(repeating: "a", count: 13)
        XCTAssertEqual(tooLong.encode()?.count, bytes.count)
    }

    // MARK: - Noise payload type aliases

    func testPrereleasePrivateFileAliasDecodesButIsNeverEmitted() {
        XCTAssertEqual(NoisePayloadType.decoded(rawValue: 0x09), .privateFile)
        XCTAssertEqual(NoisePayloadType.decoded(rawValue: 0x20), .privateFile)
        XCTAssertEqual(NoisePayloadType.decoded(rawValue: 0x21), .authenticatedPeerState)
        XCTAssertNil(NoisePayloadType.decoded(rawValue: 0x7F))
        XCTAssertEqual(NoisePayloadType.privateFile.rawValue, 0x20)
        XCTAssertTrue(NoisePayloadType.isPrivateFile(rawValue: 0x09))
        XCTAssertTrue(NoisePayloadType.isPrivateFile(rawValue: 0x20))
        XCTAssertFalse(NoisePayloadType.isPrivateFile(rawValue: 0x01))
        XCTAssertFalse(NoisePayloadType.isPrivateFile(rawValue: nil))
        XCTAssertEqual(NoisePayload.decode(Data([0x09, 0xAB]))?.type, .privateFile)
    }
}
